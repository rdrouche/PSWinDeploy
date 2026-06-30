# TaskEngine.psm1 -- LE MOTEUR d'ordonnancement de la phase 2.
#
# RESPONSABILITES (et SEULEMENT celles-ci) :
#   - charger la sequence (psd1) et l'etat (state.psd1)
#   - derouler les steps dans l'ordre (filtre de phase)
#   - pour chaque step : ecrire un marqueur, APPELER le handler par son Type,
#     lire le CONTRAT retourne (New-TaskResult), decider reboot / step suivant
#   - gerer la REPRISE selon le modele simple :
#       * autologon active UNE FOIS au debut, marqueur "deployment in progress"
#       * UNE tache "a l'ouverture de session" relance l'assistant en P2
#       * desarmement (autologon + tache) UNIQUEMENT a la fin (done)
#
# LE MOTEUR NE CONNAIT PAS le detail des taches : il dispatche par Type vers les
# handlers (TaskHandlers) et lit un contrat standard. C'est tout.

# Charge le module leger DeployReport (Send-DeployReport) si pas deja present.
# TaskEngine emet des heartbeats via Send-DeployReport pendant le deploiement.
if (-not (Get-Command Send-DeployReport -EA SilentlyContinue)) {
    $drMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'DeployReport\DeployReport.psm1'
    if (Test-Path $drMod) { Import-Module $drMod -Force -Global -EA SilentlyContinue }
}

Set-StrictMode -Version Latest

# --- Etat / chemins standard de la phase 2 ---
$script:EngineRoot   = 'C:\Deploy'
$script:EngineLogs   = 'C:\Deploy\Logs'
$script:EngineState  = 'C:\Deploy\Runtime\state.psd1'
$script:EngineSeq    = 'C:\Deploy\Runtime\sequence.psd1'

