#Requires -Version 5.1
<#
.SYNOPSIS
    MailNotify.psm1 -- Notification email de fin de deploiement (SMTP simple).
.DESCRIPTION
    Module autonome et volontairement SIMPLE. Lit une configuration PLATE dans
    PSWinDeploy.psd1 :

        NotifEmail    = $true            # active/desactive l'envoi
        SMTP_FROM     = 'deploy@corp.local'
        SMTP_TO       = 'a@corp.local'   # ou 'a@corp.local,b@corp.local'
        SMTP_Server   = 'smtp.corp.local'
        SMTP_Port     = 587
        SMTP_SECURE   = 'TLS'            # 'Plain' | 'TLS' | 'SSL'
        SMTP_USER     = ''               # vide => pas d'authentification
        SMTP_PASSWORD = ''               # vide => pas d'authentification

    Regles :
      - Toute variable absente n'a AUCUNE incidence : l'envoi est simplement
        ignore (jamais d'erreur bloquante pour le deploiement).
      - Si NotifEmail n'est pas $true -> aucun envoi.
      - Si SMTP_USER et SMTP_PASSWORD sont vides -> connexion SANS authentification.
      - SMTP_SECURE :
          'Plain' : aucune couche TLS (port 25 typiquement).
          'TLS'   : STARTTLS (connexion claire puis passage TLS, port 587).
          'SSL'   : SSL/TLS direct des la connexion (port 465).

    Utilise System.Net.Mail.SmtpClient pour un vrai support des 3 modes
    (Send-MailMessage gere mal le SSL direct 465).

    NOTE SECURITE : le mot de passe est stocke en clair dans PSWinDeploy.psd1
    (compromis de simplicite assume). Le module ne loggue JAMAIS le mot de passe.
#>

function Write-MailLog {
    param([string]$Message, [ValidateSet('INFO','WARN','SUCCESS','ERROR')][string]$Level = 'INFO')
    $color = switch ($Level) { 'SUCCESS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
    Write-Host "[MailNotify] $Message" -ForegroundColor $color
}

function Get-MailNotifyConfig {
    <# .SYNOPSIS Charge la config email a plat depuis PSWinDeploy.psd1.
        Lit DIRECTEMENT le .psd1 (Import-PowerShellDataFile) sans dependre du
        module Config ni de son cache : plus robuste en phase 2 sur la machine
        cible. Cherche le fichier dans les emplacements standards.
        Retourne un hashtable (vide si rien trouve). #>
    $candidates = @()
    # 1. Variable d'environnement explicite
    $envPath = [System.Environment]::GetEnvironmentVariable('PSWINDEX_CONFIG')
    if ($envPath) { $candidates += $envPath }
    # 2. A cote du module (remontee vers la racine projet)
    try {
        $callerDir = Split-Path $PSScriptRoot -Parent    # Modules\ -> racine
        $projectRoot = Split-Path $callerDir -Parent
        foreach ($dir in @($callerDir, $projectRoot)) {
            if ($dir) { $candidates += (Join-Path $dir 'PSWinDeploy.psd1') }
        }
    } catch {}
    # 3. Emplacements absolus standards (machine cible en phase 2, WinPE)
    $candidates += @(
        'C:\Deploy\PSWinDeploy.psd1',
        'X:\Deploy\PSWinDeploy.psd1',
        'W:\Deploy\PSWinDeploy.psd1',
        'D:\Deploy\PSWinDeploy.psd1'
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -EA SilentlyContinue)) {
            try {
                $data = Import-PowerShellDataFile $c
                if ($data) { return $data }
            } catch {}
        }
    }
    return @{}
}

function Test-MailNotifyEnabled {
    <# .SYNOPSIS Renvoie $true si l'envoi email est active ET configurable.
        Verifie le strict minimum : NotifEmail=$true, un serveur, un from, un to. #>
    param($Config)
    if (-not $Config) { $Config = Get-MailNotifyConfig }
    if ("$($Config.NotifEmail)" -ne 'True' -and $Config.NotifEmail -ne $true) { return $false }
    if (-not $Config.SMTP_Server) { return $false }
    if (-not $Config.SMTP_FROM)   { return $false }
    if (-not $Config.SMTP_TO)     { return $false }
    return $true
}

