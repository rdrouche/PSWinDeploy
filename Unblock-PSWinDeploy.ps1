#Requires -Version 5.1
<#
.SYNOPSIS
    Unblock-PSWinDeploy.ps1 -- Supprime les avertissements de securite sur les fichiers PSWinDeploy
.DESCRIPTION
    Windows marque les fichiers telecharges depuis Internet avec une zone NTFS (Zone.Identifier ADS).
    Cela provoque le message "voulez-vous executer ce fichier" et peut bloquer les scripts PS.

    Ce script supprime ces marqueurs sur tous les fichiers .ps1, .psm1, .psd1, .cmd, .json
    du dossier PSWinDeploy.

    A executer UNE SEULE FOIS apres avoir extrait l'archive, en tant qu'Administrateur.

.PARAMETER Path
    Dossier racine PSWinDeploy. Detecte automatiquement depuis le dossier du script si absent.
.EXAMPLE
    # Depuis la racine du dossier d'installation
    .\Unblock-PSWinDeploy.ps1

    # Chemin explicite
    .\Unblock-PSWinDeploy.ps1 -Path 'E:\PSWinDeploy'
#>

[CmdletBinding()]
param(
    [string]$Path = ''
)

$ErrorActionPreference = 'Continue'

# Determiner le dossier racine
if (-not $Path) {
    $Path = Split-Path $PSCommandPath -Parent
}

Write-Host ""
Write-Host "  PSWinDeploy -- Deblocage des fichiers" -ForegroundColor Cyan
Write-Host "  Dossier : $Path" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $Path)) {
    Write-Host "  [X] Dossier introuvable : $Path" -ForegroundColor Red
    exit 1
}

# Extensions a debloquer
$extensions = @('*.ps1','*.psm1','*.psd1','*.cmd','*.psd1','*.yml','*.jsx','*.js','*.html')

$total   = 0
$blocked = 0
$fixed   = 0

foreach ($ext in $extensions) {
    $files = @(Get-ChildItem $Path -Filter $ext -Recurse -ErrorAction SilentlyContinue |
               Where-Object { -not $_.PSIsContainer })

    foreach ($file in $files) {
        $total++
        # Verifier si le fichier est bloque (Zone.Identifier ADS present)
        $zoneFile = $file.FullName + ':Zone.Identifier'
        $isBlocked = [System.IO.File]::Exists($zoneFile)

        if (-not $isBlocked) {
            # Methode alternative : utiliser Get-Item avec le stream
            try {
                $streams = Get-Item $file.FullName -Stream * -ErrorAction SilentlyContinue
                $isBlocked = ($streams | Where-Object { $_.Stream -eq 'Zone.Identifier' }) -ne $null
            } catch {}
        }

        if ($isBlocked) {
            $blocked++
            try {
                Unblock-File $file.FullName -ErrorAction Stop
                $fixed++
                Write-Host "  [OK] $($file.FullName.Replace($Path,'').TrimStart('\'))" -ForegroundColor Green
            } catch {
                Write-Host "  [!]  Echec : $($file.Name) -- $_" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ""
Write-Host "  $total fichier(s) analyses" -ForegroundColor Gray
if ($blocked -eq 0) {
    Write-Host "  No blocked file -- already unblocked or extracted locally" -ForegroundColor Cyan
} else {
    Write-Host "  $blocked fichier(s) bloques detectes" -ForegroundColor Yellow
    Write-Host "  $fixed fichier(s) debloque(s)" -ForegroundColor Green
}

Write-Host ""
Write-Host "  Conseil : pour eviter ce probleme a l'avenir," -ForegroundColor DarkGray
Write-Host "  debloquer le .zip avant d'extraire :" -ForegroundColor DarkGray
Write-Host "    Clic-droit sur le .zip -> Proprietes -> Debloquer" -ForegroundColor DarkGray
Write-Host "    Ou : Unblock-File 'PSWinDeploy_v0.7.0.zip'" -ForegroundColor Gray
Write-Host ""
