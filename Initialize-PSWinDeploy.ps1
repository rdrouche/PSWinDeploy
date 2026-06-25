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
            Write-Warn "Cette valeur est obligatoire."
            return Read-Answer @PSBoundParameters
        }
        return ''
    }

    if ($Options) {
        $match = $Options | Where-Object { $_.ToLower() -eq $answer.Trim().ToLower() } | Select-Object -First 1
        if (-not $match) {
            Write-Warn "Valeur invalide. Choisir parmi : $($Options -join ', ')"
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
        $pw2 = Read-Answer -Question "Confirmer" -Password -Required
        if ($pw1 -ne $pw2) { Write-Warn "Les mots de passe ne correspondent pas." }
    } while ($pw1 -ne $pw2)
    return $pw1
}

# ---------------------------------------------------------------------------
# BANNIERE
# ---------------------------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "              PSWinDeploy  --  Initialisation               " -ForegroundColor Cyan
Write-Host "         Remplacement MDT en PowerShell moderne  v0.6.9     " -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Ce script va :" -ForegroundColor White
Write-Host "    1. Choisir le dossier d'installation" -ForegroundColor Gray
Write-Host "    2. Creer la structure de dossiers et les partages SMB" -ForegroundColor Gray
Write-Host "    3. Generer le fichier de configuration PSWinDeploy.psd1" -ForegroundColor Gray
Write-Host "    4. Creer le vault de secrets (mots de passe chiffres)" -ForegroundColor Gray
Write-Host "    5. Verifier les prerequis (ADK, Pode)" -ForegroundColor Gray
Write-Host "    6. Generer les scripts Start-API.ps1 et Build-WinPE.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  Note : Le compte de jonction domaine (svc-joindomain) est utilise" -ForegroundColor DarkGray
Write-Host "  UNIQUEMENT par la machine cible pendant le step JoinDomain." -ForegroundColor DarkGray
Write-Host "  Le serveur PSWinDeploy n'a lui-meme pas besoin de rejoindre un domaine." -ForegroundColor DarkGray
Write-Host ""

if (-not $Silent) {
    Write-Host "  [?]  Appuyez sur Entree pour commencer..." -ForegroundColor White -NoNewline
    Read-Host | Out-Null
}

# ---------------------------------------------------------------------------
# ETAPE 1 -- CHEMIN D'INSTALLATION
# ---------------------------------------------------------------------------

Write-Header "Etape 1 -- Chemin d'installation"

Write-Info "Contient les modules, partages, ISO WinPE et la configuration."
Write-Host ""

if (-not $InstallPath) {
    Write-Info "Disques disponibles :"
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } |
        ForEach-Object {
            $freeGB = if ($_.Free) { [Math]::Round($_.Free / 1GB, 1) } else { '?' }
            Write-Host ("    {0}:\  {1} GB libres" -f $_.Name, $freeGB) -ForegroundColor Gray
        }
    Write-Host ""
    $InstallPath = Read-Answer -Question "Dossier d'installation" -Default 'C:\PSWinDeploy' -Required
}

