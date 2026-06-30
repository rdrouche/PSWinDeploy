#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Export-WIMImage.ps1 -- Extraire une edition Windows depuis un ISO ou WIM/ESD
.DESCRIPTION
    Monte un ISO, liste les editions disponibles via DISM, permet la selection
    et exporte l'edition choisie dans un WIM optimise vers le partage Images.
    Lit automatiquement la destination depuis PSWinDeploy.psd1.
.EXAMPLE
    .\Export-WIMImage.ps1
    .\Export-WIMImage.ps1 -SourceISO 'D:\ISOs\Win11_23H2_FR.iso'
    .\Export-WIMImage.ps1 -SourceISO 'D:\ISOs\Win11.iso' -WimIndex 3
#>

[CmdletBinding()]
param(
    [string]$SourceISO,
    [string]$SourceWIM,
    [int]$WimIndex   = 0,
    [string]$OutputPath,
    [string]$OutputName,
    [switch]$AllEditions,
    [switch]$KeepISOMounted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Title)
    $width = 58
    $line  = '-' * $width
    Write-Host ""
    Write-Host "  +$line+" -ForegroundColor Cyan
    $pad  = [Math]::Max(0, [Math]::Floor(($width - $Title.Length) / 2))
    $padR = [Math]::Max(0, $width - $Title.Length - $pad)
    Write-Host "  |$(' ' * $pad)$Title$(' ' * $padR)|" -ForegroundColor Cyan
    Write-Host "  +$line+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }

function Read-YesNo {
    param([string]$Q, [bool]$Def = $true)
    Write-Host "  [?]  $Q [$(if ($Def) { 'O/n' } else { 'o/N' })] : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Def }
    return $a.Trim().ToLower() -in @('o','oui','y','yes')
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -gt 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -gt 1MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f ($Bytes / 1KB)
}

