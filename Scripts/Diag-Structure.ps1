<#
.SYNOPSIS Inventaire de la structure serveur : montre TOUS les emplacements de
    Scripts/Modules/Sequences/Profiles pour reperer les doublons.
.EXAMPLE .\Diag-Structure.ps1 -InstallPath E:\PSWinDeploy
#>
param([string]$InstallPath = '')
function Say($m,$c='Gray'){ Write-Host "  $m" -ForegroundColor $c }

if (-not $InstallPath) { $InstallPath = Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
Say "===== STRUCTURE SERVEUR =====" 'Cyan'
Say "Install analyse : $InstallPath" 'White'
Say ""

# Tous les emplacements possibles de chaque type
$types = @('Scripts','Modules','Sequences','Profiles')
foreach ($t in $types) {
    Say "--- $t ---" 'White'
    $locations = @(
        (Join-Path $InstallPath $t),
        (Join-Path $InstallPath "App\$t"),
        (Join-Path $InstallPath "Shares\Deploy\$t"),
        (Join-Path $InstallPath "Shares\Scripts")  # cas particulier
    ) | Select-Object -Unique
    foreach ($loc in $locations) {
        if (Test-Path $loc -EA SilentlyContinue) {
            $n = @(Get-ChildItem $loc -EA SilentlyContinue).Count
            $psd1 = @(Get-ChildItem $loc -Filter '*.psd1' -EA SilentlyContinue).Count
            Say "  [PRESENT] $loc  ($n items, $psd1 .psd1)" 'Green'
        }
    }
    Say ""
}

Say "=== Partages SMB configures ===" 'White'
Get-SmbShare -EA SilentlyContinue | Where-Object { $_.Name -notmatch '\$$' } |
    ForEach-Object { Say "  $($_.Name) -> $($_.Path)" 'Gray' }
Say ""
Say "Envoie cette sortie pour le menage." 'Yellow'
