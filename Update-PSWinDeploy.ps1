#Requires -Version 5.1
<#
.SYNOPSIS
    Update-PSWinDeploy.ps1 -- Mise a jour de PSWinDeploy
.DESCRIPTION
    Met a jour les fichiers "code" sans toucher a la configuration :
      PRESERVES : PSWinDeploy.psd1, secrets.vault, Profiles\, Sequences\,
                  Catalogue\, Shares\, WinPE\ISO\

      MIS A JOUR : Modules\, Scripts\, API\, Web\, scripts racine
.PARAMETER InstallPath  Dossier d installation (detecte auto).
.PARAMETER SourcePath   Dossier source extrait. Si absent, demande interactivement.
.PARAMETER ArchivePath  Chemin vers le .zip. Extrait automatiquement.
.PARAMETER Force        Tout mettre a jour sans demander.
.PARAMETER DryRun       Simuler sans modifier.
.PARAMETER All          Mettre a jour tout sans confirmation individuelle.
.EXAMPLE
    .\Update-PSWinDeploy.ps1                                    # Interactif
    .\Update-PSWinDeploy.ps1 -ArchivePath 'D:\PSW_v0.7.0.zip'  # Depuis archive
    .\Update-PSWinDeploy.ps1 -All                               # Tout sans confirmation
    .\Update-PSWinDeploy.ps1 -DryRun                            # Simulation
#>

[CmdletBinding()]
param(
    [string]$InstallPath = '',
    [string]$SourcePath  = '',
    [string]$ArchivePath = '',
    [switch]$Force,
    [switch]$DryRun,
    [switch]$All        # Mettre a jour TOUT sans confirmation individuelle
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$T)
    $w=58
    Write-Host ""
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    $p=' '*[Math]::Max(0,[Math]::Floor(($w-$T.Length)/2))
    $r=' '*[Math]::Max(0,$w-$T.Length-$p.Length)
    Write-Host "  |$p$T$r|" -ForegroundColor Cyan
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }
function Write-Skip { param([string]$M) Write-Host "  [-]  $M" -ForegroundColor DarkGray }
function Write-Dry  { param([string]$M) Write-Host "  [~]  [DRY] $M" -ForegroundColor DarkYellow }

function Read-YesNo {
    param([string]$Q, [bool]$Def=$true)
    Write-Host "  [?]  $Q [$(if($Def){'O/n'}else{'o/N'})] : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Def }
    return $a.Trim().ToLower() -in @('o','oui','y','yes')
}

function Get-FileVersion {
    param([string]$PsdPath)
    if (-not (Test-Path $PsdPath -ErrorAction SilentlyContinue)) { return '0.0.0' }
    try { $d = Import-PowerShellDataFile $PsdPath; return $d.Version } catch { return '0.0.0' }
}

function Get-MD5 {
    param([string]$Path)
    try { return (Get-FileHash $Path -Algorithm MD5 -ErrorAction SilentlyContinue).Hash }
    catch { return '' }
}

function Copy-Updated {
    <#
    Copie src vers dst si le hash MD5 est different (contenu change).
    Avec -Force : copie toujours sans verifier le hash.
    #>
    param([string]$Src, [string]$Dst, [switch]$DryRun, [switch]$ForceCopy)
    if (-not (Test-Path $Src)) { return $false }

    $needsCopy = $false
    $reason    = ''
    if ($ForceCopy) {
        $needsCopy = $true
        $reason    = 'force'
    } elseif (-not (Test-Path $Dst)) {
        $needsCopy = $true
        $reason = 'nouveau'
    } else {
        # Comparaison rapide taille d'abord, hash seulement si tailles identiques
        $srcInfo = Get-Item $Src
        $dstInfo = Get-Item $Dst
        if ($srcInfo.Length -ne $dstInfo.Length) {
            $needsCopy = $true
            $reason    = 'taille differente'
        } else {
            # Tailles egales -- comparer le hash pour etre sur
            if ((Get-MD5 $Src) -ne (Get-MD5 $Dst)) {
                $needsCopy = $true
                $reason    = 'contenu modifie'
            }
        }
    }

    if (-not $needsCopy) { return $false }

    if ($DryRun) {
        Write-Dry "$reason : $(Split-Path $Dst -Leaf)"
        return $true
    }

    $dstDir = Split-Path $Dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory $dstDir -Force | Out-Null }
    Copy-Item $Src $Dst -Force
    return $true
}

