#Requires -Version 5.1
<#
.SYNOPSIS
    Notify.psm1 -- Notifications de deploiement (Mail SMTP + Microsoft Teams)
.DESCRIPTION
    Envoie des notifications structurees en fin de deploiement
    (succes, echec, reboot) via SMTP et/ou Teams Webhooks.
    S'integre avec TaskSequence.psm1 via des hooks configurables.
    Lit sa config depuis PSWinDeploy.psd1 (section Notifications).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CONFIG & LOGGING
# -----------------------------------------------------------------------------

function Write-NLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{INFO='Cyan';WARN='Yellow';ERROR='Red';SUCCESS='Green';STEP='Magenta'}
    $icons  = @{INFO='[~]';WARN='[!]';ERROR='[X]';SUCCESS='[OK]';STEP='[>>]'}
    Write-Host "$ts $($icons[$Level]) [Notify] $Msg" -ForegroundColor $colors[$Level]
}

function Get-NotifyConfig {
    <#Charge la config notif depuis PSWinDeploy.psd1 ou retourne les defaults#>
    try {
        $modPath = Join-Path $PSScriptRoot '..\Config\Config.psm1'
        if (Test-Path $modPath) {
            Import-Module $modPath -Force -ErrorAction SilentlyContinue
            $cfg = Get-PSWinDeployConfig -ErrorAction SilentlyContinue
            if ($cfg -and $cfg.Notifications) { return $cfg.Notifications }
        }
    } catch {}
    return @{}
}

# -----------------------------------------------------------------------------
# CONSTRUCTION DES MESSAGES
# -----------------------------------------------------------------------------

