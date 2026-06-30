#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Build-WinPE-Assistant.ps1 -- Assistant interactif de construction WinPE
.DESCRIPTION
    Guide pas a pas la construction d un environnement WinPE bootable :
      1. Verification ADK
      2. Choix architecture (amd64 / arm64)
      3. Packages WinPE a inclure
      4. Drivers par categorie (Net, Storage, Sys)
      5. Configuration reseau (credentials partage)
      6. Customisation (startnet.cmd, fichiers supplementaires)
      7. Choix des medias de sortie : ISO, USB, WIM PXE/WDS
      8. Configuration WDS si disponible
      9. Build et rapport final
.EXAMPLE
    .\Build-WinPE-Assistant.ps1
    .\Build-WinPE-Assistant.ps1 -ConfigPath 'E:\PSWinDeploy\App\PSWinDeploy.psd1'
    .\Build-WinPE-Assistant.ps1 -Unattended   # Utilise PSWinDeploy.psd1 sans questions
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Unattended,
    [switch]$QuickMode      # Mode rapide : valeurs par defaut, aucune question
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Title)
    $w = 58
    Write-Host ""
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    $p = ' ' * [Math]::Max(0,[Math]::Floor(($w-$Title.Length)/2))
    $r = ' ' * [Math]::Max(0,$w-$Title.Length-$p.Length)
    Write-Host "  |$p$Title$r|" -ForegroundColor Cyan
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }

function Read-Answer {
    param([string]$Q, [string]$Default='', [switch]$Required)
    $hint = if ($Default) { " (defaut : $Default)" } else { '' }
    Write-Host "  [?]  $Q$hint : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) {
        if ($Default) { return $Default }
        if ($Required) { Write-Warn "Value required."; return Read-Answer @PSBoundParameters }
        return ''
    }
    return $a.Trim()
}

function Read-YesNo {
    param([string]$Q, [bool]$Def=$true)
    Write-Host "  [?]  $Q [$(if($Def){'O/n'}else{'o/N'})] : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Def }
    return $a.Trim().ToLower() -in @('o','oui','y','yes')
}

function Read-MultiChoice {
    param([string]$Q, [string[]]$Options, [string[]]$Defaults=@())
    Write-Host "  [?]  $Q" -ForegroundColor White
    for ($i=0;$i -lt $Options.Count;$i++) {
        $sel = if ($Options[$i] -in $Defaults) { '[X]' } else { '[ ]' }
        Write-Host "       [$($i+1)] $sel $($Options[$i])" -ForegroundColor Gray
    }
    Write-Host "       [0] Confirm" -ForegroundColor DarkGray
    $selected = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $Defaults) { $selected.Add($d) }
    $editing = $true
    while ($editing) {
        Write-Host "  [?]  Number to check/uncheck (0=confirm): " -ForegroundColor White -NoNewline
        $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        if ($inp -eq '0' -or [string]::IsNullOrWhiteSpace($inp)) { $editing=$false }
        elseif ($inp -match '^\d+$' -and [int]$inp -ge 1 -and [int]$inp -le $Options.Count) {
            $item = $Options[[int]$inp-1]
            if ($selected.Contains($item)) {
                $selected.Remove($item)
                Write-Host "       [-] $item" -ForegroundColor DarkGray
            } else {
                $selected.Add($item)
                Write-Host "       [+] $item" -ForegroundColor Green
            }
        }
    }
    return $selected.ToArray()
}

function Format-Size {
    param([long]$B)
    if ($B -gt 1GB) { return "{0:N1} GB" -f ($B/1GB) }
    if ($B -gt 1MB) { return "{0:N0} MB" -f ($B/1MB) }
    return "{0:N0} KB" -f ($B/1KB)
}

# ---------------------------------------------------------------------------
# CHARGEMENT CONFIG
# ---------------------------------------------------------------------------

$scriptDir   = Split-Path $PSCommandPath -Parent
$projectRoot = Split-Path $scriptDir -Parent

$cfg = @{
    AdkPath         = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    Architecture    = 'amd64'
    WinPEWorkspace  = 'C:\WinPE-Work'
    WinPEOutputPath = 'C:\WinPE-ISO'
    WinPELocale     = 'fr-FR'
    DeployShare     = '\\SERVEUR\Deploy'
    DriverShare     = '\\SERVEUR\Drivers'
    WinPEShareUser  = ''
    WinPESharePassword = ''
}

$cfgSearchPaths = @(
    $ConfigPath,
    "$projectRoot\PSWinDeploy.psd1",
    "$scriptDir\PSWinDeploy.psd1",
    'C:\Deploy\PSWinDeploy.psd1',
    'C:\PSWinDeploy\App\PSWinDeploy.psd1'
)
$configFile = $null
foreach ($p in $cfgSearchPaths) {
    if ($p -and (Test-Path $p -ErrorAction SilentlyContinue)) {
        try {
            $loaded = Import-PowerShellDataFile $p
            foreach ($k in $loaded.Keys) { $cfg[$k] = $loaded[$k] }
            $configFile = $p   # memoriser pour l'embarquer dans le WIM
            Write-OK "Config : $p"
        } catch {}
        break
    }
}

