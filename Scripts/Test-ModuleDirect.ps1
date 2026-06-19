<#
.SYNOPSIS
    Test d'ISOLATION : appelle les fonctions du MODULE WIM-Manager une par une
    (comme le From Scratch), mais en DIRECT et sequentiel (comme le test qui boote).
.DESCRIPTION
    But : determiner si le BSOD vient des FONCTIONS du module ou de la
    TaskSequence/enchainement autour.
    - Si ce script BSOD  -> une fonction du module (Initialize-DeployDisk,
      Apply-WIMImage ou Set-WindowsBootloader) est en cause.
    - Si ce script BOOTE -> les fonctions sont OK, le souci est la TaskSequence
      (ordre, parametres, etat) ou la phase 2.

    On NE met PAS d'unattend complexe : juste de quoi booter. On isole le
    pipeline DISQUE + WIM + BOOT.
.EXAMPLE
    .\Test-ModuleDirect.ps1 -WimPath "\\10.0.8.111\Images\ws2025.wim" -ModulesRoot "\\10.0.8.111\Scripts\Modules"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WimPath,
    [int]$Index = 1,
    [int]$DiskNumber = 0,
    [string]$ModulesRoot = ''   # dossier contenant WIM-Manager\WIM-Manager.psm1
)
$ErrorActionPreference = 'Stop'
function Say($m,$c='Cyan'){ Write-Host "`n[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor $c }

# Localiser le module WIM-Manager
if (-not $ModulesRoot) {
    $ModulesRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'
}
$wimMod = Join-Path $ModulesRoot 'WIM-Manager\WIM-Manager.psm1'
if (-not (Test-Path $wimMod)) {
    # essayer a cote du script
    $wimMod = Join-Path $PSScriptRoot 'WIM-Manager.psm1'
}
if (-not (Test-Path $wimMod)) {
    throw "WIM-Manager.psm1 introuvable. Precise -ModulesRoot (dossier contenant WIM-Manager\WIM-Manager.psm1)."
}
Say "Module WIM-Manager : $wimMod" 'Green'
Import-Module $wimMod -Force

Say "=== ETAPE 1 : Initialize-DeployDisk (MODULE) ===" 'Yellow'
$diskInfo = Initialize-DeployDisk -DiskNumber $DiskNumber -FirmwareType UEFI -Force
Say "Resultat partitionnement :" 'Green'
$diskInfo | Format-List | Out-String | Write-Host

# Verifier IMMEDIATEMENT que les partitions sont la
Say "=== Verification des partitions creees ===" 'Yellow'
"list disk`nselect disk $DiskNumber`nlist partition`nlist volume`nexit" | diskpart | Write-Host
foreach ($l in @('S','W','R')) {
    $ok = Test-Path "${l}:\" -EA SilentlyContinue
    Say "  Lettre ${l}: montee = $ok" $(if($ok){'Green'}else{'Red'})
}

Say "=== ETAPE 2 : Apply-WIMImage (MODULE) ===" 'Yellow'
Apply-WIMImage -WimPath $WimPath -Index $Index -TargetPath 'W:\' -Verify

# Verifier que W:\Windows existe apres application
$winOk = Test-Path 'W:\Windows\System32\ntoskrnl.exe' -EA SilentlyContinue
Say "  W:\Windows\System32\ntoskrnl.exe present = $winOk" $(if($winOk){'Green'}else{'Red'})

Say "=== ETAPE 3 : Set-WindowsBootloader (MODULE) ===" 'Yellow'
Set-WindowsBootloader -WindowsDrive 'W:' -SystemDrive 'S:' -FirmwareType UEFI -RecoveryDrive 'R:'

# Verifier le BCD sur l'ESP
Say "=== Verification du boot (ESP) ===" 'Yellow'
$bcdOk = Test-Path 'S:\EFI\Microsoft\Boot\BCD' -EA SilentlyContinue
$bootmgr = Test-Path 'S:\EFI\Microsoft\Boot\bootmgfw.efi' -EA SilentlyContinue
Say "  S:\EFI\Microsoft\Boot\BCD present = $bcdOk" $(if($bcdOk){'Green'}else{'Red'})
Say "  bootmgfw.efi present = $bootmgr" $(if($bootmgr){'Green'}else{'Red'})

Say "=== ETAPE 4 : unattend MINIMAL (juste admin + autologon temoin) ===" 'Yellow'
New-Item -ItemType Directory 'W:\Windows\Panther' -Force | Out-Null
$ua = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <UserAccounts><AdministratorPassword><Value>Azerty18</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
            <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>1</ProtectYourPC></OOBE>
        </component>
    </settings>
</unattend>
'@
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText('W:\Windows\Panther\unattend.xml', $ua, $enc)
Say "  unattend minimal ecrit" 'Green'

Say "========================================" 'Green'
Say " TERMINE -- TOUTES LES FONCTIONS DU MODULE ONT TOURNE" 'Green'
Say " Retire l'ISO et tape : wpeutil reboot" 'Cyan'
Say "" 'Gray'
Say " - Si ca BOOTE : les fonctions du module sont OK -> le souci est la" 'Gray'
Say "   TaskSequence/enchainement ou la phase 2." 'Gray'
Say " - Si ca BSOD : une fonction du module casse le boot. On saura laquelle" 'Gray'
Say "   grace aux verifications affichees ci-dessus (partitions, BCD, ntoskrnl)." 'Gray'
Say "========================================" 'Green'