function Sync-FileGroup {
    <# Synchronise un dossier source vers dest. Retourne @{Updated=n; Skipped=n; Total=n} #>
    param(
        [string]$Label,
        [string]$SrcDir,
        [string]$DstDir,
        [string[]]$Include,
        [string[]]$Exclude = @(),
        [switch]$Recurse,
        [switch]$DryRun
    )
    if (-not (Test-Path $SrcDir)) {
        Write-Skip "$Label : source absente"
        return @{ Updated=0; Skipped=0; Total=0; Label=$Label }
    }

    # PS bug : -Include sans -Recurse sur un dossier retourne 0 resultats
    # Solution : utiliser Join-Path $SrcDir '*' pour forcer la liste des fichiers
    $srcGlob = if ($Recurse) { $SrcDir } else { Join-Path $SrcDir '*' }
    $files = @(Get-ChildItem $srcGlob -Include $Include -Recurse:$Recurse -ErrorAction SilentlyContinue |
               Where-Object { -not $_.PSIsContainer })
    if ($Exclude) {
        $files = $files | Where-Object { $name=$_.Name; -not ($Exclude | Where-Object { $name -like $_ }) }
    }

    $updated = 0; $skipped = 0
    foreach ($file in $files) {
        $rel     = $file.FullName.Substring($SrcDir.Length).TrimStart('\','/')
        $dstFile = Join-Path $DstDir $rel
        if (Copy-Updated -Src $file.FullName -Dst $dstFile -DryRun:$DryRun -ForceCopy:$Force) {
            $updated++
            if (-not $DryRun) { Write-OK "  $rel" }
        } else { $skipped++ }
    }

    if ($updated -gt 0) {
        Write-Info "$Label : $updated mis a jour, $skipped inchange(s) ($($files.Count) total)"
    } else {
        Write-Skip "$Label : $($files.Count) fichier(s) -- deja a jour"
    }
    return @{ Updated=$updated; Skipped=$skipped; Total=$files.Count; Label=$Label }
}

# ---------------------------------------------------------------------------
# DETECTION INSTALLATION / SOURCE
# ---------------------------------------------------------------------------

function Test-IsInstall { param([string]$D)
    if (-not (Test-Path $D -EA SilentlyContinue)) { return $false }
    return (Test-Path (Join-Path $D 'Shares') -EA SilentlyContinue) -or
           (Test-Path (Join-Path $D 'Deploy') -EA SilentlyContinue) -or
           (Test-Path (Join-Path $D 'Start-API.ps1') -EA SilentlyContinue) -or
           (Test-Path (Join-Path $D 'Build-WinPE.ps1') -EA SilentlyContinue)
}

function Test-IsSource { param([string]$D)
    if (-not (Test-Path $D -EA SilentlyContinue)) { return $false }
    $hasCode = (Test-Path (Join-Path $D 'Modules') -EA SilentlyContinue) -or
               (Test-Path (Join-Path $D 'App\Modules') -EA SilentlyContinue)
    $hasInst = (Test-Path (Join-Path $D 'Shares') -EA SilentlyContinue) -or
               (Test-Path (Join-Path $D 'Start-API.ps1') -EA SilentlyContinue)
    return $hasCode -and -not $hasInst
}

# ---------------------------------------------------------------------------
# BANNIERE
# ---------------------------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "        PSWinDeploy -- Mise a jour                          " -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""
if ($DryRun) { Write-Host "  SIMULATION MODE -- No file will be modified" -ForegroundColor DarkYellow; Write-Host "" }

# ---------------------------------------------------------------------------
# DETECTION INSTALLPATH
# ---------------------------------------------------------------------------

$scriptDir = Split-Path $PSCommandPath -Parent

# Cas 1 : parametre explicite
if ($InstallPath) { $InstallPath = $InstallPath.TrimEnd('\').Trim('"').Trim("'") }

# Cas 2 : lance depuis l'installation
if (-not $InstallPath -and (Test-IsInstall $scriptDir)) {
    $InstallPath = $scriptDir
    Write-Info "Installation detectee : $InstallPath"
}

# Cas 3 : lance depuis le dossier source -- chercher l'installation
if (-not $InstallPath -and (Test-IsSource $scriptDir)) {
    Write-Warn "Ce dossier semble etre une source (pas une installation)."
    Write-Info "Recherche des installations PSWinDeploy sur les lecteurs..."
    $candidates = @()
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue | Select-Object -ExpandProperty Name)) {
        foreach ($name in @('PSWinDeploy','PSWIndex','Deploy')) {
            $c = "${drive}:\$name"
            if (Test-IsInstall $c) { $candidates += $c }
        }
    }
    if ($candidates.Count -gt 0) {
        Write-Info "Installations trouvees :"
        for ($ci=0;$ci -lt $candidates.Count;$ci++) {
            $v = Get-FileVersion (Join-Path $candidates[$ci] 'PSWinDeploy.psd1')
            Write-Host "    [$($ci+1)] $($candidates[$ci])  (v$v)" -ForegroundColor Gray
        }
        Write-Host "    [0] Saisir manuellement" -ForegroundColor DarkGray
        Write-Host "  [?]  Choix : " -ForegroundColor White -NoNewline
        $ci = (Read-Host).Trim()
        if ($ci -match '^\d+$' -and [int]$ci -ge 1 -and [int]$ci -le $candidates.Count) {
            $InstallPath = $candidates[[int]$ci-1]
        }
    }
    if (-not $InstallPath) {
        Write-Host "  [?]  Chemin d installation PSWinDeploy : " -ForegroundColor White -NoNewline
        $InstallPath = (Read-Host).Trim().Trim('"').Trim("'").Trim()
    }
    if (-not $SourcePath) { $SourcePath = $scriptDir }
}

# Cas 4 : rien detecte
if (-not $InstallPath) {
    Write-Host "  [?]  Chemin d installation PSWinDeploy : " -ForegroundColor White -NoNewline
    $InstallPath = (Read-Host).Trim().Trim('"').Trim("'").Trim()
}

$InstallPath = $InstallPath.TrimEnd('\')
if (-not (Test-Path $InstallPath)) { Write-Err "Dossier introuvable : $InstallPath"; exit 1 }

$installedPsd1 = Join-Path $InstallPath 'PSWinDeploy.psd1'
if (-not (Test-Path $installedPsd1)) { $installedPsd1 = Join-Path $InstallPath 'App\PSWinDeploy.psd1' }
$installedVersion = Get-FileVersion $installedPsd1
Write-Info "Installation : $InstallPath  (v$installedVersion)"

# ---------------------------------------------------------------------------
# SOURCE DE MISE A JOUR
# ---------------------------------------------------------------------------

Write-Header "Source de mise a jour"

$tempDir   = $null
$needClean = $false

if ($SourcePath -and -not $ArchivePath) {
    Write-OK "Source : $SourcePath (detectee automatiquement)"
}

if (-not $SourcePath -and -not $ArchivePath) {
    Write-Host "  [1] Fichier archive (.zip)" -ForegroundColor Gray
    Write-Host "  [2] Dossier extrait" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [?]  Source : " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim()

    if ($choice -eq '2') {
        Write-Host "  [?]  Chemin du dossier source : " -ForegroundColor White -NoNewline
        $SourcePath = (Read-Host).Trim().Trim('"').Trim("'").Trim()
    } else {
        # Chercher les zip disponibles
        $zips = @()
        foreach ($dir in @("$env:USERPROFILE\Downloads", $InstallPath, (Split-Path $InstallPath -Parent))) {
            if (Test-Path $dir -EA SilentlyContinue) {
                $zips += @(Get-ChildItem $dir -Filter 'PSWinDeploy_*.zip' -EA SilentlyContinue |
                           Sort-Object LastWriteTime -Descending | Select-Object -First 5)
            }
        }
        if ($zips.Count -gt 0) {
            Write-Info "Archives PSWinDeploy trouvees :"
            for ($i=0;$i -lt $zips.Count;$i++) {
                Write-Host "    [$($i+1)] $($zips[$i].Name)  ($([Math]::Round($zips[$i].Length/1KB)) KB)" -ForegroundColor Gray
            }
            Write-Host "    [0] Saisir manuellement" -ForegroundColor DarkGray
            Write-Host "  [?]  Choix : " -ForegroundColor White -NoNewline
            $c = (Read-Host).Trim()
            if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $zips.Count) {
                $ArchivePath = $zips[[int]$c-1].FullName
            }
        }
        if (-not $ArchivePath) {
            Write-Host "  [?]  Chemin du .zip : " -ForegroundColor White -NoNewline
            $ArchivePath = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        }
    }
}

# Extraction archive
if ($ArchivePath) {
    if (-not (Test-Path $ArchivePath)) { Write-Err "Archive introuvable : $ArchivePath"; exit 1 }
    Unblock-File $ArchivePath -EA SilentlyContinue
    Write-Step "Extraction..."
    $tempDir   = Join-Path $env:TEMP "PSWinDeploy-upd-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $needClean = $true
    try {
        Expand-Archive -Path $ArchivePath -DestinationPath $tempDir -Force
        $extracted = Get-ChildItem $tempDir -Directory | Select-Object -First 1
        $SourcePath = if ($extracted) { $extracted.FullName } else { $tempDir }
        Write-OK "Extrait : $SourcePath"
    } catch { Write-Err "Extraction echouee : $_"; exit 1 }
}

if (-not (Test-Path $SourcePath)) { Write-Err "Source introuvable : $SourcePath"; exit 1 }

$sourcePsd1 = Join-Path $SourcePath 'PSWinDeploy.psd1'
if (-not (Test-Path $sourcePsd1)) { $sourcePsd1 = Join-Path $SourcePath 'App\PSWinDeploy.psd1' }
$sourceVersion = Get-FileVersion $sourcePsd1
Write-OK "Source : $SourcePath  (v$sourceVersion)"

# Verification de version
if ($sourceVersion -ne '0.0.0' -and $installedVersion -ne '0.0.0') {
    try {
        $src = [System.Version]::new(($sourceVersion -replace '[^0-9.]',''))
        $ins = [System.Version]::new(($installedVersion -replace '[^0-9.]',''))
        if ($src -le $ins -and -not $Force -and -not $All) {
            Write-Warn "Source v$sourceVersion <= installee v$installedVersion"
            if (-not (Read-YesNo "Forcer la mise a jour ?" $false)) { Write-Info "Cancelled."; exit 0 }
        } else {
            Write-OK "Mise a jour : v$installedVersion -> v$sourceVersion"
        }
    } catch {}
}

# Chemins App
$srcApp = if (Test-Path (Join-Path $SourcePath 'App\Modules') -EA SilentlyContinue) {
              Join-Path $SourcePath 'App'
          } else { $SourcePath }
$dstApp = if (Test-Path (Join-Path $InstallPath 'App\Modules') -EA SilentlyContinue) {
              Join-Path $InstallPath 'App'
          } else { $InstallPath }

Write-Info "Source App : $srcApp"
Write-Info "Dest   App : $dstApp"

# ---------------------------------------------------------------------------
# SAUVEGARDE
# ---------------------------------------------------------------------------

Write-Header "Backup"

$backupDir = Join-Path $InstallPath "Backup-$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not $DryRun) {
    $doBackup = $Force -or $All -or (Read-YesNo "Create a backup before updating?" $true)
    if ($doBackup) {
        Write-Step "Backing up..."
        New-Item -ItemType Directory $backupDir -Force | Out-Null
        foreach ($item in @('Modules','Scripts','API')) {
            $src2 = Join-Path $dstApp $item
            if (Test-Path $src2) { Copy-Item $src2 (Join-Path $backupDir $item) -Recurse -Force }
        }
        foreach ($f in @('PSWinDeploy-Console.ps1','Initialize-PSWinDeploy.ps1','Unblock-PSWinDeploy.ps1','Update-PSWinDeploy.ps1')) {
            $src2 = Join-Path $InstallPath $f
            if (Test-Path $src2) { Copy-Item $src2 $backupDir -Force }
        }
        Write-OK "Sauvegarde : $backupDir"
    }
} else { Write-Dry "Creerait une sauvegarde dans $backupDir" }

