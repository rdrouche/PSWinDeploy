#Requires -Version 5.1
<#
.SYNOPSIS
    Update-Version.ps1 -- Met a jour la version du projet partout (le "bump").
.DESCRIPTION
    Source unique de verite : le fichier VERSION a la racine. Ce script propage
    la version dans tous les fichiers qui exigent un LITTERAL (manifestes .psd1,
    package.json, badges README, references d'archive), car ils ne peuvent pas
    lire VERSION au runtime.

    A lancer apres avoir change le numero dans VERSION (ou via -NewVersion).

    Optionnellement, genere l'archive de mise a jour nommee selon la version
    (PSWinDeploy_vX.Y.Z.zip) avec -Package.
.PARAMETER NewVersion
    Nouvelle version (ex : 0.7.0). Si fournie, ecrit d'abord VERSION puis propage.
    Si omise, lit la version depuis le fichier VERSION existant.
.PARAMETER Package
    Si present, genere aussi l'archive PSWinDeploy_v<version>.zip (hors
    node_modules / dist) dans le dossier parent.
.EXAMPLE
    .\Update-Version.ps1 -NewVersion 0.7.0
    .\Update-Version.ps1 -NewVersion 0.7.0 -Package
#>
[CmdletBinding()]
param(
    [string]$NewVersion,
    [switch]$Package
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Write-Info { param($M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param($M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param($M) Write-Host "  [!]  $M" -ForegroundColor Yellow }

# --- 1. Determiner la version -----------------------------------------------
$versionFile = Join-Path $root 'VERSION'
if ($NewVersion) {
    if ($NewVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Version invalide : '$NewVersion' (attendu X.Y.Z)." }
    Set-Content -Path $versionFile -Value $NewVersion -Encoding ASCII -NoNewline
    Write-OK "VERSION ecrit : $NewVersion"
}
if (-not (Test-Path $versionFile)) { throw "VERSION file not found. Provide -NewVersion." }
$version = (Get-Content $versionFile -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION malforme : '$version'." }
Write-Info "Propagation de la version $version dans le projet..."

# --- 2. Helpers d'edition (preserve le BOM des .ps1/.psm1/.psd1) -------------
function Update-FileRegex {
    param([string]$Path, [string]$Pattern, [string]$Replacement, [switch]$KeepBom)
    if (-not (Test-Path $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.TrimStart([char]0xFEFF) }
    $new = [regex]::Replace($text, $Pattern, $Replacement)
    if ($new -eq $text) { return $false }
    $enc = New-Object System.Text.UTF8Encoding($hasBom -or $KeepBom)
    [System.IO.File]::WriteAllText($Path, $new, $enc)
    return $true
}

$changed = 0
$verEsc = [regex]::Escape($version)

# --- 3. Manifestes de modules (.psd1) : ModuleVersion = 'X.Y.Z' -------------
foreach ($psd1 in Get-ChildItem (Join-Path $root 'Modules') -Recurse -Filter '*.psd1' -EA SilentlyContinue) {
    if (Update-FileRegex -Path $psd1.FullName -Pattern "ModuleVersion(\s*)=(\s*)'[\d.]+'" -Replacement "ModuleVersion`$1=`$2'$version'") {
        $changed++; Write-OK "  $($psd1.Name)"
    }
}

# --- 4. Config par defaut + PSWinDeploy.psd1 : Version = 'X.Y.Z' -------------
foreach ($f in @(
    (Join-Path $root 'Modules\Config\Config.psm1'),
    (Join-Path $root 'PSWinDeploy.psd1')
)) {
    if (Update-FileRegex -Path $f -Pattern "Version(\s+)=(\s*)'[\d.]+'" -Replacement "Version`$1=`$2'$version'") {
        $changed++; Write-OK "  $(Split-Path $f -Leaf)"
    }
}

# --- 5. Console + API : chaines de version litterales ------------------------
if (Update-FileRegex -Path (Join-Path $root 'PSWinDeploy-Console.ps1') -Pattern "Version(\s+)=(\s*)'[\d.]+'" -Replacement "Version`$1=`$2'$version'") { $changed++; Write-OK "  PSWinDeploy-Console.ps1" }
if (Update-FileRegex -Path (Join-Path $root 'API\Deploy-API.ps1') -Pattern "version(\s+)=(\s*)'[\d.]+'" -Replacement "version`$1=`$2'$version'") { $changed++; Write-OK "  Deploy-API.ps1" }

# --- 6. Initialize : banniere + Version generee dans le psd1 -----------------
$initPath = Join-Path $root 'Initialize-PSWinDeploy.ps1'
if (Update-FileRegex -Path $initPath -Pattern "moderne(\s+)v[\d.]+" -Replacement "moderne`$1v$version") { $changed++; Write-OK "  Initialize (banniere)" }
if (Update-FileRegex -Path $initPath -Pattern "Version(\s+)=(\s*)'[\d.]+'" -Replacement "Version`$1=`$2'$version'") { $changed++ }

# --- 6b. Start-Deploy : version de repli de la banniere WinPE ----------------
$startDeploy = Join-Path $root 'Scripts\Start-Deploy.ps1'
if (Update-FileRegex -Path $startDeploy -Pattern "\`$v = '[\d.]+'" -Replacement "`$v = '$version'") { $changed++; Write-OK "  Start-Deploy (banniere)" }

# --- 7. Web : package.json (front + server) ---------------------------------
foreach ($pkg in @(
    (Join-Path $root 'Web\frontend\package.json'),
    (Join-Path $root 'Web\server\package.json')
)) {
    if (Update-FileRegex -Path $pkg -Pattern '"version":(\s*)"[\d.]+"' -Replacement "`"version`":`$1`"$version`"") {
        $changed++; Write-OK "  $(Split-Path (Split-Path $pkg -Parent) -Leaf)/package.json"
    }
}

# --- 8. README : badge + references d'archive --------------------------------
$readme = Join-Path $root 'README.md'
if (Update-FileRegex -Path $readme -Pattern "version-[\d.]+-f0a830" -Replacement "version-$version-f0a830") { $changed++; Write-OK "  README (badge)" }
if (Update-FileRegex -Path $readme -Pattern "PSWinDeploy_v[\d.]+\.zip" -Replacement "PSWinDeploy_v$version.zip") { $changed++; Write-OK "  README (archive)" }

# --- 8b. Autres references a l'archive (Unblock, docs) ----------------------
foreach ($f in @(
    (Join-Path $root 'Unblock-PSWinDeploy.ps1'),
    (Join-Path $root 'REPART-A-ZERO.md')
)) {
    if (Update-FileRegex -Path $f -Pattern "PSWinDeploy_v[\d.]+\.zip" -Replacement "PSWinDeploy_v$version.zip") {
        $changed++; Write-OK "  $(Split-Path $f -Leaf) (archive)"
    }
}

Write-Host ""
Write-OK "Version $version propagee ($changed fichier(s) modifie(s))."

# --- 9. Generation de l'archive (optionnel) ---------------------------------
if ($Package) {
    Write-Host ""
    Write-Info "Generation de l'archive..."
    $parent  = Split-Path $root -Parent
    $zipName = "PSWinDeploy_v$version.zip"
    $zipPath = Join-Path $parent $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Copier le projet dans un dossier temporaire en excluant node_modules/dist.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pswd-pkg-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $dst = Join-Path $tmp 'PSWinDeploy'
    New-Item -ItemType Directory $dst -Force | Out-Null
    robocopy $root $dst /E /XD node_modules dist .git /XF *.log /NFL /NDL /NJH /NJS /NP | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zipPath)
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue

    if (Test-Path $zipPath) {
        $sizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-OK "Archive generee : $zipPath ($sizeMB MB)"
    } else {
        Write-Warn "Echec de generation de l'archive."
    }
}

Write-Host ""
Write-Info "Pour publier : commit + tag git v$version, puis distribuer l'archive."
