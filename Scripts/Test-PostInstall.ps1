<#
.SYNOPSIS
    Script de TEST post-installation. Cree C:\test\test.txt avec un horodatage.
    Sert a valider que la phase 2 execute bien les scripts du partage.
.NOTES
    Code retour : 0 = OK. (Ne demande pas de reboot.)
#>
$ErrorActionPreference = 'Stop'
try {
    $dir = 'C:\test'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir 'test.txt'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $file -Value "[$stamp] Test post-installation OK sur $env:COMPUTERNAME (user=$env:USERNAME)" -Encoding UTF8
    Write-Host "[TEST] Fichier cree/complete : $file" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "[TEST] ERREUR : $_" -ForegroundColor Red
    exit 1
}