$InstallPath = $InstallPath.TrimEnd('\')
Write-Info "Chemin selectionne : $InstallPath"

$driveLetter = Split-Path $InstallPath -Qualifier
$driveObj    = Get-PSDrive -Name $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
if ($driveObj -and $driveObj.Free) {
    $freeGB = [Math]::Round($driveObj.Free / 1GB, 1)
    if ($driveObj.Free -lt 20GB) {
        Write-Warn "Espace libre : $freeGB GB (minimum recommande : 20 GB)"
        if (-not (Read-YesNo "Continuer quand meme ?" $false)) { exit 1 }
    } else {
        Write-OK "Espace libre : $freeGB GB"
    }
}

# ---------------------------------------------------------------------------
# ETAPE 2 -- RESEAU
# ---------------------------------------------------------------------------

Write-Header "Etape 2 -- Configuration reseau"

# Detection automatique du NOM et de l'IP du serveur. L'utilisateur confirme
# (defaut = valeur detectee) ou saisit manuellement. Les deux servent a generer
# les partages au format @{ DNS; IP } -- robuste dans ET hors domaine.
$serverName = $env:COMPUTERNAME
Write-Info "Nom de ce serveur detecte : $serverName"
$serverFQDN = Read-Answer -Question "Nom DNS du serveur (pour les partages)" -Default $serverName
if ([string]::IsNullOrWhiteSpace($serverFQDN)) {
    $serverFQDN = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($serverFQDN)) {
        $serverFQDN = Read-Answer -Question "Nom du serveur (obligatoire)" -Required
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
if ($detectedIp) { Write-Info "Adresse IP detectee : $detectedIp" }
$serverIP = Read-Answer -Question "Adresse IP du serveur (fallback hors domaine)" -Default $detectedIp
if ([string]::IsNullOrWhiteSpace($serverIP)) {
    Write-Warn "Pas d'IP fournie -- le fallback IP ne sera pas disponible (risque hors domaine)."
    $serverIP = $serverFQDN  # repli : utiliser le nom partout
}
Write-Info "Serveur : nom='$serverFQDN' IP='$serverIP'"

Write-Host ""
Write-Info "Partages SMB qui seront crees :"
foreach ($s in @('Images','Deploy','Drivers','Logiciels','Scripts','Logs')) {
    Write-Host ("    \\{0}\{1}  -->  {2}\Shares\{1}" -f $serverFQDN, $s, $InstallPath) -ForegroundColor Gray
}
Write-Host ""
$createShares = -not $SkipShares -and (Read-YesNo "Creer les partages SMB sur ce serveur ?" $true)

# ---------------------------------------------------------------------------
# ETAPE 3 -- COMPTE RESEAU WINPE (svc-winpe)
# ---------------------------------------------------------------------------

Write-Header "Etape 3 -- Compte reseau WinPE"

Write-Info "Ce compte permet a WinPE d'acceder aux partages de deploiement."
Write-Info "Droits : lecture seule sur Images/Deploy/Drivers, ecriture sur Logs."
Write-Info "Ce compte n'a AUCUN acces aux machines deployees."
Write-Host ""

$winpeUserMode = Read-Answer -Question "Type de compte" -Options @('local','domaine') -Default 'local'

if ($winpeUserMode -eq 'local') {
    $winpeUser     = Read-Answer -Question "Nom du compte local" -Default 'svc-winpe'
    $winpeUserFull = "$serverName\$winpeUser"
} else {
    $wpeDomain     = Read-Answer -Question "Nom du domaine" -Required
    $winpeUser     = Read-Answer -Question "Nom du compte" -Default 'svc-winpe'
    $winpeUserFull = "$wpeDomain\$winpeUser"
}

$winpePassword = Read-Password -Question "Mot de passe pour $winpeUserFull"

# ---------------------------------------------------------------------------
# ETAPE 4 -- JONCTION DOMAINE
# ---------------------------------------------------------------------------

Write-Header "Etape 4 -- Jonction domaine Active Directory"

Write-Info "Le compte de jonction est utilise par la MACHINE DEPLOYEE (pas le serveur)"
Write-Info "lors du step JoinDomain pour s'enregistrer dans l'AD."
Write-Host ""

$joinDomain     = Read-YesNo "Les machines deployees rejoignent-elles un domaine AD ?" $true
$domainName     = ''
$domainJoinUser = ''
$domainJoinPass = ''
$defaultOU      = ''

if ($joinDomain) {
    $domainName     = Read-Answer -Question "Nom du domaine (ex: corp.local)" -Required
    $domainJoinUser = Read-Answer -Question "Compte de jonction (ex: svc-joindomain)" -Default 'svc-joindomain'
    Write-Info "Ce compte doit avoir le droit 'Add workstations to domain' sur l'OU cible."
    $domainJoinPass = Read-Password -Question "Mot de passe de $domainJoinUser"
    $defaultOU      = Read-Answer -Question "OU par defaut (laisser vide si non applicable)" -Default ''
}

# ---------------------------------------------------------------------------
# ETAPE 5 -- MOTS DE PASSE
# ---------------------------------------------------------------------------

Write-Header "Etape 5 -- Mots de passe de deploiement"

Write-Info "Ces mots de passe sont chiffres dans le vault, jamais en clair."
Write-Host ""

Write-Info "Mot de passe du compte Administrateur local (builtin) des machines :"
Write-Info "Ce compte existe deja dans Windows -- on definit juste son mot de passe."
Write-Info "Il sert a l'autologon de la phase 2 et reste l'admin de la machine."
$localAdminPass = Read-Password -Question "Mot de passe Administrateur local"

Write-Host ""
Write-Info "Jonction de domaine AD (optionnel -- laisser vide si non utilise) :"
$domainJoinUser = Read-Answer -Question "Compte de jonction (ex: CORP\\svc-join, vide=aucun)" -Default ''
$domainJoinPass = ''
if ($domainJoinUser) {
    $domainJoinPass = Read-Password -Question "Mot de passe du compte de jonction"
}

Write-Host ""
$vaultMode = Read-Answer -Question "Mode de chiffrement du vault" -Options @('AES','Plain') -Default 'AES'

$vaultPassword = ''
if ($vaultMode -eq 'AES') {
    Write-Info "Le mot de passe AES protege le vault. Requis au boot WinPE."
    Write-Info "Peut aussi etre passe via la variable d'env PSWINDEX_VAULT_PASSWORD."
    $vaultPassword = Read-Password -Question "Mot de passe vault AES"
} else {
    Write-Warn "Mode Plain : vault en clair, protege par droits reseau et acces physique."
}

# ---------------------------------------------------------------------------
# ETAPE 6 -- WINPE
# ---------------------------------------------------------------------------

Write-Header "Etape 6 -- Configuration WinPE"

Write-Info "Note : x86 retire depuis ADK 2004. Architectures supportees : amd64, arm64."
Write-Host ""
$arch     = Read-Answer -Question "Architecture" -Options @('amd64','arm64') -Default 'amd64'
$locale   = Read-Answer -Question "Locale" -Default 'fr-FR'
$timezone = Read-Answer -Question "Fuseau horaire" -Default 'Romance Standard Time'
$firmware = Read-Answer -Question "Firmware par defaut" -Options @('UEFI','BIOS') -Default 'UEFI'

# ---------------------------------------------------------------------------
# ETAPE 7 -- NOTIFICATIONS
# ---------------------------------------------------------------------------

Write-Header "Etape 7 -- Notifications (optionnel)"

$configNotif  = Read-YesNo "Configurer les notifications (email / Teams) ?" $false
$smtpServer   = ''
$smtpFrom     = ''
$smtpTo       = ''
$teamsWebhook = ''

if ($configNotif) {
    if (Read-YesNo "  Notifications par email ?" $true) {
        $smtpServer = Read-Answer -Question "  Serveur SMTP" -Required
        $smtpFrom   = Read-Answer -Question "  Expediteur" -Default "pswindex@$domainName"
        $smtpTo     = Read-Answer -Question "  Destinataire(s) (virgules)" -Required
    }
    if (Read-YesNo "  Notifications Teams ?" $false) {
        Write-Info "  Canal Teams --> ... --> Connecteurs --> Incoming Webhook"
        $teamsWebhook = Read-Answer -Question "  URL webhook Teams" -Required
    }
}

# ---------------------------------------------------------------------------
# RECAPITULATIF
# ---------------------------------------------------------------------------

Write-Header "Recapitulatif"
Write-Host "  Dossier installation   : $InstallPath" -ForegroundColor Gray
Write-Host "  Serveur partages       : \\$serverFQDN\..." -ForegroundColor Gray
Write-Host "  Partages SMB           : $(if ($createShares) { 'Oui' } else { 'Non' })" -ForegroundColor Gray
Write-Host "  Compte WinPE           : $winpeUserFull" -ForegroundColor Gray
Write-Host "  Type vault             : $vaultMode" -ForegroundColor Gray
Write-Host "  Domaine                : $(if ($joinDomain) { $domainName } else { '(standalone)' })" -ForegroundColor Gray
if ($joinDomain) {
    Write-Host "  Compte jonction        : $domainName\$domainJoinUser" -ForegroundColor Gray
    Write-Host "  OU par defaut          : $(if ($defaultOU) { $defaultOU } else { '(non defini)' })" -ForegroundColor Gray
}
Write-Host "  Architecture WinPE     : $arch" -ForegroundColor Gray
Write-Host "  Locale                 : $locale" -ForegroundColor Gray
Write-Host "  Firmware               : $firmware" -ForegroundColor Gray
Write-Host "  SMTP                   : $(if ($smtpServer) { $smtpServer } else { '(non configure)' })" -ForegroundColor Gray
Write-Host "  Teams                  : $(if ($teamsWebhook) { 'Configure' } else { '(non configure)' })" -ForegroundColor Gray
Write-Host ""

if (-not (Read-YesNo "Lancer l'installation ?" $true)) {
    Write-Warn "Installation annulee."
    exit 0
}

# ---------------------------------------------------------------------------
# INSTALLATION
# ---------------------------------------------------------------------------

Write-Header "Installation en cours"
$errors = [System.Collections.Generic.List[string]]::new()

# -- Structure dossiers -------------------------------------------------------
Write-Step "Creation de la structure de dossiers..."

$folders = @(
    $InstallPath,
    "$InstallPath\App",
    "$InstallPath\App\Modules",
    "$InstallPath\App\API",
    "$InstallPath\App\Scripts",
    "$InstallPath\App\Web",
    "$InstallPath\App\Profiles",
    "$InstallPath\App\Catalogue",
    "$InstallPath\App\Sequences",
    "$InstallPath\Shares\Images",
    "$InstallPath\Shares\Deploy",
    "$InstallPath\Shares\Deploy\Profiles",
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
Write-OK "Structure creee ($($folders.Count) dossiers)"

# -- Copie des fichiers -------------------------------------------------------
Write-Step "Copie des fichiers PSWinDeploy..."

$scriptDir = Split-Path $PSCommandPath -Parent

if (Test-Path "$scriptDir\Modules") {
    Copy-Item "$scriptDir\Modules" "$InstallPath\App\" -Recurse -Force
    Copy-Item "$scriptDir\Modules" "$InstallPath\Deploy\" -Recurse -Force
    Write-OK "Modules copies"
} else {
    Write-Warn "Dossier Modules absent -- a copier manuellement depuis l'archive"
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

foreach ($item in @('Profiles','Catalogue','Sequences')) {
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
    # Aucun catalogue fourni : creer un fichier vide valide pour eviter un
    # catalogue introuvable cote API.
    if (-not (Test-Path $catDir)) { New-Item -ItemType Directory $catDir -Force | Out-Null }
    $emptyCat = "@{`r`n    Applications = @()`r`n}"
    $utf8Bom2 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($catFile, $emptyCat, $utf8Bom2)
    Write-OK "Catalogue vide initialise : catalogue.psd1"
}

Write-OK "Fichiers copies"

# -- Partages SMB -------------------------------------------------------------
if ($createShares) {
    Write-Step "Creation des partages SMB..."

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
            $errors.Add("Partage $($share.Name) non cree")
        }
    }
}

# -- Compte local svc-winpe ---------------------------------------------------
if ($winpeUserMode -eq 'local') {
    Write-Step "Creation du compte local $winpeUser..."
    try {
        $secPwd = ConvertTo-SecureString $winpePassword -AsPlainText -Force
        if (Get-LocalUser -Name $winpeUser -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $winpeUser -Password $secPwd
            Write-OK "Mot de passe $winpeUser mis a jour"
        } else {
            New-LocalUser -Name $winpeUser -Password $secPwd `
                -Description "Compte service WinPE PSWinDeploy" `
                -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
            Write-OK "Compte $winpeUser cree"
        }

        if ($createShares) {
            foreach ($shareName in @('Images','Deploy','Drivers','Logiciels','Scripts')) {
                Grant-SmbShareAccess -Name $shareName -AccountName $winpeUser `
                    -AccessRight Read -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Grant-SmbShareAccess -Name 'Logs' -AccountName $winpeUser `
                -AccessRight Full -Force -ErrorAction SilentlyContinue | Out-Null
            Write-OK "Droits SMB attribues a $winpeUser"
        }
    } catch {
        Write-Warn "Compte $winpeUser : $_"
        $errors.Add("Compte svc-winpe : $_")
    }
}

# -- Generation PSWinDeploy.psd1 ----------------------------------------------
Write-Step "Generation de PSWinDeploy.psd1..."

# Blocs conditionnels
$domainSection = if ($joinDomain) {
    "    DefaultDomain   = '$domainName'`r`n    DefaultOU       = '$defaultOU'"
} else {
    "    # Pas de domaine configure (standalone)"
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
    "    # Utiliser variable d'env PSWINDEX_VAULT_PASSWORD ou -VaultPassword au build WinPE"
} else {
    "    # Mode Plain : pas de mot de passe vault"
}

# Construction du psd1 par concatenation (pas de here-string pour eviter les problemes d'encodage)
# Generation du token API (aleatoire). Il protege l'API et doit etre recopie
# dans le conteneur web (TOKEN_API_PSWINDEPLOY).
$apiToken = New-RandomString

$psd1Lines = @(
    '@{'
    '    # Version'
    "    Version         = '0.6.9'"
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
    '    # Compte reseau WinPE'
    "    WinPEShareServer   = '$serverFQDN'"
    "    WinPEShareServerIP = '$serverIP'"
    "    WinPEShareUser     = '$winpeUserFull'"
    "    # WinPESharePassword = '...'  # Passer via -ShareVaultPassword lors du build WinPE"
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
Write-OK "PSWinDeploy.psd1 genere"

# -- Vault de secrets ---------------------------------------------------------
if (-not $SkipVault) {
    Write-Step "Creation du vault de secrets..."

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
        Write-OK "Vault PSD1 cree : $vaultPath"
        $domInfo = if ($domainJoinUser) { ' + jonction AD' } else { '' }
        Write-Info "  Comptes : Administrateur local (builtin) + svc-winpe (acces SMB)$domInfo"
    } catch {
        Write-Warn "Vault : $_"
        $errors.Add("Vault non cree : $_")
    }
}

# -- Web .env -----------------------------------------------------------------
Write-Step "Configuration interface Web..."
# Le conteneur web (BFF) utilise ces variables. Le mot de passe admin est a
# generer via la page /hash de la console (PASSWORD_ADMIN_HASH).
$envLines = @(
    "URL_API_PSWINDEPLOY=http://${serverFQDN}:8080"
    "TOKEN_API_PSWINDEPLOY=$apiToken"
    "ADMIN_USER=admin"
    "# Genere le hash sur http://<hote-conteneur>:8088/hash puis colle-le ici :"
    "PASSWORD_ADMIN_HASH="
    "SESSION_TTL_HOURS=12"
)
[System.IO.File]::WriteAllText("$InstallPath\App\Web\.env", ($envLines -join "`r`n"), [System.Text.Encoding]::UTF8)
Write-OK "Web/.env configure (URL API + token pre-remplis)"

# -- Module Pode --------------------------------------------------------------
Write-Step "Verification de Pode (API REST)..."
if (Get-Module -ListAvailable -Name Pode -ErrorAction SilentlyContinue) {
    $podeVer = (Get-Module -ListAvailable Pode | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-OK "Pode $podeVer deja installe"
} else {
    try {
        # AllUsers car le script tourne en admin et l'API peut tourner en service
        Install-Module -Name Pode -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Write-OK "Pode installe"
    } catch {
        Write-Warn "Pode non installe : $_"
        Write-Warn "Lancer manuellement : Install-Module Pode -Scope CurrentUser -Force"
        $errors.Add("Pode non installe")
    }
}

# -- Verification ADK ---------------------------------------------------------
if (-not $SkipADK) {
    Write-Step "Verification Windows ADK..."
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
        Write-OK "Windows ADK + WinPE Add-on detectes"
    } else {
        Write-Warn "ADK ou WinPE Add-on non detectes"
        Write-Warn "Telecharger : https://learn.microsoft.com/windows-hardware/get-started/adk-install"
        Write-Warn "Installer : ADK (Deployment Tools seulement) + WinPE Add-on (complet)"
        $errors.Add("ADK non installe")
    }
}

# -- Scripts de demarrage -----------------------------------------------------
Write-Step "Generation des scripts de demarrage..."

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
    '$vaultPwd = Read-Host "Mot de passe vault WinPE (AES)" -AsSecureString'
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

Write-OK "Start-API.ps1 et Build-WinPE.ps1 generes"

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

Write-Header "Installation terminee"

if ($errors.Count -gt 0) {
    Write-Warn "$($errors.Count) avertissement(s) a corriger :"
    foreach ($e in $errors) { Write-Warn "  - $e" }
    Write-Host ""
}

Write-OK "PSWinDeploy installe dans : $InstallPath"
Write-Host ""
Write-Host "  Structure :" -ForegroundColor White
Write-Host "    $InstallPath\" -ForegroundColor Gray
Write-Host "    +-- App\                  Modules, sequences, profils, API, Web" -ForegroundColor Gray
Write-Host "    +-- Shares\               Dossiers partages (Images, Deploy, etc.)" -ForegroundColor Gray
Write-Host "    +-- WinPE\                Workspace et ISO WinPE" -ForegroundColor Gray
Write-Host "    +-- Deploy\               Moteur local deploiement" -ForegroundColor Gray
Write-Host "    +-- PSWinDeploy.psd1      Configuration generee" -ForegroundColor Gray
    Write-Host "    +-- PSWinDeploy-Console.ps1  Console d administration" -ForegroundColor Gray
Write-Host "    +-- Start-API.ps1         Lance l'API Pode" -ForegroundColor Gray
Write-Host "    +-- Build-WinPE.ps1       Construit l'ISO WinPE" -ForegroundColor Gray
Write-Host ""
Write-Host "  Prochaines etapes :" -ForegroundColor White
Write-Host ""
    Write-Host "  1. Exporter une image Windows depuis un ISO :" -ForegroundColor Cyan
    Write-Host "     $InstallPath\App\Scripts\Export-WIMImage.ps1" -ForegroundColor Gray
    Write-Host "     (monte l ISO, liste les editions, exporte vers $InstallPath\Shares\Images\)" -ForegroundColor DarkGray
Write-Host ""
    Write-Host "  2. Placer les drivers WinPE dans les sous-dossiers :" -ForegroundColor Cyan
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Net\     (NIC - obligatoire)" -ForegroundColor Gray
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Storage\ (NVMe/SATA/RAID)" -ForegroundColor Gray
    Write-Host "     $InstallPath\Shares\Drivers\WinPE\Sys\     (chipset, USB)" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "  3. Construire l'ISO WinPE :" -ForegroundColor Cyan
Write-Host "     $InstallPath\Build-WinPE.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  0. Debloquer les scripts (si telechargement depuis Internet) :" -ForegroundColor Cyan
    Write-Host "     $InstallPath\Unblock-PSWinDeploy.ps1" -ForegroundColor Gray
    Write-Host "     (ou : Unblock-File sur le .zip avant extraction)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1. Lancer la console d administration :" -ForegroundColor Cyan
    Write-Host "     $InstallPath\PSWinDeploy-Console.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Demarrer l'API :" -ForegroundColor Cyan
Write-Host "     $InstallPath\Start-API.ps1" -ForegroundColor Gray
Write-Host ""
    Write-Host "  4. Interface Web (conteneur Docker) -- a deployer sur un hote Linux :" -ForegroundColor Cyan
    Write-Host "     Build/push l'image puis, avec le docker-compose fourni dans App/Web/ :" -ForegroundColor Gray
    Write-Host "       docker compose up -d" -ForegroundColor Gray
    Write-Host "     Variables (deja pre-remplies dans App/Web/.env) :" -ForegroundColor Gray
    Write-Host "       URL_API_PSWINDEPLOY   = http://${serverFQDN}:8080" -ForegroundColor DarkGray
    Write-Host "       TOKEN_API_PSWINDEPLOY = $apiToken" -ForegroundColor DarkGray
    Write-Host "       PASSWORD_ADMIN_HASH   = genere-le sur http://<hote>:8088/hash" -ForegroundColor DarkGray
    Write-Host "     Console accessible : http://<hote-conteneur>:8088" -ForegroundColor Gray
Write-Host ""
    Write-Host "  IMPORTANT -- Token API genere : $apiToken" -ForegroundColor Yellow
    Write-Host "     (identique dans PSWinDeploy.psd1 et le .env du conteneur)" -ForegroundColor DarkGray
Write-Host ""

if ($errors.Count -eq 0) {
    Write-Host "  Tout est pret -- aucune erreur !" -ForegroundColor Green
} else {
    Write-Host "  Installation partielle -- corriger les avertissements." -ForegroundColor Yellow
}
Write-Host ""

if (-not $Silent) {
    if (Read-YesNo "Ouvrir le dossier dans l'Explorateur ?" $false) {
        Start-Process explorer.exe $InstallPath
    }
}
