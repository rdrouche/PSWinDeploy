<#
.SYNOPSIS
    Test decisif : deploie le WIM (sequence qui boote) + applique l'unattend
    COMPLET genere a la volee. Aucun fichier externe necessaire.
.DESCRIPTION
    Reprend la sequence du test minimal (qui boote) et ajoute l'unattend complet
    directement dans Panther. Permet de confirmer si l'unattend est le coupable.

    Usage : .\Test-Unattend-Complet.ps1 -WimPath "\\10.0.8.111\Images\...frFR.wim"
    Option : -Niveau minimal|oobe|specialize|complet  (defaut complet)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WimPath,
    [int]$Index = 1,
    [int]$DiskNumber = 0,
    [ValidateSet('minimal','oobe','specialize','complet')]
    [string]$Niveau = 'complet',
    [switch]$ViaModule,          # genere l'unattend avec le VRAI module (pas le XML en dur)
    [string]$ModulePath = '',    # si vide : cherche Unattend.psm1 a cote du script
    [string]$SaveDir = ''        # si vide : copie l'unattend a cote du script (PSScriptRoot)
)
# Resoudre le chemin du module : a cote du script de test par defaut
if (-not $ModulePath) {
    $ModulePath = Join-Path $PSScriptRoot 'Unattend.psm1'
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Step($n,$m){ Write-Host "`n[$n] $m" -ForegroundColor Cyan }

Step 1 "Partitionnement UEFI (sequence PSD)"
# NETTOYAGE ROBUSTE (comme la prod) : Clear-Disk -RemoveData -RemoveOEM retire
# AUSSI les partitions OEM/systeme protegees (ESP, Recovery) d'un Windows deja
# installe. Un simple "clean" ne les retire pas -> bcdboot 123. Representatif
# de l'usage reel (machine deja deployee).
try {
    $d = Get-Disk -Number $DiskNumber -EA Stop
    if ($d.PartitionStyle -ne "RAW") {
        Write-Host "  Nettoyage complet (Clear-Disk -RemoveData -RemoveOEM)..." -ForegroundColor Yellow
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -EA Stop
        Write-Host "  Disque nettoye (OEM/systeme inclus)" -ForegroundColor Green
    }
} catch {
    Write-Host "  Clear-Disk fallback diskpart clean ($_)" -ForegroundColor Yellow
    "select disk $DiskNumber`r`nclean`r`nexit" | diskpart | Out-Null
}
Start-Sleep 2
@"
select disk $DiskNumber
clean
convert gpt
create partition efi size=499
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=128
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
assign letter=R
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
exit
"@ | diskpart | Out-Null
Write-Host "  Partitionnement OK" -ForegroundColor Green

Step 2 "Application du WIM (dism.exe)"
# Verifier que le WIM existe AVANT dism (message clair si chemin faux/accent)
if (-not (Test-Path -LiteralPath $WimPath)) {
    Write-Host "  ERREUR : WIM introuvable a ce chemin :" -ForegroundColor Red
    Write-Host "    $WimPath" -ForegroundColor Red
    Write-Host "  Verifie le nom exact (dir) et les accents. Astuce : monte le" -ForegroundColor Yellow
    Write-Host "  partage (net use Z: ...) et utilise Z:\ws2025.wim sans accent." -ForegroundColor Yellow
    throw "WIM introuvable : $WimPath"
}
Write-Host "  WIM trouve : $WimPath" -ForegroundColor Green
$scratch = "X:\scratch"; New-Item -ItemType Directory $scratch -Force | Out-Null
$start = Get-Date
& dism.exe /Apply-Image /ImageFile:"$WimPath" /Index:$Index /ApplyDir:W:\ /CheckIntegrity
if ($LASTEXITCODE -ne 0) { throw "dism /Apply-Image echoue ($LASTEXITCODE)" }
Write-Host "  WIM applique en $((New-TimeSpan $start (Get-Date)).TotalMinutes.ToString('0.0')) min" -ForegroundColor Green

Step 3 "bcdboot /c sans /l"
# Verifier que S: (ESP) est bien montee AVANT bcdboot
if (-not (Test-Path "S:\")) {
    Write-Host "  ERREUR : la partition EFI S: n'est pas accessible." -ForegroundColor Red
    Write-Host "  Le disque a peut-etre une ancienne ESP verrouillee. Nettoyage force..." -ForegroundColor Yellow
    @"
select disk $DiskNumber
clean
exit
"@ | diskpart | Out-Null
    throw "Partition EFI S: absente -- relance le test (disque nettoye)."
}
& bcdboot.exe W:\Windows /s S: /f UEFI /c
$bcdExit = $LASTEXITCODE
if ($bcdExit -ne 0) {
    Write-Host "  bcdboot ECHEC (exit=$bcdExit)" -ForegroundColor Red
    Write-Host "  Boot files NON crees -> l'OS ne demarrera pas." -ForegroundColor Red
    if ($bcdExit -eq 123) {
        Write-Host "  exit=123 = nom/volume invalide. La partition EFI n'etait pas prete." -ForegroundColor Yellow
        Write-Host "  Cause frequente : ancienne ESP d'un deploiement precedent." -ForegroundColor Yellow
        Write-Host "  Solution : redemarre en WinPE sur disque VIERGE, ou diskpart clean manuel." -ForegroundColor Yellow
    }
    throw "bcdboot a echoue (exit=$bcdExit) -- arret du test."
}
Write-Host "  bcdboot OK (exit=$bcdExit) -- boot files crees" -ForegroundColor Green

Step 4 "Pause 5s + flip EFI + bcdedit"
Start-Sleep 5
@"
select volume S
set id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
exit
"@ | diskpart | Out-Null
& bcdedit.exe | Out-Null
Write-Host "  EFI + BCD OK" -ForegroundColor Green

Step 5 "Generation de l'unattend (niveau : $Niveau)"
# Blocs construits selon le niveau
$specialize = ""
$oobeExtra  = ""

if ($Niveau -in @('specialize','complet')) {
    $intl = ""
    if ($Niveau -eq 'complet') {
        $intl = @"
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>040c:0000040c</InputLocale>
            <SystemLocale>fr-FR</SystemLocale>
            <UILanguage>fr-FR</UILanguage>
            <UserLocale>fr-FR</UserLocale>
        </component>
"@
    }
    $specialize = @"
    <settings pass="specialize">
$intl
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <ComputerName>test-dep-1</ComputerName>
            <TimeZone>Romance Standard Time</TimeZone>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Description>EnableAdmin</Description><Order>1</Order><Path>cmd /c net user Administrator /active:yes</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Description>UnattendCreatedUser</Description><Order>2</Order><Path>reg add HKLM\Software\Microsoft\Windows\CurrentVersion\Setup\OOBE /v UnattendCreatedUser /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
"@
}

if ($Niveau -in @('oobe','specialize','complet')) {
    $oobeExtra = @"
            <AutoLogon>
                <Password><Value>Azerty18</Value><PlainText>true</PlainText></Password>
                <Enabled>true</Enabled><LogonCount>1</LogonCount><Username>Administrator</Username><Domain>.</Domain>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c echo PHASE2 OK > C:\phase2-ok.txt</CommandLine><Description>Test phase2</Description><RequiresUserInput>false</RequiresUserInput></SynchronousCommand>
            </FirstLogonCommands>
"@
}

$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
$specialize
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>040c:0000040c</InputLocale>
            <SystemLocale>fr-FR</SystemLocale>
            <UILanguage>fr-FR</UILanguage>
            <UserLocale>fr-FR</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <UserAccounts>
                <AdministratorPassword><Value>Azerty18</Value><PlainText>true</PlainText></AdministratorPassword>
            </UserAccounts>
            <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>1</ProtectYourPC></OOBE>
$oobeExtra
        </component>
    </settings>
</unattend>
"@

New-Item -ItemType Directory "W:\Windows\Panther" -Force | Out-Null

if ($ViaModule) {
    # MODE TEST DECISIF : generer via le VRAI module (comme le From Scratch)
    Write-Host "  Mode -ViaModule : generation via New-UnattendXml du module" -ForegroundColor Yellow
    if (-not (Test-Path $ModulePath)) {
        Write-Host "  Module introuvable : $ModulePath" -ForegroundColor Red
        throw "Module Unattend introuvable"
    }
    Import-Module $ModulePath -Force
    $modParams = @{
        ComputerName      = 'test-dep-1'
        TimeZone          = 'Romance Standard Time'
        FirstLogonCommand = 'cmd /c echo PHASE2 OK > C:\phase2-ok.txt'
        AutoLogonPassword = 'Azerty18'
        LocalAdminPassword = 'Azerty18'
    }
    $unattend = New-UnattendXml @modParams
    Write-Host "  XML genere par le module (longueur $($unattend.Length) caracteres)" -ForegroundColor Yellow
    # Ecrire avec la fonction Write-UnattendFile du module (encodage exact du From Scratch)
    $null = Write-UnattendFile -TargetDrive 'W:' -Parameters $modParams
    Write-Host "  unattend.xml ecrit par Write-UnattendFile (methode From Scratch)" -ForegroundColor Green
} else {
    # UTF-8 SANS BOM (methode du test qui boote)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText("W:\Windows\Panther\unattend.xml", $unattend, $enc)
    Write-Host "  unattend.xml ($Niveau) ecrit dans Panther" -ForegroundColor Green
}

# Afficher le debut du XML ecrit pour inspection
Write-Host "  --- Premieres lignes de l'unattend ecrit ---" -ForegroundColor DarkGray
Get-Content "W:\Windows\Panther\unattend.xml" -TotalCount 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
# Verifier le BOM
$bytes = [System.IO.File]::ReadAllBytes("W:\Windows\Panther\unattend.xml")
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "  *** ATTENTION : l'unattend a un BOM UTF-8 (peut casser Windows Setup) ***" -ForegroundColor Red
} else {
    Write-Host "  Encodage : UTF-8 sans BOM (OK)" -ForegroundColor Green
}

# --- Copier l'unattend genere sur le partage avec un nom UNIQUE (horodate) ---
# Permet de conserver/comparer chaque unattend sans ecraser les precedents.
try {
    if (-not $SaveDir) {
        if ($PSScriptRoot) { $SaveDir = $PSScriptRoot } else { $SaveDir = 'X:\' }
    }
    $mode = if ($ViaModule) { 'module' } else { $Niveau }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $saveName = "unattend-genere_${mode}_${stamp}.xml"
    $savePath = Join-Path $SaveDir $saveName
    Copy-Item "W:\Windows\Panther\unattend.xml" $savePath -Force
    Write-Host "  >> Unattend sauvegarde : $savePath" -ForegroundColor Cyan
    Write-Host "     (nom unique horodate -- aucun ecrasement)" -ForegroundColor DarkGray
} catch {
    Write-Host "  (!) Impossible de copier l'unattend vers $SaveDir : $_" -ForegroundColor Yellow
    Write-Host "      Tu peux le recuperer manuellement : W:\Windows\Panther\unattend.xml" -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " TERMINE -- niveau unattend : $Niveau" -ForegroundColor Green
Write-Host " Retirez l'ISO et tapez : wpeutil reboot" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green
Write-Host "`n minimal    = admin + OOBE seulement" -ForegroundColor Gray
Write-Host " oobe       = + autologon + phase2" -ForegroundColor Gray
Write-Host " specialize = + ComputerName + EnableAdmin" -ForegroundColor Gray
Write-Host " complet    = + International-Core (langue fr-FR)" -ForegroundColor Gray