# Charger les modules
$modRoot = Join-Path $projectRoot 'Modules'
foreach ($mod in @('Config','WinPE-Builder')) {
    $mp = Join-Path $modRoot "$mod\$mod.psm1"
    if (Test-Path $mp) { Import-Module $mp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# BANNIERE
# ---------------------------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "     PSWinDeploy -- WinPE build assistant                  " -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# CHOIX DU MODE : RAPIDE (defauts) ou PERSONNALISE
# ---------------------------------------------------------------------------
# Le mode RAPIDE saute toutes les questions et utilise les valeurs par defaut
# (architecture amd64, packages standard, locale fr-FR, ISO + boot.wim PXE).
# Ideal pour reconstruire vite un WinPE sans tout reparametrer.
if (-not $Unattended -and -not $QuickMode) {
    Write-Host "  Mode de construction :" -ForegroundColor White
    Write-Host "    [1] QUICK         -- default values, no questions (recommended)" -ForegroundColor Green
    Write-Host "    [2] CUSTOM        -- choose each option step by step" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [?]  Votre choix [1] : " -ForegroundColor White -NoNewline
    $modeChoice = (Read-Host).Trim()
    if ($modeChoice -ne '2') {
        $QuickMode = $true
        Write-Host ""
        Write-OK "QUICK mode: build with default values"
    } else {
        Write-Host ""
        Write-Info "CUSTOM mode: each option will be asked"
    }
}
# En mode rapide, on se comporte comme Unattended pour les questions tout en
# gardant l'affichage. On centralise via $useDefaults.
$useDefaults = $Unattended -or $QuickMode

# ---------------------------------------------------------------------------
# ETAPE 1 : VERIFICATION ADK
# ---------------------------------------------------------------------------

Write-Header "Step 1 -- ADK check"

$adkRoot  = $cfg.AdkPath
$wpeRoot  = $cfg.WinPEAddonPath
$copype   = Join-Path $wpeRoot 'copype.cmd'
$makemedia= Join-Path $wpeRoot 'MakeWinPEMedia.cmd'
$dismExe  = Join-Path $adkRoot 'Deployment Tools\x86\DISM\dism.exe'

$adkOk = Test-Path $copype
$dismOk = (Test-Path $dismExe) -or ($null -ne (Get-Command dism.exe -ErrorAction SilentlyContinue))

if ($adkOk) {
    Write-OK "ADK detecte : $adkRoot"
    Write-OK "WinPE Add-on : $wpeRoot"
} else {
    Write-Err "ADK or WinPE Add-on not detected!"
    Write-Warn "Telecharger : https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    Write-Warn "  1. Windows ADK (cocher 'Deployment Tools')"
    Write-Warn "  2. WinPE Add-on (tout cocher)"
    if (-not (Read-YesNo "Continue anyway (different ADK path)?" $false)) { exit 1 }
    $adkRoot = Read-Answer "Chemin ADK" -Required
    $wpeRoot = Read-Answer "Chemin WinPE Add-on" -Required
    $copype  = Join-Path $wpeRoot 'copype.cmd'
}

if ($dismOk) { Write-OK "DISM available" }
else         { Write-Warn "DISM not found -- using the system DISM" }

# ---------------------------------------------------------------------------
# ETAPE 2 : ARCHITECTURE
# ---------------------------------------------------------------------------

Write-Header "Step 2 -- Architecture"

Write-Info "Architectures supported since ADK 2004:"
Write-Host "    amd64 : x64 standard -- la quasi-totalite des PC/serveurs" -ForegroundColor Gray
Write-Host "    arm64 : Surface Pro X, Copilot+ PC, serveurs ARM" -ForegroundColor Gray
Write-Host "    x86   : RETIRE depuis ADK 2004 -- non supporte" -ForegroundColor DarkGray
Write-Host ""

$arch = if ($useDefaults) { $cfg.Architecture }
        else { Read-Answer "Architecture" -Default $cfg.Architecture }

if ($arch -eq 'x86') {
    Write-Err "x86 retire depuis ADK 2004. Utiliser amd64."
    $arch = 'amd64'
}
if ($arch -notin @('amd64','arm64')) {
    Write-Warn "Architecture inconnue '$arch' -- bascule sur amd64"
    $arch = 'amd64'
}
Write-OK "Architecture : $arch"

# Verifier que l'arch existe dans l'ADK
$archPath = Join-Path $wpeRoot $arch
if (-not (Test-Path $archPath)) {
    Write-Err "Dossier $arch introuvable dans l'ADK : $archPath"
    Write-Warn "Verifier que le WinPE Add-on est bien installe pour l'architecture $arch"
    if (-not (Read-YesNo "Continue anyway?" $false)) { exit 1 }
}

# ---------------------------------------------------------------------------
# ETAPE 3 : PACKAGES WINPE
# ---------------------------------------------------------------------------

Write-Header "Step 3 -- WinPE packages"

Write-Info "Packages add features to WinPE (they increase the WIM size)."
Write-Host ""

$allPackages = @(
    'PowerShell'
    'WMI'
    'NetFx'
    'Scripting'
    'StorageWMI'
    'EnhancedStorage'
    'HTA'
    'RNDIS'
    'WinRE'
)

$packageDescs = @{
    PowerShell      = 'PS 5.1 -- indispensable pour PSWinDeploy'
    WMI             = 'Detection materiel (modele, RAM, disques)'
    NetFx           = '.NET Framework -- requis par PowerShell'
    Scripting       = 'Compatibilite scripts legacy'
    StorageWMI      = 'Gestion disques avancee (Get-Disk etc.)'
    EnhancedStorage = 'Support stockage chiffre (BitLocker pre-boot)'
    HTA             = 'Applications HTML (UI leger en WinPE)'
    RNDIS           = 'Reseau USB (partage connexion telephone)'
    WinRE           = 'Configuration environnement de recuperation'
}

$defaultPkgs = @('PowerShell','WMI','NetFx','Scripting','StorageWMI','EnhancedStorage')

Write-Info "Available packages:"
foreach ($p in $allPackages) {
    $isDefault = if ($p -in $defaultPkgs) { ' [defaut]' } else { '' }
    Write-Host ("    {0,-20} {1}{2}" -f $p, $packageDescs[$p], $isDefault) -ForegroundColor Gray
}
Write-Host ""

$selectedPkgs = if ($useDefaults) {
    if ($cfg.WinPEPackages) { @($cfg.WinPEPackages) } else { $defaultPkgs }
} else {
    Read-MultiChoice "Packages to include (check/uncheck)" `
        -Options $allPackages -Defaults $defaultPkgs
}

Write-OK "Packages : $($selectedPkgs -join ', ')"

# ---------------------------------------------------------------------------
# ETAPE 4 : DRIVERS
# ---------------------------------------------------------------------------

Write-Header "Step 4 -- WinPE drivers"

Write-Info "WinPE already includes many Microsoft drivers (inbox)."
Write-Info "Add only what is missing for your machines."
Write-Host ""
Write-Host "    Net     : NIC drivers (Intel I219/I225, Realtek 8125...)" -ForegroundColor Gray
Write-Host "              CRITICAL -- without NIC, WinPE cannot see the network" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Storage : disk drivers (NVMe Samsung, Intel RST, AMD RAID...)" -ForegroundColor Gray
Write-Host "              CRITICAL -- without Storage, WinPE cannot see the disks" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Sys     : system drivers (Intel/AMD chipset, USB 3.x...)" -ForegroundColor Gray
Write-Host "              Optional but recommended" -ForegroundColor DarkGray
Write-Host ""

$driverBase = $cfg.DriverShare
if (-not $driverBase) { $driverBase = '\\SERVEUR\Drivers' }

# Proposer les chemins par defaut bases sur la config
$defaultNetPath     = Join-Path $driverBase 'WinPE\Net'
$defaultStoragePath = Join-Path $driverBase 'WinPE\Storage'
$defaultSysPath     = Join-Path $driverBase 'WinPE\Sys'

function Get-DriverPath {
    param([string]$Cat, [string]$Default, [string]$Color='Gray')
    $exists = Test-Path $Default -ErrorAction SilentlyContinue
    $status = if ($exists) { " [accessible]" } else { " [inaccessible ou vide]" }
    Write-Host "  [?]  Chemin drivers $Cat$status" -ForegroundColor White
    Write-Host "       (laisser vide = ignorer cette categorie)" -ForegroundColor DarkGray
    Write-Host "       Defaut : $Default : " -ForegroundColor $Color -NoNewline
    $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($inp)) { return $Default }
    return $inp
}

if ($useDefaults) {
    $netPath     = $defaultNetPath
    $storagePath = $defaultStoragePath
    $sysPath     = $defaultSysPath
} else {
    $netPath     = Get-DriverPath 'Net'     $defaultNetPath     'Cyan'
    $storagePath = Get-DriverPath 'Storage' $defaultStoragePath 'Yellow'
    $sysPath     = Get-DriverPath 'Sys'     $defaultSysPath     'Gray'
}

# Resume accessibilite
foreach ($entry in @(
    @{ Cat='Net';     Path=$netPath }
    @{ Cat='Storage'; Path=$storagePath }
    @{ Cat='Sys';     Path=$sysPath }
)) {
    $exists = Test-Path $entry.Path -ErrorAction SilentlyContinue
    $count  = if ($exists) {
        (@(Get-ChildItem $entry.Path -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)).Count
    } else { 0 }
    $status = if ($exists -and $count -gt 0) { "[OK] $count driver(s) .inf" }
              elseif ($exists)               { "[!]  Empty folder -- no driver will be injected" }
              else                           { "[~]  Inaccessible -- sera ignore au build" }
    $col = if ($exists -and $count -gt 0) { 'Green' } elseif ($exists) { 'Yellow' } else { 'Cyan' }
    Write-Host "    $($entry.Cat,-10) $status  ($($entry.Path))" -ForegroundColor $col
}
Write-Host ""

# ---------------------------------------------------------------------------
# ETAPE 5 : RESEAU (credentials partage)
# ---------------------------------------------------------------------------

Write-Header "Step 5 -- Network access from WinPE"

Write-Info "WinPE needs credentials to access the SMB shares."
Write-Info "These credentials will be stored in the vault and injected into the ISO."
Write-Host ""

$shareUser = $cfg.WinPEShareUser
$sharePass = ''
$vaultPass = ''

if ($shareUser) {
    Write-OK "Compte configure dans PSWinDeploy.psd1 : $shareUser"
    if (-not $useDefaults) {
        if (Read-YesNo "Change the credentials?" $false) {
            $shareUser = Read-Answer "WinPE network account (e.g. SERVER\svc-winpe)" -Default $shareUser
        }
    }
} else {
    Write-Warn "No network account configured in PSWinDeploy.psd1"
    $shareUser = Read-Answer "WinPE network account (e.g. SERVER\svc-winpe)" -Required
}

# Essayer de lire le mot de passe depuis le vault existant (PSD1 plat ou JSON legacy)
$sharePass = ''
# Chercher le vault dans plusieurs emplacements/extensions
$vaultCandidates = @()
if ($cfg.VaultPath) {
    $vaultCandidates += $cfg.VaultPath
    if ($cfg.VaultPath -notmatch '\.psd1$') { $vaultCandidates += "$($cfg.VaultPath).psd1" }
}
# Chercher le vault relativement a l'INSTALLATION (pas C:\Deploy qui est la cible).
# Le vault est genere par l'assistant d'install dans le dossier Deploy de l'install.
$instRoot = Split-Path $projectRoot -Parent   # <install> (parent de App\)
foreach ($base in @($projectRoot, $instRoot, $scriptDir)) {
    $vaultCandidates += (Join-Path $base 'Deploy\secrets.vault.psd1')
    $vaultCandidates += (Join-Path $base 'Deploy\secrets.vault')
    $vaultCandidates += (Join-Path $base 'Shares\Deploy\secrets.vault.psd1')
    $vaultCandidates += (Join-Path $base 'Shares\Deploy\secrets.vault')
    $vaultCandidates += (Join-Path $base 'secrets.vault.psd1')
    $vaultCandidates += (Join-Path $base 'secrets.vault')
}
$vaultCandidates += 'C:\Deploy\secrets.vault.psd1'
$vaultCandidates += 'C:\Deploy\secrets.vault'
$existingVaultPath = $null
foreach ($vc in $vaultCandidates) {
    if ($vc -and (Test-Path $vc -ErrorAction SilentlyContinue)) { $existingVaultPath = $vc; break }
}
if ($existingVaultPath) {
    Write-OK "Vault serveur trouve : $existingVaultPath"
} else {
    Write-Warn "NO server vault found. Searched in:"
    foreach ($vc in $vaultCandidates) { Write-Host "      - $vc" -ForegroundColor DarkGray }
}
if ($existingVaultPath) {
    try {
        if ($existingVaultPath -match '\.psd1$') {
            # Format PSD1 plat (standard actuel)
            $vs = Import-PowerShellDataFile $existingVaultPath
            if ($vs.winpePassword) { $sharePass = $vs.winpePassword }
            elseif ($vs.sharePassword) { $sharePass = $vs.sharePassword }
            if ($sharePass) { Write-OK "Mot de passe WinPE lu depuis le vault PSD1 : $existingVaultPath" }
            # Recuperer aussi l'utilisateur si present
            if (-not $shareUser -and $vs.winpeUser) { $shareUser = $vs.winpeUser }
        } else {
            # Format JSON legacy
            $vd = Get-Content $existingVaultPath -Raw | ConvertFrom-Json
            if ($vd.method -eq 'Plain') {
                $vsj = $vd.data | ConvertFrom-Json
                $sharePass = if ($vsj.winpePassword) { $vsj.winpePassword } elseif ($vsj.sharePassword) { $vsj.sharePassword }
                if ($sharePass) { Write-OK "WinPE password read from the JSON vault" }
            }
        }
    } catch { Write-Warn "Lecture vault existant : $_" }
}

if (-not $sharePass) {
    Write-Host "  [?]  Mot de passe pour $shareUser : " -ForegroundColor White -NoNewline
    $sp = Read-Host -AsSecureString
    $sharePass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
} else {
    if (-not (Read-YesNo "Use the existing vault password?" $true)) {
        Write-Host "  [?]  Nouveau mot de passe pour $shareUser : " -ForegroundColor White -NoNewline
        $sp = Read-Host -AsSecureString
        $sharePass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
    }
}

# Pour les deploiements multi-operateurs, Plain est recommande :
# le vault est dans le WIM/ISO, protege par les droits d acces reseau + physique
$vaultMode = Read-Answer "Chiffrement vault (AES/Plain)" -Default 'Plain'
if ($vaultMode -eq 'Plain') {
    Write-Info "Plain mode: credentials in the WIM (protected by physical/network access)"
    Write-Info "MDT Bootstrap.ini equivalent -- suited for multi-operator environments"
}
if ($vaultMode -eq 'AES') {
    Write-Host "  [?]  Mot de passe vault AES : " -ForegroundColor White -NoNewline
    $vp = Read-Host -AsSecureString
    $vaultPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($vp))
}

# ---------------------------------------------------------------------------
# ETAPE 6 : CUSTOMISATION
# ---------------------------------------------------------------------------

Write-Header "Step 6 -- WinPE customization"

$locale   = Read-Answer "Locale WinPE" -Default $(if ($cfg.WinPELocale) { $cfg.WinPELocale } else { 'fr-FR' })
$timezone = Read-Answer "Fuseau horaire" -Default 'Romance Standard Time'

Write-Host ""
Write-Info "Commandes supplementaires dans startnet.cmd :"
Write-Info "PSWinDeploy automatically adds wpeinit and Start-Deploy.ps1"
$extraCmds = @()
if (-not $useDefaults) {
    if (Read-YesNo "Add custom commands to startnet.cmd?" $false) {
        Write-Host "  Enter commands one by one (empty to finish):" -ForegroundColor Gray
        while ($true) {
            Write-Host "  > " -ForegroundColor White -NoNewline
            $cmd = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            if ([string]::IsNullOrWhiteSpace($cmd)) { break }
            $extraCmds += $cmd
        }
    }
}

# Fichiers supplementaires a copier dans le WIM
$extraFiles = @{}
if (-not $useDefaults) {
    if (Read-YesNo "Copy additional files into the WIM? (scripts, configs)" $false) {
        while ($true) {
            Write-Host "  Source (empty to finish): " -ForegroundColor White -NoNewline
            $src = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            if ([string]::IsNullOrWhiteSpace($src)) { break }
            Write-Host "  Destination dans WIM (ex: Deploy\Scripts) : " -ForegroundColor White -NoNewline
            $dst = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            if ($src -and $dst) { $extraFiles[$src] = $dst }
        }
    }
}

# ---------------------------------------------------------------------------
# ETAPE 7 : MEDIAS DE SORTIE
# ---------------------------------------------------------------------------

Write-Header "Step 7 -- Output media"

Write-Info "Choose the desired output formats:"
Write-Host ""
Write-Host "    ISO     : .iso file for USB key or VM mounting" -ForegroundColor Gray
Write-Host "    USB     : bootable USB key (the key will be FORMATTED)" -ForegroundColor Gray
Write-Host "    WIM PXE : boot.wim for WDS/PXE (network boot)" -ForegroundColor Yellow
Write-Host ""

$buildISO   = if ($useDefaults) { $true  } else { Read-YesNo "Generate an ISO?" $true }
$buildUSB   = if ($useDefaults) { $false } else { Read-YesNo "Create a bootable USB key?" $false }
$buildPXE   = if ($useDefaults) { $true  } else { Read-YesNo "Generate a boot.wim for WDS/PXE?" $true }

$usbDrive = ''
if ($buildUSB) {
    Write-Host ""
    Write-Warn "The selected USB key will be ENTIRELY FORMATTED!"
    # Lister les lecteurs USB
    $usbDrives = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | ForEach-Object {
        $vols = Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                Get-Volume -ErrorAction SilentlyContinue
        $letter = @(($vols | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter)
        [PSCustomObject]@{ Number=$_.Number; Name=$_.FriendlyName; Size=(Format-Size $_.Size); Letter=$letter }
    }
)
    if ($usbDrives.Count -gt 0) {
        Write-Info "USB keys detected:"
        foreach ($d in $usbDrives) {
            $letter = if ($d.Letter) { "$($d.Letter):" } else { '(non monte)' }
            Write-Host "    $letter  $($d.Name)  $($d.Size)" -ForegroundColor Gray
        }
    }
    $usbDrive = Read-Answer "Lettre de la cle USB cible (ex: E)" -Required
    $usbDrive = $usbDrive.TrimEnd(':') + ':'
}

# Chemins de sortie
$workspacePath = Read-Answer "WinPE workspace folder" -Default $(if ($cfg.WinPEWorkspace) { $cfg.WinPEWorkspace } else { 'C:\WinPE-Work' })
$outputPath    = Read-Answer "Output folder (ISO / WIM)" -Default $(if ($cfg.WinPEOutputPath) { $cfg.WinPEOutputPath } else { 'C:\WinPE-ISO' })

# ---------------------------------------------------------------------------
# ETAPE 8 : CONFIGURATION WDS (si demande et disponible)
# ---------------------------------------------------------------------------

$wdsConfig = $null

if ($buildPXE) {
    Write-Header "Step 8 -- WDS configuration"

    $wdsAvailable = $false
    try {
        $wdsSvc = Get-Service -Name WDSServer -ErrorAction SilentlyContinue
        if ($wdsSvc) {
            $wdsAvailable = $true
            $wdsStatus    = $wdsSvc.Status
            Write-OK "Service WDS detecte : $wdsStatus"
        }
    } catch {}

    if (-not $wdsAvailable) {
        Write-Info "WDS service (WDSServer) not detected on this server."
        Write-Info "The boot.wim will be generated -- you can import it manually into WDS."
        Write-Host ""
        Write-Info "Pour installer WDS :"
        Write-Host "    Install-WindowsFeature WDS -IncludeManagementTools" -ForegroundColor Gray
        Write-Host "    wdsutil /initialize-server /remInst:D:\RemoteInstall" -ForegroundColor Gray
    } else {
        if (Read-YesNo "Configure WDS automatically with the generated boot.wim?" $true) {
            $wdsConfig = @{
                Configure   = $true
                RemInstPath = Read-Answer "Chemin RemoteInstall WDS" -Default 'D:\RemoteInstall'
                BootImageName = Read-Answer "WDS boot image name" -Default 'PSWinDeploy WinPE'
                StartService  = Read-YesNo "Restart the WDS service after configuration?" $true
            }
            Write-OK "WDS sera configure automatiquement"
        }
    }
}

# ---------------------------------------------------------------------------
# RECAPITULATIF
# ---------------------------------------------------------------------------

Write-Header "Recapitulatif -- Approbation avant build"

Write-Host "  Architecture    : $arch" -ForegroundColor White
Write-Host "  Locale          : $locale" -ForegroundColor White
Write-Host "  Packages        : $($selectedPkgs -join ', ')" -ForegroundColor White
Write-Host ""
Write-Host "  Drivers Net     : $netPath" -ForegroundColor $(if(Test-Path $netPath -EA SilentlyContinue){'Green'}else{'Yellow'})
Write-Host "  Drivers Storage : $storagePath" -ForegroundColor $(if(Test-Path $storagePath -EA SilentlyContinue){'Green'}else{'Yellow'})
Write-Host "  Drivers Sys     : $sysPath" -ForegroundColor $(if(Test-Path $sysPath -EA SilentlyContinue){'Green'}else{'Yellow'})
Write-Host ""
Write-Host "  Compte reseau   : $shareUser" -ForegroundColor White
Write-Host "  Vault           : $vaultMode" -ForegroundColor White
Write-Host ""
Write-Host "  Workspace       : $workspacePath" -ForegroundColor White
Write-Host "  Sortie          : $outputPath" -ForegroundColor White
Write-Host ""
Write-Host "  Media           : " -NoNewline -ForegroundColor White
$medias = @()
if ($buildISO) { $medias += 'ISO' }
if ($buildUSB) { $medias += "USB ($usbDrive)" }
if ($buildPXE) { $medias += 'WIM PXE/WDS' }
Write-Host ($medias -join '  |  ') -ForegroundColor Cyan
if ($wdsConfig) {
    Write-Host "  Config WDS      : Oui ($($wdsConfig.RemInstPath))" -ForegroundColor Green
}
Write-Host ""

if (-not (Read-YesNo "Start the build?" $true)) {
    Write-Warn "Build cancelled."
    exit 0
}

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

Write-Header "Build en cours"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# S'assurer que les modules sont charges
$wpeModPath = Join-Path (Split-Path $scriptDir -Parent) 'Modules\WinPE-Builder\WinPE-Builder.psm1'
if (Test-Path $wpeModPath) {
    Import-Module $wpeModPath -Force
    Write-OK "Module WinPE-Builder charge"
} else {
    Write-Err "Module WinPE-Builder introuvable : $wpeModPath"
    exit 1
}
$nsModPath = Join-Path (Split-Path $scriptDir -Parent) 'Modules\NetShare\NetShare.psm1'
if (Test-Path $nsModPath) { Import-Module $nsModPath -Force }

# -- Configurer l'ADK si different du defaut
Set-WinPEConfig -AdkPath $adkRoot `
    -Architecture $arch `
    -WorkspacePath $workspacePath `
    -Locale $locale

# -- Creer le vault WinPE avec les credentials reseau
Write-Step "Creating the WinPE network vault..."
if (-not (Test-Path $outputPath)) { New-Item -ItemType Directory $outputPath -Force | Out-Null }
$vaultTmpDir = Join-Path $env:TEMP "pswpe-vault-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory $vaultTmpDir -Force | Out-Null

# Garde-fou : le mot de passe ne doit jamais etre vide
if ([string]::IsNullOrWhiteSpace($sharePass)) {
    Write-Warn "Empty WinPE password -- entry required"
    Write-Host "  [?]  Mot de passe pour $shareUser : " -ForegroundColor White -NoNewline
    $sp = Read-Host -AsSecureString
    $sharePass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
    if ([string]::IsNullOrWhiteSpace($sharePass)) {
        throw "WinPE password required to create the network vault."
    }
}

$vaultArgs = @{
    Username   = $shareUser
    Password   = $sharePass
    OutputPath = $vaultTmpDir
}
if ($vaultMode -eq 'Plain')  { $vaultArgs.Plain         = $true }
elseif ($vaultPass)           { $vaultArgs.VaultPassword = $vaultPass }

# IMPORTANT : reporter localAdminPassword (et autres secrets metier) depuis le
# vault SERVEUR existant vers le vault embarque. Sinon le WIM n'a que les
# credentials WinPE, et la phase 1/2 retombe sur le mot de passe admin par defaut.
$extraSecrets = @{}
if ($existingVaultPath -and (Test-Path $existingVaultPath -EA SilentlyContinue)) {
    try {
        if ($existingVaultPath -match '\.psd1$') {
            $srvVault = Import-PowerShellDataFile $existingVaultPath -EA Stop
        } else {
            $srvVault = Get-Content $existingVaultPath -Raw | ConvertFrom-Json
        }
        foreach ($k in @('localAdminPassword','domainJoinUser','domainJoinPassword')) {
            $val = $null
            if ($srvVault -is [hashtable]) { if ($srvVault.ContainsKey($k)) { $val = $srvVault[$k] } }
            else { if ($srvVault.PSObject.Properties[$k]) { $val = $srvVault.$k } }
            if ($val) { $extraSecrets[$k] = $val }
        }
        if ($extraSecrets.ContainsKey('localAdminPassword')) {
            Write-OK "localAdminPassword carried over from the server vault into the WIM"
        } else {
            Write-Warn "localAdminPassword ABSENT du vault serveur ($existingVaultPath)"
            Write-Warn "=> the local admin password will be the default. Add the key to the server vault."
        }
    } catch {
        Write-Warn "Lecture du vault serveur pour localAdminPassword echouee : $_"
    }
} else {
    Write-Warn "No server vault found -- localAdminPassword not carried over (default used)."
}
if ($extraSecrets.Count -gt 0) { $vaultArgs.AdditionalSecrets = $extraSecrets }

if (Get-Command New-WinPEShareVault -ErrorAction SilentlyContinue) {
    $vaultFile = New-WinPEShareVault @vaultArgs
    Write-OK "Vault WinPE cree : $vaultFile"
} else {
    Write-Warn "New-WinPEShareVault function unavailable -- vault not generated"
    $vaultFile = $null
}

# -- Build WinPE principal
Write-Step "Construction WinPE ($arch)..."

# Construire la commande startnet avec les parametres du serveur
# NetworkShare : lu depuis PSWinDeploy.psd1 (WinPEShareServer)
$deployServer = if ($cfg.WinPEShareServer) { $cfg.WinPEShareServer } else { $cfg.ServerFQDN }
if (-not $deployServer) { $deployServer = $env:COMPUTERNAME }

$networkShare   = "\\\\$deployServer\\Deploy"
$vaultInWim     = 'X:\Deploy\secrets.vault'

# Resoudre l IP du serveur au moment du build pour un fallback fiable en WinPE
# (DNS pas toujours disponible au boot WinPE avant connexion reseau complete)
$serverIP = $null
# Priorite : l'IP declaree dans PSWinDeploy.psd1 (WinPEShareServerIP).
if ($cfg.WinPEShareServerIP) {
    $serverIP = $cfg.WinPEShareServerIP
    Write-OK "IP serveur depuis la config : $serverIP"
} else {
    # Sinon, resoudre par DNS au build.
    try {
        $dns = [System.Net.Dns]::GetHostAddresses($deployServer) |
               Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
               Select-Object -First 1
        if ($dns) {
            $serverIP = $dns.IPAddressToString
            Write-OK "Serveur $deployServer resolu : $serverIP (fallback IP)"
        }
    } catch {
        Write-Warn "Resolution DNS $deployServer echouee -- pas de fallback IP"
    }
}

$networkShareFallback = if ($serverIP) { "\\\\$serverIP\\Deploy" } else { $null }

# Construire la commande Start-Deploy avec nom ET IP de fallback
# ImageShare depuis PSWinDeploy.psd1
$imageShareVal = if ($cfg.ImageShare) {
    # ImageShare peut etre @{DNS;IP} ou une string. Prendre la forme DNS comme base.
    if ($cfg.ImageShare -is [hashtable]) { $cfg.ImageShare['DNS'] } else { $cfg.ImageShare }
} else {
    ($networkShare -replace '\\Deploy$', '\Images')
}
# Remplacer le serveur par IP si basculement
if ($serverIP -and $imageShareVal -match '^\\\\([^\\]+)\\') {
    $imageShareVal = $imageShareVal -replace [regex]::Escape($Matches[1]), $serverIP
}

$startDeployCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Scripts\Start-Deploy.ps1"
$startDeployCmd += " -NetworkShare `"$networkShare`""
$startDeployCmd += " -VaultPath `"$vaultInWim`""
$startDeployCmd += " -ImageShare `"$imageShareVal`""
if ($networkShareFallback) {
    $startDeployCmd += " -NetworkShareFallback `"$networkShareFallback`""
}

# Forcer AZERTY en tout debut de startnet (avant Start-Deploy)
# wpeutil SetKeyboardLocale s assure que le clavier est bien FR meme si DISM ne suffit pas
$localeForKeyboard = if ($locale) { $locale } elseif ($cfg.WinPELocale) { $cfg.WinPELocale } else { 'fr-FR' }
$startnetCmds = @(
    "wpeutil SetKeyboardLocale $localeForKeyboard",
    $startDeployCmd
)
if ($extraCmds) { $startnetCmds += $extraCmds }

$filesToCopy = @{}
# Injecter le vault dans le WIM
if ($vaultFile -and (Test-Path $vaultFile)) {
    $filesToCopy[$vaultFile] = 'Deploy'
}
# Injecter PSWinDeploy.psd1 (LA source unique de config) dans le WIM.
# Il sera lu en phase 1 (X:\Deploy) et copie sur C:\Deploy en phase 2.
if ($configFile -and (Test-Path $configFile)) {
    $filesToCopy[$configFile] = 'Deploy'
    Write-OK "Config PSWinDeploy.psd1 embarquee dans le WIM : $configFile"
} else {
    Write-Warn "PSWinDeploy.psd1 not found -- the config will not be embedded!"
}
# Copier les modules Deploy dans le WIM
$deployModules = Join-Path (Split-Path $scriptDir -Parent) 'Modules'
if (Test-Path $deployModules) { $filesToCopy[$deployModules] = 'Deploy\Modules' }
$deployScripts = $scriptDir
if (Test-Path $deployScripts) { $filesToCopy[$deployScripts] = 'Deploy\Scripts' }
# Sequences et Profiles : PAS embarques dans le WIM. Ils vivent sur le PARTAGE
# (\\serveur\Deploy\Sequences), pour pouvoir en ajouter/modifier SANS rebuild
# du WinPE (et gestion future via web/API). WinPE les lit par le reseau.
# (Separation code/donnees : le moteur dans le WIM, les donnees sur le partage.)
# Fichiers supplementaires
foreach ($k in $extraFiles.Keys) {
    if (Test-Path $k) { $filesToCopy[$k] = $extraFiles[$k] }
}

$buildArgs = @{
    WorkspacePath      = $workspacePath
    Architecture       = $arch
    Packages           = $selectedPkgs
    StartnetCommands   = $startnetCmds
    OutputPath         = $outputPath
    ISOFileName        = "WinPE-$arch.iso"
    Force              = $true
}
if ($filesToCopy.Count -gt 0) { $buildArgs.ExtraFiles = $filesToCopy }

# Drivers
if ((Test-Path $netPath -EA SilentlyContinue) -or
    (Test-Path $storagePath -EA SilentlyContinue) -or
    (Test-Path $sysPath -EA SilentlyContinue)) {
    $buildArgs.DriversNetPath     = $netPath
    $buildArgs.DriversStoragePath = $storagePath
    $buildArgs.DriversSysPath     = $sysPath
}

$buildResult = Invoke-WinPEBuild @buildArgs

Write-OK "Main build complete"

# -- Generer le WIM PXE/WDS si demande
$pxeWimPath = $null
if ($buildPXE) {
    Write-Step "Generating boot.wim for PXE/WDS..."
    $pxeDir = Join-Path $outputPath 'PXE'
    if (-not (Test-Path $pxeDir)) { New-Item -ItemType Directory $pxeDir -Force | Out-Null }
    $pxeWimPath = Join-Path $pxeDir "boot-$arch.wim"

    # Le boot.wim se trouve dans le media WinPE genere
    $sourceWim = Join-Path $workspacePath 'media\sources\boot.wim'
    if (Test-Path $sourceWim) {
        Copy-Item $sourceWim $pxeWimPath -Force
        $pxeSize = Format-Size (Get-Item $pxeWimPath).Length
        Write-OK "boot.wim PXE : $pxeWimPath ($pxeSize)"
    } else {
        Write-Warn "boot.wim source introuvable : $sourceWim"
        Write-Warn "Le build ISO n'a peut-etre pas encore commis le WIM"
    }
}

# -- Configuration WDS automatique
if ($buildPXE -and $pxeWimPath -and $wdsConfig -and $wdsConfig.Configure) {
    Write-Step "Configuration WDS..."

    $remInst   = $wdsConfig.RemInstPath
    $bootImages = Join-Path $remInst "Boot"
    $wdsWimDest = Join-Path $bootImages "$arch\Images\boot.wim"

    if (-not (Test-Path (Split-Path $wdsWimDest -Parent))) {
        New-Item -ItemType Directory (Split-Path $wdsWimDest -Parent) -Force | Out-Null
    }

    # Copier le WIM dans RemoteInstall
    Copy-Item $pxeWimPath $wdsWimDest -Force
    Write-OK "WIM copie : $wdsWimDest"

    # Importer dans WDS via wdsutil
    $wdsutilArgs = @(
        '/verbose',
        '/add-image',
        "/imagefile:$wdsWimDest",
        '/imagetype:boot',
        "/imagegroup:$($wdsConfig.BootImageName)"
    )

    try {
        $wdsOut = & wdsutil.exe @wdsutilArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Image importee dans WDS : $($wdsConfig.BootImageName)"
        } else {
            Write-Warn "wdsutil : $($wdsOut | Select-Object -Last 3 | Out-String)"
            Write-Warn "Import manually via the WDS console or wdsutil /add-image"
        }
    } catch {
        Write-Warn "wdsutil non disponible : $_"
        Write-Info "Importer manuellement :"
        Write-Info "  wdsutil /add-image /imagefile:$wdsWimDest /imagetype:boot"
    }

    # Redemarrer WDS si demande
    if ($wdsConfig.StartService) {
        try {
            Restart-Service WDSServer -Force
            Write-OK "WDS service restarted"
        } catch {
            Write-Warn "Impossible de redemarrer WDS : $_"
        }
    }
}

# Nettoyage vault temporaire
Remove-Item $vaultTmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# RAPPORT FINAL
# ---------------------------------------------------------------------------

$sw.Stop()
Write-Header "Build complete"

Write-Host "  Duree totale : $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min" -ForegroundColor White
Write-Host ""
Write-Host "  Files produced:" -ForegroundColor White
Write-Host ""

$isoPath = Join-Path $outputPath "WinPE-$arch.iso"
if (Test-Path $isoPath) {
    $sz = Format-Size (Get-Item $isoPath).Length
    Write-Host "    ISO     : $isoPath  ($sz)" -ForegroundColor Green
} else {
    Write-Host "    ISO     : not generated" -ForegroundColor DarkGray
}

if ($buildUSB -and $usbDrive) {
    Write-Host "    USB     : $usbDrive (bootable)" -ForegroundColor Green
}

if ($pxeWimPath -and (Test-Path $pxeWimPath)) {
    $sz = Format-Size (Get-Item $pxeWimPath).Length
    Write-Host "    WIM PXE : $pxeWimPath  ($sz)" -ForegroundColor Green
}

Write-Host ""
Write-Host "  Utilisation :" -ForegroundColor White
Write-Host ""

if (Test-Path $isoPath) {
    Write-Host "    ISO  --> Burn to USB with Rufus or mount in a VM" -ForegroundColor Gray
}
if ($pxeWimPath -and (Test-Path $pxeWimPath)) {
    Write-Host "    WIM PXE :" -ForegroundColor Gray
    if (-not $wdsConfig) {
        Write-Host "      Copy into the WDS RemoteInstall folder:" -ForegroundColor Gray
        Write-Host "        wdsutil /add-image /imagefile:$pxeWimPath /imagetype:boot" -ForegroundColor Cyan
        Write-Host "      Or via the WDS console: right-click Boot Images > Add" -ForegroundColor Gray
    } else {
        Write-Host "      Image importee dans WDS : $($wdsConfig.BootImageName)" -ForegroundColor Green
        Write-Host "      Configure the WDS answer policy if not already done" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  Notes WDS/PXE :" -ForegroundColor Cyan
Write-Host "    - Configure DHCP option 66 (WDS server name) and 67 (pxeboot.n12)" -ForegroundColor Gray
Write-Host "    - Or DHCP option 60 (PXEClient) depending on your DHCP server" -ForegroundColor Gray
Write-Host "    - Le serveur WDS doit repondre aux clients PXE (wdsutil /set-server /answerclientson)" -ForegroundColor Gray
Write-Host ""
