#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Initialize-PSWinDeploy.ps1 - Script d'initialisation interactif PSWinDeploy
.DESCRIPTION
    Guide pas a pas l'installation et la configuration complete de PSWinDeploy.
    A lancer UNE SEULE FOIS sur le serveur de deploiement, en tant qu'Administrateur.
    Peut etre relance sans risque (detecte ce qui existe deja).
.EXAMPLE
    .\Initialize-PSWinDeploy.ps1
    .\Initialize-PSWinDeploy.ps1 -InstallPath 'D:\PSWinDeploy' -Silent
#>

[CmdletBinding()]
param(
    [string]$InstallPath,
    [switch]$Silent,
    [switch]$SkipADK,
    [switch]$SkipShares,
    [switch]$SkipVault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
function New-RandomString {
    param([int]$Length = 20)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    # -Count avec Get-Random : tirage sans repetition, pas de boucle.
    return -join (Get-Random -Count $Length -InputObject $chars)
}

# ---------------------------------------------------------------------------
# HELPERS VISUELS
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Title)
    $width = 58
    $line  = '-' * $width
    Write-Host ""
    Write-Host "  +$line+" -ForegroundColor Cyan
    $pad  = ' ' * [Math]::Max(0, [Math]::Floor(($width - $Title.Length) / 2))
    $padR = ' ' * [Math]::Max(0, $width - $Title.Length - $pad.Length)
    Write-Host "  |$pad$Title$padR|" -ForegroundColor Cyan
    Write-Host "  +$line+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }

function Read-Answer {
    param(
        [string]$Question,
        [string]$Default   = '',
        [string[]]$Options,
        [switch]$Password,
        [switch]$Required
    )
    $hint = if ($Default)  { " (defaut : $Default)" } else { '' }
    $opts = if ($Options)  { " [$($Options -join '/')] " } else { ' ' }
    Write-Host "  [?]  $Question$hint$opts" -ForegroundColor White -NoNewline

    if ($Password) {
        $secure = Read-Host -AsSecureString
        $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if (-not $plain -and $Default) { return $Default }
        return $plain
    }

    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) {
        if ($Default)   { return $Default }
        if ($Required)  {
            Write-Warn "This value is required."
            return Read-Answer @PSBoundParameters
        }
        return ''
    }

    if ($Options) {
        $match = $Options | Where-Object { $_.ToLower() -eq $answer.Trim().ToLower() } | Select-Object -First 1
        if (-not $match) {
            Write-Warn "Invalid value. Choose from: $($Options -join ', ')"
            return Read-Answer @PSBoundParameters
        }
        return $match
    }
    # Supprimer les guillemets ajoutes par Windows (Copier en tant que chemin)
    $cleaned = $answer.Trim().Trim('"').Trim("'").Trim()
    return $cleaned
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $defStr = if ($Default) { 'O/n' } else { 'o/N' }
    Write-Host "  [?]  $Question [$defStr] : " -ForegroundColor White -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower() -in @('o','oui','y','yes')
}

function Read-Password {
    param([string]$Question)
    $pw1 = $null
    $pw2 = $null
    do {
        $pw1 = Read-Answer -Question $Question -Password -Required
        $pw2 = Read-Answer -Question "Confirm" -Password -Required
        if ($pw1 -ne $pw2) { Write-Warn "Passwords do not match." }
    } while ($pw1 -ne $pw2)
    return $pw1
}

# ---------------------------------------------------------------------------
# BANNIERE
# ---------------------------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "                PSWinDeploy  --  Setup                     " -ForegroundColor Cyan
Write-Host "         A modern MDT replacement in PowerShell  v0.8.0    " -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This script will:" -ForegroundColor White
Write-Host "    1. Choose the installation folder" -ForegroundColor Gray
Write-Host "    2. Create the folder structure and SMB shares" -ForegroundColor Gray
Write-Host "    3. Generate the PSWinDeploy.psd1 configuration file" -ForegroundColor Gray
Write-Host "    4. Create the secrets vault (encrypted passwords)" -ForegroundColor Gray
Write-Host "    5. Check prerequisites (ADK, Pode)" -ForegroundColor Gray
Write-Host "    6. Generate Start-API.ps1 and Build-WinPE.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  Note: the domain-join account (svc-joindomain) is used" -ForegroundColor DarkGray
Write-Host "  ONLY by the target machine during the JoinDomain step." -ForegroundColor DarkGray
Write-Host "  The PSWinDeploy server itself does not need to join a domain." -ForegroundColor DarkGray
Write-Host ""

if (-not $Silent) {
    Write-Host "  [?]  Press Enter to start..." -ForegroundColor White -NoNewline
    Read-Host | Out-Null
}

# ---------------------------------------------------------------------------
# ETAPE 1 -- CHEMIN D'INSTALLATION
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# STEP 1 -- INSTALLATION PATH
# ---------------------------------------------------------------------------

Write-Header "Step 1 -- Installation path"
Write-Info "Contains modules, shares, WinPE ISO and configuration."
Write-Host ""

if (-not $InstallPath) {
    Write-Info "Available drives:"
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } |
        ForEach-Object {
            $freeGB = if ($_.Free) { [Math]::Round($_.Free / 1GB, 1) } else { '?' }
            Write-Host ("    {0}:\  {1} GB free" -f $_.Name, $freeGB) -ForegroundColor Gray
        }
    Write-Host ""
    $InstallPath = Read-Answer -Question "Installation folder" -Default 'C:\PSWinDeploy' -Required
}