function Get-WIMEditions {
    <#
    Lit les editions d un WIM/ESD.
    Strategie :
      1. Get-WindowsImage (cmdlet PS natif, aucun probleme d encodage)
      2. Fallback dism.exe si Get-WindowsImage indisponible
    #>
    param([string]$WimPath)

    $images = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ?? Methode 1 : Get-WindowsImage (DISM PS natif, multilingue sans souci) ??
    try {
        $wimImages = Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop
        foreach ($img in $wimImages) {
            $entry = [PSCustomObject]@{
                Index       = $img.ImageIndex
                Name        = $img.ImageName
                Description = $img.ImageDescription
                Size        = $img.ImageSize
                Build       = ''
                Language    = ''
                Edition     = ''
                Flags       = ''
                DisplayName = ''
            }
            # Tenter de lire les details complets (Version, Language, EditionId)
            try {
                $detail = Get-WindowsImage -ImagePath $WimPath -Index $img.ImageIndex -ErrorAction SilentlyContinue
                if ($detail) {
                    if ($detail.Version)  { $entry.Build    = $detail.Version }
                    if ($detail.Languages){ $entry.Language = $detail.Languages[0] }
                    if ($detail.EditionId){ $entry.Edition  = $detail.EditionId }
                }
            } catch {}
            $images.Add($entry)
        }
        Write-Verbose "Get-WindowsImage : $($images.Count) edition(s) lues"

    } catch {
        # ?? Methode 2 : dism.exe en fallback ??????????????????????????????????
        Write-Verbose "Get-WindowsImage indisponible ($_ ) -- fallback dism.exe"

        $prevEncoding = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
        $output = & dism.exe /Get-WimInfo /WimFile:"$WimPath" 2>&1
        try { [Console]::OutputEncoding = $prevEncoding } catch {}

        if ($LASTEXITCODE -ne 0) {
            throw "DISM Get-WimInfo echec (code $LASTEXITCODE) : $($output | Select-Object -Last 3 | Out-String)"
        }

        $current = $null
        foreach ($rawLine in $output) {
            $line = if ($rawLine -is [string]) { $rawLine } else { $rawLine.ToString() }
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Debut de bloc index (espace normal ou insecable avant :)
            if ($line -match '^Index\s*:\s*(\d+)\s*$') {
                if ($null -ne $current) { $images.Add($current) }
                $current = [PSCustomObject]@{
                    Index=([int]$Matches[1]); Name=''; Description=''
                    Size=''; Build=''; Language=''; Edition=''; Flags=''; DisplayName=''
                }
                continue
            }
            if ($null -eq $current) { continue }

            if ($line -match '^([^:]+?)\s*:\s*(.+)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                switch -Regex ($key) {
                    '^(Name|Nom|Nombre|Nome|Naam|Image Name)$' {
                        if (-not $current.Name) { $current.Name = $val }
                    }
                    '^(Description)$' { $current.Description = $val }
                    '^(Size|Taille|Grosse|Groesse|Tamano|Dimensione|Grootte)$' {
                        $current.Size = $val
                    }
                    '^(Version|Build)$'       { $current.Build    = $val }
                    '^(Default Language|Langue par defaut|Standardsprache|Idioma predeterminado)$' {
                        $current.Language = $val
                    }
                    '^(Edition ID|ID d.edition|Editions-ID|Id. de edicion|ID edizione|Editie-id)$' {
                        $current.Edition = $val
                    }
                    '^(Flags|Indicateurs)$'   { $current.Flags    = $val }
                }
            }
        }
        if ($null -ne $current) { $images.Add($current) }
    }

    if ($images.Count -eq 0) {
        throw "Aucune edition trouvee dans $WimPath -- verifier que le fichier est un WIM valide"
    }

    # ?? Fallback nom vide ??????????????????????????????????????????????????????
    foreach ($img in $images) {
        if ([string]::IsNullOrWhiteSpace($img.Name)) {
            $img.Name = if ($img.Edition) { "Windows ($($img.Edition))" }
                        else              { "Edition $($img.Index)" }
        }

        # Build : extraire juste le numero de build depuis la version complete
        # Ex "10.0.26100.1" -> "26100"
        if ($img.Build -match '\d+\.\d+\.(\d+)') {
            $img.Build = $Matches[1]
        }

        # DisplayName enrichi avec edition et GUI/Core
        $editionLabel = switch -Regex ($img.Edition) {
            'ServerDatacenterCore'   { 'Datacenter Core' }
            'ServerDatacenter$'      { 'Datacenter' }
            'ServerStandardCore'     { 'Standard Core' }
            'ServerStandard$'        { 'Standard' }
            'ServerAzureStackHCICore'{ 'Azure Stack HCI Core' }
            'Professional$'          { 'Pro' }
            'ProfessionalN'          { 'Pro N' }
            'Education$'             { 'Education' }
            'EducationN'             { 'Education N' }
            'Enterprise$'            { 'Enterprise' }
            'EnterpriseN'            { 'Enterprise N' }
            'EnterpriseS$'           { 'Enterprise LTSC' }
            'Home$'                  { 'Home' }
            'HomeN'                  { 'Home N' }
            'IoTEnterprise'          { 'IoT Enterprise' }
            default                  { $img.Edition }
        }

        if ($editionLabel -and $img.Name -notmatch [regex]::Escape($editionLabel)) {
            $img.DisplayName = "$($img.Name)  [$editionLabel]"
        } else {
            $img.DisplayName = $img.Name
        }

        # Indicateur GUI pour les serveurs si pas deja dans le nom
        if ($img.Edition -match 'Core$' -and $img.Name -notmatch 'Core') {
            $img.DisplayName += '  [sans GUI]'
        } elseif ($img.Edition -match '^Server' -and $img.Edition -notmatch 'Core' -and $img.Name -notmatch 'experience') {
            $img.DisplayName += '  [avec GUI]'
        }
    }

    return $images
}

