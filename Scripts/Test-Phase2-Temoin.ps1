<#
.SYNOPSIS Temoin de test phase 2 : ecrit une ligne horodatee a chaque appel.
    Permet de prouver que la phase 2 tourne ET reprend apres reboot.
#>
param([string]$Tag = '')
$f = 'C:\Deploy\Logs\test-phase2.log'
New-Item -ItemType Directory (Split-Path $f -Parent) -Force -EA SilentlyContinue | Out-Null
$line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] PHASE2 passage : $Tag (machine=$env:COMPUTERNAME)"
Add-Content -Path $f -Value $line -Encoding UTF8
Write-Host $line -ForegroundColor Green
# Copier sur le partage Logs si dispo
foreach ($d in (Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue)) {
    if ($d.DisplayRoot -and $d.DisplayRoot -like '\\*') {
        $ls = Join-Path (Split-Path $d.DisplayRoot -Parent) 'Logs'
        if (Test-Path $ls -EA SilentlyContinue) {
            Copy-Item $f (Join-Path $ls "test-phase2_$($env:COMPUTERNAME).log") -Force -EA SilentlyContinue
            break
        }
    }
}
exit 0
