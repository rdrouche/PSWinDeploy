#Requires -Version 5.1
<#
.SYNOPSIS
    PSWinDeploy-Console.ps1 -- Console d'administration PSWinDeploy
.DESCRIPTION
    Point d'entree unique pour toutes les operations PSWinDeploy :
      - Deploiement (assistant, lancement direct)
      - WinPE (build, verification)
      - Images WIM (export, catalogue)
      - Sante du systeme (ADK, partages, vault, WDS)
      - Securite (rotation mots de passe, vault)
      - Profils et sequences (edition, validation)
      - Notifications (test, configuration)
      - Journaux (consultation, nettoyage)
.EXAMPLE
    .\PSWinDeploy-Console.ps1
    .\PSWinDeploy-Console.ps1 -ConfigPath 'E:\PSWinDeploy\App\PSWinDeploy.psd1'
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

# StrictMode 1 : evite les erreurs .Count/$null dans les scripts appeles
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# HELPERS VISUELS
# ---------------------------------------------------------------------------

function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host "  |                                                            |" -ForegroundColor Cyan
    Write-Host "  |              PSWinDeploy  --  Console Admin               |" -ForegroundColor Cyan
    Write-Host "  |              Remplacement MDT en PowerShell               |" -ForegroundColor Cyan
    Write-Host "  |                                                            |" -ForegroundColor Cyan
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-MenuHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Yellow
    $p = ' ' * [Math]::Max(0,[Math]::Floor((58-$Title.Length)/2))
    $r = ' ' * [Math]::Max(0,58-$Title.Length-$p.Length)
    Write-Host "  |$p$Title$r|" -ForegroundColor Yellow
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
}

function Write-MenuItem {
    param([string]$Key, [string]$Label, [string]$Desc='', [string]$Status='')
    $statusStr = if ($Status) { "  [$Status]" } else { '' }
    Write-Host "    " -NoNewline
    Write-Host "[$Key]" -ForegroundColor Cyan -NoNewline
    Write-Host "  $Label$statusStr" -ForegroundColor White
    if ($Desc) {
        Write-Host "        $Desc" -ForegroundColor DarkGray
    }
}

function Write-MenuSep {
    Write-Host "    $('-'*54)" -ForegroundColor DarkGray
}

function Write-StatusBar {
    param([hashtable]$Status)
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkGray
    $line = '  |  '
    foreach ($key in $Status.Keys) {
        $val = $Status[$key]
        $col = switch ($val) {
            'OK'    { 'Green'  }
            'WARN'  { 'Yellow' }
            'ERR'   { 'Red'    }
            default { 'Gray'   }
        }
        Write-Host $line -NoNewline -ForegroundColor DarkGray
        Write-Host "$key " -NoNewline -ForegroundColor DarkGray
        Write-Host $val -NoNewline -ForegroundColor $col
    }
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkGray
}

function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }

function Read-MenuChoice {
    param([string]$Prompt = 'Choix')
    Write-Host ""
    Write-Host "  [?]  $Prompt : " -ForegroundColor White -NoNewline
    return (Read-Host).Trim().ToLower()
}

function Invoke-Pause {
    param([string]$Msg = 'Appuyez sur Entree pour continuer...')
    Write-Host ""
    Write-Host "  $Msg" -ForegroundColor DarkGray -NoNewline
    Read-Host | Out-Null
}

function Format-Size {
    param([long]$B)
    if ($B -gt 1GB) { return "{0:N1} GB" -f ($B/1GB) }
    if ($B -gt 1MB) { return "{0:N0} MB" -f ($B/1MB) }
    return "{0:N0} KB" -f ($B/1KB)
}

function Invoke-Script {
    param([string]$ScriptPath, [string[]]$Args = @())
    # Verifier que le chemin n'est pas vide avant tout
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        Write-Err "Chemin de script non configure"
        Write-Info "Verifier que l'installation est complete (Initialize-PSWinDeploy.ps1)"
        Invoke-Pause
        return
    }
    if (-not (Test-Path $ScriptPath)) {
        Write-Err "Script introuvable : $ScriptPath"
        Invoke-Pause
        return
    }
    Write-Step "Lancement : $(Split-Path $ScriptPath -Leaf)"
    Write-Host ""
    if ($Args.Count -gt 0) {
        & $ScriptPath @Args
    } else {
        & $ScriptPath
    }
    Write-Host ""
    Invoke-Pause
}

# ---------------------------------------------------------------------------
# CHARGEMENT CONFIG
# ---------------------------------------------------------------------------

$scriptDir   = Split-Path $PSCommandPath -Parent
$projectRoot = Split-Path $scriptDir -Parent

$cfg = @{
    Version         = '0.6.9'
    AdkPath         = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    Architecture    = 'amd64'
    WinPEWorkspace  = 'C:\WinPE-Work'
    WinPEOutputPath = 'C:\WinPE-ISO'
    ImageShare      = '\\SERVEUR\Images'
    DeployShare     = '\\SERVEUR\Deploy'
    LogShare        = '\\SERVEUR\Logs'
    DriverShare     = '\\SERVEUR\Drivers'
    SoftwareShare   = '\\SERVEUR\Logiciels'
    ProfilesPath    = '\\SERVEUR\Deploy\Profiles'
    SequencesPath   = '\\SERVEUR\Deploy\Sequences'
    VaultPath       = 'C:\Deploy\secrets.vault.psd1'
    VaultMethod     = 'DPAPI'
    ApiPort         = 8080
    DeployLogPath   = 'C:\Deploy\Logs\deploy.log'
    AdvancedMode    = $false
}

$cfgFile = ''
foreach ($p in @($ConfigPath,
    "$scriptDir\PSWinDeploy.psd1",              # Racine installation
    "$scriptDir\App\PSWinDeploy.psd1",          # Sous App    "$projectRoot\PSWinDeploy.psd1",
    'C:\Deploy\PSWinDeploy.psd1',
    'C:\PSWinDeploy\App\PSWinDeploy.psd1',
    'X:\Deploy\PSWinDeploy.psd1')) {
    if ($p -and (Test-Path $p -ErrorAction SilentlyContinue)) {
        try {
            $loaded = Import-PowerShellDataFile $p
            foreach ($k in $loaded.Keys) { $cfg[$k] = $loaded[$k] }
            # Resoudre les chemins @{DNS;IP} -> chemin accessible (teste DNS puis IP)
            foreach ($shareKey in @('ImageShare','DeployShare','LogShare','DriverShare','SoftwareShare','ScriptShare','ProfilesPath','CataloguePath','SequencesPath','RuntimePath')) {
                if ($cfg.ContainsKey($shareKey) -and $cfg[$shareKey] -is [hashtable]) {
                    $hv = $cfg[$shareKey]
                    $cfg[$shareKey] = if ($hv['DNS'] -and (Test-Path $hv['DNS'] -EA SilentlyContinue)) { $hv['DNS'] }
                                      elseif ($hv['IP'] -and (Test-Path $hv['IP'] -EA SilentlyContinue)) { $hv['IP'] }
                                      elseif ($hv['DNS']) { $hv['DNS'] } else { $hv['IP'] }
                }
            }
            $cfgFile = $p
        } catch {}
        break
    }
}

# Chemins scripts
# La console est a la RACINE du dossier d'installation (ex: E:\PSWinDeploy\)
# Les scripts sont dans App\Scripts\
# Les modules sont dans App\Modules\
# Chercher App\Scripts (structure normale apres Initialize)
# App\Scripts est TOUJOURS prioritaire sur Scripts\ a la racine
# Scripts\ a la racine peut etre un vestige d ancienne installation
$appScriptsDir = $null
# Priorite 1 : App\Scripts avec Build-WinPE-Assistant (le plus specifique)
$p1 = Join-Path $scriptDir 'App\Scripts'
if (Test-Path (Join-Path $p1 'Build-WinPE-Assistant.ps1') -ErrorAction SilentlyContinue) {
    $appScriptsDir = $p1
}
# Priorite 2 : App\Scripts avec Deploy-Assistant seulement
if (-not $appScriptsDir -and
    (Test-Path (Join-Path $p1 'Deploy-Assistant.ps1') -ErrorAction SilentlyContinue)) {
    $appScriptsDir = $p1
}
# Priorite 3 : Scripts\ racine (fallback -- vestige ou structure non standard)
if (-not $appScriptsDir) {
    $p3 = Join-Path $scriptDir 'Scripts'
    if (Test-Path (Join-Path $p3 'Deploy-Assistant.ps1') -ErrorAction SilentlyContinue) {
        $appScriptsDir = $p3
        Write-Warn "Scripts trouves dans $p3 (racine) -- verifier si App\Scripts existe"
    }
}
# Fallback sans verification -- si aucun script trouve
if (-not $appScriptsDir) {
    $appScriptsDir = Join-Path $scriptDir 'App\Scripts'
    Write-Warn "Scripts non trouves -- chemin suppose : $appScriptsDir"
    Write-Warn "Verifier que l'installation est complete (Initialize-PSWinDeploy.ps1)"
}

