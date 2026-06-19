<#
.SYNOPSIS
    Test de deploiement MINIMAL pour isoler la cause du BSOD CRITICAL_PROCESS_DIED.
.DESCRIPTION
    Reproduit la sequence MDT/PSD EXACTE, etape par etape, en mode manuel.
    A lancer depuis WinPE sur la machine cible. Aucune dependance aux modules
    PSWinDeploy -- tout est autonome pour un diagnostic pur.

    Usage : .\Test-MinimalDeploy.ps1 -WimPath "\\10.0.8.111\Images\ws2025std.wim" -DiskNumber 0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WimPath,
    [int]$Index = 1,
    [int]$DiskNumber = 0,
    [string]$UnattendPath = ''   # si fourni : copie cet unattend dans Panther (test isole)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

Step 1 "Partitionnement UEFI (sequence PSD exacte)"
# PSD : EFI 499MB (basic data puis flip), MSR 128MB, OS reste, Recovery 1024MB
$diskpart = @"
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
"@
$diskpart | diskpart
Write-Host "  Partitionnement termine" -ForegroundColor Green

Step 2 "Application du WIM (dism.exe -- toujours present en WinPE)"
$scratch = "X:\scratch"
New-Item -ItemType Directory $scratch -Force | Out-Null
$start = Get-Date
# IMPORTANT : on utilise dism.exe et PAS Expand-WindowsImage (le module DISM
# PowerShell n'est pas toujours present dans WinPE).
& dism.exe /Apply-Image /ImageFile:"$WimPath" /Index:$Index /ApplyDir:W:\ /CheckIntegrity
if ($LASTEXITCODE -ne 0) { throw "dism /Apply-Image a echoue (code $LASTEXITCODE)" }
Write-Host "  WIM applique en $((New-TimeSpan $start (Get-Date)).TotalMinutes.ToString('0.0')) min" -ForegroundColor Green

Step 3 "bcdboot (avec /c, SANS /l -- methode PSD)"
$bcdResult = & bcdboot.exe W:\Windows /s S: /f UEFI /c 2>&1
$bcdResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  bcdboot termine (exit=$LASTEXITCODE)" -ForegroundColor Green

# DIAGNOSTIC : verifier que le BCD a bien ete ecrit sur l'ESP
Write-Host "  Verification du contenu de l'ESP (S:) :" -ForegroundColor Yellow
if (Test-Path "S:\EFI\Microsoft\Boot\BCD") {
    Write-Host "    BCD present : OK" -ForegroundColor Green
} else {
    Write-Host "    BCD ABSENT -- bcdboot n'a pas ecrit le store !" -ForegroundColor Red
}
if (Test-Path "S:\EFI\Boot\bootx64.efi") {
    Write-Host "    bootx64.efi present : OK" -ForegroundColor Green
} else {
    Write-Host "    bootx64.efi absent (peut etre normal)" -ForegroundColor Yellow
}
if (Test-Path "S:\EFI\Microsoft\Boot\bootmgfw.efi") {
    Write-Host "    bootmgfw.efi present : OK" -ForegroundColor Green
} else {
    Write-Host "    bootmgfw.efi ABSENT -- bootloader UEFI manquant !" -ForegroundColor Red
}
# Lister les entrees BCD
Write-Host "  Entrees BCD :" -ForegroundColor Yellow
& bcdedit.exe /store S:\EFI\Microsoft\Boot\BCD /enum 2>&1 | Select-Object -First 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

Step 4 "Pause 15s (synchronisation FS, comme PSD)"
Start-Sleep -Seconds 15

Step 5 "Flip type partition EFI en 'System' (Set-PSDEFIDiskpartition)"
$efiFlip = @"
select volume S
set id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
exit
"@
$efiFlip | diskpart
Write-Host "  Type EFI confirme" -ForegroundColor Green

Step 6 "Configuration WinRE (Winre.wim + reagentc)"
$winre = "W:\Windows\System32\Recovery\Winre.wim"
if (Test-Path $winre) {
    New-Item -ItemType Directory "R:\Recovery\WindowsRE" -Force | Out-Null
    Copy-Item $winre "R:\Recovery\WindowsRE\Winre.wim" -Force
    & W:\Windows\System32\Reagentc.exe /Setreimage /Path R:\Recovery\WindowsRE /Target W:\Windows
    Write-Host "  WinRE configure" -ForegroundColor Green
} else {
    Write-Host "  Winre.wim absent (non bloquant)" -ForegroundColor Yellow
}

Step 7 "bcdedit refresh"
& bcdedit.exe | Out-Null
Write-Host "  BCD rafraichi" -ForegroundColor Green

# Etape optionnelle : tester l'unattend ISOLE (tout le reste est identique au test qui boote)
if ($UnattendPath -and (Test-Path $UnattendPath)) {
    Step 8 "Copie de l'unattend dans Panther (TEST ISOLE de l'unattend)"
    New-Item -ItemType Directory "W:\Windows\Panther" -Force | Out-Null
    Copy-Item $UnattendPath "W:\Windows\Panther\unattend.xml" -Force
    Write-Host "  unattend.xml copie dans W:\Windows\Panther\" -ForegroundColor Yellow
    Write-Host "  >> Si CE test BSOD alors que sans -UnattendPath il boote :" -ForegroundColor Yellow
    Write-Host "     le probleme est le CONTENU de l'unattend, isole et confirme." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " DEPLOIEMENT MINIMAL TERMINE" -ForegroundColor Green
Write-Host " AUCUN unattend applique (WIM brut pur)" -ForegroundColor Yellow
Write-Host " Retirez l'ISO et redemarrez : wpeutil reboot" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nSi ca boote -> le probleme etait dans notre pipeline" -ForegroundColor White
Write-Host "Si CRITICAL_PROCESS_DIED -> le WIM ou le firmware VM (Secure Boot/VBS)" -ForegroundColor White
