<#
.SYNOPSIS
    Diagnostic : verifie quelle version de Start-Deploy.ps1 est REELLEMENT
    utilisee par la console et embarquee dans le WinPE.
.DESCRIPTION
    Repond a la question "d'ou vient le probleme" en montrant, pour chaque
    copie de Start-Deploy.ps1 trouvee sur le systeme, si elle contient les
    4 options avancees ou seulement 2.
.EXAMPLE
    .\Diag-Version.ps1 -InstallPath E:\PSWinDeploy
#>
[CmdletBinding()]
param(
    [string]$InstallPath = ''
)
function Say($m,$c='Gray'){ Write-Host "  $m" -ForegroundColor $c }

if (-not $InstallPath) {
    # Tenter de deviner depuis l'emplacement du script
    $InstallPath = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
}
Say "Installation analysee : $InstallPath" 'Cyan'
Say ""

# Chercher TOUTES les copies de Start-Deploy.ps1 sur les emplacements probables
$searchRoots = @(
    $InstallPath,
    'C:\PSWinDeploy', 'E:\PSWinDeploy', 'D:\PSWinDeploy',
    'C:\WinPE-Work', 'C:\WinPE-ISO'
) | Select-Object -Unique

Say "=== Recherche de toutes les copies de Start-Deploy.ps1 ===" 'White'
$found = @()
foreach ($root in $searchRoots) {
    if (Test-Path $root -EA SilentlyContinue) {
        Get-ChildItem $root -Recurse -Filter 'Start-Deploy.ps1' -EA SilentlyContinue | ForEach-Object {
            $found += $_.FullName
        }
    }
}
$found = $found | Select-Object -Unique

if ($found.Count -eq 0) {
    Say "No copy found. Check the -InstallPath path." 'Red'
    return
}

foreach ($f in $found) {
    $content = Get-Content $f -Raw -EA SilentlyContinue
    $hasNoPhase2  = $content -match 'SANS lancer la phase 2'
    $hasCopyUnatt = $content -match "Copier l'unattend genere"
    $nbOptions = 2
    if ($hasNoPhase2)  { $nbOptions++ }
    if ($hasCopyUnatt) { $nbOptions++ }
    $date = (Get-Item $f).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    $col = if ($nbOptions -eq 4) { 'Green' } else { 'Red' }
    Say "" 
    Say "Fichier : $f" 'White'
    Say "  Modifie : $date" 'DarkGray'
    Say "  Options avancees detectees : $nbOptions / 4" $col
    if ($nbOptions -ne 4) {
        Say "  >> VERSION ANCIENNE (manque: $(@(if(-not $hasNoPhase2){'sans phase 2'}; if(-not $hasCopyUnatt){'copie unattend'}) -join ', '))" 'Red'
    } else {
        Say "  >> VERSION A JOUR" 'Green'
    }
}

Say ""
Say "=== Verifier aussi le WIM (boot.wim) ===" 'White'
Say "Le WinPE embarque sa PROPRE copie de Start-Deploy.ps1 dans le WIM." 'DarkGray'
Say "Pour la verifier, monte le boot.wim :" 'DarkGray'
Say '  Mount-WindowsImage -ImagePath "C:\WinPE-ISO\media\sources\boot.wim" -Index 1 -Path C:\mount' 'DarkGray'
Say '  Get-Content C:\mount\Deploy\Scripts\Start-Deploy.ps1 | Select-String "phase 2"' 'DarkGray'
Say '  Dismount-WindowsImage -Path C:\mount -Discard' 'DarkGray'
Say ""
Say "INTERPRETATION :" 'Yellow'
Say "- Si la copie dans App\\Scripts montre 4/4 mais le WIM montre 2/4 ->" 'DarkGray'
Say "  le build a tourne AVANT l'update, ou a pris une autre source. Rebuild." 'DarkGray'
Say "- Si App\\Scripts montre 2/4 -> l'update n'a pas mis a jour cet emplacement." 'DarkGray'