$scriptPaths = @{
    Deploy      = Join-Path $appScriptsDir 'Deploy-Assistant.ps1'
    StartDeploy = Join-Path $appScriptsDir 'Start-Deploy.ps1'
    BuildWinPE  = Join-Path $appScriptsDir 'Build-WinPE-Assistant.ps1'
    ExportWIM   = Join-Path $appScriptsDir 'Export-WIMImage.ps1'
    Initialize  = Join-Path $scriptDir     'Initialize-PSWinDeploy.ps1'
    Update      = Join-Path $scriptDir     'Update-PSWinDeploy.ps1'
    Unblock     = Join-Path $scriptDir     'Unblock-PSWinDeploy.ps1'
}

# Modules -- chercher dans App\Modules ou Modules selon la structure
# Rechercher App\Modules en verifiant la presence du module Config
$modRoot = $null
foreach ($candidate in @(
    (Join-Path $scriptDir 'App\Modules'),
    (Join-Path $scriptDir 'Modules')
)) {
    if (Test-Path (Join-Path $candidate 'Config\Config.psm1') -ErrorAction SilentlyContinue) {
        $modRoot = $candidate
        break
    }
}
if (-not $modRoot) { $modRoot = Join-Path $scriptDir "App\Modules" }
$modsLoaded = @{}
foreach ($mod in @('Config','TaskSequence','WinPE-Builder','WIM-Manager','NetShare','ProfileManager','Notify')) {
    $mp = Join-Path $modRoot "$mod\$mod.psm1"
    if (Test-Path $mp) {
        try {
            Import-Module $mp -Force -ErrorAction SilentlyContinue
            $modsLoaded[$mod] = $true
        } catch { $modsLoaded[$mod] = $false }
    } else { $modsLoaded[$mod] = $false }
}

# ---------------------------------------------------------------------------
# ANALYSE DE SANTE
# ---------------------------------------------------------------------------

function Get-HealthStatus {
    $h = [ordered]@{}

    # ADK
    $copype = Join-Path $cfg.WinPEAddonPath 'copype.cmd'
    $h.ADK = if (Test-Path $copype) { 'OK' } else { 'ERR' }

    # Partages reseau
    $h.Images   = if (Test-Path $cfg.ImageShare   -EA SilentlyContinue) { 'OK' } else { 'ERR' }
    $h.Deploy   = if (Test-Path $cfg.DeployShare  -EA SilentlyContinue) { 'OK' } else { 'ERR' }
    $h.Drivers  = if (Test-Path $cfg.DriverShare  -EA SilentlyContinue) { 'OK' } else { 'WARN' }

    # Vault
    $h.Vault = if (Test-Path $cfg.VaultPath -EA SilentlyContinue) { 'OK' } else { 'WARN' }

    # Pode (API)
    $podeOk = Get-Module -ListAvailable Pode -ErrorAction SilentlyContinue
    $h.Pode = if ($podeOk) { 'OK' } else { 'WARN' }

    # WDS
    $wdsSvc = Get-Service WDSServer -ErrorAction SilentlyContinue
    $h.WDS = if ($wdsSvc) { if ($wdsSvc.Status -eq 'Running') { 'OK' } else { 'WARN' } } else { 'N/A' }

    # WIM disponibles
    $wimCount = 0
    if (Test-Path $cfg.ImageShare -EA SilentlyContinue) {
        $wimCount = (Get-ChildItem $cfg.ImageShare -Filter '*.wim' -EA SilentlyContinue).Count
    }
    $h.WIM = if ($wimCount -gt 0) { "OK ($wimCount)" } else { 'WARN' }

    return $h
}