# ---------------------------------------------------------------------------
# CHOIX DU MODE DE MISE A JOUR
# ---------------------------------------------------------------------------

Write-Header "Mode de mise a jour"

$updateAll = $Force -or $All

if (-not $DryRun -and -not $updateAll) {
    Write-Host "  [1] Update everything (recommended)" -ForegroundColor White
    Write-Host "       Modules + Scripts + API + Web + scripts racine" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [2] Choose component by component" -ForegroundColor White
    Write-Host "       Confirmation individuelle pour chaque groupe" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [3] Simulation (DryRun)" -ForegroundColor White
    Write-Host "       Voir ce qui serait mis a jour sans rien modifier" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [?]  Choix [1/2/3] : " -ForegroundColor White -NoNewline
    $modeChoice = (Read-Host).Trim()
    switch ($modeChoice) {
        '1' { $updateAll = $true; $Force = $true }  # Forcer la copie de tous les fichiers
        '3' { $DryRun    = $true; $updateAll = $true }
        default { $updateAll = $false }  # mode selectif
    }
}

# ---------------------------------------------------------------------------
# MISE A JOUR
# ---------------------------------------------------------------------------

Write-Header "Mise a jour des fichiers"
$wimRebuildNeeded = $false

$totalUpdated = 0

$groups = @(
    @{ Label='Modules PS';     SrcDir=Join-Path $srcApp 'Modules'; DstDir=Join-Path $dstApp 'Modules'; Include=@('*.psm1','*.psd1'); Recurse=$true }
    @{ Label='Scripts App';    SrcDir=Join-Path $srcApp 'Scripts'; DstDir=Join-Path $dstApp 'Scripts'; Include=@('*.ps1','*.cmd');   Recurse=$false }
    @{ Label='Scripts racine'; SrcDir=Join-Path $srcApp 'Scripts'; DstDir=Join-Path $InstallPath 'Scripts'; Include=@('*.ps1','*.cmd');   Recurse=$false }
    @{ Label='API Pode';       SrcDir=Join-Path $srcApp 'API';     DstDir=Join-Path $dstApp 'API';     Include=@('*.ps1');           Recurse=$false }
    @{ Label='Interface Web';  SrcDir=Join-Path $srcApp 'Web';     DstDir=Join-Path $dstApp 'Web';     Include=@('*.jsx','*.js','*.html','*.css','*.psd1'); Recurse=$true; Exclude=@('package-lock.json') }
)