$InstallPath = $InstallPath.TrimEnd('\')
Write-Info "Selected path: $InstallPath"

$driveLetter = Split-Path $InstallPath -Qualifier
$driveObj    = Get-PSDrive -Name $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
if ($driveObj -and $driveObj.Free) {
    $freeGB = [Math]::Round($driveObj.Free / 1GB, 1)
    if ($driveObj.Free -lt 20GB) {
        Write-Warn "Free space: $freeGB GB (recommended minimum: 20 GB)"
        if (-not (Read-YesNo "Continue anyway?" $false)) { exit 1 }
    } else {
        Write-OK "Free space: $freeGB GB"
    }
}

# ---------------------------------------------------------------------------
# ETAPE 2 -- RESEAU
# ---------------------------------------------------------------------------

Write-Header "Step 2 -- Network configuration"

# Detection automatique du NOM et de l'IP du serveur. L'utilisateur confirme
# (defaut = valeur detectee) ou saisit manuellement. Les deux servent a generer
# les partages au format @{ DNS; IP } -- robuste dans ET hors domaine.
$serverName = $env:COMPUTERNAME
Write-Info "Detected server name: $serverName"
$serverFQDN = Read-Answer -Question "Server DNS name (for the shares)" -Default $serverName
if ([string]::IsNullOrWhiteSpace($serverFQDN)) {
    $serverFQDN = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($serverFQDN)) {
        $serverFQDN = Read-Answer -Question "Server name (required)" -Required
    }
}