function Show-HealthReport {
    Write-MenuHeader "Rapport de sante du systeme"

    $h = Get-HealthStatus

    # Section ADK
    Write-Host "  ADK et WinPE" -ForegroundColor White
    $copype = Join-Path $cfg.WinPEAddonPath 'copype.cmd'
    if (Test-Path $copype) {
        Write-OK "ADK : $($cfg.AdkPath)"
        Write-OK "WinPE Add-on : $($cfg.WinPEAddonPath)"

        # Verifier l'architecture
        $archPath = Join-Path $cfg.WinPEAddonPath $cfg.Architecture
        if (Test-Path $archPath) {
            Write-OK "Architecture $($cfg.Architecture) disponible"
        } else {
            Write-Warn "Architecture $($cfg.Architecture) non trouvee dans l'ADK"
        }

        # Verifier les packages disponibles
        $pkgPath = Join-Path $cfg.WinPEAddonPath "OptionalComponents\$($cfg.Architecture)"
        if (Test-Path $pkgPath) {
            $pkgCount = (Get-ChildItem $pkgPath -Filter '*.cab' -EA SilentlyContinue).Count
            Write-OK "Packages optionnels : $pkgCount disponibles"
        }
    } else {
        Write-Err "ADK non detecte : $($cfg.WinPEAddonPath)"
        Write-Info "Telecharger : https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    }
    Write-Host ""

    # Section Partages
    Write-Host "  Partages reseau" -ForegroundColor White
    $shares = [ordered]@{
        Images     = $cfg.ImageShare
        Deploy     = $cfg.DeployShare
        Logs       = $cfg.LogShare
        Drivers    = $cfg.DriverShare
        Logiciels  = $cfg.SoftwareShare
    }
    foreach ($name in $shares.Keys) {
        $path = $shares[$name]
        if (-not $path) { continue }
        $exists = Test-Path $path -ErrorAction SilentlyContinue
        if ($exists) {
            $itemCount = (Get-ChildItem $path -ErrorAction SilentlyContinue).Count
            Write-OK "$name : $path ($itemCount elements)"

            # Compter les WIM specifiquement
            if ($name -eq 'Images') {
                $wims = Get-ChildItem $path -Filter '*.wim' -ErrorAction SilentlyContinue
                if ($wims.Count -gt 0) {
                    $totalSize = ($wims | Measure-Object -Property Length -Sum).Sum
                    Write-OK "  $($wims.Count) image(s) WIM -- $(Format-Size $totalSize) total"
                    $wims | ForEach-Object {
                        Write-Info "  $($_.Name)  ($(Format-Size $_.Length))"
                    }
                } else {
                    Write-Warn "  Aucun fichier .wim -- utiliser Export-WIMImage.ps1"
                }
            }

            # Compter les drivers
            if ($name -eq 'Drivers') {
                $infs = Get-ChildItem $path -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue
                Write-Info "  $($infs.Count) driver(s) .inf dans l'arborescence"
                # Verifier les sous-dossiers WinPE
                foreach ($sub in @('WinPE\Net','WinPE\Storage','WinPE\Sys')) {
                    $sp = Join-Path $path $sub
                    if (Test-Path $sp) {
                        $cnt = (Get-ChildItem $sp -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
                        Write-Info "    $sub : $cnt .inf"
                    } else {
                        Write-Warn "    $sub : absent (creer et deposer les drivers)"
                    }
                }
            }
        } else {
            $isCritical = $name -in @('Images','Deploy')
            if ($isCritical) { Write-Err "$name : $path -- INACCESSIBLE" }
            else             { Write-Warn "$name : $path -- inaccessible" }
        }
    }
    Write-Host ""

    # Section Vault
    Write-Host "  Securite" -ForegroundColor White
    if (Test-Path $cfg.VaultPath -EA SilentlyContinue) {
        $vaultInfo = Get-Content $cfg.VaultPath -Raw | ConvertFrom-Json
        $method    = $vaultInfo.method
        $modDate   = (Get-Item $cfg.VaultPath).LastWriteTime.ToString('dd/MM/yyyy HH:mm')
        Write-OK "Vault : $($cfg.VaultPath)"
        Write-Info "  Methode : $method"
        Write-Info "  Derniere modification : $modDate"
        if ($method -eq 'Plain') {
            Write-Warn "  ATTENTION : vault en clair (mode Plain) -- non securise en production !"
        }
    } else {
        Write-Warn "Vault absent : $($cfg.VaultPath)"
        Write-Info "  Creer avec : Initialize-SecretVault dans TaskSequence.psm1"
    }
    Write-Host ""

    # Section API
    Write-Host "  API et services" -ForegroundColor White
    $podeOk = Get-Module -ListAvailable Pode -ErrorAction SilentlyContinue
    if ($podeOk) {
        $podeVer = ($podeOk | Sort-Object Version -Desc | Select-Object -First 1).Version
        Write-OK "Pode $podeVer installe"
    } else {
        Write-Warn "Pode non installe : Install-Module Pode -Scope CurrentUser -Force"
    }

    # Tester l'API
    try {
        $resp = Invoke-RestMethod -Uri "http://localhost:$($cfg.ApiPort)/api/health" -TimeoutSec 3 -EA Stop
        Write-OK "API en cours : port $($cfg.ApiPort) (v$($resp.version))"
    } catch {
        Write-Info "API arretee (port $($cfg.ApiPort)) -- lancer Start-API.ps1"
    }

    # WDS
    $wdsSvc = Get-Service WDSServer -ErrorAction SilentlyContinue
    if ($wdsSvc) {
        $col = if ($wdsSvc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "  [~]  WDS : $($wdsSvc.Status)" -ForegroundColor $col
    } else {
        Write-Info "WDS non installe (optionnel pour PXE)"
    }
    Write-Host ""

    # Section Modules PS
    Write-Host "  Modules PSWinDeploy" -ForegroundColor White
    foreach ($mod in $modsLoaded.Keys) {
        if ($modsLoaded[$mod]) { Write-OK "$mod" }
        else { Write-Warn "$mod : non charge (cherche dans $modRoot\$mod\)" }
    }
    Write-Host ""

    # Section ISO/WIM PXE
    Write-Host "  Medias WinPE" -ForegroundColor White
    $isoPath = Join-Path $cfg.WinPEOutputPath "WinPE-$($cfg.Architecture).iso"
    if (Test-Path $isoPath) {
        $isoDate = (Get-Item $isoPath).LastWriteTime.ToString('dd/MM/yyyy HH:mm')
        Write-OK "ISO : $isoPath ($(Format-Size (Get-Item $isoPath).Length)) -- $isoDate"
    } else {
        Write-Warn "ISO non trouve : $isoPath"
        Write-Info "  Lancer l'assistant Build WinPE pour le generer"
    }
    $pxeWim = Join-Path $cfg.WinPEOutputPath "PXE\boot-$($cfg.Architecture).wim"
    if (Test-Path $pxeWim) {
        Write-OK "WIM PXE : $pxeWim ($(Format-Size (Get-Item $pxeWim).Length))"
    } else {
        Write-Info "WIM PXE non genere (optionnel)"
    }
    Write-Host ""

    # Bilan global
    $errors   = ($h.Values | Where-Object { $_ -eq 'ERR'  }).Count
    $warnings = ($h.Values | Where-Object { $_ -eq 'WARN' }).Count
    if ($errors -eq 0 -and $warnings -eq 0) {
        Write-OK "Systeme pret pour le deploiement"
    } elseif ($errors -eq 0) {
        Write-Warn "Systeme operationnel avec $warnings avertissement(s)"
    } else {
        Write-Err "$errors erreur(s) critique(s) a corriger avant deploiement"
    }

    Invoke-Pause
}

# ---------------------------------------------------------------------------
# GESTION MOT DE PASSE / VAULT
# ---------------------------------------------------------------------------

function Show-VaultMenu {
    Write-MenuHeader "Gestion du vault de secrets"

    if (-not $modsLoaded['TaskSequence']) {
        Write-Warn "Module TaskSequence non charge -- certaines fonctions indisponibles"
    }

    Write-MenuItem '1' 'Afficher les cles presentes dans le vault'
    Write-MenuItem '2' 'Changer le mot de passe admin local'
    Write-MenuItem '3' 'Changer le mot de passe compte reseau WinPE'
    Write-MenuItem '4' 'Changer le mot de passe jonction domaine'
    Write-MenuItem '5' 'Changer le mot de passe deploy-temp'
    Write-MenuItem '6' 'Changer le mot de passe vault AES (re-chiffrement)'
    Write-MenuSep
    Write-MenuItem '7' 'Recreer le vault complet (tous les secrets)'
    Write-MenuItem '8' 'Convertir Plain -> AES (securiser un vault de lab)'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'

    $c = Read-MenuChoice
    switch ($c) {

        '1' {
            if (Test-Path $cfg.VaultPath -EA SilentlyContinue) {
                try {
                    $v = Get-Content $cfg.VaultPath -Raw | ConvertFrom-Json
                    Write-Host ""
                    Write-Info "Vault : $($cfg.VaultPath)"
                    Write-Info "Methode : $($v.method)"
                    if ($v.method -eq 'Plain') {
                        $secrets = $v.data | ConvertFrom-Json
                        Write-Host ""
                        Write-Warn "Vault en clair -- affichage des cles (pas des valeurs) :"
                        $secrets.PSObject.Properties.Name | ForEach-Object {
                            Write-Host "    $_" -ForegroundColor Gray
                        }
                    } else {
                        Write-Host ""
                        Write-Host "  [?]  Mot de passe vault pour lire les cles : " -ForegroundColor White -NoNewline
                        $sp  = Read-Host -AsSecureString
                        $pwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
                        try {
                            $key     = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                                           [System.Text.Encoding]::UTF8.GetBytes($pwd))
                            $secrets = ($v.data | ConvertTo-SecureString -Key $key |
                                ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }) | ConvertFrom-Json
                            Write-Host ""
                            Write-Info "Cles presentes dans le vault :"
                            $secrets.PSObject.Properties.Name | ForEach-Object {
                                Write-Host "    $_" -ForegroundColor Gray
                            }
                        } catch { Write-Err "Mot de passe incorrect ou vault corrompu" }
                    }
                } catch { Write-Err "Erreur lecture vault : $_" }
            } else { Write-Warn "Vault absent : $($cfg.VaultPath)" }
            Invoke-Pause
        }

        { $_ -in @('2','3','4','5') } {
            $keyMap = @{ '2'='localAdminPassword'; '3'='winpePassword'; '4'='domainJoinPassword'; '5'='deployPassword' }
            $labelMap = @{ '2'='Admin local'; '3'='Reseau WinPE (winpePassword)'; '4'='Jonction domaine'; '5'='deploy-temp' }
            $key   = $keyMap[$c]
            $label = $labelMap[$c]

            if (-not (Test-Path $cfg.VaultPath -EA SilentlyContinue)) {
                Write-Err "Vault absent -- creer d'abord le vault (option 7)"
                Invoke-Pause
                return
            }

            Write-Host ""
            Write-Info "Modification : $label"

            # Lire le vault entier
            $vaultData = Get-Content $cfg.VaultPath -Raw | ConvertFrom-Json
            $secrets   = $null
            $vaultPwd  = ''

            if ($vaultData.method -eq 'Plain') {
                $secrets = $vaultData.data | ConvertFrom-Json
            } else {
                Write-Host "  [?]  Mot de passe vault actuel : " -ForegroundColor White -NoNewline
                $sp  = Read-Host -AsSecureString
                $vaultPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
                try {
                    $aesKey  = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                                   [System.Text.Encoding]::UTF8.GetBytes($vaultPwd))
                    $secrets = ($vaultData.data | ConvertTo-SecureString -Key $aesKey |
                        ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }) | ConvertFrom-Json
                } catch { Write-Err "Mot de passe vault incorrect"; Invoke-Pause; return }
            }

            # Demander le nouveau mot de passe
            Write-Host "  [?]  Nouveau mot de passe pour $label : " -ForegroundColor White -NoNewline
            $np1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            Write-Host "  [?]  Confirmer : " -ForegroundColor White -NoNewline
            $np2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))

            if ($np1 -ne $np2) { Write-Err "Les mots de passe ne correspondent pas"; Invoke-Pause; return }
            if ([string]::IsNullOrWhiteSpace($np1)) { Write-Err "Mot de passe vide interdit"; Invoke-Pause; return }

            # Mettre a jour et re-chiffrer
            $secrets | Add-Member -NotePropertyName $key -NotePropertyValue $np1 -Force
            $json = $secrets | ConvertTo-Json -Compress

            if ($vaultData.method -eq 'Plain') {
                @{ method='Plain'; data=$json } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
            } else {
                $aesKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                              [System.Text.Encoding]::UTF8.GetBytes($vaultPwd))
                $enc    = ($json | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString -Key $aesKey
                @{ method='AES'; data=$enc } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
            }
            Write-OK "Mot de passe '$label' mis a jour dans le vault"
            Invoke-Pause
        }

        '6' {
            if (-not (Test-Path $cfg.VaultPath -EA SilentlyContinue)) {
                Write-Err "Vault absent"; Invoke-Pause; return
            }
            $vaultData = Get-Content $cfg.VaultPath -Raw | ConvertFrom-Json
            if ($vaultData.method -eq 'Plain') {
                Write-Warn "Vault Plain -- utiliser option 8 pour convertir en AES"
                Invoke-Pause; return
            }
            Write-Host "  [?]  Ancien mot de passe vault : " -ForegroundColor White -NoNewline
            $oldPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                          [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            try {
                $aesKey  = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                               [System.Text.Encoding]::UTF8.GetBytes($oldPwd))
                $json    = ($vaultData.data | ConvertTo-SecureString -Key $aesKey |
                    ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) })
            } catch { Write-Err "Ancien mot de passe incorrect"; Invoke-Pause; return }

            Write-Host "  [?]  Nouveau mot de passe vault : " -ForegroundColor White -NoNewline
            $np1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            Write-Host "  [?]  Confirmer : " -ForegroundColor White -NoNewline
            $np2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            if ($np1 -ne $np2) { Write-Err "Mots de passe differents"; Invoke-Pause; return }

            $newKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                          [System.Text.Encoding]::UTF8.GetBytes($np1))
            $enc    = ($json | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString -Key $newKey
            @{ method='AES'; data=$enc } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
            Write-OK "Mot de passe vault AES modifie"
            Invoke-Pause
        }

        '7' {
            Write-Host ""
            Write-Warn "Cela va RECREER le vault avec de nouveaux secrets."
            Write-Host "  [?]  Continuer ? [o/N] : " -ForegroundColor White -NoNewline
            if ((Read-Host).Trim().ToLower() -ne 'o') { return }
            Write-Host ""
            $s = @{}
            foreach ($entry in @(
                @{ Key='winpeUser';          Label='Compte reseau WinPE (ex: SERVEUR\svc-winpe)'; IsUser=$true }
                @{ Key='winpePassword';      Label='Mot de passe reseau WinPE' }
                @{ Key='domainJoinUser';     Label='Compte jonction domaine (ex: svc-joindomain)'; IsUser=$true }
                @{ Key='domainJoinPassword'; Label='Mot de passe jonction domaine' }
                @{ Key='localAdminPassword'; Label='Mot de passe admin local machines' }
                @{ Key='deployPassword';     Label='Mot de passe deploy-temp' }
            )) {
                if ($entry.IsUser) {
                    Write-Host "  [?]  $($entry.Label) : " -ForegroundColor White -NoNewline
                    $s[$entry.Key] = (Read-Host).Trim()
                } else {
                    Write-Host "  [?]  $($entry.Label) : " -ForegroundColor White -NoNewline
                    $s[$entry.Key] = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
                }
            }
            Write-Host ""
            Write-Host "  [?]  Mode vault [AES/Plain] : " -ForegroundColor White -NoNewline
            $vm = (Read-Host).Trim().ToUpper()
            $vp = ''
            if ($vm -eq 'AES') {
                Write-Host "  [?]  Mot de passe vault AES : " -ForegroundColor White -NoNewline
                $vp = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                          [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            }
            if ($modsLoaded['TaskSequence']) {
                if ($vm -eq 'AES') { Initialize-SecretVault -Secrets $s -VaultPath $cfg.VaultPath -Password $vp }
                else               { Initialize-SecretVault -Secrets $s -VaultPath $cfg.VaultPath -Plain }
                Write-OK "Vault recree : $($cfg.VaultPath)"
            } else {
                $json = $s | ConvertTo-Json -Compress
                if ($vm -eq 'AES' -and $vp) {
                    $aesKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                                  [System.Text.Encoding]::UTF8.GetBytes($vp))
                    $enc    = ($json | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString -Key $aesKey
                    @{ method='AES'; data=$enc } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
                } else {
                    @{ method='Plain'; data=$json } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
                }
                Write-OK "Vault recree : $($cfg.VaultPath)"
            }
            Invoke-Pause
        }

        '8' {
            if (-not (Test-Path $cfg.VaultPath -EA SilentlyContinue)) {
                Write-Err "Vault absent"; Invoke-Pause; return
            }
            $vaultData = Get-Content $cfg.VaultPath -Raw | ConvertFrom-Json
            if ($vaultData.method -ne 'Plain') {
                Write-Warn "Le vault n'est pas en Plain (methode : $($vaultData.method))"
                Invoke-Pause; return
            }
            Write-Host "  [?]  Nouveau mot de passe AES : " -ForegroundColor White -NoNewline
            $np = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString)))
            $aesKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                          [System.Text.Encoding]::UTF8.GetBytes($np))
            $enc    = ($vaultData.data | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString -Key $aesKey
            @{ method='AES'; data=$enc } | ConvertTo-Json | Set-Content $cfg.VaultPath -Encoding UTF8
            Write-OK "Vault converti Plain -> AES"
            Invoke-Pause
        }
    }
}