function Build-DeployMessage {
    <#
    .SYNOPSIS Construit le contenu du message a partir du resultat de deploiement.
    .PARAMETER Result  PSCustomObject retourne par Invoke-TaskSequence
    .PARAMETER Profile PSCustomObject profil utilise
    .PARAMETER Format  Plain | Html | TeamsCard
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,
        [PSCustomObject]$Profile,
        [ValidateSet('Plain','Html','TeamsCard')]
        [string]$Format = 'Plain'
    )

    $isSuccess   = $Result.Success -ne $false
    $machine     = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'INCONNU' }
    $profileName = if ($Profile) { $Profile.name } else { 'Sequence directe' }
    $duration    = if ($Result.Duration) { "$([Math]::Round($Result.Duration.TotalMinutes,1)) min" } else { 'N/A' }
    $reboots     = if ($Result.rebootCount) { $Result.rebootCount } else { 0 }
    $timestamp   = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
    $stepsDone   = if ($Result.completedSteps) { $Result.completedSteps.Count } else { 0 }
    $statusEmoji = if ($isSuccess) { '?' } else { '?' }
    $statusText  = if ($isSuccess) { 'Succes' } else { 'Echec' }
    $errorMsg    = if (-not $isSuccess -and $Result.lastError) { $Result.lastError } else { '' }

    switch ($Format) {

        'Plain' {
            $lines = @(
                "PSWinDeploy -- Deploiement $statusText"
                "==================================="
                "Machine   : $machine"
                "Profil    : $profileName"
                "Statut    : $statusText"
                "Duree     : $duration"
                "Steps     : $stepsDone completes"
                "Reboots   : $reboots"
                "Date      : $timestamp"
            )
            if ($errorMsg) { $lines += "Erreur    : $errorMsg" }
            return $lines -join "`n"
        }

        'Html' {
            $statusColor = if ($isSuccess) { '#059669' } else { '#dc2626' }
            $statusBg    = if ($isSuccess) { '#ecfdf5' } else { '#fee2e2' }
            $errorBlock  = if ($errorMsg) {
                "<tr><td style='padding:6px 12px;color:#6b7280;font-size:13px'>Erreur</td><td style='padding:6px 12px;color:#dc2626;font-size:13px;font-family:monospace'>$errorMsg</td></tr>"
            } else { '' }

            return @"
<!DOCTYPE html>
<html>
<head><meta charset='utf-8'></head>
<body style='font-family:Segoe UI,Arial,sans-serif;background:#f1f5f9;margin:0;padding:20px'>
<div style='max-width:520px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #e5e7eb'>
  <div style='background:$statusColor;padding:20px 24px;display:flex;align-items:center;gap:12px'>
    <span style='font-size:28px'>$statusEmoji</span>
    <div>
      <div style='color:#fff;font-size:18px;font-weight:600'>Deploiement $statusText</div>
      <div style='color:$($statusBg)99;font-size:13px'>$machine -- $timestamp</div>
    </div>
  </div>
  <div style='padding:20px 24px'>
    <table style='width:100%;border-collapse:collapse'>
      <tr style='background:#f8fafc'><td style='padding:8px 12px;color:#6b7280;font-size:13px;width:35%'>Machine</td><td style='padding:8px 12px;font-weight:600;font-size:14px'>$machine</td></tr>
      <tr><td style='padding:6px 12px;color:#6b7280;font-size:13px'>Profil</td><td style='padding:6px 12px;font-size:13px'>$profileName</td></tr>
      <tr style='background:#f8fafc'><td style='padding:6px 12px;color:#6b7280;font-size:13px'>Duree</td><td style='padding:6px 12px;font-size:13px'>$duration</td></tr>
      <tr><td style='padding:6px 12px;color:#6b7280;font-size:13px'>Steps completes</td><td style='padding:6px 12px;font-size:13px'>$stepsDone</td></tr>
      <tr style='background:#f8fafc'><td style='padding:6px 12px;color:#6b7280;font-size:13px'>Reboots</td><td style='padding:6px 12px;font-size:13px'>$reboots</td></tr>
      $errorBlock
    </table>
  </div>
  <div style='padding:12px 24px 20px;border-top:1px solid #f1f5f9;font-size:12px;color:#9ca3af'>
    PSWinDeploy v0.5 -- Deploiement Windows automatise
  </div>
</div>
</body>
</html>
"@
        }

        'TeamsCard' {
            # Adaptive Card JSON pour Teams Incoming Webhook
            $color     = if ($isSuccess) { 'Good' } else { 'Attention' }
            $factsList = @(
                @{ title = "Machine";    value = $machine }
                @{ title = "Profile";     value = $profileName }
                @{ title = "Duree";      value = $duration }
                @{ title = "Steps";      value = "$stepsDone completes" }
                @{ title = "Reboots";    value = "$reboots" }
                @{ title = "Date";       value = $timestamp }
            )
            if ($errorMsg) { $factsList += @{ title = "Error"; value = $errorMsg } }

            $card = [PSCustomObject]@{
                '@type'      = 'MessageCard'
                '@context'   = 'http://schema.org/extensions'
                themeColor   = if ($isSuccess) { '0ea5e9' } else { 'ef4444' }
                summary      = "Deploiement $statusText -- $machine"
                sections     = @(
                    [PSCustomObject]@{
                        activityTitle    = "$statusEmoji Deploiement $statusText -- $machine"
                        activitySubtitle = "Profil : $profileName"
                        activityImage    = "https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/assets/Desktop%20computer/3D/desktop_computer_3d.png"
                        facts            = $factsList
                        markdown         = $true
                    }
                )
            }
            return $card | ConvertTo-Json -Depth 10
        }
    }
}

# -----------------------------------------------------------------------------
# ENVOI SMTP
# -----------------------------------------------------------------------------

