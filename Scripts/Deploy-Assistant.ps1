#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy-Assistant.ps1 -- Editeur de sequences de POST-INSTALLATION (phase 2).
.DESCRIPTION
    Outil COTE SERVEUR pour creer et editer les sequences de deploiement (.psd1)
    qui pilotent la phase 2 (apres l'installation de Windows).

    IMPORTANT -- separation des phases :
      * Phase 1 (WinPE / SimpleDeploy) : disque, application du WIM, drivers.
        => NON gere ici. Choisi au boot WinPE sur la machine cible.
      * Phase 2 (cette sequence) : jonction domaine, logiciels, scripts, reglages.
        => C'est ce que cet assistant edite.

    Cet assistant ne lance AUCUN deploiement : il produit/modifie un fichier
    sequence .psd1 dans le partage Sequences.
.EXAMPLE
    .\Deploy-Assistant.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$SequencesPath,
    [string]$CataloguePath,
    [string]$ScriptShare
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# HELPERS VISUELS
# ---------------------------------------------------------------------------
function Write-Header {
    param([string]$Title)
    $w = 58; $line = '-' * $w
    Write-Host ""
    Write-Host "  +$line+" -ForegroundColor Cyan
    $pad  = ' ' * [Math]::Max(0, [Math]::Floor(($w - $Title.Length) / 2))
    $padR = ' ' * [Math]::Max(0, $w - $Title.Length - $pad.Length)
    Write-Host "  |$pad$Title$padR|" -ForegroundColor Cyan
    Write-Host "  +$line+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }
function Write-Sep  { Write-Host "  $('-'*58)" -ForegroundColor DarkGray }

function Read-Answer {
    param([string]$Question, [string]$Default = '')
    $hint = if ($Default) { " (defaut : $Default)" } else { '' }
    Write-Host "  [?]  $Question$hint : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim().Trim('"').Trim("'").Trim()
}
function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $d = if ($Default) { 'O/n' } else { 'o/N' }
    Write-Host "  [?]  $Question [$d] : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim().ToLower() -in @('o','oui','y','yes')
}
function Read-Choice {
    param([string]$Question, [int]$Max, [int]$Min = 1)
    while ($true) {
        Write-Host "  [?]  $Question [$Min-$Max] : " -ForegroundColor White -NoNewline
        $a = Read-Host
        if ($a -match '^\d+$' -and [int]$a -ge $Min -and [int]$a -le $Max) { return [int]$a }
        Write-Warn "Invalid choice."
    }
}

# ---------------------------------------------------------------------------
# SERIALISATION PSD1 (sequence -> fichier)
# ---------------------------------------------------------------------------
function Save-SequencePsd1 {
    param($Data, [string]$Path)
    function ConvertTo-P {
        param($O, [int]$I = 0)
        $sp = '    ' * $I; $sp1 = '    ' * ($I + 1)
        if ($null -eq $O) { return '$null' }
        if ($O -is [bool]) { return $(if ($O) { '$true' } else { '$false' }) }
        if ($O -is [int] -or $O -is [long] -or $O -is [double]) { return "$O" }
        if ($O -is [string]) { $e = $O.Replace("'", "''"); return "'$e'" }
        if ($O -is [System.Collections.IEnumerable] -and $O -isnot [string]) {
            $items = @($O | ForEach-Object { "$sp1$(ConvertTo-P $_ ($I+1))" })
            if ($items.Count -eq 0) { return '@()' }
            return "@(`n$($items -join "`n")`n$sp)"
        }
        if ($O -is [PSCustomObject] -or $O -is [hashtable]) {
            $props = if ($O -is [hashtable]) { $O.GetEnumerator() } else { $O.PSObject.Properties }
            $pairs = @($props | ForEach-Object { "$sp1$($_.Name) = $(ConvertTo-P $_.Value ($I+1))" })
            if ($pairs.Count -eq 0) { return '@{}' }
            return "@{`n$($pairs -join "`n")`n$sp}"
        }
        return "'$O'"
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, (ConvertTo-P $Data), $utf8Bom)
}