foreach ($grp in $groups) {
    $doUpdate = $updateAll

    if (-not $updateAll) {
        $doUpdate = Read-YesNo "Mettre a jour : $($grp.Label) ?" $true
    }

    if ($doUpdate) {
        Write-Step "$($grp.Label)..."
        $params = @{
            Label   = $grp.Label
            SrcDir  = $grp.SrcDir
            DstDir  = $grp.DstDir
            Include = $grp.Include
            Recurse = $grp.Recurse
            DryRun  = $DryRun
        }
        if ($grp.Exclude) { $params.Exclude = $grp.Exclude }
        $result = Sync-FileGroup @params
        $totalUpdated += $result.Updated
            if ($result.Updated -gt 0 -and $grp.Label -match 'Module|Script') { $wimRebuildNeeded = $true }
    } else {
        Write-Skip "$($grp.Label) : ignore"
    }
}

# Scripts racine -- toujours mis a jour si updateAll, sinon demander une seule fois
$doRacine = $updateAll
if (-not $updateAll) { $doRacine = Read-YesNo "Mettre a jour : scripts racine (Console, Initialize, Update, Unblock) ?" $true }
if ($doRacine) {
    Write-Step "Scripts racine..."
    foreach ($fn in @('PSWinDeploy-Console.ps1','Initialize-PSWinDeploy.ps1','Unblock-PSWinDeploy.ps1','Update-PSWinDeploy.ps1','docker-compose.yml')) {
        $srcF = Join-Path $SourcePath $fn
        $dstF = Join-Path $InstallPath $fn
        if (Copy-Updated -Src $srcF -Dst $dstF -DryRun:$DryRun) {
            $totalUpdated++
            if (-not $DryRun) { Write-OK "  $fn" }
        }
    }
}