function Send-DeployMailNotification {
    <#
    .SYNOPSIS Envoie une notification par email (SMTP).
    .DESCRIPTION
        Supporte SMTP avec ou sans authentification, TLS optionnel.
        Les credentials sont lus depuis le vault PSWinDeploy si non fournis.
    .PARAMETER Result     Resultat du deploiement (PSCustomObject).
    .PARAMETER Profile    Profil utilise.
    .PARAMETER To         Destinataire(s) -- tableau d'adresses.
    .PARAMETER From       Expediteur.
    .PARAMETER SmtpServer Serveur SMTP.
    .PARAMETER SmtpPort   Port SMTP (defaut: 587).
    .PARAMETER UseTls     Utilise STARTTLS (defaut: $true).
    .PARAMETER Credential PSCredential pour l'auth SMTP. Si absent, tente le vault.
    .EXAMPLE
        Send-DeployMailNotification -Result $deployResult -Profile $profil `
            -To 'it@corp.local' -SmtpServer 'smtp.corp.local'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,
        [PSCustomObject]$Profile,
        [Parameter(Mandatory)]
        [string[]]$To,
        [string]$From       = 'pswindex@corp.local',
        [string]$SmtpServer,
        [int]$SmtpPort      = 587,
        [bool]$UseTls       = $true,
        [PSCredential]$Credential,
        [string]$Subject
    )

    # Config depuis PSWinDeploy.psd1 si parametres absents
    $cfg = Get-NotifyConfig
    if (-not $SmtpServer) { $SmtpServer = $cfg.SmtpServer }
    if (-not $SmtpServer) { throw "SmtpServer non configure -- definir Notifications.SmtpServer dans PSWinDeploy.psd1" }

    $isSuccess  = $Result.Success -ne $false
    $machine    = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'MACHINE' }
    $statusText = if ($isSuccess) { 'Succes ?' } else { 'Echec ?' }

    if (-not $Subject) {
        $Subject = "PSWinDeploy -- $statusText -- $machine"
    }

    $htmlBody = Build-DeployMessage -Result $Result -Profile $Profile -Format Html

    Write-NLog "Envoi email -> $($To -join ', ')" -Level INFO

    $mailParams = @{
        To         = $To
        From       = $From
        Subject    = $Subject
        Body       = $htmlBody
        BodyAsHtml = $true
        SmtpServer = $SmtpServer
        Port       = $SmtpPort
        UseSsl     = $UseTls
    }

    # Auth SMTP
    if ($Credential) {
        $mailParams.Credential = $Credential
    } elseif ($cfg.SmtpUser) {
        try {
            $smtpPwd = Get-Secret -Source vault -Key $(if ($cfg.SmtpPasswordKey) { $cfg.SmtpPasswordKey } else { 'smtpPassword' }) -ErrorAction SilentlyContinue
            if ($smtpPwd) {
                $mailParams.Credential = New-Object PSCredential($cfg.SmtpUser, (ConvertTo-SecureString $smtpPwd -AsPlainText -Force))
            }
        } catch { Write-NLog "Cannot load the SMTP credential from the vault" -Level WARN }
    }

    try {
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-NLog "Email envoye avec succes" -Level SUCCESS
    } catch {
        Write-NLog "Echec envoi email : $_" -Level ERROR
        throw
    }
}

# -----------------------------------------------------------------------------
# ENVOI TEAMS WEBHOOK
# -----------------------------------------------------------------------------

function Send-DeployTeamsNotification {
    <#
    .SYNOPSIS Envoie une notification via Microsoft Teams Incoming Webhook.
    .DESCRIPTION
        Poste une Adaptive Card dans un canal Teams via webhook URL.
        Supporte les webhooks O365 Connector (MessageCard) et Power Automate.
        L'URL du webhook peut etre stockee dans le vault (cle 'teamsWebhook').
    .PARAMETER Result      Resultat du deploiement.
    .PARAMETER Profile     Profil utilise.
    .PARAMETER WebhookUrl  URL du webhook Teams. Si absent, lue depuis vault/config.
    .EXAMPLE
        Send-DeployTeamsNotification -Result $r -Profile $p `
            -WebhookUrl 'https://outlook.office.com/webhook/xxx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,
        [PSCustomObject]$Profile,
        [string]$WebhookUrl
    )

    # Resolution URL webhook
    if (-not $WebhookUrl) {
        $cfg = Get-NotifyConfig
        if ($cfg.TeamsWebhookKey) {
            try {
                $WebhookUrl = Get-Secret -Source vault -Key $cfg.TeamsWebhookKey -ErrorAction SilentlyContinue
            } catch {}
        }
        if (-not $WebhookUrl -and $cfg.TeamsWebhookUrl) {
            $WebhookUrl = $cfg.TeamsWebhookUrl
        }
    }

    if (-not $WebhookUrl) {
        throw "WebhookUrl Teams non configuree -- definir dans PSWinDeploy.psd1 (Notifications.TeamsWebhookUrl) ou vault (teamsWebhook)"
    }

    $cardJson = Build-DeployMessage -Result $Result -Profile $Profile -Format TeamsCard
    Write-NLog "Envoi notification Teams..." -Level INFO

    try {
        $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post `
            -ContentType 'application/json' -Body $cardJson -ErrorAction Stop

        if ($response -eq 1 -or $response -eq 'OK' -or $null -eq $response) {
            Write-NLog "Notification Teams envoyee" -Level SUCCESS
        } else {
            Write-NLog "Reponse Teams inattendue : $response" -Level WARN
        }
    } catch {
        Write-NLog "Echec notification Teams : $_" -Level ERROR
        throw
    }
}

# -----------------------------------------------------------------------------
# FONCTION PRINCIPALE -- TOUS CANAUX
# -----------------------------------------------------------------------------

function Send-DeployNotification {
    <#
    .SYNOPSIS
        Envoie les notifications sur tous les canaux configures.
    .DESCRIPTION
        Point d'entree unique appele par TaskSequence.psm1 en fin de sequence
        (succes ou echec). Determine automatiquement les canaux actifs
        depuis PSWinDeploy.psd1 section Notifications.
        Chaque canal echoue silencieusement (continueOnError implicite)
        pour ne pas bloquer la fin de deploiement.
    .PARAMETER Result       Resultat complet du deploiement.
    .PARAMETER Profile      Profil de deploiement utilise.
    .PARAMETER Force        Envoie meme si le deploiement est en cours (pas termine).
    .PARAMETER SkipOnSuccess Pas de notification si succes (seulement les echecs).
    .PARAMETER SkipOnFailure Pas de notification si echec.
    .EXAMPLE
        # Appele automatiquement en fin de Invoke-TaskSequence
        Send-DeployNotification -Result $sequenceResult -Profile $profil
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,
        [PSCustomObject]$Profile,
        [switch]$Force,
        [switch]$SkipOnSuccess,
        [switch]$SkipOnFailure
    )

    $isSuccess = $Result.Success -ne $false

    if ($SkipOnSuccess -and $isSuccess)  { Write-NLog "Notification ignoree (succes)" -Level INFO; return }
    if ($SkipOnFailure -and -not $isSuccess) { Write-NLog "Notification ignoree (echec)" -Level INFO; return }

    $cfg     = Get-NotifyConfig
    $sent    = 0
    $failed  = 0

    Write-NLog "=== Envoi des notifications ===" -Level STEP

    # -- Email --
    $mailCfg = if ($cfg.Mail) { $cfg.Mail } else { $cfg.Email }
    if ($mailCfg -and $mailCfg.Enabled -ne $false -and $mailCfg.SmtpServer) {
        try {
            $toList = if ($mailCfg.To -is [array]) { $mailCfg.To } else { @($mailCfg.To) }
            if (-not $isSuccess -and $mailCfg.ToOnError) {
                $toList = @($toList) + @($mailCfg.ToOnError) | Select-Object -Unique
            }
            Send-DeployMailNotification -Result $Result -Profile $Profile `
                -To $toList -From $(if ($mailCfg.From) { $mailCfg.From } else { 'pswindex@corp.local' }) `
                -SmtpServer $mailCfg.SmtpServer -SmtpPort $(if ($mailCfg.Port) { $mailCfg.Port } else { 587 }) `
                -UseTls $(if ($null -ne $mailCfg.UseTls) { $mailCfg.UseTls } else { $true })
            $sent++
        } catch { Write-NLog "Email : $_" -Level WARN; $failed++ }
    }

    # -- Teams --
    $teamsCfg = $cfg.Teams
    if ($teamsCfg -and $teamsCfg.Enabled -ne $false) {
        try {
            $webhookUrl = $teamsCfg.WebhookUrl
            if (-not $webhookUrl -and $teamsCfg.WebhookKey) {
                $webhookUrl = Get-Secret -Source vault -Key $teamsCfg.WebhookKey -ErrorAction SilentlyContinue
            }
            if ($webhookUrl) {
                Send-DeployTeamsNotification -Result $Result -Profile $Profile -WebhookUrl $webhookUrl
                $sent++
            }
        } catch { Write-NLog "Teams : $_" -Level WARN; $failed++ }
    }

    # -- Webhook generique (Slack, autre) --
    $webhookCfg = $cfg.Webhook
    if ($webhookCfg -and $webhookCfg.Enabled -ne $false -and $webhookCfg.Url) {
        try {
            $payload = Build-DeployMessage -Result $Result -Profile $Profile -Format Plain
            $body    = @{ text = $payload } | ConvertTo-Json
            Invoke-RestMethod -Uri $webhookCfg.Url -Method Post -ContentType 'application/json' -Body $body | Out-Null
            Write-NLog "Webhook generique envoye : $($webhookCfg.Url)" -Level SUCCESS
            $sent++
        } catch { Write-NLog "Webhook : $_" -Level WARN; $failed++ }
    }

    if ($sent -eq 0 -and $failed -eq 0) {
        Write-NLog "No notification channel configured -- skip" -Level WARN
        Write-NLog "Configurer Notifications.Mail / Notifications.Teams dans PSWinDeploy.psd1" -Level INFO
    } else {
        Write-NLog "$sent canal(aux) notifie(s), $failed echec(s)" -Level $(if ($failed -eq 0) {'SUCCESS'} else {'WARN'})
    }
}