function Write-EngineLog {
    param([string]$Message, [string]$Level = 'INFO', [string]$StepId = '')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $tag = if ($StepId) { "[$StepId]" } else { "[-]" }
    $color = switch ($Level) { 'SUCCESS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host "$stamp $tag $Message" -ForegroundColor $color
    try {
        if (-not (Test-Path $script:EngineLogs)) { New-Item -ItemType Directory $script:EngineLogs -Force -EA SilentlyContinue | Out-Null }
        Add-Content -Path (Join-Path $script:EngineLogs 'engine.log') -Value "$stamp [$Level] $tag $Message" -EA SilentlyContinue
    } catch {}
}

# ===========================================================================
#  REPRISE -- modele simple : autologon = "deployment in progress",
#  une tache "a l'ouverture de session" relance l'assistant.
# ===========================================================================
function Get-LocalAdminName {
    # Nom reel du compte admin local (SID -500), independant de la langue.
    try {
        $a = Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -EA Stop |
             Where-Object { $_.SID -like 'S-1-5-21-*-500' } | Select-Object -First 1
        if ($a -and $a.Name) { return $a.Name }
    } catch {}
    return 'Administrator'
}

function Enable-DeploymentMode {
    <#
    .SYNOPSIS Active le "deployment mode" : autologon ON + tache de reprise a
        l'ouverture de session. Appele UNE FOIS au debut de la phase 2. Idempotent.
    .PARAMETER AdminPassword  mot de passe du compte admin local (pour l'autologon)
    .PARAMETER ResumeScript   chemin de Start-Deploy.ps1 a relancer
    #>
    param(
        [string]$AdminPassword,
        [string]$ResumeScript = 'C:\Deploy\Scripts\Start-Deploy.ps1'
    )
    $adminName = Get-LocalAdminName

    # 1) AUTOLOGON (marqueur "deployment in progress")
    if ($AdminPassword) {
        try {
            $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty $wl -Name 'AutoAdminLogon'    -Value '1'        -Type String -Force -EA Stop
            Set-ItemProperty $wl -Name 'DefaultUserName'   -Value $adminName -Type String -Force -EA Stop
            Set-ItemProperty $wl -Name 'DefaultPassword'   -Value $AdminPassword -Type String -Force -EA Stop
            # Pas de DefaultDomainName (compte local). AutoLogonCount non utilise :
            # on veut que l'autologon PERSISTE jusqu'au desarmement explicite.
            Remove-ItemProperty $wl -Name 'AutoLogonCount' -Force -EA SilentlyContinue
            Write-EngineLog "Mode deploiement : autologon active (compte '$adminName')." 'SUCCESS'
        } catch {
            Write-EngineLog "Activation autologon echouee : $_" 'WARN'
        }
    } else {
        Write-EngineLog "No admin password -- autologon not enabled (resume via startup task)." 'WARN'
    }

    # 2) TACHE DE REPRISE "A L'OUVERTURE DE SESSION"
    # Elle tourne DANS la session du compte autologon -> fenetre VISIBLE.
    # Si l'autologon n'est pas dispo, on bascule sur un declencheur au demarrage.
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $ResumeScript -EA SilentlyContinue)) {
            $alt = @('C:\Deploy\Scripts\Start-Deploy.ps1','C:\Deploy\Start-Deploy.ps1') |
                   Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
            if ($alt) { $ResumeScript = $alt }
        }
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ResumeScript`" -Resume"
        Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue
        $action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
        if ($AdminPassword) {
            # A l'ouverture de session du compte admin -> session interactive visible
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $adminName
            $principal = New-ScheduledTaskPrincipal -UserId $adminName -LogonType Interactive -RunLevel Highest
        } else {
            # Filet : au demarrage en SYSTEM (pas de fenetre, mais ca reprend)
            $trigger   = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'PSWinDeployResume' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -EA Stop | Out-Null
        Write-EngineLog "Resume task created (at logon)." 'SUCCESS'
    } catch {
        Write-EngineLog "Creation tache de reprise echouee : $_" 'WARN'
    }

    # 3) Script de secours sur le disque + Bureau
    Write-DeployResetScript
}

function Disable-DeploymentMode {
    <#
    .SYNOPSIS Desactive le "deployment mode" : autologon OFF + tache supprimee +
        mot de passe retire du registre. Appele UNE FOIS a la fin (deploiement
        termine). C'est le SEUL endroit qui desarme.
    #>
    try {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $wl -Name 'AutoAdminLogon' -Value '0' -Type String -Force -EA SilentlyContinue
        Remove-ItemProperty $wl -Name 'DefaultPassword' -Force -EA SilentlyContinue
    } catch {}
    try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue } catch {}
    # Filet : certaines configs n'aiment pas Unregister-ScheduledTask -> schtasks.
    try { schtasks /Delete /TN 'PSWinDeployResume' /F 2>&1 | Out-Null } catch {}
    Write-EngineLog "Deployment mode disabled (autologon OFF, task removed)." 'INFO'
}

function Test-DeploymentMode {
    <# .SYNOPSIS Le deployment mode est-il actif ? (autologon ON = en cours) #>
    try {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $v = (Get-ItemProperty $wl -Name 'AutoAdminLogon' -EA SilentlyContinue).AutoAdminLogon
        return ("$v" -eq '1')
    } catch { return $false }
}

function Write-DeployResetScript {
    if (-not (Test-Path 'C:\Deploy' -EA SilentlyContinue)) { return }
    $script = @'
# Reset-PSWinDeploy.ps1 -- desarme l'autologon et la reprise PSWinDeploy.
# A lancer en administrateur si le deploiement reboucle ou se bloque.
Write-Host "Disarming autologon and resume..." -ForegroundColor Yellow
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
try { Set-ItemProperty $wl -Name 'AutoAdminLogon' -Value '0' -Type String -Force -EA SilentlyContinue } catch {}
try { Remove-ItemProperty $wl -Name 'DefaultPassword' -Force -EA SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue } catch {}
Write-Host "Done. Autologon and resume disabled." -ForegroundColor Green
Read-Host "Entree pour fermer"
'@
    foreach ($dest in @('C:\Deploy\Reset-PSWinDeploy.ps1', "$env:PUBLIC\Desktop\Reset-PSWinDeploy.ps1")) {
        try {
            $dir = Split-Path $dest -Parent
            if (Test-Path $dir -EA SilentlyContinue) {
                $enc = New-Object System.Text.UTF8Encoding($true)
                [System.IO.File]::WriteAllText($dest, $script, $enc)
            }
        } catch {}
    }
}


# ===========================================================================
#  STATE -- persistance de l'avancement (quel step reprendre apres reboot)
# ===========================================================================
function Get-EngineState {
    if (-not (Test-Path $script:EngineState -EA SilentlyContinue)) { return $null }
    try { return Import-PowerShellDataFile $script:EngineState -EA Stop } catch { return $null }
}

function Save-EngineState {
    param([hashtable]$State)
    try {
        $dir = Split-Path $script:EngineState -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force -EA SilentlyContinue | Out-Null }
        $lines = @('@{')
        foreach ($k in $State.Keys) {
            $v = $State[$k]
            if ($v -is [int] -or $v -is [bool]) { $lines += "    $k = $v" }
            else { $sv = "$v".Replace("'","''"); $lines += "    $k = '$sv'" }
        }
        $lines += '}'
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($script:EngineState, ($lines -join "`r`n"), $enc)
    } catch { Write-EngineLog "Sauvegarde state echouee : $_" 'WARN' }
}

function Remove-EngineState {
    try { Remove-Item $script:EngineState -Force -EA SilentlyContinue } catch {}
}

# ===========================================================================
#  DISPATCH -- appeler le bon handler selon le Type du step
# ===========================================================================
function Invoke-StepHandler {
    <#
    .SYNOPSIS Appelle le handler correspondant au Type du step et NORMALISE le
        resultat via le contrat (ConvertTo-TaskResult). Retourne TOUJOURS un
        PSCustomObject standard.
    #>
    param($Step, $Context)
    $type = "$(Get-StepProperty $Step 'type')"
    if (-not $type) { $type = "$(Get-StepProperty $Step 'Type')" }

    # Table de correspondance Type -> fonction handler
    $map = @{
        'JoinDomain'      = 'Invoke-TaskJoinDomain'
        'InstallApps'     = 'Invoke-TaskInstallApps'
        'InstallSoftware' = 'Invoke-TaskInstallApps'
        'InstallUpdates'  = 'Invoke-TaskInstallUpdates'
        'RunScript'       = 'Invoke-TaskRunScript'
        'WaitForNetwork'  = 'Invoke-TaskWaitForNetwork'
        'Reboot'          = 'Invoke-TaskReboot'
        'Cleanup'         = 'Invoke-TaskCleanup'
        'ShowWizard'      = 'Invoke-TaskShowWizard'
        'CopyFiles'       = 'Invoke-TaskCopyFiles'
        'SetRegistry'     = 'Invoke-TaskSetRegistry'
        'SetComputerName' = 'Invoke-TaskSetComputerName'
        'SetLocale'       = 'Invoke-TaskSetLocale'
        'InjectDrivers'   = 'Invoke-TaskInjectDrivers'
    }
    $fn = $map[$type]
    if (-not $fn) {
        Write-EngineLog "Type de step inconnu : '$type' -- ignore." 'WARN' $Step.id
        return (New-TaskResult -Message "type inconnu: $type")
    }
    if (-not (Get-Command $fn -EA SilentlyContinue)) {
        Write-EngineLog "Handler '$fn' introuvable pour le type '$type'." 'WARN' $Step.id
        return (New-TaskResult -Success:$false -Message "handler manquant: $fn")
    }
    try {
        $raw = & $fn -Step $Step -Context $Context
        return (ConvertTo-TaskResult $raw)
    } catch {
        Write-EngineLog "Handler '$fn' a leve une exception : $_" 'ERROR' $Step.id
        return (New-TaskResult -Success:$false -Message "exception: $_")
    }
}

# ===========================================================================
#  Invoke-Engine -- LA BOUCLE PRINCIPALE
# ===========================================================================

function Invoke-Engine {
    <#
    .SYNOPSIS Deroule une sequence : charge, boucle sur les steps, dispatche vers
        les handlers, lit le contrat, gere reboot/state/marqueur. Un seul flux.
    .PARAMETER SequencePath  chemin local de la sequence (toujours C:\Deploy\Runtime\sequence.psd1)
    .PARAMETER Context       table partagee (Log, GetConfig, GetSecret, LogsDir...)
    .PARAMETER Resume        reprendre depuis le state existant
    .PARAMETER PhaseFilter   'Windows' en phase 2
    #>
    param(
        [string]$SequencePath = $script:EngineSeq,
        [hashtable]$Context,
        [switch]$Resume,
        [string]$PhaseFilter = 'Windows'
    )
    if (-not $Context) { $Context = @{} }
    # Acces hashtable SUR en StrictMode : tester ContainsKey avant d'acceder.
    if (-not $Context.ContainsKey('LogsDir') -or -not $Context['LogsDir']) { $Context['LogsDir'] = $script:EngineLogs }
    if (-not $Context.ContainsKey('Log')    -or -not $Context['Log'])    { $Context['Log'] = { param($m,$l,$s) Write-EngineLog $m $l $s } }
    if (-not $Context.ContainsKey('GetConfig')) { $Context['GetConfig'] = $null }
    if (-not $Context.ContainsKey('GetSecret')) { $Context['GetSecret'] = $null }

    if (-not (Test-Path $SequencePath -EA SilentlyContinue)) {
        Write-EngineLog "Sequence introuvable : $SequencePath" 'ERROR'
        return $null
    }
    $sequence = Import-PowerShellDataFile $SequencePath -EA Stop
    $allSteps = @($sequence.Steps)
    Write-EngineLog "Sequence '$($sequence.Name)' -- $($allSteps.Count) step(s)" 'INFO'

    # Filtre de phase : un step est 'WinPE' par defaut, 'Windows' s'il le declare.
    $stepsToRun = @($allSteps | Where-Object {
        $ph = "$(Get-StepProperty $_ 'Phase')"
        if (-not $ph) { $ph = 'WinPE' }
        $ph -eq $PhaseFilter
    })
    Write-EngineLog "Filtre de phase '$PhaseFilter' : $($stepsToRun.Count) step(s) retenu(s)" 'INFO'

    # Reprise : retrouver le step de depart
    $state = if ($Resume) { Get-EngineState } else { $null }
    $startId = if ($state -and $state.nextStepId) { "$($state.nextStepId)" } else { '' }
    $rebootCount = if ($state -and $state.rebootCount) { [int]$state.rebootCount } else { 0 }

    $startIdx = 0
    if ($startId -and $startId -ne '__done__') {
        for ($i = 0; $i -lt $stepsToRun.Count; $i++) {
            if ("$(Get-StepProperty $stepsToRun[$i] 'Id')" -eq $startId) { $startIdx = $i; break }
        }
        Write-EngineLog "Reprise : depart au step '$startId' (reboot #$rebootCount)" 'INFO'
    }
    if ($startId -eq '__done__') {
        Write-EngineLog "State = done. Nothing to do." 'SUCCESS'
        return @{ done = $true }
    }

    # ----- BOUCLE PRINCIPALE -----
    for ($idx = $startIdx; $idx -lt $stepsToRun.Count; $idx++) {
        $step = $stepsToRun[$idx]
        $stepId = "$(Get-StepProperty $step 'Id')"
        $stepName = "$(Get-StepProperty $step 'Name')"
        $stepEnabled = Get-StepProperty $step 'Enabled' -Default $true
        if (-not $stepEnabled) { Write-EngineLog "Step '$stepName' desactive -- ignore." 'INFO' $stepId; continue }

        # MARQUEUR "je commence cette action" (diagnostic + reprise)
        $marker = Join-Path $Context.LogsDir '.current-step'
        try {
            $mi = @("stepId=$stepId", "stepName=$stepName", "startedAt=$(Get-Date -Format 'o')") -join "`r`n"
            Set-Content -Path $marker -Value $mi -Encoding UTF8 -EA SilentlyContinue
        } catch {}
        Write-EngineLog "[DEBUT] Step '$stepName'" 'STEP' $stepId

        # Heartbeat vers l'API (suivi temps reel dans le web). Pourcentage =
        # progression dans la liste des steps.
        $pct = if ($stepsToRun.Count -gt 0) { [int](($idx / $stepsToRun.Count) * 100) } else { 0 }
        Send-DeployReport -Status 'running' -Step $stepId -Percent $pct -Message $stepName

        # APPEL DU HANDLER (dispatch) -> contrat standard
        $result = Invoke-StepHandler -Step $step -Context $Context

        # Lecture du contrat : proprietes TOUJOURS presentes (plus d'ambiguite)
        if (-not $result.Success) {
            Write-EngineLog "Step '$stepName' a ECHOUE : $($result.Message)" 'ERROR' $stepId
            # On continue quand meme aux steps suivants (tolerant), sauf si on
            # veut un arret dur -- ici on log et on poursuit.
        } else {
            $suffix = if ($result.Skipped) { ' (saute)' } else { '' }
            Write-EngineLog "Step '$stepName' termine$suffix : $($result.Message)" 'SUCCESS' $stepId
        }

        # Step termine sans reboot -> retirer le marqueur. Sinon le garder.
        if (-not $result.RebootRequired) {
            try { Remove-Item $marker -Force -EA SilentlyContinue } catch {}
        }

        # ----- DECISION REBOOT -----
        $rebootPolicy = "$(Get-StepProperty $step 'RebootAfter')"
        if (-not $rebootPolicy) { $rebootPolicy = 'IfRequired' }
        $needReboot = $false
        switch ($rebootPolicy) {
            'Always'     { $needReboot = -not $result.Skipped }  # saute = pas de reboot
            'IfRequired' { $needReboot = $result.RebootRequired }
            'Never'      { $needReboot = $false }
            default      { $needReboot = $result.RebootRequired }
        }

        if ($needReboot) {
            # Determiner le step suivant (par ID) ; StayOnStep -> rejouer le meme
            if ($result.StayOnStep) {
                $nextId = $stepId
            } elseif ($idx + 1 -lt $stepsToRun.Count) {
                $nextId = "$(Get-StepProperty $stepsToRun[$idx + 1] 'Id')"
            } else {
                $nextId = '__done__'
            }
            $rebootCount++
            Save-EngineState -State @{ nextStepId = $nextId; rebootCount = $rebootCount }
            Write-EngineLog "Reboot #$rebootCount -- reprise prevue au step '$nextId'" 'WARN'
            # L'autologon + la tache de reprise sont DEJA armes (deployment mode
            # active au demarrage). On reboote simplement.
            Send-DeployReport -Status 'rebooting' -Step $nextId -Message "Reboot avant $nextId"
            Write-EngineLog "=== REBOOT in 5 seconds ===" 'WARN'
            Start-Sleep -Seconds 5
            Restart-Computer -Force
            return @{ rebooting = $true }
        }
    }

    # ----- SEQUENCE TERMINEE -----
    Remove-EngineState
    foreach ($mk in @('.current-step', '.updates-passes')) {
        try { Remove-Item (Join-Path $Context.LogsDir $mk) -Force -EA SilentlyContinue } catch {}
    }
    Send-DeployReport -Status 'done' -Percent 100 -Message "Deployment complete: $($sequence.Name)"
    Write-EngineLog "==============================================" 'SUCCESS'
    Write-EngineLog "  DEPLOIEMENT TERMINE : '$($sequence.Name)'" 'SUCCESS'
    Write-EngineLog "==============================================" 'SUCCESS'
    return @{ done = $true }
}

Export-ModuleMember -Function @(
    'Invoke-Engine'
    'Get-EngineState'
    'Save-EngineState'
    'Remove-EngineState'
    'Invoke-StepHandler'
    'Write-EngineLog'
    'Get-LocalAdminName'
    'Enable-DeploymentMode'
    'Disable-DeploymentMode'
    'Test-DeploymentMode'
    'Write-DeployResetScript'
)