# -- Sequences et Profiles : NON gerees par Update --
# Decision d'architecture : les sequences/profils sont des DONNEES qui vivent sur
# le PARTAGE (\\serveur\Deploy\Sequences), pas dans l'install. Update ne gere
# que le CODE (Scripts/Modules). Tu deposes les sequences sur le partage toi-meme
# (ou via l'API web plus tard), comme tu deposes les images dans Shares\Images.
# Les sequences livrees d'exemple sont dans le zip (dossier Sequences\) -- a
# copier manuellement dans \\serveur\Deploy\Sequences au besoin.

# Mettre a jour la version dans PSWinDeploy.psd1 de l'installation
# (le psd1 est preserve pour ne pas ecraser la config, mais la version doit refleter la MAJ)
if (-not $DryRun -and $sourceVersion -ne '0.0.0' -and $sourceVersion -ne $installedVersion) {
    try {
        $psdToUpdate = Join-Path $InstallPath 'PSWinDeploy.psd1'
        if (-not (Test-Path $psdToUpdate)) { $psdToUpdate = Join-Path $InstallPath 'App\PSWinDeploy.psd1' }
        if (Test-Path $psdToUpdate) {
            $psdContent = Get-Content $psdToUpdate -Raw
            $psdContent = $psdContent -replace "(Version\s*=\s*')[^']*(')", "`${1}$sourceVersion`$2"
            Set-Content $psdToUpdate $psdContent -Encoding UTF8
            Write-OK "Version mise a jour dans PSWinDeploy.psd1 : $installedVersion -> $sourceVersion"
        }
    } catch { Write-Warn "Mise a jour version psd1 : $_" }
}

