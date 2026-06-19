<#
.SYNOPSIS
    Collecte les fichiers de diagnostic depuis une partition Windows (VHDX monte
    ou disque) apres un BSOD, dans un dossier ZIP a transmettre pour analyse.

.DESCRIPTION
    Apres un BSOD au premier boot, monte le VHDX (ou branche le disque), puis
    lance ce script en pointant la lettre de la partition Windows. Il rassemble
    les logs Panther, minidumps, event logs, logs DISM et l'etat PSWinDeploy.

.PARAMETER WindowsDrive
    Lettre de la partition Windows montee (ex: 'F:'). OBLIGATOIRE.

.PARAMETER OutputDir
    Dossier ou creer l'archive. Defaut : dossier courant.

.EXAMPLE
    .\Collect-BSODInfo.ps1 -WindowsDrive F:
    # Monte d'abord le vhdx (clic droit > Monter), repere la lettre, puis lance.
#>
[CmdletBinding()]
param(
    [string]$WindowsDrive = '',   # si vide : auto-detection de la partition Windows
    [string]$OutputDir = '.'
)
$ErrorActionPreference = 'Continue'
function Say($m,$c='Gray'){ Write-Host "  $m" -ForegroundColor $c }

# --- Auto-detection de la partition Windows si non fournie ------------------
# Un VHDX UEFI a plusieurs partitions NTFS (Windows + Recovery). On cherche
# celle qui contient un VRAI Windows installe (System32
toskrnl.exe).
function Find-WindowsVolume {
    $candidates = @()
    foreach ($v in (Get-Volume -EA SilentlyContinue | Where-Object { $_.DriveLetter })) {
        $d = "$($v.DriveLetter):"
        if (Test-Path "$d\Windows\System32\ntoskrnl.exe" -EA SilentlyContinue) {
            $candidates += [PSCustomObject]@{
                Drive = $d
                SizeGB = [Math]::Round($v.Size/1GB,1)
                HasPanther = Test-Path "$d\Windows\Panther" -EA SilentlyContinue
                HasUsers = Test-Path "$d\Users" -EA SilentlyContinue
            }
        }
    }
    return $candidates
}