# ---------------------------------------------------------------------------
# CONFIG : resoudre les chemins (partage Sequences, catalogue, scripts)
# ---------------------------------------------------------------------------
function Resolve-SharePath {
    # Accepte une valeur @{DNS;IP} ou une string ; retourne le 1er chemin joignable.
    param($Value)
    if (-not $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    foreach ($k in @('DNS','IP')) {
        if ($Value.$k -and (Test-Path $Value.$k -EA SilentlyContinue)) { return $Value.$k }
    }
    if ($Value.DNS) { return $Value.DNS }
    if ($Value.IP)  { return $Value.IP }
    return ''
}

$cfg = $null
if (-not $ConfigPath) {
    foreach ($c in @("$PSScriptRoot\..\PSWinDeploy.psd1", "$PSScriptRoot\PSWinDeploy.psd1", "$PSScriptRoot\..\..\PSWinDeploy.psd1")) {
        if (Test-Path $c -EA SilentlyContinue) { $ConfigPath = (Resolve-Path $c).Path; break }
    }
}
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try { $cfg = Import-PowerShellDataFile $ConfigPath } catch { Write-Warn "Config illisible : $_" }
}
if (-not $SequencesPath) { $SequencesPath = Resolve-SharePath $cfg.SequencesPath }
if (-not $CataloguePath) {
    if ($cfg.ApiPaths -and $cfg.ApiPaths.CataloguePath) { $CataloguePath = $cfg.ApiPaths.CataloguePath }
    else { $CataloguePath = Resolve-SharePath $cfg.CataloguePath }
}
if (-not $ScriptShare) {
    if ($cfg.ApiPaths -and $cfg.ApiPaths.ScriptShare) { $ScriptShare = $cfg.ApiPaths.ScriptShare }
    else { $ScriptShare = Resolve-SharePath $cfg.ScriptShare }
}

# ---------------------------------------------------------------------------
# LECTURE CATALOGUE / SCRIPTS (pour aider la saisie)
# ---------------------------------------------------------------------------
function Get-CatalogueApps {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path -EA SilentlyContinue)) { return @() }
    try {
        $data = Import-PowerShellDataFile $Path
        if ($data.Applications) { return @($data.Applications) }
        # Repli : catalogue a plat (cle = id)
        return @($data.GetEnumerator() | ForEach-Object { $_.Value })
    } catch { return @() }
}
function Get-ShareScripts {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path -EA SilentlyContinue)) { return @() }
    return @(Get-ChildItem $Path -Recurse -Filter '*.ps1' -EA SilentlyContinue | Select-Object -First 200)
}

# ---------------------------------------------------------------------------
# TYPES DE STEPS PHASE 2 (liste autoritaire du moteur)
# ---------------------------------------------------------------------------
$StepTypes = @(
    @{ Type = 'WaitForNetwork';  Label = 'Attendre le reseau' }
    @{ Type = 'JoinDomain';      Label = 'Jonction au domaine' }
    @{ Type = 'InstallUpdates';  Label = 'Windows Update' }
    @{ Type = 'InstallApps';     Label = 'Installer des applications (catalogue)' }
    @{ Type = 'RunScript';       Label = 'Executer un script' }
    @{ Type = 'SetComputerName'; Label = 'Renommer la machine' }
    @{ Type = 'SetLocale';       Label = 'Langue / fuseau horaire' }
    @{ Type = 'CopyFiles';       Label = 'Copier des fichiers' }
    @{ Type = 'SetRegistry';     Label = 'Cle de registre' }
    @{ Type = 'Reboot';          Label = 'Redemarrer' }
    @{ Type = 'Cleanup';         Label = 'Nettoyage final' }
    @{ Type = 'ShowWizard';      Label = 'Assistant interactif (pause operateur)' }
)