# Deblocage Zone.Identifier
if (-not $DryRun -and $totalUpdated -gt 0) {
    Write-Step "Deblocage des fichiers mis a jour..."
    Get-ChildItem $dstApp -Recurse -Include '*.ps1','*.psm1','*.psd1','*.cmd' -EA SilentlyContinue |
        ForEach-Object { Unblock-File $_.FullName -EA SilentlyContinue }
    Get-ChildItem $InstallPath -Filter '*.ps1' -EA SilentlyContinue |
        ForEach-Object { Unblock-File $_.FullName -EA SilentlyContinue }
    Write-OK "Files unblocked"
}

# Fichiers preserves
Write-Host ""
Write-Info "Fichiers PRESERVES (non touches) :"
foreach ($p in @(
    (Join-Path $InstallPath 'PSWinDeploy.psd1'),
    (Join-Path $InstallPath 'Deploy\secrets.vault'),
    (Join-Path $InstallPath 'Shares')
)) {
    if (Test-Path $p -EA SilentlyContinue) { Write-Skip $p }
}

# Nettoyage
if ($needClean -and $tempDir -and (Test-Path $tempDir)) {
    Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue
}

# ---------------------------------------------------------------------------
# RAPPORT FINAL
# ---------------------------------------------------------------------------

Write-Header "Resultat"

if ($DryRun) {
    Write-Info "SIMULATION : $totalUpdated fichier(s) auraient ete mis a jour"
    Write-Info "Relancer sans -DryRun pour appliquer"
} elseif ($totalUpdated -eq 0) {
    Write-OK "Tout est deja a jour -- aucun fichier modifie"
} else {
    Write-OK "$totalUpdated fichier(s) mis a jour  (v$installedVersion -> v$sourceVersion)"
    Write-Host ""
    Write-Info "Actions post-mise a jour :"
    Write-Host "  - Verifier PSWinDeploy.psd1 (nouvelles cles eventuelles)" -ForegroundColor Gray
    if ($wimRebuildNeeded) {
        Write-Host ""
        Write-Warn "  /!\ Modules ou scripts modifies -- RECONSTRUIRE le WinPE :"
        Write-Host "      .\Build-WinPE.ps1" -ForegroundColor Yellow
        Write-Host ""
    }
    Write-Host "  - Redemarrer l'API si modifiee : Start-API.ps1" -ForegroundColor Gray
    Write-Host "  - Redemarrer le Web si modifie : docker-compose restart" -ForegroundColor Gray
    if ($backupDir -and (Test-Path $backupDir -EA SilentlyContinue)) {
        Write-Host ""
        Write-Info "Sauvegarde disponible : $backupDir"
        Write-Info "Supprimer apres validation :"
        Write-Host "  Remove-Item '$backupDir' -Recurse -Force" -ForegroundColor DarkGray
    }
}
Write-Host ""