if (-not $WindowsDrive) {
    Say "Auto-detection de la partition Windows..." 'Cyan'
    $found = Find-WindowsVolume
    if ($found.Count -eq 0) {
        Write-Host "ERREUR : aucune partition Windows trouvee (pas de ntoskrnl.exe)." -ForegroundColor Red
        Write-Host "Le VHDX est-il bien monte ? (Mount-VHD -Path ...)" -ForegroundColor Yellow
        Write-Host "Verifie : Get-Volume  doit lister les lettres du VHDX." -ForegroundColor Yellow
        return
    }
    Say "Partition(s) Windows detectee(s) :" 'Green'
    foreach ($c in $found) {
        Say "  $($c.Drive)  $($c.SizeGB) GB  Panther=$($c.HasPanther)  Users=$($c.HasUsers)" 'Gray'
    }
    # Choisir la plus grosse (= l'OS, pas la Recovery)
    $W = ($found | Sort-Object SizeGB -Descending | Select-Object -First 1).Drive
    Say "Partition retenue : $W" 'Cyan'
} else {
    $W = $WindowsDrive.TrimEnd('\').TrimEnd(':') + ':'
}

if (-not (Test-Path "$W\Windows")) {
    Write-Host "ERREUR : $W\Windows introuvable." -ForegroundColor Red
    return
}

# --- INVENTAIRE CRITIQUE : que contient le disque ? ------------------------
# Determine si le crash est AVANT ou PENDANT Windows Setup.
Say "" ; Say "=== INVENTAIRE DU DISQUE (diagnostic du moment du crash) ===" 'White'
$inv = [ordered]@{
    'ntoskrnl.exe (noyau)'        = "$W\Windows\System32\ntoskrnl.exe"
    'ruche SYSTEM'                = "$W\Windows\System32\config\SYSTEM"
    'ruche SOFTWARE'              = "$W\Windows\System32\config\SOFTWARE"
    'WinSxS (image complete)'     = "$W\Windows\WinSxS"
    'Panther (Setup a tourne)'    = "$W\Windows\Panther"
    'Panther\unattend.xml'       = "$W\Windows\Panther\unattend.xml"
    'Users (OOBE passe)'          = "$W\Users"
    'Logs\CBS'                   = "$W\Windows\Logs\CBS"
    'Minidump (BSOD)'             = "$W\Windows\Minidump"
}
foreach ($k in $inv.Keys) {
    $exists = Test-Path $inv[$k] -EA SilentlyContinue
    $mark = if ($exists) { '[OK]' } else { '[ABSENT]' }
    $col  = if ($exists) { 'Green' } else { 'Red' }
    Say "  $mark  $k" $col
}
Say ""
Say "  INTERPRETATION :" 'Yellow'
Say "  - WinSxS ABSENT -> l'image WIM ne s'est pas appliquee (probleme dism/disque)" 'DarkGray'
Say "  - Panther ABSENT -> Windows Setup n'a jamais demarre (crash TRES precoce, AVANT config)" 'DarkGray'
Say "  - Panther PRESENT -> lire setuperr.log (probleme dans la config unattend)" 'DarkGray'
Say "  - Users ABSENT mais Panther present -> crash pendant specialize/oobe" 'DarkGray'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $OutputDir "BSOD-Info_$stamp"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Say "Collecte vers : $dest" 'Cyan'
Say ""

# Helper : copier en preservant un sous-chemin, sans planter si absent
function Grab($relPath, $label) {
    $src = Join-Path $W $relPath
    if (Test-Path $src) {
        $leaf = Split-Path $relPath -Leaf
        $sub  = ($relPath -replace '[:\\/]','_')
        try {
            if ((Get-Item $src).PSIsContainer) {
                Copy-Item $src (Join-Path $dest $sub) -Recurse -Force -EA SilentlyContinue
            } else {
                Copy-Item $src (Join-Path $dest $sub) -Force -EA SilentlyContinue
            }
            Say "[OK] $label" 'Green'
        } catch { Say "[!!] $label (erreur copie)" 'Yellow' }
    } else {
        Say "[--] $label (absent)" 'DarkGray'
    }
}

Say "=== 1. Logs de configuration (Panther) ===" 'White'
Grab 'Windows\Panther\setupact.log'            'Panther setupact.log'
Grab 'Windows\Panther\setuperr.log'            'Panther setuperr.log (ERREURS)'
Grab 'Windows\Panther\unattend.xml'            'unattend.xml utilise'
Grab 'Windows\Panther\diagerr.xml'             'diagerr.xml'
Grab 'Windows\Panther\diagwrn.xml'             'diagwrn.xml'
Grab 'Windows\Panther\UnattendGC\setupact.log' 'UnattendGC setupact.log (oobe)'
Grab 'Windows\Panther\UnattendGC\setuperr.log' 'UnattendGC setuperr.log (oobe)'

Say ""
Say "=== 2. Minidump du BSOD ===" 'White'
Grab 'Windows\Minidump'                        'Minidump (cause du crash)'
# MEMORY.DMP peut etre enorme : on note juste sa presence/taille
$memdmp = "$W\Windows\MEMORY.DMP"
if (Test-Path $memdmp) {
    $sz = [Math]::Round((Get-Item $memdmp).Length/1MB,0)
    Say "[i ] MEMORY.DMP present ($sz MB) -- NON copie (trop gros). Chemin : $memdmp" 'Yellow'
}

Say ""
Say "=== 3. Event logs ===" 'White'
Grab 'Windows\System32\winevt\Logs\System.evtx'      'System.evtx'
Grab 'Windows\System32\winevt\Logs\Application.evtx' 'Application.evtx'
Grab 'Windows\System32\winevt\Logs\Setup.evtx'       'Setup.evtx'

Say ""
Say "=== 4. Logs DISM / CBS ===" 'White'
Grab 'Windows\Logs\DISM\dism.log'              'DISM dism.log'
Grab 'Windows\Logs\CBS\CBS.log'                'CBS.log'

Say ""
Say "=== 5. Traces PSWinDeploy ===" 'White'
Grab 'Deploy\state.psd1'                       'state.psd1 (etat deploiement)'
Grab 'Deploy\Logs'                             'Deploy\Logs'

Say ""
Say "=== 6. Verifications de coherence ===" 'White'
$report = Join-Path $dest 'RAPPORT-COHERENCE.txt'
$lines = @()
$lines += "Rapport de coherence -- $stamp"
$lines += "Partition Windows analysee : $W"
$lines += ""
# winload.efi / boot
$lines += "winload.efi present : " + (Test-Path "$W\Windows\System32\winload.efi")
# Taille du dossier Windows (image appliquee ?)
try {
    $winSize = (Get-ChildItem "$W\Windows" -Recurse -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    $lines += "Taille de \Windows : " + [Math]::Round($winSize/1GB,2) + " GB (attendu > 10 GB si image complete)"
} catch { $lines += "Taille de \Windows : non calculable" }
# Presence des dossiers cles
foreach ($d in @('Windows\System32','Windows\Panther','Windows\Minidump','Deploy','Deploy\Scripts','Deploy\Modules')) {
    $lines += "$d : " + (Test-Path "$W\$d")
}
# Compte des fichiers Panther
if (Test-Path "$W\Windows\Panther") {
    $pc = @(Get-ChildItem "$W\Windows\Panther" -Recurse -EA SilentlyContinue).Count
    $lines += "Fichiers dans Panther : $pc"
}
$lines | Set-Content $report -Encoding UTF8
Say "[OK] RAPPORT-COHERENCE.txt genere" 'Green'

Say ""
Say "=== Compression ===" 'White'
$zip = "$dest.zip"
try {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path "$dest\*" -DestinationPath $zip -Force
    Say "Archive prete : $zip" 'Cyan'
    Say "Transmets ce ZIP pour analyse." 'Cyan'
} catch {
    Say "Compression echouee, mais les fichiers sont dans : $dest" 'Yellow'
}

Say ""
Say ">> A LIRE EN PRIORITE : setuperr.log et UnattendGC\setuperr.log" 'Yellow'
Say "   Ils indiquent souvent EXACTEMENT le parametre/composant qui a echoue." 'Yellow'