# ---------------------------------------------------------------------------
# GESTION DES JOURNAUX
# ---------------------------------------------------------------------------

function Show-LogsMenu {
    Write-MenuHeader "Journaux de deploiement"

    $logPath = $cfg.DeployLogPath
    $logDir  = Split-Path $logPath -Parent
    $logShare = $cfg.LogShare

    Write-MenuItem '1' 'Afficher les 50 dernieres lignes du journal local'
    Write-MenuItem '2' 'Rechercher dans les journaux (par machine ou date)'
    Write-MenuItem '3' 'Afficher uniquement les erreurs'
    Write-MenuItem '4' 'Lister les journaux sur le partage reseau'
    Write-MenuItem '5' 'Nettoyer les journaux de plus de 30 jours'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'

    $c = Read-MenuChoice
    switch ($c) {
        '1' {
            if (Test-Path $logPath) {
                Write-Host ""
                Write-Info "Journal : $logPath"
                Write-Host "  $('-'*56)" -ForegroundColor DarkGray
                Get-Content $logPath -Tail 50 | ForEach-Object {
                    $col = if ($_ -match '\[X\]') { 'Red' }
                           elseif ($_ -match '\[!\]') { 'Yellow' }
                           elseif ($_ -match '\[OK\]') { 'Green' }
                           elseif ($_ -match '\[>>\]') { 'Magenta' }
                           else { 'Gray' }
                    Write-Host "  $_" -ForegroundColor $col
                }
            } else { Write-Warn "Journal absent : $logPath" }
            Invoke-Pause
        }
        '2' {
            Write-Host "  [?]  Terme a rechercher (machine, date, step) : " -ForegroundColor White -NoNewline
            $term = (Read-Host).Trim()
            if ($term) {
                $paths = @($logPath)
                if (Test-Path $logShare) {
                    $paths += Get-ChildItem $logShare -Filter '*.log' -EA SilentlyContinue |
                              Select-Object -ExpandProperty FullName
                }
                $found = 0
                foreach ($lp in $paths) {
                    if (Test-Path $lp) {
                        $matches_found = Get-Content $lp -EA SilentlyContinue | Where-Object { $_ -match [regex]::Escape($term) }
                        if ($matches_found) {
                            Write-Host ""
                            Write-Info "Fichier : $lp"
                            $matches_found | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                            $found += $matches_found.Count
                        }
                    }
                }
                Write-Host ""
                Write-Info "$found ligne(s) trouvee(s) pour '$term'"
            }
            Invoke-Pause
        }
        '3' {
            $paths = @($logPath)
            if (Test-Path $logShare) {
                $paths += Get-ChildItem $logShare -Filter '*.log' -EA SilentlyContinue |
                          Select-Object -ExpandProperty FullName
            }
            Write-Host ""
            $errCount = 0
            foreach ($lp in $paths) {
                if (Test-Path $lp) {
                    $errs = Get-Content $lp -EA SilentlyContinue | Where-Object { $_ -match '\[X\]|\[!\]' }
                    if ($errs) {
                        Write-Info "Fichier : $lp"
                        $errs | ForEach-Object {
                            $col = if ($_ -match '\[X\]') { 'Red' } else { 'Yellow' }
                            Write-Host "  $_" -ForegroundColor $col
                        }
                        $errCount += $errs.Count
                    }
                }
            }
            Write-Host ""
            if ($errCount -eq 0) { Write-OK "Aucune erreur trouvee dans les journaux" }
            else { Write-Warn "$errCount erreur(s)/avertissement(s) trouves" }
            Invoke-Pause
        }
        '4' {
            if (Test-Path $logShare -EA SilentlyContinue) {
                $logs = Get-ChildItem $logShare -Filter '*.log' -Recurse -EA SilentlyContinue |
                        Sort-Object LastWriteTime -Descending
                Write-Host ""
                Write-Info "$($logs.Count) journal(ux) sur $logShare"
                $logs | Select-Object -First 20 | ForEach-Object {
                    $age  = [Math]::Round(((Get-Date)-$_.LastWriteTime).TotalDays,0)
                    Write-Host ("    {0,-40} {1,8}  il y a {2}j" -f $_.Name, (Format-Size $_.Length), $age) -ForegroundColor Gray
                }
            } else { Write-Warn "Partage logs inaccessible : $logShare" }
            Invoke-Pause
        }
        '5' {
            $paths = @()
            if (Test-Path $logDir -EA SilentlyContinue) { $paths += Get-ChildItem $logDir -Filter '*.log' -EA SilentlyContinue }
            if (Test-Path $logShare -EA SilentlyContinue) { $paths += Get-ChildItem $logShare -Filter '*.log' -Recurse -EA SilentlyContinue }
            $old = $paths | Where-Object { ((Get-Date)-$_.LastWriteTime).TotalDays -gt 30 }
            if ($old.Count -eq 0) { Write-Info "Aucun journal de plus de 30 jours"; Invoke-Pause; return }
            Write-Warn "$($old.Count) fichier(s) de plus de 30 jours"
            Write-Host "  [?]  Supprimer ces fichiers ? [o/N] : " -ForegroundColor White -NoNewline
            if ((Read-Host).Trim().ToLower() -eq 'o') {
                $old | Remove-Item -Force -EA SilentlyContinue
                Write-OK "$($old.Count) fichier(s) supprime(s)"
            }
            Invoke-Pause
        }
    }
}