# -----------------------------------------------------------------------------
# TEST DE CONFIGURATION
# -----------------------------------------------------------------------------

function Test-NotifyConfig {
    <#
    .SYNOPSIS Teste la configuration de notification en envoyant un message de test.
    .EXAMPLE
        Test-NotifyConfig
        Test-NotifyConfig -Channel Teams
        Test-NotifyConfig -Channel Mail
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('All','Mail','Teams','Webhook')]
        [string]$Channel = 'All'
    )

    Write-NLog "Test de notification ($Channel)..." -Level STEP

    $testResult = [PSCustomObject]@{
        Success        = $true
        Duration       = [TimeSpan]::FromMinutes(1.5)
        completedSteps = @('test-step-01','test-step-02')
        rebootCount    = 0
        sequenceId     = 'test'
        startedAt      = (Get-Date).AddMinutes(-1.5) | Get-Date -Format 'o'
    }
    $testProfile = [PSCustomObject]@{
        name = 'TEST -- Message de verification PSWinDeploy'
    }

    switch ($Channel) {
        'Mail'    { Send-DeployMailNotification -Result $testResult -Profile $testProfile }
        'Teams'   { Send-DeployTeamsNotification -Result $testResult -Profile $testProfile }
        'Webhook' {
            $cfg = Get-NotifyConfig
            if ($cfg.Webhook -and $cfg.Webhook.Url) {
                $body = @{ text = Build-DeployMessage -Result $testResult -Profile $testProfile -Format Plain } | ConvertTo-Json
                Invoke-RestMethod -Uri $cfg.Webhook.Url -Method Post -ContentType 'application/json' -Body $body | Out-Null
                Write-NLog "Webhook test envoye" -Level SUCCESS
            }
        }
        'All'     { Send-DeployNotification -Result $testResult -Profile $testProfile -Force }
    }
}

Export-ModuleMember -Function @(
    'Send-DeployNotification'
    'Send-DeployMailNotification'
    'Send-DeployTeamsNotification'
    'Build-DeployMessage'
    'Test-NotifyConfig'
)