# ---------------------------------------------------------------------------
# CONSTRUCTION D'UN STEP (selon le type)
# ---------------------------------------------------------------------------
function New-Step {
    param([int]$Index)
    Write-Host ""
    Write-Info "Step type:"
    for ($i = 0; $i -lt $StepTypes.Count; $i++) {
        Write-Host ("    [{0,2}] {1,-16} {2}" -f ($i+1), $StepTypes[$i].Type, $StepTypes[$i].Label) -ForegroundColor Gray
    }
    Write-Host "    [ 0] Cancel / finish" -ForegroundColor DarkGray
    $sel = Read-Choice "Choose the type" -Max $StepTypes.Count -Min 0
    if ($sel -eq 0) { return $null }
    $t = $StepTypes[$sel-1].Type

    $id   = 'pi-{0:D2}' -f $Index
    $name = Read-Answer "Step name" -Default $StepTypes[$sel-1].Label
    $step = [ordered]@{
        Id          = $id
        Type        = $t
        Phase       = 'Windows'
        Name        = $name
        Enabled     = $true
        RebootAfter = 'Never'
    }
    $params = [ordered]@{}

    switch ($t) {
        'JoinDomain' {
            $params.Domain = Read-Answer "Domaine (vide = depuis la config)"
            $params.OU     = Read-Answer "OU (optionnel)"
            $step.RebootAfter = 'IfRequired'
        }
        'WaitForNetwork' {
            $params.TimeoutSec = [int](Read-Answer "Timeout (secondes)" -Default '120')
        }
        'InstallUpdates' {
            $step.RebootAfter = 'IfRequired'
        }
        'InstallApps' {
            $apps = Get-CatalogueApps -Path $CataloguePath
            if ($apps.Count -gt 0) {
                Write-Info "$($apps.Count) application(s) au catalogue :"
                for ($i = 0; $i -lt [Math]::Min($apps.Count, 40); $i++) {
                    $a = $apps[$i]
                    $nm = if ($a.Name) { $a.Name } elseif ($a.Id) { $a.Id } else { "$a" }
                    Write-Host ("    [{0,2}] {1}" -f ($i+1), $nm) -ForegroundColor Gray
                }
                Write-Info "Saisir les numeros separes par des virgules (ex : 1,3,5)."
                $picks = (Read-Answer "Applications to install") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
                $sel = foreach ($p in $picks) {
                    $idx = [int]$p - 1
                    if ($idx -ge 0 -and $idx -lt $apps.Count) {
                        $a = $apps[$idx]
                        if ($a.Id) { $a.Id } elseif ($a.Name) { $a.Name } else { "$a" }
                    }
                }
                $params.Apps = @($sel)
            } else {
                Write-Warn "Catalogue vide ou introuvable ($CataloguePath)."
                $params.Apps = @((Read-Answer "Identifiants d'apps (separes par virgule)") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            $step.RebootAfter = 'IfRequired'
        }
        'RunScript' {
            $scripts = Get-ShareScripts -Path $ScriptShare
            if ($scripts.Count -gt 0) {
                Write-Info "$($scripts.Count) script(s) dans le partage :"
                for ($i = 0; $i -lt [Math]::Min($scripts.Count, 40); $i++) {
                    Write-Host ("    [{0,2}] {1}" -f ($i+1), $scripts[$i].Name) -ForegroundColor Gray
                }
                Write-Host "    [ 0] Saisir un chemin manuellement" -ForegroundColor DarkGray
                $pick = Read-Choice "Choose the script" -Max $scripts.Count -Min 0
                if ($pick -eq 0) { $params.Path = Read-Answer "Script path" }
                else { $params.Path = $scripts[$pick-1].FullName }
            } else {
                $params.Path = Read-Answer "Script path (.ps1)"
            }
            $params.Shell = 'PowerShell'
        }
        'SetComputerName' {
            $params.Name = Read-Answer "New name (or template, e.g. WS-%SERIAL%)"
            $step.RebootAfter = 'IfRequired'
        }
        'SetLocale' {
            $params.Locale   = Read-Answer "Locale" -Default 'fr-FR'
            $params.Timezone = Read-Answer "Fuseau horaire" -Default 'Romance Standard Time'
        }
        'CopyFiles' {
            $params.Source = Read-Answer "Source"
            $params.Dest   = Read-Answer "Destination"
        }
        'SetRegistry' {
            $params.Path  = Read-Answer "Cle (ex HKLM:\Software\...)"
            $params.Name  = Read-Answer "Value name"
            $params.Value = Read-Answer "Donnee"
        }
        'Reboot' {
            $step.RebootAfter = 'Always'
        }
        'Cleanup'    { }
        'ShowWizard' { }
    }

    if ($params.Count -gt 0) { $step.Params = $params }
    return $step
}

# ---------------------------------------------------------------------------
# EDITION DES STEPS D'UNE SEQUENCE
# ---------------------------------------------------------------------------
function Edit-Steps {
    param([System.Collections.ArrayList]$Steps)
    while ($true) {
        Write-Header "Sequence steps"
        if ($Steps.Count -eq 0) {
            Write-Info "No step yet."
        } else {
            for ($i = 0; $i -lt $Steps.Count; $i++) {
                $s = $Steps[$i]
                $en = if ($s.Enabled) { ' ' } else { 'x' }
                Write-Host ("    [{0,2}] ({1}) {2,-16} {3}" -f ($i+1), $en, $s.Type, $s.Name) -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "    [A] Add a step" -ForegroundColor Gray
        Write-Host "    [S] Delete a step" -ForegroundColor Gray
        Write-Host "    [M] Move a step up / down" -ForegroundColor Gray
        Write-Host "    [T] Enable / disable a step" -ForegroundColor Gray
        Write-Host "    [V] Validate and save" -ForegroundColor Green
        Write-Host "    [Q] Quit without saving" -ForegroundColor DarkGray
        Write-Host "  [?]  Choix : " -ForegroundColor White -NoNewline
        $c = (Read-Host).Trim().ToUpper()
        switch ($c) {
            'A' {
                $st = New-Step -Index ($Steps.Count + 1)
                if ($st) { [void]$Steps.Add($st) }
            }
            'S' {
                if ($Steps.Count -gt 0) {
                    $n = Read-Choice "Number to delete" -Max $Steps.Count
                    $Steps.RemoveAt($n-1)
                }
            }
            'M' {
                if ($Steps.Count -gt 1) {
                    $n = Read-Choice "Numero a deplacer" -Max $Steps.Count
                    $dir = Read-Answer "Move up (h) or down (b)?" -Default 'h'
                    $idx = $n - 1
                    $tgt = if ($dir -eq 'b') { $idx + 1 } else { $idx - 1 }
                    if ($tgt -ge 0 -and $tgt -lt $Steps.Count) {
                        $tmp = $Steps[$idx]; $Steps[$idx] = $Steps[$tgt]; $Steps[$tgt] = $tmp
                    }
                }
            }
            'T' {
                if ($Steps.Count -gt 0) {
                    $n = Read-Choice "Numero a (des)activer" -Max $Steps.Count
                    $Steps[$n-1].Enabled = -not $Steps[$n-1].Enabled
                }
            }
            'V' { return $true }
            'Q' { return $false }
        }
    }
}

# ---------------------------------------------------------------------------
# MENU PRINCIPAL
# ---------------------------------------------------------------------------
Clear-Host
Write-Header "PSWinDeploy -- Sequence editor (phase 2)"
Write-Info "Edits POST-INSTALLATION sequences (after Windows is installed)."
Write-Info "Disk, WIM and drivers are handled in phase 1 (WinPE)."
Write-Host ""
Write-Info "Partage sequences : $SequencesPath"
Write-Host ""

if (-not $SequencesPath) {
    Write-Err "Sequences share path not found. Check PSWinDeploy.psd1."
    exit 1
}
if (-not (Test-Path $SequencesPath -EA SilentlyContinue)) {
    Write-Warn "Le partage Sequences n'existe pas encore : $SequencesPath"
    if (Read-YesNo "Create it?" $true) { New-Item -ItemType Directory $SequencesPath -Force | Out-Null }
    else { exit 1 }
}

while ($true) {
    Write-Header "Mode"
    Write-Host "    [1] Create a new sequence" -ForegroundColor White
    Write-Host "    [2] Edit an existing sequence" -ForegroundColor White
    Write-Host "    [3] List sequences" -ForegroundColor White
    Write-Host "    [Q] Quitter" -ForegroundColor DarkGray
    Write-Host "  [?]  Choix : " -ForegroundColor White -NoNewline
    $mode = (Read-Host).Trim().ToUpper()

    if ($mode -eq 'Q') { break }

    if ($mode -eq '3') {
        Write-Header "Available sequences"
        $files = @(Get-ChildItem $SequencesPath -Filter '*.psd1' -EA SilentlyContinue)
        if ($files.Count -eq 0) { Write-Info "No sequence." }
        foreach ($f in $files) {
            try {
                $s = Import-PowerShellDataFile $f.FullName
                $nb = if ($s.Steps) { @($s.Steps).Count } else { 0 }
                Write-Host "    $($f.Name)" -ForegroundColor White -NoNewline
                Write-Host "  ($nb etape(s))" -ForegroundColor DarkGray
            } catch { Write-Warn "    $($f.Name) (illisible)" }
        }
        Write-Host ""
        Write-Host "  [?]  Entree pour continuer..." -ForegroundColor White -NoNewline
        Read-Host | Out-Null
        continue
    }

    $seq = $null
    $outPath = $null

    if ($mode -eq '1') {
        Write-Header "New sequence"
        $name = Read-Answer "Sequence name" -Default 'Post-installation standard'
        $fileName = Read-Answer "File name (.psd1)" -Default 'ma-sequence.psd1'
        if ($fileName -notlike '*.psd1') { $fileName += '.psd1' }
        $outPath = Join-Path $SequencesPath $fileName
        $seq = [ordered]@{
            Id      = 'ts-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
            Name    = $name
            Version = '1.0.0'
            Metadata = [ordered]@{ Os = 'Windows'; Locale = 'fr-FR' }
            Options  = [ordered]@{ ContinueOnError = $true; LogLevel = 'Info' }
            Steps    = @()
        }
    }
    elseif ($mode -eq '2') {
        $files = @(Get-ChildItem $SequencesPath -Filter '*.psd1' -EA SilentlyContinue)
        if ($files.Count -eq 0) { Write-Warn "No sequence to edit."; continue }
        Write-Header "Choose the sequence"
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i+1), $files[$i].Name) -ForegroundColor White
        }
        $pick = Read-Choice "Sequence to edit" -Max $files.Count
        $outPath = $files[$pick-1].FullName
        try {
            $loaded = Import-PowerShellDataFile $outPath
            $seq = [ordered]@{
                Id      = if ($loaded.Id) { $loaded.Id } else { 'ts-' + ([guid]::NewGuid().ToString('N').Substring(0,8)) }
                Name    = if ($loaded.Name) { $loaded.Name } else { $files[$pick-1].BaseName }
                Version = if ($loaded.Version) { $loaded.Version } else { '1.0.0' }
                Metadata = if ($loaded.Metadata) { $loaded.Metadata } else { [ordered]@{ Os = 'Windows'; Locale = 'fr-FR' } }
                Options  = if ($loaded.Options) { $loaded.Options } else { [ordered]@{ ContinueOnError = $true; LogLevel = 'Info' } }
                Steps    = @()
            }
            $existingSteps = @($loaded.Steps)
        } catch {
            Write-Err "Lecture impossible : $_"; continue
        }
    }
    else { continue }

    # Charger les steps existants dans une liste editable.
    $steps = [System.Collections.ArrayList]::new()
    if ($mode -eq '2' -and $existingSteps) {
        foreach ($s in $existingSteps) {
            $o = [ordered]@{}
            foreach ($k in @('Id','Type','Phase','Name','Enabled','RebootAfter')) {
                if ($null -ne $s.$k) { $o[$k] = $s.$k }
            }
            if ($s.Params) { $o['Params'] = $s.Params }
            [void]$steps.Add($o)
        }
    }

    $save = Edit-Steps -Steps $steps
    if (-not $save) { Write-Warn "Aborted (not saved)."; continue }

    # Re-numeroter les Id pour rester coherent.
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if (-not $steps[$i].Id) { $steps[$i].Id = 'pi-{0:D2}' -f ($i+1) }
    }
    $seq.Steps = @($steps)

    Save-SequencePsd1 -Data $seq -Path $outPath
    Write-OK "Sequence enregistree : $outPath"
    Write-Info "$($steps.Count) etape(s)."
    Write-Host ""
    Write-Host "  [?]  Entree pour continuer..." -ForegroundColor White -NoNewline
    Read-Host | Out-Null
}

Write-Host ""
Write-OK "A bientot."