# ---------------------------------------------------------------------------
# GESTION DES PROFILS
# ---------------------------------------------------------------------------

function Show-HttpsMenu {
    Write-MenuHeader "API HTTPS / Certificat"
    Write-Info "Objectif : CHIFFRER le trafic de l'API (cert auto-signe accepte)."
    Write-Info "Les clients (interface web, postes) ignorent les erreurs de cert."
    Write-Host ""

    $certDir  = Join-Path (Split-Path $cfgFile -Parent) 'Certs'
    $certPfx  = Join-Path $certDir 'pswd-api.pfx'
    $httpsState = if (Test-Path $certPfx -EA SilentlyContinue) { 'cert present' } else { 'aucun cert' }
    Write-Host "    Etat : " -ForegroundColor Gray -NoNewline
    Write-Host $httpsState -ForegroundColor $(if ($httpsState -eq 'cert present') { 'Green' } else { 'DarkGray' })
    Write-Host ""

    Write-MenuItem '1' 'Generer un certificat auto-signe (le plus simple)'
    Write-MenuItem '2' 'Fournir mon propre certificat (.pfx)'
    Write-MenuItem '3' 'Afficher comment activer HTTPS dans Start-API.ps1'
    Write-MenuItem '4' 'Revenir en HTTP (desactiver HTTPS)'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'
    $c = Read-MenuChoice
    switch ($c) {
        '1' {
            Write-Host ""
            try {
                if (-not (Test-Path $certDir)) { New-Item -ItemType Directory $certDir -Force | Out-Null }
                $srvName = if ($cfg.WinPEShareServer) { $cfg.WinPEShareServer } else { $env:COMPUTERNAME }
                $srvIp   = if ($cfg.WinPEShareServerIP) { $cfg.WinPEShareServerIP } else { '' }
                $dns = @($srvName, 'localhost')
                if ($srvIp) { $dns += $srvIp }
                Write-Info "Generation d'un certificat auto-signe pour : $($dns -join ', ')"
                # Mot de passe aleatoire pour proteger le .pfx
                $pfxPass = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
                $cert = New-SelfSignedCertificate -DnsName $dns -CertStoreLocation 'Cert:\LocalMachine\My' `
                            -FriendlyName 'PSWinDeploy API' -NotAfter (Get-Date).AddYears(5) -EA Stop
                $sec = ConvertTo-SecureString $pfxPass -AsPlainText -Force
                Export-PfxCertificate -Cert $cert -FilePath $certPfx -Password $sec | Out-Null
                # Retirer le cert du magasin (on garde juste le .pfx)
                Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force -EA SilentlyContinue
                # Sauver le mot de passe du pfx a cote (lecture admin only)
                Set-Content -Path (Join-Path $certDir 'pswd-api.pfx.pass') -Value $pfxPass -Encoding UTF8
                Write-OK "Certificat genere : $certPfx"
                Write-Info "Mot de passe du .pfx enregistre dans pswd-api.pfx.pass"
                Write-Host ""
                Write-Info "Pour activer : option 3 (instructions Start-API.ps1)."
            } catch {
                Write-Warn "Echec generation cert : $_"
            }
            Invoke-Pause
        }
        '2' {
            Write-Host "  [?]  Chemin du .pfx a utiliser : " -ForegroundColor White -NoNewline
            $src = (Read-Host).Trim().Trim('"')
            if ($src -and (Test-Path $src)) {
                if (-not (Test-Path $certDir)) { New-Item -ItemType Directory $certDir -Force | Out-Null }
                Copy-Item $src $certPfx -Force
                Write-OK "Certificat copie : $certPfx"
                Write-Info "Renseigne le mot de passe du .pfx dans Start-API.ps1 (option 3)."
            } else { Write-Warn "Fichier introuvable." }
            Invoke-Pause
        }
        '3' {
            Write-Host ""
            Write-Info "Pour servir l'API en HTTPS, lance Deploy-API.ps1 avec :"
            Write-Host "    -CertPath '$certPfx' -CertPassword '<mot-de-passe-pfx>'" -ForegroundColor Cyan
            Write-Host ""
            Write-Info "Cote interface web (conteneur) : mets URL_API_PSWINDEPLOY en https://"
            Write-Info "Le backend ignore deja les erreurs de cert auto-signe."
            Write-Host ""
            Write-Info "Edite $InstallRoot\Start-API.ps1 pour ajouter ces parametres."
            Invoke-Pause
        }
        '4' {
            Write-Host ""
            Write-Warn "Pour revenir en HTTP : retire -CertPath/-CertPassword de Start-API.ps1."
            Write-Info "L'API ecoutera alors en HTTP simple (port 8080)."
            Invoke-Pause
        }
    }
}

function Show-SequencesMenu {
    Write-MenuHeader "Sequences de deploiement"
    $seqPath = $cfg.SequencesPath
    # Etat de la sequence par defaut (_default.psd1 actif, ou _default.psd1.DISABLE).
    $defActive  = Join-Path $seqPath '_default.psd1'
    $defDisabled = Join-Path $seqPath '_default.psd1.DISABLE'
    $defState = if (Test-Path $defActive -EA SilentlyContinue) { 'ACTIVE' }
                elseif (Test-Path $defDisabled -EA SilentlyContinue) { 'desactivee' }
                else { 'absente' }
    $defColor = if ($defState -eq 'ACTIVE') { 'Yellow' } else { 'DarkGray' }
    Write-Host "    Sequence par defaut (_default) : " -ForegroundColor Gray -NoNewline
    Write-Host $defState -ForegroundColor $defColor
    Write-Host ""

    Write-MenuItem '1' 'Lister les sequences disponibles'
    Write-MenuItem '2' 'Valider une sequence (dry-run)'
    Write-MenuItem '3' 'Afficher le detail d une sequence'
    Write-MenuItem '4' "Activer / desactiver la sequence par defaut [$defState]"
    Write-MenuItem '5' 'Editer les sequences (assistant)'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'
    $c = Read-MenuChoice
    switch ($c) {
        '1' {
            Write-Host ""
            if (Test-Path $seqPath -EA SilentlyContinue) {
                # Sequences = *.psd1 (hors _default), + modeles, + by-name/by-mac.
                $files = Get-ChildItem $seqPath -Filter '*.psd1' -EA SilentlyContinue
                Write-Info "$($files.Count) sequence(s) dans $seqPath"
                foreach ($f in $files) {
                    $tag = if ($f.Name -like '_default*') { ' (defaut)' } else { '' }
                    try {
                        $s = Import-PowerShellDataFile $f.FullName -EA Stop
                        $nm = if ($s.Name) { $s.Name } else { $f.BaseName }
                        $os = if ($s.Metadata -and $s.Metadata.Os) { $s.Metadata.Os } else { '?' }
                        $nbSteps = if ($s.Steps) { @($s.Steps).Count } else { 0 }
                        Write-Host "    $nm$tag" -ForegroundColor White -NoNewline
                        Write-Host "  [$os]  $nbSteps step(s)" -ForegroundColor DarkGray
                        Write-Host "    $($f.Name)" -ForegroundColor DarkGray
                        Write-Host ""
                    } catch { Write-Warn "Invalide : $($f.Name)" }
                }
                # Sequences nominatives (by-name / by-mac)
                foreach ($sub in @('by-name','by-mac')) {
                    $subDir = Join-Path $seqPath $sub
                    if (Test-Path $subDir -EA SilentlyContinue) {
                        $subFiles = Get-ChildItem $subDir -Filter '*.psd1' -EA SilentlyContinue
                        if ($subFiles.Count -gt 0) {
                            Write-Host "    [$sub] $($subFiles.Count) sequence(s) nominative(s)" -ForegroundColor Cyan
                        }
                    }
                }
            } else { Write-Warn "Dossier sequences inaccessible : $seqPath" }
            Invoke-Pause
        }
        '2' {
            if ($modsLoaded['TaskSequence']) {
                Write-Host "  [?]  Chemin sequence a valider : " -ForegroundColor White -NoNewline
                $sp = (Read-Host).Trim().Trim('"')
                if ($sp -and (Test-Path $sp)) {
                    Write-Host ""
                    Test-TaskSequence -SequencePath $sp
                } else { Write-Warn "Fichier introuvable" }
            } else { Write-Warn "Module TaskSequence non charge" }
            Invoke-Pause
        }
        '3' {
            Write-Host "  [?]  Nom de la sequence (ou chemin .psd1) : " -ForegroundColor White -NoNewline
            $inp = (Read-Host).Trim().Trim('"')
            $fp  = $null
            if (Test-Path $inp -EA SilentlyContinue) { $fp = $inp }
            else {
                $found = Get-ChildItem $seqPath -Filter '*.psd1' -EA SilentlyContinue |
                         Where-Object { $_.BaseName -match [regex]::Escape($inp) } | Select-Object -First 1
                if ($found) { $fp = $found.FullName }
            }
            if ($fp) {
                Write-Host ""
                Get-Content $fp -Raw | Write-Host -ForegroundColor Gray
            } else { Write-Warn "Sequence non trouvee : $inp" }
            Invoke-Pause
        }
        '4' {
            # Toggle de la sequence par defaut : ACTIVE <-> .DISABLE.
            Write-Host ""
            if (Test-Path $defActive -EA SilentlyContinue) {
                Rename-Item $defActive '_default.psd1.DISABLE' -Force -EA SilentlyContinue
                Write-OK "Sequence par defaut DESACTIVEE (renommee _default.psd1.DISABLE)."
                Write-Info "Le moteur ne la prendra plus automatiquement."
            } elseif (Test-Path $defDisabled -EA SilentlyContinue) {
                Rename-Item $defDisabled '_default.psd1' -Force -EA SilentlyContinue
                Write-OK "Sequence par defaut REACTIVEE (_default.psd1)."
            } else {
                Write-Warn "Aucune sequence par defaut (_default.psd1) trouvee dans $seqPath."
            }
            Invoke-Pause
        }
        '5' {
            Write-Host ""
            Invoke-Script $scriptPaths.Deploy
        }
    }
}


# ---------------------------------------------------------------------------
# GESTION DES DRIVERS
# ---------------------------------------------------------------------------

function Show-DriversMenu {
    Write-MenuHeader "Gestion des drivers"

    $driverBase = $cfg.DriverShare
    if (-not $driverBase) { $driverBase = '\\SERVEUR\Drivers' }
    $accessible = Test-Path $driverBase -ErrorAction SilentlyContinue
    $accessStr  = if ($accessible) { " [accessible]" } else { " [INACCESSIBLE]" }
    Write-Info "Partage drivers : $driverBase$accessStr"
    Write-Host ""

    Write-MenuItem '1' 'Resume des drivers disponibles'   'Comptage .inf par categorie WinPE et OS'
    Write-MenuItem '2' 'Creer la structure de dossiers'   'WinPE\Net, WinPE\Storage, WinPE\Sys, Dell, HP...'
    Write-MenuItem '3' 'Lister les drivers WinPE'         'Detail Net / Storage / Sys'
    Write-MenuItem '4' 'Lister les drivers OS par modele' 'Sous-dossiers fabricant\modele'
    Write-MenuItem '5' 'Verifier les drivers manquants'   'Analyse avant build WinPE'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'

    $c = Read-MenuChoice
    switch ($c) {

        '1' {
            Write-Host ""
            if (-not $accessible) { Write-Warn "Partage inaccessible : $driverBase"; Invoke-Pause; return }

            Write-Host "  Drivers WinPE" -ForegroundColor White
            foreach ($cat in @('WinPE\Net','WinPE\Storage','WinPE\Sys')) {
                $labels = @{ 'WinPE\Net'='NIC reseau'; 'WinPE\Storage'='NVMe/SATA/RAID'; 'WinPE\Sys'='Chipset/USB' }
                $p    = Join-Path $driverBase $cat
                $infs = if (Test-Path $p -EA SilentlyContinue) {
                            @(Get-ChildItem $p -Filter '*.inf' -Recurse -EA SilentlyContinue)
                        } else { @() }
                $subs = if (Test-Path $p -EA SilentlyContinue) {
                            @(Get-ChildItem $p -Directory -EA SilentlyContinue)
                        } else { @() }
                $col  = if ($infs.Count -gt 0) { 'Green' } elseif (Test-Path $p -EA SilentlyContinue) { 'Yellow' } else { 'Red' }
                $state = if (Test-Path $p -EA SilentlyContinue) { "$($infs.Count) .inf" } else { "absent" }
                Write-Host ("    {0,-20} {1,-12}  {2,2} sous-dossier(s)  [{3}]" -f $cat, $state, $subs.Count, $labels[$cat]) -ForegroundColor $col
                $subs | ForEach-Object {
                    $cnt = @(Get-ChildItem $_.FullName -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
                    Write-Host ("         {0,-28} {1} .inf" -f $_.Name, $cnt) -ForegroundColor DarkGray
                }
            }
            Write-Host ""
            Write-Host "  Drivers OS (fabricant\modele)" -ForegroundColor White
            $fabs = @(Get-ChildItem $driverBase -Directory -EA SilentlyContinue | Where-Object { $_.Name -ne 'WinPE' })
            if ($fabs.Count -gt 0) {
                foreach ($fab in $fabs) {
                    $models  = @(Get-ChildItem $fab.FullName -Directory -EA SilentlyContinue)
                    $allInfs = @(Get-ChildItem $fab.FullName -Filter '*.inf' -Recurse -EA SilentlyContinue)
                    Write-Host ("    {0,-18} {1,2} modele(s)   {2,4} .inf total" -f $fab.Name, $models.Count, $allInfs.Count) -ForegroundColor Gray
                    $models | Select-Object -First 4 | ForEach-Object {
                        $cnt = @(Get-ChildItem $_.FullName -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
                        Write-Host ("         {0,-28} {1} .inf" -f $_.Name, $cnt) -ForegroundColor DarkGray
                    }
                    if ($models.Count -gt 4) { Write-Host "         ... $($models.Count-4) autres" -ForegroundColor DarkGray }
                }
            } else {
                Write-Info "Aucun dossier fabricant. Utiliser option [2] pour creer la structure."
            }
            Invoke-Pause
        }

        '2' {
            if (-not $accessible) { Write-Warn "Partage inaccessible : $driverBase"; Invoke-Pause; return }
            $toCreate = @(
                "$driverBase\WinPE\Net",
                "$driverBase\WinPE\Storage",
                "$driverBase\WinPE\Sys",
                "$driverBase\Dell",
                "$driverBase\HP",
                "$driverBase\Lenovo"
            )
            Write-Host ""
            Write-Info "Dossiers a creer :"
            $toCreate | ForEach-Object {
                $exists = Test-Path $_ -EA SilentlyContinue
                $status = if ($exists) { "(existe deja)" } else { "(a creer)" }
                Write-Host "    $_ $status" -ForegroundColor Gray
            }
            Write-Host ""
            if (Read-YesNo "Creer ces dossiers ?" $true) {
                foreach ($dir in $toCreate) {
                    if (-not (Test-Path $dir -EA SilentlyContinue)) {
                        New-Item -ItemType Directory $dir -Force | Out-Null
                        Write-OK "Cree : $dir"
                    } else { Write-Info "Existe : $dir" }
                }
                Write-Host ""
                Write-Info "Deposer ensuite les fichiers .inf/.sys/.cat dans :"
                Write-Host "    WinPE\Net\     drivers NIC WinPE (Intel I225, Realtek 8125...)" -ForegroundColor Gray
                Write-Host "    WinPE\Storage\ NVMe (Samsung, Intel RST, AMD RAID...)" -ForegroundColor Gray
                Write-Host "    WinPE\Sys\     chipset Intel/AMD, USB 3.x" -ForegroundColor Gray
                Write-Host "    Dell\OptiPlex-7090\  drivers OS complets par modele" -ForegroundColor Gray
                Write-Host "    Sources : Dell Command Update, HP SoftPaq, Lenovo System Update" -ForegroundColor DarkGray
            }
            Invoke-Pause
        }

        '3' {
            Write-Host ""
            foreach ($cat in @('WinPE\Net','WinPE\Storage','WinPE\Sys')) {
                $p    = Join-Path $driverBase $cat
                Write-Host "  $cat" -ForegroundColor White
                if (Test-Path $p -EA SilentlyContinue) {
                    $infs = @(Get-ChildItem $p -Filter '*.inf' -Recurse -EA SilentlyContinue)
                    if ($infs.Count -gt 0) {
                        $infs | Select-Object -First 12 | ForEach-Object {
                            Write-Host "    $($_.FullName.Replace($p,'').TrimStart('\'))" -ForegroundColor Gray
                        }
                        if ($infs.Count -gt 12) { Write-Host "    ... $($infs.Count-12) autres" -ForegroundColor DarkGray }
                    } else { Write-Host "    (vide -- aucun .inf)" -ForegroundColor DarkGray }
                } else { Write-Host "    (absent)" -ForegroundColor Red }
                Write-Host ""
            }
            Invoke-Pause
        }

        '4' {
            Write-Host ""
            $fabs = @(Get-ChildItem $driverBase -Directory -EA SilentlyContinue | Where-Object { $_.Name -ne 'WinPE' })
            if ($fabs.Count -eq 0) {
                Write-Info "Aucun dossier fabricant. Utiliser option [2]."; Invoke-Pause; return
            }
            foreach ($fab in $fabs) {
                Write-Host "  $($fab.Name)" -ForegroundColor White
                $models = @(Get-ChildItem $fab.FullName -Directory -EA SilentlyContinue)
                foreach ($model in $models) {
                    $cnt = @(Get-ChildItem $model.FullName -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
                    $col = if ($cnt -gt 0) { 'Gray' } else { 'DarkGray' }
                    Write-Host ("    {0,-35} {1,3} .inf" -f $model.Name, $cnt) -ForegroundColor $col
                }
                if ($models.Count -eq 0) {
                    Write-Host "    (aucun modele -- creer $($fab.Name)\<NOM-MODELE>\)" -ForegroundColor DarkGray
                }
                Write-Host ""
            }
            Invoke-Pause
        }

        '5' {
            Write-Host ""
            Write-Info "Analyse drivers WinPE critiques :"
            Write-Host ""
            $checks = [ordered]@{
                'Net (NIC -- CRITIQUE)'     = 'WinPE\Net'
                'Storage (disques -- CRITIQUE)' = 'WinPE\Storage'
                'Sys (chipset -- optionnel)'= 'WinPE\Sys'
            }
            $allOk = $true
            foreach ($label in $checks.Keys) {
                $p    = Join-Path $driverBase $checks[$label]
                $infs = if (Test-Path $p -EA SilentlyContinue) {
                            @(Get-ChildItem $p -Filter '*.inf' -Recurse -EA SilentlyContinue)
                        } else { @() }
                if ($infs.Count -gt 0) {
                    Write-OK "$label : $($infs.Count) .inf"
                } else {
                    if ($label -match 'CRITIQUE') {
                        Write-Err "$label : AUCUN driver"
                        $allOk = $false
                    } else { Write-Warn "$label : aucun (optionnel)" }
                }
            }
            Write-Host ""
            if ($allOk) {
                Write-OK "Configuration drivers WinPE correcte"
            } else {
                Write-Warn "Drivers manquants -- le WinPE risque de ne pas voir le reseau/les disques"
                Write-Info "Sources recommandees :"
                Write-Host "    Dell/HP/Lenovo : extraire depuis les packs drivers du fabricant (.inf/.sys/.cat)" -ForegroundColor DarkGray
                Write-Host "    Intel NIC I225 : https://www.intel.com/content/www/us/en/download/727998" -ForegroundColor DarkGray
                Write-Host "    Intel RST NVMe : dans le pack Dell/HP WinPE ou sur intel.com" -ForegroundColor DarkGray
            }
            Invoke-Pause
        }
    }
}

# ---------------------------------------------------------------------------
# TEST NOTIFICATIONS
# ---------------------------------------------------------------------------

function Show-NotifyMenu {
    Write-MenuHeader "Notifications"
    Write-MenuItem '1' 'Tester toutes les notifications configurees'
    Write-MenuItem '2' 'Tester uniquement email'
    Write-MenuItem '3' 'Tester uniquement Teams'
    Write-MenuItem '4' 'Afficher la configuration notifications'
    Write-MenuSep
    Write-MenuItem 'R' 'Retour'
    $c = Read-MenuChoice
    switch ($c) {
        '1' { if ($modsLoaded['Notify']) { Test-NotifyConfig -Channel All } else { Write-Warn "Module Notify non charge" }; Invoke-Pause }
        '2' { if ($modsLoaded['Notify']) { Test-NotifyConfig -Channel Mail } else { Write-Warn "Module Notify non charge" }; Invoke-Pause }
        '3' { if ($modsLoaded['Notify']) { Test-NotifyConfig -Channel Teams } else { Write-Warn "Module Notify non charge" }; Invoke-Pause }
        '4' {
            Write-Host ""
            if ($cfgFile) {
                $cfgData = Import-PowerShellDataFile $cfgFile
                if ($cfgData.Notifications) {
                    $cfgData.Notifications | ConvertTo-Json -Depth 5 | Write-Host -ForegroundColor Gray
                } else { Write-Warn "Aucune section Notifications dans $cfgFile" }
            } else { Write-Warn "PSWinDeploy.psd1 non charge" }
            Invoke-Pause
        }
    }
}

# ---------------------------------------------------------------------------
# MENU PRINCIPAL
# ---------------------------------------------------------------------------

while ($true) {
    $health = Get-HealthStatus

    Write-Banner

    # Barre de statut
    $statusBar = [ordered]@{
        'ADK'    = $health.ADK
        ' Imgs'  = $health.Images
        ' Deploy'= $health.Deploy
        ' Vault' = $health.Vault
        ' API'   = $health.Pode
        ' WDS'   = $health.WDS
    }
    Write-StatusBar $statusBar

    if ($cfgFile) { Write-Info "Config : $cfgFile  |  v$($cfg.Version)  |  $($cfg.Architecture)" }
    else { Write-Warn "PSWinDeploy.psd1 non trouve -- valeurs par defaut" }
    Write-Host ""

    # Menu principal
    Write-MenuHeader "Menu principal"

    Write-Host "  DEPLOIEMENT" -ForegroundColor DarkGray
    Write-MenuItem 'D' 'Gerer les sequences' 'Creer / editer des sequences PSD1 de deploiement'
    Write-Host ""

    Write-Host "  WINPE" -ForegroundColor DarkGray
    Write-MenuItem 'W' 'Construire le WinPE' 'Assistant build (packages, drivers, ISO, WIM PXE)'
    Write-MenuItem 'E' 'Exporter une image WIM' 'Depuis un ISO Windows'
    Write-MenuItem 'R' 'Drivers' 'Resume, recherche et organisation des drivers'
    Write-Host ""

    Write-Host "  ADMINISTRATION" -ForegroundColor DarkGray
    Write-MenuItem 'S' 'Sante du systeme' 'Rapport complet (ADK, partages, vault, WDS...)'
    Write-MenuItem 'V' 'Vault / Mots de passe' 'Changer, rotater, convertir les secrets'
    Write-MenuItem 'P' 'Sequences' 'Lister, valider, afficher, (des)activer la sequence par defaut'
    Write-MenuItem 'L' 'Journaux' 'Consulter, rechercher, nettoyer'
    Write-MenuItem 'N' 'Notifications' 'Tester email et Teams'
    Write-Host ""

    Write-Host "  CONFIGURATION" -ForegroundColor DarkGray
    Write-MenuItem 'M' 'Mise a jour'                  'Mettre a jour depuis une archive ou dossier'
    Write-MenuItem 'U' 'Debloquer les scripts'        'Supprimer les avertissements Zone Internet'
    Write-MenuItem 'H' 'API HTTPS / Certificat'       'Generer un cert auto-signe ou en fournir un (chiffrer l API)'
    Write-MenuItem 'I' 'Re-initialiser' 'Relancer Initialize-PSWinDeploy.ps1'
    Write-MenuItem 'C' 'Ouvrir PSWinDeploy.psd1' 'Editer la configuration dans le Bloc-notes'
    $advState = if ($cfg.AdvancedMode) { 'ACTIVE' } else { 'desactive' }
    $advColor = if ($cfg.AdvancedMode) { 'Yellow' } else { 'DarkGray' }
    Write-MenuItem 'A' "Mode avance [$advState]" 'Debloquer les options de diagnostic (test BSOD, etc.)'
    Write-Host ""

    Write-MenuSep
    Write-MenuItem 'Q' 'Quitter'

    $choice = Read-MenuChoice

    switch ($choice) {
        'd' {
            # [D] cote serveur = creer/editer des sequences (pas lancer un deploiement)
            # Le deploiement reel se fait depuis WinPE sur la machine cible
            Write-Host ""
            Write-Host "  Le deploiement se lance depuis WinPE sur la machine cible." -ForegroundColor Cyan
            Write-Host "  Ici vous pouvez creer et editer les sequences de deploiement (.psd1)." -ForegroundColor Gray
            Write-Host ""
            Invoke-Script $scriptPaths.Deploy
        }
        'w' { Invoke-Script $scriptPaths.BuildWinPE }
        'e' { Invoke-Script $scriptPaths.ExportWIM }
        'c' {
            # Regenerer le catalogue os-catalogue.psd1 depuis les WIM existants
            $imgShare = $cfg.ImageShare
            if (-not (Test-Path $imgShare -EA SilentlyContinue)) {
                Write-Host "  Partage Images inaccessible : $imgShare" -ForegroundColor Red
            } else {
                Write-Host "  Scan de $imgShare..." -ForegroundColor Cyan
                $allWims = @(Get-ChildItem $imgShare -Filter '*.wim' -EA SilentlyContinue)
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
                    $catLines += "            FileName = '$($wim.Name)'"
                    $catLines += "            FullPath = '$($wim.FullName)'"
                    $catLines += "            Name     = '$(($wimName -replace ""'"",""''""))'"
                    $catLines += "            SizeGB   = $([Math]::Round($wim.Length/1GB,2))"
                    $eds | ForEach-Object {
                        $catLines += "            # Edition $($_.ImageIndex) : $($_.ImageName)"
                    }
                    $catLines += '        }'
                }
                $catLines += '    )'
                $catLines += '}'
                $catalogPath = Join-Path $imgShare 'os-catalogue.psd1'
                ($catLines -join "`r`n") | Set-Content $catalogPath -Encoding UTF8
                Write-Host "  [OK] Catalogue genere : $catalogPath ($($allWims.Count) image(s))" -ForegroundColor Green
                $allWims | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Gray }
            }
        }
        's' { Show-HealthReport }
        'v' { Show-VaultMenu }
        'p' { Show-SequencesMenu }
        'l' { Show-LogsMenu }
        'r' { Show-DriversMenu }
        'n' { Show-NotifyMenu }
        'h' { Show-HttpsMenu }
        'm' { Invoke-Script $scriptPaths.Update }
        'u' {
            if (Test-Path $scriptPaths.Unblock) {
                Invoke-Script $scriptPaths.Unblock
            } else {
                Write-Step "Deblocage en cours..."
                Get-ChildItem $scriptDir -Recurse -Include '*.ps1','*.psm1','*.psd1','*.cmd','*.psd1' -ErrorAction SilentlyContinue |
                    ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }
                Write-OK "Fichiers debloque dans $scriptDir"
                Invoke-Pause
            }
        }
        'i' { Invoke-Script $scriptPaths.Initialize }
        'c' {
            if ($cfgFile) { Start-Process notepad.exe $cfgFile }
            else { Write-Warn "PSWinDeploy.psd1 non trouve" }
        }
        'a' {
            # Basculer le mode avance et persister dans la config
            $newVal = -not [bool]$cfg.AdvancedMode
            Write-Host ""
            if ($newVal) {
                Write-Host "  Mode avance ACTIVE." -ForegroundColor Yellow
                Write-Host "  Les assistants proposeront des options de diagnostic :" -ForegroundColor Gray
                Write-Host "    - noAutoLogon : desactive l'autologon unattend (test BSOD)" -ForegroundColor Gray
                Write-Host "    - skipUnattend : deploie le WIM brut sans unattend" -ForegroundColor Gray
            } else {
                Write-Host "  Mode avance desactive." -ForegroundColor Cyan
            }
            Write-Host ""
            # Mettre a jour en memoire (la console utilise un hashtable, pas le module Config)
            $cfg['AdvancedMode'] = $newVal
            # Persister dans le fichier PSD1 (modifier juste la cle AdvancedMode)
            if ($cfgFile -and (Test-Path $cfgFile -EA SilentlyContinue)) {
                try {
                    $raw = Get-Content $cfgFile -Raw
                    $valStr = if ($newVal) { '$true' } else { '$false' }
                    if ($raw -match 'AdvancedMode\s*=') {
                        $raw = $raw -replace 'AdvancedMode\s*=\s*\$(true|false)', "AdvancedMode = $valStr"
                    } else {
                        # Ajouter la cle avant la derniere accolade
                        $raw = $raw -replace '\}\s*$', "    AdvancedMode = $valStr`r`n}"
                    }
                    $utf8Bom = New-Object System.Text.UTF8Encoding $true
                    [System.IO.File]::WriteAllText($cfgFile, $raw, $utf8Bom)
                    Write-OK "Configuration persistee : $cfgFile"
                } catch {
                    Write-Warn "Persistance fichier : $_ (actif pour cette session seulement)"
                }
            } else {
                Write-Warn "Fichier config introuvable -- actif pour cette session seulement"
            }
            Invoke-Pause
        }
        'q' {
            Write-Host ""
            Write-Host "  Au revoir." -ForegroundColor Cyan
            Write-Host ""
            exit 0
        }
        default { Write-Warn "Choix invalide : $choice" }
    }
}
