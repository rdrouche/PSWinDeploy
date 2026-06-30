<#
.SYNOPSIS
    Diagnostic complet de la chaine phase 2 : verifie chaque maillon entre le
    WinPE et la cible, pour localiser pourquoi C:\Deploy\Runtime\sequence.psd1
    n'est pas cree.
.DESCRIPTION
    A lancer EN WINPE (avant ou apres deploiement) via Shift+F10 ou l'option [C].
    Verifie : le dossier Sequences embarque dans le WIM, la presence de W:\,
    et simule la copie.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File X:\Deploy\Scripts\Diag-Phase2.ps1
#>
function Say($m,$c='Gray'){ Write-Host "  $m" -ForegroundColor $c }

Say "===== DIAGNOSTIC CHAINE PHASE 2 =====" 'Cyan'
Say ""

# 1. Le dossier Sequences est-il embarque dans le WIM (X:\Deploy\Sequences) ?
Say "[1] Dossier Sequences embarque dans le WinPE ?" 'White'
foreach ($p in @('X:\Deploy\Sequences','X:\Deploy\Scripts','X:\Deploy\Modules','X:\Deploy\Profiles')) {
    $exists = Test-Path $p -EA SilentlyContinue
    $mark = if ($exists) { '[OK]' } else { '[ABSENT]' }
    $col  = if ($exists) { 'Green' } else { 'Red' }
    Say "  $mark  $p" $col
    if ($exists -and $p -like '*Sequences*') {
        $seqs = @(Get-ChildItem $p -Filter '*.psd1' -EA SilentlyContinue)
        Say "        -> $($seqs.Count) sequence(s) : $(($seqs.BaseName) -join ', ')" 'DarkGray'
    }
}
Say ""

# 2. Ou est reellement lance Start-Deploy ? (X:\Deploy\Scripts ou ailleurs)
Say "[2] Emplacement de Start-Deploy.ps1 lance" 'White'
foreach ($p in @('X:\Deploy\Scripts\Start-Deploy.ps1','X:\Windows\System32\startnet.cmd')) {
    Say "  $(if(Test-Path $p){'[OK]'}else{'[ABSENT]'})  $p" $(if(Test-Path $p){'Green'}else{'Red'})
}
Say ""

# 3. La partition cible W: existe-t-elle ? (apres partitionnement)
Say "[3] Partition cible W: (doit exister APRES le partitionnement)" 'White'
foreach ($l in @('W','S','R')) {
    Say "  $(if(Test-Path "${l}:\"){'[OK]'}else{'[ABSENT]'})  ${l}:\" $(if(Test-Path "${l}:\"){'Green'}else{'DarkGray'})
}
if (Test-Path 'W:\Deploy' -EA SilentlyContinue) {
    Say "  W:\Deploy contient :" 'Gray'
    Get-ChildItem 'W:\Deploy' -EA SilentlyContinue | ForEach-Object { Say "      - $($_.Name)" 'DarkGray' }
}
Say ""

# 4. Verifier la version de SimpleDeploy embarquee (a-t-elle le code -SequencePath ?)
Say "[4] SimpleDeploy embarque gere-t-il -SequencePath / -DeployConfig ?" 'White'
$sd = 'X:\Deploy\Modules\SimpleDeploy\SimpleDeploy.psm1'
if (Test-Path $sd) {
    $c = Get-Content $sd -Raw
    Say "  $(if($c -match 'SequencePath'){'[OK]'}else{'[ABSENT]'})  parametre SequencePath" $(if($c -match 'SequencePath'){'Green'}else{'Red'})
    Say "  $(if($c -match 'DeployConfig'){'[OK]'}else{'[ABSENT]'})  parametre DeployConfig" $(if($c -match 'DeployConfig'){'Green'}else{'Red'})
    Say "  $(if($c -match 'deploy-config'){'[OK]'}else{'[ABSENT]'})  ecriture deploy-config.psd1" $(if($c -match 'deploy-config'){'Green'}else{'Red'})
} else {
    Say "  [ABSENT] $sd -- SimpleDeploy pas embarque !" 'Red'
}
Say ""

# 5. Version de Start-Deploy embarquee (a-t-elle le menu sequence ?)
Say "[5] Start-Deploy embarque a-t-il le menu sequence phase 2 ?" 'White'
$sdp = 'X:\Deploy\Scripts\Start-Deploy.ps1'
if (Test-Path $sdp) {
    $c = Get-Content $sdp -Raw
    Say "  $(if($c -match 'Sequence de phase 2'){'[OK]'}else{'[ABSENT]'})  menu sequence phase 2" $(if($c -match 'Sequence de phase 2'){'Green'}else{'Red'})
    Say "  $(if($c -match 'Dossier Sequences introuvable'){'[OK derniere version]'}else{'[ANCIENNE version]'})  diagnostic dossier" $(if($c -match 'Dossier Sequences introuvable'){'Green'}else{'Yellow'})
} else {
    Say "  [ABSENT] $sdp" 'Red'
}
Say ""
Say "===== FIN DIAGNOSTIC =====" 'Cyan'
Say "Send this output to locate the missing link." 'Yellow'

# ===== AJOUT : verification des fichiers de config sur la cible (phase 2) =====
Write-Host ""
Write-Host "  ===== FICHIERS DE CONFIG SUR LA CIBLE (C:\Deploy) =====" -ForegroundColor Cyan
foreach ($f in @('C:\Deploy\deploy-config.psd1','C:\Deploy\secrets.vault','C:\Deploy\secrets.vault.psd1','C:\Deploy\Runtime\sequence.psd1')) {
    if (Test-Path $f -EA SilentlyContinue) {
        Write-Host "  [OK]  $f" -ForegroundColor Green
        if ($f -match 'deploy-config') {
            try {
                $c = Import-PowerShellDataFile $f
                Write-Host "        NetworkShare = $($c.NetworkShare)" -ForegroundColor Gray
                Write-Host "        Fallback     = $($c.NetworkShareFallback)" -ForegroundColor Gray
            } catch { Write-Host "        (lecture echouee)" -ForegroundColor Red }
        }
        if ($f -match 'secrets.vault') {
            try {
                $v = Import-PowerShellDataFile $f -EA SilentlyContinue
                $hasLap = if ($v -and $v.ContainsKey('localAdminPassword')) { 'OUI' } else { 'NON' }
                Write-Host "        localAdminPassword present : $hasLap" -ForegroundColor $(if($hasLap -eq 'OUI'){'Green'}else{'Red'})
            } catch {}
        }
    } else {
        Write-Host "  [ABSENT]  $f" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "  Si deploy-config ABSENT -> SimpleDeploy ne l'a pas ecrit (CopyDeploy off ?)" -ForegroundColor Yellow
Write-Host "  Si vault sans localAdminPassword -> rebuild WinPE avec le nouveau build" -ForegroundColor Yellow