function Get-CleanFileName {
    <# Genere un nom de fichier propre depuis le nom d'une edition Windows #>
    param([string]$ImageName, [string]$Language, [string]$Build)

    # Translitterer les accents AVANT nettoyage : en PowerShell \w garde les
    # caracteres accentues Unicode (e, e, a...), ce qui laisserait des accents
    # dans le nom de fichier -> probleme dism en WinPE (console cp850).
    # On normalise donc en ASCII pur.
    # (La normalisation NFD ci-dessous retire les diacritiques ; pas besoin
    # de table de correspondance.)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $ImageName.ToCharArray()) {
        # Decomposer puis retirer les diacritiques (NFD)
        $norm = ([string]$ch).Normalize([Text.NormalizationForm]::FormD)
        $base = ($norm.ToCharArray() | Where-Object {
            [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
        }) -join ''
        [void]$sb.Append($base)
    }
    $asciiName = $sb.ToString()

    # Nettoyer le nom : "Windows 11 Pro" -> "Win11Pro"
    $clean = $asciiName `
        -replace 'Windows\s+',  'Win' `
        -replace '\s+N\s*$',    'N' `
        -replace '\bEducation\b','Edu' `
        -replace '\bEnterprise\b','Ent' `
        -replace '\bProfessional\b','Pro' `
        -replace '\s+',         '_' `
        -replace '[^a-zA-Z0-9_\-]', ''

    $buildStr = if ($Build) {
        # Ex: "10.0.26100.1" -> "26100"
        $parts = $Build -split '\.'
        if ($parts.Count -ge 3) { "_$($parts[2])" } else { "_$Build" }
    } else { '' }

    $langStr = if ($Language) { "_$($Language -replace '-','')" } else { '' }

    return "${clean}${buildStr}${langStr}.wim"
}

# ---------------------------------------------------------------------------
# LECTURE CONFIG PSWINDEX
# ---------------------------------------------------------------------------

$configImageShare = ''
$scriptDir  = Split-Path $PSCommandPath -Parent
$projectRoot = Split-Path $scriptDir -Parent

$cfgPaths = @(
    "$projectRoot\PSWinDeploy.psd1",
    "$scriptDir\PSWinDeploy.psd1",
    "C:\Deploy\PSWinDeploy.psd1",
    "C:\PSWinDeploy\App\PSWinDeploy.psd1"
)
foreach ($cfgPath in $cfgPaths) {
    if (Test-Path $cfgPath) {
        try {
            $cfg = Import-PowerShellDataFile $cfgPath
            if ($cfg.ImageShare) {
                # ImageShare peut etre @{DNS;IP} ou string. Export tourne sur le
                # serveur (domaine) -> prendre DNS, repli IP.
                if ($cfg.ImageShare -is [hashtable]) {
                    $configImageShare = if ($cfg.ImageShare['DNS']) { $cfg.ImageShare['DNS'] } else { $cfg.ImageShare['IP'] }
                } else {
                    $configImageShare = $cfg.ImageShare
                }
                Write-Info "Config : $cfgPath"
                Write-Info "Partage Images : $configImageShare"
            }
        } catch {}
        break
    }
}

# ---------------------------------------------------------------------------
# BANNIERE
# ---------------------------------------------------------------------------

Clear-Host
Write-Header "PSWinDeploy -- Export WIM"
Write-Info "Extrait une edition Windows depuis un ISO ou WIM source."
Write-Info "Produces an optimized .wim file ready for deployment."
Write-Host ""
Write-Host "  ISO Windows --> plusieurs editions --> WIM unique par edition" -ForegroundColor Gray
Write-Host "  Avantages : WIM plus petit, index unique, DISM plus rapide." -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# ETAPE 1 : SOURCE
# ---------------------------------------------------------------------------

Write-Header "Step 1 -- Source"

$wimSourcePath = $null
$isoWasMounted = $false

if ($SourceWIM) {
    if (-not (Test-Path $SourceWIM)) { throw "WIM introuvable : $SourceWIM" }
    $wimSourcePath = $SourceWIM
    Write-OK "WIM source : $wimSourcePath"

} elseif ($SourceISO) {
    if (-not (Test-Path $SourceISO)) { throw "ISO introuvable : $SourceISO" }

} else {
    # Choix interactif
    Write-Host "  [?]  Source: [1] Mount an ISO  [2] Existing WIM/ESD file: " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim().Trim('"').Trim("'").Trim()

    if ($choice -eq '2') {
        Write-Host "  [?]  Chemin WIM ou ESD : " -ForegroundColor White -NoNewline
        $SourceWIM = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        if (-not (Test-Path $SourceWIM)) { throw "Fichier introuvable : $SourceWIM" }
        $wimSourcePath = $SourceWIM
    } else {
        # Chercher les ISO disponibles
        $searchDirs = @(
            (Split-Path $scriptDir -Parent),
            "$env:USERPROFILE\Downloads"
        )
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name.Length -eq 1 })) {
            $searchDirs += "$($drive.Name):\"
        }

        $isos = [System.Collections.Generic.List[object]]::new()
        foreach ($dir in $searchDirs) {
            if (Test-Path $dir -ErrorAction SilentlyContinue) {
                $found = Get-ChildItem $dir -Filter '*.iso' -ErrorAction SilentlyContinue |
                         Select-Object -First 5
                if ($found) { foreach ($f in @($found)) { $isos.Add($f) } }
            }
        }
        $isos = @($isos | Sort-Object LastWriteTime -Descending | Select-Object -First 10)

        if ($isos.Count -gt 0) {
            Write-Info "Fichiers ISO trouves :"
            for ($i = 0; $i -lt $isos.Count; $i++) {
                $sz = Format-Size $isos[$i].Length
                Write-Host "    [$($i+1)] $($isos[$i].FullName)  ($sz)" -ForegroundColor Gray
            }
            Write-Host "    [0] Saisir manuellement" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  [?]  Choix : " -ForegroundColor White -NoNewline
            $isoChoice = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            if ($isoChoice -match '^\d+$' -and [int]$isoChoice -ge 1 -and [int]$isoChoice -le $isos.Count) {
                $SourceISO = $isos[[int]$isoChoice - 1].FullName
            }
        }

        if (-not $SourceISO) {
            Write-Host "  [?]  Chemin ISO Windows : " -ForegroundColor White -NoNewline
            $SourceISO = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        }
        if (-not (Test-Path $SourceISO)) { throw "ISO introuvable : $SourceISO" }
    }
}

# Montage ISO
if ($SourceISO -and -not $wimSourcePath) {
    Write-Step "Montage ISO : $(Split-Path $SourceISO -Leaf)"
    $mountResult  = Mount-DiskImage -ImagePath $SourceISO -PassThru -ErrorAction Stop
    $mountedVol   = $mountResult | Get-Volume
    $isoDrive     = $mountedVol.DriveLetter + ':'
    $isoWasMounted = $true
    Write-OK "Monte sur $isoDrive"

    foreach ($wn in @('install.wim','install.esd','sources\install.wim','sources\install.esd')) {
        $candidate = Join-Path $isoDrive $wn
        if (Test-Path $candidate) { $wimSourcePath = $candidate; break }
    }
    if (-not $wimSourcePath) {
        Dismount-DiskImage -ImagePath $SourceISO | Out-Null
        throw "No install.wim/install.esd in the ISO."
    }
    Write-OK "Image trouvee : $wimSourcePath"
}

# ---------------------------------------------------------------------------
# ETAPE 2 : EDITIONS
# ---------------------------------------------------------------------------

Write-Header "Step 2 -- Available editions"
Write-Step "Lecture via DISM..."

$wimInfo    = @(Get-WIMEditions -WimPath $wimSourcePath)
$wimSizeStr = Format-Size (Get-Item $wimSourcePath).Length

Write-OK "$($wimInfo.Count) edition(s) dans le fichier ($wimSizeStr)"
Write-Host ""

foreach ($img in $wimInfo) {
    $langStr  = if ($img.Language) { "  [$($img.Language)]" } else { '' }
    $buildStr = if ($img.Build) {
        $parts = $img.Build -split '\.'
        # Format : Build 26100 (juste le numero de build, pas la version complete)
        $buildNum = if ($parts.Count -ge 3) { $parts[2] } else { $img.Build }
        "  Build $buildNum"
    } else { '' }

    # Ligne principale : index + DisplayName enrichi + langue + build
    Write-Host "    [$($img.Index)]  $($img.DisplayName)$langStr$buildStr" -ForegroundColor White

    # Description si differente (texte explicatif Microsoft)
    # On ne l'affiche PAS -- trop verbeux et generique (c'est le texte sur GUI vs Core)
    # A la place on affiche Edition ID si present et pas deja dans DisplayName
    if ($img.Edition -and $img.DisplayName -notmatch [regex]::Escape($img.Edition)) {
        Write-Host "         Edition ID : $($img.Edition)" -ForegroundColor DarkGray
    }

    # Taille decompressee
    if ($img.Size) {
        $sizeClean = $img.Size -replace '[^\d]',''
        if ($sizeClean -match '^\d+$') {
            $szBytes = [long]$sizeClean
            Write-Host "         Decompresse : $(Format-Size $szBytes)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# ETAPE 3 : SELECTION
# ---------------------------------------------------------------------------

Write-Header "Etape 3 -- Selection"

$indicesToExport = @()

if ($AllEditions) {
    $indicesToExport = $wimInfo | Select-Object -ExpandProperty Index
    Write-Info "Export de toutes les editions ($($indicesToExport.Count))"

} elseif ($WimIndex -gt 0) {
    if ($WimIndex -notin ($wimInfo | Select-Object -ExpandProperty Index)) {
        throw "Index $WimIndex introuvable. Disponibles : $($wimInfo.Index -join ', ')"
    }
    $indicesToExport = @($WimIndex)

} elseif ($wimInfo.Count -eq 1) {
    $indicesToExport = @($wimInfo[0].Index)
    Write-OK "Une seule edition : $($wimInfo[0].Name) -- selection automatique"

} else {
    $validIdx = $wimInfo | Select-Object -ExpandProperty Index
    Write-Host "  [?]  Index a exporter [$($validIdx -join '/')] : " -ForegroundColor White -NoNewline
    $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
    if ($inp -match '^\d+$' -and [int]$inp -in $validIdx) {
        $indicesToExport = @([int]$inp)
    } else {
        throw "Index invalide : $inp. Valeurs attendues : $($validIdx -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# ETAPE 4 : DESTINATION
# ---------------------------------------------------------------------------

Write-Header "Step 4 -- Destination"

if (-not $OutputPath) {
    if ($configImageShare) {
        # Tester si le partage est accessible
        if (Test-Path $configImageShare -ErrorAction SilentlyContinue) {
            $OutputPath = $configImageShare
            Write-OK "Partage Images PSWinDeploy : $OutputPath"
        } else {
            Write-Warn "Partage configure ($configImageShare) inaccessible"
            Write-Host "  [?]  Dossier de destination [$(Split-Path $wimSourcePath -Parent)] : " -ForegroundColor White -NoNewline
            $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            $OutputPath = if ($inp) { $inp } else { Split-Path $wimSourcePath -Parent }
        }
    } else {
        Write-Host "  [?]  Dossier de destination [$(Split-Path $wimSourcePath -Parent)] : " -ForegroundColor White -NoNewline
        $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        $OutputPath = if ($inp) { $inp } else { Split-Path $wimSourcePath -Parent }
    }
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-OK "Dossier cree : $OutputPath"
}

Write-OK "Destination : $OutputPath"

# --- Proposer un nom de fichier par defaut, modifiable (si 1 seul index) -----
# Si plusieurs index, chaque fichier prend son nom auto (pas de saisie unique).
if (-not $OutputName -and $indicesToExport.Count -eq 1) {
    $imgForName = $wimInfo | Where-Object { $_.Index -eq $indicesToExport[0] } | Select-Object -First 1
    $defaultName = Get-CleanFileName -ImageName $imgForName.Name -Language $imgForName.Language -Build $imgForName.Build
    Write-Host ""
    Write-Host "  Suggested file name: " -ForegroundColor White -NoNewline
    Write-Host $defaultName -ForegroundColor Cyan
    Write-Host "  [?]  Entree pour accepter, ou tapez un autre nom (sans accent) : " -ForegroundColor White -NoNewline
    $nameInput = (Read-Host).Trim().Trim('"').Trim("'").Trim()
    if ($nameInput) {
        # Ajouter .wim si absent
        if ($nameInput -notmatch '\.wim$') { $nameInput = "$nameInput.wim" }
        # Verifier l'absence d'accents / caracteres problematiques
        $hasNonAscii = $false
        foreach ($c in $nameInput.ToCharArray()) { if ([int][char]$c -gt 127) { $hasNonAscii = $true; break } }
        if ($hasNonAscii) {
            Write-Warn "Le nom contient des accents/caracteres speciaux -- ils peuvent poser probleme en WinPE."
            Write-Host "  [?]  Utiliser quand meme ? (o/N) : " -ForegroundColor White -NoNewline
            $confirmAccent = (Read-Host).Trim().ToLower()
            if ($confirmAccent -ne 'o') {
                Write-Info "Nom propose conserve : $defaultName"
                $OutputName = $defaultName
            } else {
                $OutputName = $nameInput
            }
        } else {
            $OutputName = $nameInput
        }
    } else {
        $OutputName = $defaultName
    }
    Write-OK "Nom de sortie : $OutputName"
}

# ---------------------------------------------------------------------------
# ETAPE 5 : EXPORT
# ---------------------------------------------------------------------------

Write-Header "Step 5 -- DISM export"
$exportedFiles = @()

foreach ($idx in $indicesToExport) {
    $imgInfo = $wimInfo | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
    Write-Step "Export [$idx] $($imgInfo.Name)"

    # Nom de fichier de sortie
    if ($OutputName -and $indicesToExport.Count -eq 1) {
        $destName = if ($OutputName -match '\.wim$') { $OutputName } else { "$OutputName.wim" }
    } else {
        $destName = Get-CleanFileName -ImageName $imgInfo.Name -Language $imgInfo.Language -Build $imgInfo.Build
    }
    $destPath = Join-Path $OutputPath $destName

    Write-Info "  -> $destPath"

    if (Test-Path $destPath) {
        Write-Warn "  Fichier existant : $destName"
        if (-not (Read-YesNo "  Ecraser ?" $false)) {
            Write-Info "  Ignore."
            continue
        }
        Remove-Item $destPath -Force
    }

    Write-Info "  Compression Maximum -- patience (10-20 min selon la taille)..."
    Write-Host ""

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $dismArgs = @(
        '/Export-Image',
        "/SourceImageFile:$wimSourcePath",
        "/SourceIndex:$idx",
        "/DestinationImageFile:$destPath",
        '/Compress:maximum'
    )

    & dism.exe @dismArgs | Where-Object {
        $_ -match '\d+\.\d+%|Error|Erreur|succes|success|progress'
    } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    $sw.Stop()

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $destPath)) {
        Write-Err "  Export echoue (code $LASTEXITCODE)"
        continue
    }

    $outSize   = Format-Size (Get-Item $destPath).Length
    $duration  = "$([Math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
    Write-OK "  $($imgInfo.Name)"
    Write-OK "  Fichier : $destPath  ($outSize)  Duree : $duration"
    $exportedFiles += [PSCustomObject]@{ Path = $destPath; Name = $imgInfo.Name; Size = $outSize }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# NETTOYAGE ISO
# ---------------------------------------------------------------------------

if ($isoWasMounted -and -not $KeepISOMounted) {
    Write-Step "Unmounting ISO..."
    Dismount-DiskImage -ImagePath $SourceISO | Out-Null
    Write-OK "ISO demonte"
}

# ---------------------------------------------------------------------------
# RESUME ET MISE A JOUR CATALOGUE
# ---------------------------------------------------------------------------

Write-Header "Resultat"

if ($exportedFiles.Count -eq 0) {
    Write-Warn "No file exported."
} else {
    Write-OK "$($exportedFiles.Count) fichier(s) WIM prets pour PSWinDeploy :"
    foreach ($ef in $exportedFiles) {
        Write-Host "    $($ef.Path)  ($($ef.Size))" -ForegroundColor Green
    }
    Write-Host ""
    Write-Info "Ces WIM sont maintenant disponibles dans le catalogue OS."
    Write-Info "Utiliser Get-AvailableOS ou l'assistant de deploiement pour les voir."
    Write-Host ""

# Generation/mise a jour du catalogue os-catalogue.psd1
if ($configImageShare -and (Test-Path $configImageShare -EA SilentlyContinue)) {
    Write-Step "Generation du catalogue os-catalogue.psd1..."
    try {
        $allWims = @(Get-ChildItem $configImageShare -Filter '*.wim' -EA SilentlyContinue)
        $catLines = @('@{')
        $catLines += "    Generated = '$(Get-Date -Format 'yyyy-MM-dd HH:mm')'"
        $catLines += "    Count     = $($allWims.Count)"
        $catLines += '    Images    = @('
        foreach ($wim in $allWims) {
            $wimName = $wim.BaseName
            $eds = @()
            try { $eds = @(Get-WindowsImage -ImagePath $wim.FullName -EA SilentlyContinue) } catch {}
            if ($eds.Count -gt 0) { $wimName = $eds[0].ImageName }
            $catLines += '        @{'
            $catLines += "            FileName  = '$($wim.Name)'"
            $catLines += "            FullPath  = '$($wim.FullName)'"
            $catLines += "            Name      = '$(($wimName -replace ""'"",""''""))'"
            $catLines += "            SizeGB    = $([Math]::Round($wim.Length/1GB,2))"
            $catLines += '            Editions  = @('
            foreach ($ed in $eds) {
                $catLines += "                @{ Index=$($ed.ImageIndex); Name='$(($ed.ImageName -replace ""'"",""''""))' }"
            }
            $catLines += '            )'
            $catLines += '        }'
        }
        $catLines += '    )'
        $catLines += '}'
        $catalogPath = Join-Path $configImageShare 'os-catalogue.psd1'
        # BOM UTF-8 requis par Import-PowerShellDataFile
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($catalogPath, ($catLines -join "`r`n"), $utf8Bom)
        Write-OK "Catalogue : $catalogPath ($($allWims.Count) image(s))"
    } catch { Write-Warn "Catalogue : $_" }
}
}