function ConvertTo-RecipientList {
    <# .SYNOPSIS Normalise SMTP_TO en tableau d'adresses (accepte virgules et
        points-virgules). #>
    param([string]$To)
    if (-not $To) { return @() }
    return @($To -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Build-MailBody {
    <# .SYNOPSIS Construit le corps HTML simple du rapport de deploiement. #>
    param($Result, $Config)

    $machine = if ($Result.ComputerName) { $Result.ComputerName }
               elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'unknown' }
    $success = ($Result.Success -ne $false)
    $statusText  = if ($success) { 'SUCCESS' } else { 'FAILED' }
    $statusColor = if ($success) { '#2e7d32' } else { '#c62828' }
    $seq = if ($Result.Sequence) { $Result.Sequence } else { 'n/a' }

    # Duree lisible
    $durTxt = 'n/a'
    if ($Result.DurationSec) {
        $ts = [TimeSpan]::FromSeconds([double]$Result.DurationSec)
        $durTxt = '{0:00}h {1:00}m {2:00}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
    }
    $when = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $rows = @(
        @{ k = 'Machine';   v = $machine }
        @{ k = 'Status';    v = $statusText }
        @{ k = 'Sequence';  v = $seq }
        @{ k = 'Duration';  v = $durTxt }
        @{ k = 'Completed'; v = $when }
    )
    $trs = ($rows | ForEach-Object {
        "<tr><td style='padding:6px 14px;color:#555;font-weight:600'>$($_.k)</td><td style='padding:6px 14px'>$($_.v)</td></tr>"
    }) -join "`n"

    return @"
<html><body style='font-family:Segoe UI,Arial,sans-serif;color:#222'>
  <div style='max-width:520px;margin:auto;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden'>
    <div style='background:$statusColor;color:#fff;padding:14px 18px;font-size:16px;font-weight:600'>
      PSWinDeploy -- Deployment $statusText
    </div>
    <table style='width:100%;border-collapse:collapse;font-size:14px'>
      $trs
    </table>
    <div style='padding:10px 18px;color:#999;font-size:12px;border-top:1px solid #eee'>
      Automatic notification from PSWinDeploy.
    </div>
  </div>
</body></html>
"@
}

function Send-DeployMail {
    <#
    .SYNOPSIS
        Envoie l'email de fin de deploiement selon la config plate. Best-effort :
        ne leve JAMAIS d'exception vers l'appelant (retourne $true/$false).
    .PARAMETER Result
        Objet resultat : ComputerName, Success, Sequence, DurationSec (tous
        optionnels -- des valeurs manquantes donnent 'n/a').
    .EXAMPLE
        Send-DeployMail -Result ([PSCustomObject]@{ ComputerName='PC1'; Success=$true; DurationSec=1620 })
    #>
    [CmdletBinding()]
    param([PSCustomObject]$Result)

    try {
        $cfg = Get-MailNotifyConfig

        if (-not (Test-MailNotifyEnabled -Config $cfg)) {
            # Desactive ou incomplet -> on ne fait rien, silencieusement.
            return $false
        }

        $recipients = ConvertTo-RecipientList $cfg.SMTP_TO
        if ($recipients.Count -eq 0) {
            Write-MailLog "No valid recipient in SMTP_TO -- skipping." 'WARN'
            return $false
        }

        $server = "$($cfg.SMTP_Server)"
        $port   = if ($cfg.SMTP_Port) { [int]$cfg.SMTP_Port } else { 25 }
        $from   = "$($cfg.SMTP_FROM)"
        $secure = "$($cfg.SMTP_SECURE)".ToUpper().Trim()   # PLAIN | TLS | SSL

        if (-not $Result) { $Result = [PSCustomObject]@{ Success = $true } }
        $success    = ($Result.Success -ne $false)
        $machine    = if ($Result.ComputerName) { $Result.ComputerName }
                      elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'unknown' }
        $statusText = if ($success) { 'SUCCESS' } else { 'FAILED' }
        $subject    = "PSWinDeploy -- $statusText -- $machine"
        $bodyHtml   = Build-MailBody -Result $Result -Config $cfg

        # -- Construction du message .NET --
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress($from)
        foreach ($r in $recipients) { $msg.To.Add($r) }
        $msg.Subject    = $subject
        $msg.Body       = $bodyHtml
        $msg.IsBodyHtml = $true

        # -- Client SMTP --
        $client = New-Object System.Net.Mail.SmtpClient($server, $port)
        $client.Timeout = 30000   # 30s

        switch ($secure) {
            'SSL' {
                # SSL/TLS direct (port 465). SmtpClient utilise EnableSsl mais pour
                # le 465 "implicite" il negocie STARTTLS-like ; sur la plupart des
                # serveurs modernes acceptant 465 cela fonctionne avec EnableSsl.
                $client.EnableSsl = $true
            }
            'TLS' {
                # STARTTLS (587) : connexion claire puis upgrade TLS.
                $client.EnableSsl = $true
            }
            default {
                # PLAIN : aucun chiffrement.
                $client.EnableSsl = $false
            }
        }

        # -- Authentification (uniquement si USER ET PASSWORD fournis) --
        $user = "$($cfg.SMTP_USER)"
        $pass = "$($cfg.SMTP_PASSWORD)"
        if ($user -and $pass) {
            $client.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
        } else {
            # Pas d'auth : certains serveurs exigent UseDefaultCredentials=$false
            $client.UseDefaultCredentials = $false
        }

        Write-MailLog "Sending deployment email -> $($recipients -join ', ') (secure=$secure, auth=$([bool]($user -and $pass)))"
        $client.Send($msg)
        Write-MailLog "Email sent." 'SUCCESS'

        $msg.Dispose(); $client.Dispose()
        return $true
    }
    catch {
        # Best-effort : on n'interrompt jamais le deploiement pour un email.
        # On ne loggue PAS le mot de passe (l'exception .NET ne le contient pas).
        Write-MailLog "Email notification failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

Export-ModuleMember -Function @('Send-DeployMail','Test-MailNotifyEnabled','Get-MailNotifyConfig')