# Detecter l'IPv4 principale (premiere IP non-loopback, non-APIPA)
$detectedIp = ''
try {
    $detectedIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Sort-Object -Property SkipAsSource | Select-Object -First 1).IPAddress
} catch {}
if (-not $detectedIp) {
    try {
        $detectedIp = ([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -First 1).IPAddressToString
    } catch {}
}
if ($detectedIp) { Write-Info "Detected IP address: $detectedIp" }
$serverIP = Read-Answer -Question "Server IP address (fallback outside domain)" -Default $detectedIp
if ([string]::IsNullOrWhiteSpace($serverIP)) {
    Write-Warn "No IP provided -- IP fallback won't be available (risk outside domain)."
    $serverIP = $serverFQDN  # repli : utiliser le nom partout
}
Write-Info "Serveur : nom='$serverFQDN' IP='$serverIP'"

Write-Host ""
Write-Info "SMB shares that will be created:"
foreach ($s in @('Images','Deploy','Drivers','Logiciels','Scripts','Logs')) {
    Write-Host ("    \\{0}\{1}  -->  {2}\Shares\{1}" -f $serverFQDN, $s, $InstallPath) -ForegroundColor Gray
}
Write-Host ""
$createShares = -not $SkipShares -and (Read-YesNo "Create the SMB shares on this server?" $true)

# ---------------------------------------------------------------------------
# ETAPE 3 -- COMPTE RESEAU WINPE (svc-winpe)
# ---------------------------------------------------------------------------

Write-Header "Step 3 -- WinPE network account"

Write-Info "This account lets WinPE access the deployment shares."
Write-Info "Rights: read-only on Images/Deploy/Drivers, write on Logs."
Write-Info "This account has NO access to deployed machines."
Write-Host ""

$winpeUserMode = Read-Answer -Question "Account type" -Options @('local','domaine') -Default 'local'

if ($winpeUserMode -eq 'local') {
    $winpeUser     = Read-Answer -Question "Local account name" -Default 'svc-winpe'
    $winpeUserFull = "$serverName\$winpeUser"
} else {
    $wpeDomain     = Read-Answer -Question "Domain name" -Required
    $winpeUser     = Read-Answer -Question "Account name" -Default 'svc-winpe'
    $winpeUserFull = "$wpeDomain\$winpeUser"
}

if ($winpeUserMode -eq 'local') {
    # Account local : choix entre mot de passe aleatoire ou saisie manuelle.
    $winpePasswordMode = Read-Answer -Question "[R] Random or [S] Enter the password" -Options @('R','S') -Default 'R'
    if ($winpePasswordMode -eq 'R') {
        $winpePassword = New-RandomString
    } else {
        $winpePassword = Read-Password -Question "Password for $winpeUserFull"
    }
} else {
    # Account de domaine : saisie obligatoire (le compte existe deja dans l'AD).
    $winpePassword = Read-Password -Question "Password for $winpeUserFull"
}

# ---------------------------------------------------------------------------
# ETAPE 4 -- JONCTION DOMAINE
# ---------------------------------------------------------------------------

Write-Header "Step 4 -- Active Directory domain join"

Write-Info "The join account is used by the DEPLOYED MACHINE (not the server)"
Write-Info "during the JoinDomain step to register in AD."
Write-Host ""

$joinDomain     = Read-YesNo "Do deployed machines join an AD domain?" $true
$domainName     = ''
$domainJoinUser = ''
$domainJoinPass = ''
$defaultOU      = ''

if ($joinDomain) {
    $domainName     = Read-Answer -Question "Domain name (ex: corp.local)" -Required
    $domainJoinUser = Read-Answer -Question "Join account (e.g. svc-joindomain)" -Default 'svc-joindomain'
    Write-Info "This account needs 'Add workstations to domain' on the target OU."
    $domainJoinPass = Read-Password -Question "Password for $domainJoinUser"
    $defaultOU      = Read-Answer -Question "Default OU (leave empty if not applicable)" -Default ''
}

# ---------------------------------------------------------------------------
# ETAPE 5 -- MOTS DE PASSE
# ---------------------------------------------------------------------------

Write-Header "Step 5 -- Deployment passwords"

Write-Info "These passwords are encrypted in the vault, never in cleartext."
Write-Host ""

Write-Info "Password for the machines' built-in local Administrator account:"
Write-Info "This account already exists in Windows -- we just set its password."
Write-Info "It is used for phase 2 autologon and remains the machine admin."
$localAdminPassMode = Read-Answer -Question "[R] Random or [S] Enter the password" -Options @('R','S') -Default 'R'
if ($localAdminPassMode -eq 'R') {
    $localAdminPass = New-RandomString
} else {
    $localAdminPass = Read-Password -Question "Local Administrator password"
}

# NB : la jonction de domaine (compte + mot de passe) a DEJA ete demandee a
# l'etape 4. On NE la redemande PAS ici (sinon double saisie + ecrasement des
# variables de l'etape 4).

Write-Host ""
$vaultMode = Read-Answer -Question "Vault encryption mode" -Options @('AES','Plain') -Default 'Plain'

$vaultPassword = ''
if ($vaultMode -eq 'AES') {
    Write-Info "The AES password protects the vault. Required at WinPE boot."
    Write-Info "Can also be passed via the PSWINDEX_VAULT_PASSWORD env variable."
    $vaultPassword = Read-Password -Question "AES vault password"
} else {
    Write-Warn "Plain mode: vault in cleartext, protected by network rights and physical access."
}

# ---------------------------------------------------------------------------
# ETAPE 6 -- WINPE
# ---------------------------------------------------------------------------

Write-Header "Step 6 -- WinPE configuration"

Write-Info "Note: x86 removed since ADK 2004. Supported architectures: amd64, arm64."
Write-Host ""
$arch     = Read-Answer -Question "Architecture" -Options @('amd64','arm64') -Default 'amd64'
$locale   = Read-Answer -Question "Locale" -Default 'fr-FR'
$timezone = Read-Answer -Question "Time zone" -Default 'Romance Standard Time'
$firmware = Read-Answer -Question "Default firmware" -Options @('UEFI','BIOS') -Default 'UEFI'

# ---------------------------------------------------------------------------
# ETAPE 7 -- NOTIFICATIONS
# ---------------------------------------------------------------------------

Write-Header "Step 7 -- Notifications (optional)"

$configNotif  = Read-YesNo "Configure notifications (email / Teams)?" $false
$smtpServer   = ''
$smtpFrom     = ''
$smtpTo       = ''
$teamsWebhook = ''

if ($configNotif) {
    if (Read-YesNo "  Email notifications?" $true) {
        $smtpServer = Read-Answer -Question "  SMTP server" -Required
        $smtpFrom   = Read-Answer -Question "  Sender" -Default "pswindex@$domainName"
        $smtpTo     = Read-Answer -Question "  Recipient(s) (comma-separated)" -Required
    }
    if (Read-YesNo "  Teams notifications?" $false) {
        Write-Info "  Teams channel --> ... --> Connectors --> Incoming Webhook"
        $teamsWebhook = Read-Answer -Question "  Teams webhook URL" -Required
    }
}

# ---------------------------------------------------------------------------
# RECAPITULATIF
# ---------------------------------------------------------------------------

Write-Header "Summary"
Write-Host "  Dossier installation   : $InstallPath" -ForegroundColor Gray
Write-Host "  Serveur partages       : \\$serverFQDN\..." -ForegroundColor Gray
Write-Host "  Partages SMB           : $(if ($createShares) { 'Oui' } else { 'Non' })" -ForegroundColor Gray
Write-Host "  Account WinPE           : $winpeUserFull" -ForegroundColor Gray
Write-Host "  Type vault             : $vaultMode" -ForegroundColor Gray
Write-Host "  Domaine                : $(if ($joinDomain) { $domainName } else { '(standalone)' })" -ForegroundColor Gray
if ($joinDomain) {
    Write-Host "  Account jonction        : $domainName\$domainJoinUser" -ForegroundColor Gray
    Write-Host "  OU par defaut          : $(if ($defaultOU) { $defaultOU } else { '(non defini)' })" -ForegroundColor Gray
}
Write-Host "  Architecture WinPE     : $arch" -ForegroundColor Gray
Write-Host "  Locale                 : $locale" -ForegroundColor Gray
Write-Host "  Firmware               : $firmware" -ForegroundColor Gray
Write-Host "  SMTP                   : $(if ($smtpServer) { $smtpServer } else { '(non configure)' })" -ForegroundColor Gray
Write-Host "  Teams                  : $(if ($teamsWebhook) { 'Configure' } else { '(non configure)' })" -ForegroundColor Gray
Write-Host ""

if (-not (Read-YesNo "Start the installation?" $true)) {
    Write-Warn "Installation cancelled."
    exit 0
}

# ---------------------------------------------------------------------------
# INSTALLATION
# ---------------------------------------------------------------------------

Write-Header "Installation in progress"
$errors = [System.Collections.Generic.List[string]]::new()

# -- Structure dossiers -------------------------------------------------------
Write-Step "Creating the folder structure..."

$folders = @(
    $InstallPath,
    "$InstallPath\App",
    "$InstallPath\App\Modules",
    "$InstallPath\App\API",
    "$InstallPath\App\Scripts",
    "$InstallPath\App\Web",
    "$InstallPath\App\Catalogue",
    "$InstallPath\App\Sequences",
    "$InstallPath\Shares\Images",
    "$InstallPath\Shares\Deploy",
    "$InstallPath\Shares\Deploy\Catalogue",
    "$InstallPath\Shares\Deploy\Sequences",
    "$InstallPath\Shares\Deploy\Runtime",
    "$InstallPath\Shares\Drivers",
    "$InstallPath\Shares\Drivers\WinPE",
    "$InstallPath\Shares\Drivers\WinPE\Net",
    "$InstallPath\Shares\Drivers\WinPE\Storage",
    "$InstallPath\Shares\Drivers\WinPE\Sys",
    "$InstallPath\Shares\Logiciels",
    "$InstallPath\Shares\Scripts",
    "$InstallPath\Shares\Logs",
    "$InstallPath\WinPE\Workspace",
    "$InstallPath\WinPE\ISO",
    "$InstallPath\Deploy",
    "$InstallPath\Deploy\Modules",
    "$InstallPath\Deploy\Scripts",
    "$InstallPath\Deploy\Logs"
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}
Write-OK "Structure created ($($folders.Count) dossiers)"

# -- Copie des fichiers -------------------------------------------------------
Write-Step "Copying PSWinDeploy files..."

$scriptDir = Split-Path $PSCommandPath -Parent

if (Test-Path "$scriptDir\Modules") {
    Copy-Item "$scriptDir\Modules" "$InstallPath\App\" -Recurse -Force
    Copy-Item "$scriptDir\Modules" "$InstallPath\Deploy\" -Recurse -Force
    Write-OK "Modules copied"
} else {
    Write-Warn "Modules folder missing -- copy manually from the archive"
    $errors.Add("Modules non copies")
}

foreach ($item in @('API','Web','docker-compose.yml')) {
    $src = "$scriptDir\$item"
    if (Test-Path $src) { Copy-Item $src "$InstallPath\App\" -Recurse -Force }
}

    foreach ($script in @('Start-Deploy.ps1','startnet.cmd','Export-WIMImage.ps1','Deploy-Assistant.ps1','Build-WinPE-Assistant.ps1','PSWinDeploy-Console.ps1')) {
        foreach ($dest in @("$InstallPath\App\Scripts","$InstallPath\Deploy\Scripts")) {
        $src = "$scriptDir\Scripts\$script"
        if (Test-Path $src) { Copy-Item $src $dest -Force }
    }
}

foreach ($item in @('Catalogue','Sequences')) {
    $src = "$scriptDir\$item"
    if (Test-Path $src) {
        Copy-Item "$src\*" "$InstallPath\Shares\Deploy\$item\" -Recurse -Force
    }
}

# Uniformisation du nom du catalogue : l'API (ApiPaths.CataloguePath) attend
# 'catalogue.psd1'. Si la source fournit 'applications.psd1', on le renomme pour
# rester coherent. On ne touche pas si catalogue.psd1 existe deja.
$catDir  = "$InstallPath\Shares\Deploy\Catalogue"
$catFile = Join-Path $catDir 'catalogue.psd1'
$oldFile = Join-Path $catDir 'applications.psd1'
if ((Test-Path $oldFile) -and -not (Test-Path $catFile)) {
    Rename-Item -Path $oldFile -NewName 'catalogue.psd1' -Force -EA SilentlyContinue
    Write-OK "Catalogue uniformise : applications.psd1 -> catalogue.psd1"
} elseif (-not (Test-Path $catFile)) {
    # Aucun catalogue fourni : createdr un fichier vide valide pour eviter un
    # catalogue introuvable cote API.
    if (-not (Test-Path $catDir)) { New-Item -ItemType Directory $catDir -Force | Out-Null }
    $emptyCat = "@{`r`n    Applications = @()`r`n}"
    $utf8Bom2 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($catFile, $emptyCat, $utf8Bom2)
    Write-OK "Catalogue vide initialise : catalogue.psd1"
}

Write-OK "Files copied"

# -- Partages SMB -------------------------------------------------------------
if ($createShares) {
    Write-Step "Creating SMB shares..."

    $shareList = @(
        [PSCustomObject]@{ Name='Images';    Path="$InstallPath\Shares\Images" }
        [PSCustomObject]@{ Name='Deploy';    Path="$InstallPath\Shares\Deploy" }
        [PSCustomObject]@{ Name='Drivers';   Path="$InstallPath\Shares\Drivers" }
        [PSCustomObject]@{ Name='Logiciels'; Path="$InstallPath\Shares\Logiciels" }
        [PSCustomObject]@{ Name='Scripts';   Path="$InstallPath\Shares\Scripts" }
        [PSCustomObject]@{ Name='Logs';      Path="$InstallPath\Shares\Logs" }
    )

    # Resolution SID une seule fois (compatibilite FR/EN via SID universels)
    $everyoneName = ([System.Security.Principal.SecurityIdentifier]'S-1-1-0').Translate([System.Security.Principal.NTAccount]).Value
    $adminName    = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value

    foreach ($share in $shareList) {
        try {
            if (Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue) {
                Remove-SmbShare -Name $share.Name -Force -ErrorAction SilentlyContinue
            }
            New-SmbShare -Name $share.Name -Path $share.Path `
                -ReadAccess $everyoneName -FullAccess $adminName `
                -ErrorAction Stop | Out-Null
            Write-OK "  \\$serverFQDN\$($share.Name)"
        } catch {
            Write-Warn "  Echec partage $($share.Name) : $_"
            $errors.Add("Partage $($share.Name) non created")
        }
    }
}

# -- Account local svc-winpe ---------------------------------------------------
if ($winpeUserMode -eq 'local') {
    Write-Step "Creating local account $winpeUser..."
    try {
        $secPwd = ConvertTo-SecureString $winpePassword -AsPlainText -Force
        if (Get-LocalUser -Name $winpeUser -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $winpeUser -Password $secPwd
            Write-OK "Password $winpeUser updated"
        } else {
            New-LocalUser -Name $winpeUser -Password $secPwd `
                -Description "Account service WinPE PSWinDeploy" `
                -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
            Write-OK "Account $winpeUser created"
        }

        if ($createShares) {
            foreach ($shareName in @('Images','Deploy','Drivers','Logiciels','Scripts')) {
                Grant-SmbShareAccess -Name $shareName -AccountName $winpeUser `
                    -AccessRight Read -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Grant-SmbShareAccess -Name 'Logs' -AccountName $winpeUser `
                -AccessRight Full -Force -ErrorAction SilentlyContinue | Out-Null
            Write-OK "SMB rights granted to $winpeUser"
        }
    } catch {
        Write-Warn "Account $winpeUser : $_"
        $errors.Add("Account svc-winpe : $_")
    }
}

# -- Generation PSWinDeploy.psd1 ----------------------------------------------
Write-Step "Generating PSWinDeploy.psd1..."

# Blocs conditionnels
$domainSection = if ($joinDomain) {
    "    DefaultDomain   = '$domainName'`r`n    DefaultOU       = '$defaultOU'"
} else {
    "    # No domain configured (standalone)"
}

$notifSection = ''
if ($smtpServer -or $teamsWebhook) {
    $toLine = if ($smtpTo) {
        $toArr = ($smtpTo -split ',') | ForEach-Object { "'$($_.Trim())'" }
        "@($($toArr -join ', '))"
    } else { '@()' }

    $mailPart = if ($smtpServer) {
        "        Mail = @{`r`n            Enabled    = `$true`r`n            SmtpServer = '$smtpServer'`r`n            Port       = 587`r`n            UseTls     = `$true`r`n            From       = '$smtpFrom'`r`n            To         = $toLine`r`n        }`r`n"
    } else { '' }

    $teamsPart = if ($teamsWebhook) {
        "        Teams = @{`r`n            Enabled    = `$true`r`n            WebhookUrl = '$teamsWebhook'`r`n        }`r`n"
    } else { '' }

    $notifSection = "    Notifications   = @{`r`n$mailPart$teamsPart    }"
}

$vaultPassComment = if ($vaultMode -eq 'AES') {
    "    # Use env var PSWINDEX_VAULT_PASSWORD or -VaultPassword at WinPE build"
} else {
    "    # Plain mode: no vault password"
}

# Construction du psd1 par concatenation (pas de here-string pour eviter les problemes d'encodage)
# Generation du token API (aleatoire). Il protege l'API et doit etre recopie
# dans le conteneur web (TOKEN_API_PSWINDEPLOY).
$apiToken = New-RandomString

$psd1Lines = @(
    '@{'
    '    # Version'
    "    Version         = '0.8.0'"
    "    ProjectName     = 'PSWinDeploy'"
    ''
    '    # ADK / WinPE -- x86 retire depuis ADK 2004, amd64 et arm64 uniquement'
    "    AdkPath         = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'"
    "    WinPEAddonPath  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'"
    "    Architecture    = '$arch'"
    "    WinPEWorkspace  = '$InstallPath\WinPE\Workspace'"
    "    WinPEOutputPath = '$InstallPath\WinPE\ISO'"
    "    WinPEPackages   = @('PowerShell','WMI','NetFx','Scripting','StorageWMI','EnhancedStorage')"
    "    WinPELocale     = '$locale'"
    ''
    '    # Reseau / Partages -- format @{ DNS; IP } : teste le nom DNS, sinon l IP.'
    '    # Robuste dans le domaine (nom) ET hors domaine / WinPE (IP).'
    "    ImageShare      = @{ DNS = '\\$serverFQDN\Images';                       IP = '\\$serverIP\Images' }"
    "    DeployShare     = @{ DNS = '\\$serverFQDN\Deploy';                       IP = '\\$serverIP\Deploy' }"
    "    LogShare        = @{ DNS = '\\$serverFQDN\Logs';                         IP = '\\$serverIP\Logs' }"
    "    DriverShare     = @{ DNS = '\\$serverFQDN\Drivers';                      IP = '\\$serverIP\Drivers' }"
    "    SoftwareShare   = @{ DNS = '\\$serverFQDN\Logiciels';                    IP = '\\$serverIP\Logiciels' }"
    "    ScriptShare     = @{ DNS = '\\$serverFQDN\Scripts';                      IP = '\\$serverIP\Scripts' }"
    "    ProfilesPath    = @{ DNS = '\\$serverFQDN\Deploy\Profiles';             IP = '\\$serverIP\Deploy\Profiles' }"
    "    CataloguePath   = @{ DNS = '\\$serverFQDN\Deploy\Catalogue';            IP = '\\$serverIP\Deploy\Catalogue' }"
    "    SequencesPath   = @{ DNS = '\\$serverFQDN\Deploy\Sequences';            IP = '\\$serverIP\Deploy\Sequences' }"
    "    RuntimePath     = @{ DNS = '\\$serverFQDN\Deploy\Runtime';              IP = '\\$serverIP\Deploy\Runtime' }"
    ''
    '    # Deploiement'
    "    DefaultLocale   = '$locale'"
    "    DefaultTimezone = '$timezone'"
    "    FirmwareType    = '$firmware'"
    '    DefaultDisk     = -1'
    "    WindowsDrive    = 'W:'"
    "    SystemDrive     = 'S:'"
    "    RecoveryDrive   = 'R:'"
    ''
    '    # Securite'
    "    VaultPath       = '$InstallPath\Deploy\secrets.vault.psd1'"
    "    VaultMethod     = '$vaultMode'"
    $vaultPassComment
    '    MaxReboots      = 5'
    '    # Chemins recalcules dynamiquement (C:/W:/X:) selon la phase de deploiement'
    "    StateFile       = 'C:\Deploy\state.psd1'"
    "    DeployLogPath   = 'C:\Deploy\Logs\deploy.log'"
    ''
    '    # Account reseau WinPE'
    "    WinPEShareServer   = '$serverFQDN'"
    "    WinPEShareServerIP = '$serverIP'"
    "    WinPEShareUser     = '$winpeUserFull'"
    "    # WinPESharePassword = '...'  # Pass via -ShareVaultPassword at WinPE build"
    ''
    $domainSection
    ''
    '    # API'
    '    ApiPort         = 8080'
    "    ApiAllowedOrigin = '*'"
    "    apiToken         = '$apiToken'"
    '    ApiPaths = @{'
    "       CataloguePath = '$InstallPath\Shares\Deploy\Catalogue\catalogue.psd1'"
    "       SequencesPath = '$InstallPath\Shares\Deploy\Sequences'"
    "       DriverShare   = '$InstallPath\Shares\Drivers'"
    "       ScriptShare   = '$InstallPath\Shares\Scripts'"
    '    }'
    ''
    '    # Chemins locaux (deploiement)'
    "    DeployRoot      = '$InstallPath\Deploy'"
    "    ModulesRoot     = '$InstallPath\Deploy\Modules'"
    "    ScriptsRoot     = '$InstallPath\Deploy\Scripts'"
)

if ($notifSection) {
    $psd1Lines += ''
    $psd1Lines += $notifSection
}
$psd1Lines += '}'

$psd1Content = $psd1Lines -join "`r`n"
$psd1Path    = "$InstallPath\App\PSWinDeploy.psd1"
# BOM UTF-8 requis par Import-PowerShellDataFile
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($psd1Path, $psd1Content, $utf8Bom)
Copy-Item $psd1Path "$InstallPath\Deploy\PSWinDeploy.psd1" -Force
Write-OK "PSWinDeploy.psd1 generated"

# -- Vault de secrets ---------------------------------------------------------
if (-not $SkipVault) {
    Write-Step "Creating the secrets vault..."

    try {
        # Vault PSD1 plat (format lu directement par le deploiement)
        # Echapper les apostrophes AVANT (evite les quotes imbriquees)
        $wuE = $winpeUserFull.Replace("'", "''")
        $wpE = $winpePassword.Replace("'", "''")
        $laE = $localAdminPass.Replace("'", "''")
        $vLines = @('@{')
        $vLines += "    winpeUser          = '$wuE'"
        $vLines += "    winpePassword      = '$wpE'"
        $vLines += "    localAdminPassword = '$laE'"
        if ($domainJoinUser) {
            $djuE = $domainJoinUser.Replace("'", "''")
            $djpE = $domainJoinPass.Replace("'", "''")
            $vLines += "    domainJoinUser     = '$djuE'"
            $vLines += "    domainJoinPassword = '$djpE'"
        }
        $vLines += '}'

        $vaultPath = "$InstallPath\Deploy\secrets.vault.psd1"
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($vaultPath, ($vLines -join "`r`n"), $utf8Bom)
        Write-OK "Vault PSD1 created : $vaultPath"
        $domInfo = if ($domainJoinUser) { ' + jonction AD' } else { '' }
        Write-Info "  Comptes : Administrateur local (builtin) + svc-winpe (acces SMB)$domInfo"
    } catch {
        Write-Warn "Vault : $_"
        $errors.Add("Vault non created : $_")
    }
}

# -- Web .env -----------------------------------------------------------------
Write-Step "Configuring web interface..."
# Le conteneur web (BFF) utilise ces variables. Le mot de passe admin est a
# generer via la page /hash de la console (PASSWORD_ADMIN_HASH).
$envLines = @(
    "URL_API_PSWINDEPLOY=http://${serverFQDN}:8080"
    "TOKEN_API_PSWINDEPLOY=$apiToken"
    "ADMIN_USER=admin"
    "# Generate the hash at http://<container-host>:8088/hash then paste it here:"
    "PASSWORD_ADMIN_HASH="
    "SESSION_TTL_HOURS=12"
)
[System.IO.File]::WriteAllText("$InstallPath\App\Web\.env", ($envLines -join "`r`n"), [System.Text.Encoding]::UTF8)
Write-OK "Web/.env configured (URL API + token pre-remplis)"

# -- Module Pode --------------------------------------------------------------
Write-Step "Checking Pode (REST API)..."
if (Get-Module -ListAvailable -Name Pode -ErrorAction SilentlyContinue) {
    $podeVer = (Get-Module -ListAvailable Pode | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-OK "Pode $podeVer already installed"
} else {
    try {
        # AllUsers car le script tourne en admin et l'API peut tourner en service
        Install-Module -Name Pode -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Write-OK "Pode installed"
    } catch {
        Write-Warn "Pode not installed: $_"
        Write-Warn "Run manually: Install-Module Pode -Scope CurrentUser -Force"
        $errors.Add("Pode non installe")
    }
}

# -- Verification ADK ---------------------------------------------------------
if (-not $SkipADK) {
    Write-Step "Checking Windows ADK..."
    $adkRoots = @(
        'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',
        'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit'
    )
    $copype = $null
    foreach ($adkRoot in $adkRoots) {
        $candidate = Join-Path $adkRoot 'Windows Preinstallation Environment\copype.cmd'
        if (Test-Path $candidate) { $copype = $candidate; break }
    }
    if ($copype) {
        Write-OK "Windows ADK + WinPE Add-on detected"
    } else {
        Write-Warn "ADK or WinPE Add-on not detected"
        Write-Warn "Download: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
        Write-Warn "Install: ADK (Deployment Tools only) + WinPE Add-on (full)"
        $errors.Add("ADK non installe")
    }
}

# -- Scripts de demarrage -----------------------------------------------------
Write-Step "Generating startup scripts..."

# Start-API.ps1
$apiScript = @(
    '# Start-API.ps1 -- Lance l''API REST PSWinDeploy'
    '#Requires -Version 5.1'
    "Set-Location '$InstallPath\App'"
    "powershell -NonInteractive -File '$InstallPath\App\API\Deploy-API.ps1' -Port 8080"
)
[System.IO.File]::WriteAllText(
    "$InstallPath\Start-API.ps1",
    ($apiScript -join "`r`n"),
    [System.Text.Encoding]::UTF8
)

# Build-WinPE.ps1
$buildScript = @(
    '#Requires -RunAsAdministrator'
    '# Build-WinPE.ps1 -- Construit l''ISO WinPE PSWinDeploy'
    "Import-Module '$InstallPath\App\Modules\WinPE-Builder\WinPE-Builder.psm1' -Force"
    "Import-Module '$InstallPath\App\Modules\NetShare\NetShare.psm1' -Force"
    "Import-Module '$InstallPath\App\Modules\Config\Config.psm1' -Force"
    "Import-PSWinDeployConfig -ConfigPath '$InstallPath\App\PSWinDeploy.psd1'"
    ''
    '# Demande le mot de passe vault AES pour chiffrer les credentials WinPE dans l''ISO'
    '$vaultPwd = Read-Host "Password vault WinPE (AES)" -AsSecureString'
    '$vaultPwdPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto('
    '    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($vaultPwd))'
    ''
    'Invoke-WinPEBuild `'
    "    -WorkspacePath     '$InstallPath\WinPE\Workspace' ``"
    "    -OutputPath        '$InstallPath\WinPE\ISO' ``"
    "    -DriversNetPath    '$InstallPath\Shares\Drivers\WinPE\Net' ``"
    "    -DriversStoragePath '$InstallPath\Shares\Drivers\WinPE\Storage' ``"
    "    -DriversSysPath    '$InstallPath\Shares\Drivers\WinPE\Sys' ``"
    "    -ShareUser         '$winpeUserFull' ``"
    '    -ShareVaultPassword $vaultPwdPlain `'
    '    -Force'
)
[System.IO.File]::WriteAllText(
    "$InstallPath\Build-WinPE.ps1",
    ($buildScript -join "`r`n"),
    [System.Text.Encoding]::UTF8
)

Write-OK "Start-API.ps1 and Build-WinPE.ps1 generated"

# Console d'administration -- copiee a la racine du dossier d'installation
$consoleSrc = "$scriptDir\PSWinDeploy-Console.ps1"
if (-not (Test-Path $consoleSrc)) {
    # Chercher aussi dans App\Scripts\ si deja copie
    $consoleSrc = "$InstallPath\App\Scripts\PSWinDeploy-Console.ps1"
}
if (Test-Path $consoleSrc) {
    Copy-Item $consoleSrc "$InstallPath\PSWinDeploy-Console.ps1" -Force
    Write-OK "PSWinDeploy-Console.ps1 copie a la racine : $InstallPath\PSWinDeploy-Console.ps1"
} else {
    Write-Warn "PSWinDeploy-Console.ps1 non trouve -- copier manuellement depuis App\Scripts\"
}

# ---------------------------------------------------------------------------
# RESUME FINAL
# ---------------------------------------------------------------------------

Write-Header "Installation complete"

if ($errors.Count -gt 0) {
    Write-Warn "$($errors.Count) warning(s) to fix:"
    foreach ($e in $errors) { Write-Warn "  - $e" }
    Write-Host ""
}

Write-OK "PSWinDeploy installed in: $InstallPath"
Write-Host ""
Write-Host "  Structure:" -ForegroundColor White
Write-Host "    $InstallPath\" -ForegroundColor Gray
Write-Host "    +-- App\                  Modules, sequences, API, Web" -ForegroundColor Gray
Write-Host "    +-- Shares\               Shared folders (Images, Deploy, etc.)" -ForegroundColor Gray
Write-Host "    +-- WinPE\                WinPE workspace and ISO" -ForegroundColor Gray
Write-Host "    +-- Deploy\               Local deployment engine" -ForegroundColor Gray
Write-Host "    +-- PSWinDeploy.psd1      Generated configuration" -ForegroundColor Gray
    Write-Host "    +-- PSWinDeploy-Console.ps1  Administration console" -ForegroundColor Gray
Write-Host "    +-- Start-API.ps1         Starts the Pode API" -ForegroundColor Gray
Write-Host "    +-- Build-WinPE.ps1       Builds the WinPE ISO" -ForegroundColor Gray
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host ""
    Write-Host "  1. Export a Windows image from an ISO:" -ForegroundColor Cyan
    Write-Host "     $InstallPath\App\Scripts\Export-WIMImage.ps1" -ForegroundColor Gray
    Write-Host "     (mounts the ISO, lists editions, exports to $InstallPath\Shares\Images\)" -ForegroundColor DarkGray
Write-Host ""
    Write-Host "  2. Place WinPE drivers into the subfolders:" -ForegroundColor Cyan
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Net\     (NIC - required)" -ForegroundColor Gray
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Storage\ (NVMe/SATA/RAID)" -ForegroundColor Gray
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Sys\     (chipset, USB)" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "  3. Build the WinPE ISO:" -ForegroundColor Cyan
Write-Host "     $InstallPath\Build-WinPE.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  0. Unblock the scripts (if downloaded from the Internet):" -ForegroundColor Cyan
    Write-Host "     $InstallPath\Unblock-PSWinDeploy.ps1" -ForegroundColor Gray
    Write-Host "     (or: Unblock-File on the .zip before extracting)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1. Launch the administration console:" -ForegroundColor Cyan
    Write-Host "     $InstallPath\PSWinDeploy-Console.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Start the API:" -ForegroundColor Cyan
Write-Host "     $InstallPath\Start-API.ps1" -ForegroundColor Gray
Write-Host ""
    Write-Host "  4. Web interface (Docker container) -- to deploy on a Linux host:" -ForegroundColor Cyan
    Write-Host "     Build/push the image then, with the docker-compose in App/Web/:" -ForegroundColor Gray
    Write-Host "       docker compose up -d" -ForegroundColor Gray
    Write-Host "     Variables (already pre-filled in App/Web/.env):" -ForegroundColor Gray
    Write-Host "       URL_API_PSWINDEPLOY   = http://${serverFQDN}:8080" -ForegroundColor DarkGray
    Write-Host "       TOKEN_API_PSWINDEPLOY = $apiToken" -ForegroundColor DarkGray
    Write-Host "       PASSWORD_ADMIN_HASH   = generate it at http://<host>:8088/hash" -ForegroundColor DarkGray
    Write-Host "     Console available at: http://<container-host>:8088" -ForegroundColor Gray
Write-Host ""
    Write-Host "  IMPORTANT -- API token generated: $apiToken" -ForegroundColor Yellow
    Write-Host "     (same value in PSWinDeploy.psd1 and the container .env)" -ForegroundColor DarkGray
Write-Host ""
    # Afficher les mots de passe generes aleatoirement : l'admin ne les connait
    # pas autrement (ils sont dans le vault, mais utile de les noter une fois).
    if ($winpeUserMode -eq 'local' -and $winpePasswordMode -eq 'R') {
        Write-Host "  Password genere -- $winpeUserFull (share access): $winpePassword" -ForegroundColor Yellow
    }
    if ($localAdminPassMode -eq 'R') {
        Write-Host "  Password genere -- machines' local Administrator: $localAdminPass" -ForegroundColor Yellow
    }
    if (($winpeUserMode -eq 'local' -and $winpePasswordMode -eq 'R') -or $localAdminPassMode -eq 'R') {
        Write-Host "     (note them down: stored in the vault, but shown here only once)" -ForegroundColor DarkGray
        Write-Host ""
    }

if ($errors.Count -eq 0) {
    Write-Host "  All set -- no errors!" -ForegroundColor Green
} else {
    Write-Host "  Partial installation -- fix the warnings." -ForegroundColor Yellow
}
Write-Host ""

if (-not $Silent) {
    if (Read-YesNo "Open the folder in Explorer?" $false) {
        Start-Process explorer.exe $InstallPath
    }
}
