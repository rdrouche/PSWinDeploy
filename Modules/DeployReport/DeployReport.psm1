#Requires -Version 5.1
<#
.SYNOPSIS
    DeployReport.psm1 -- Suivi de deploiement cote CLIENT (le poste qui se deploie).
.DESCRIPTION
    Module LEGER et autonome regroupant les fonctions de reporting du poste vers
    l'API web. Aucune dependance sur le moteur de sequences : on peut le charger
    seul (ex : en phase 1 WinPE) sans tirer tout TaskEngine.

    Fonctions :
      - Send-DeployReport    : envoie un heartbeat (etat d'avancement) a l'API.
      - Set-DeployApiEndpoint : depose sur le poste l'URL + le token de l'API
                                pour activer le suivi (lus par Send-DeployReport).

    Cote SERVEUR, c'est l'API (Write-DeployReport dans ApiLogic) qui RECOIT ces
    rapports -- ce module ne concerne que l'emission.
#>

# Log interne neutre (pas de dependance externe). Ecrit en console si possible.
function Write-DRLog {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        default { 'Gray' }
    }
    try { Write-Host "  [report] $Message" -ForegroundColor $color } catch {}
}

function Set-DeployApiEndpoint {
    <#
    .SYNOPSIS Depose sur le poste les coordonnees de l'API (URL + token) pour
        que le suivi puisse envoyer ses heartbeats.
    .DESCRIPTION
        Ecrit deux fichiers dans le dossier Runtime :
          <RuntimeDir>\api-url.txt    (l'URL de l'API, ex http://10.0.8.111:8080)
          <RuntimeDir>\api-token.txt  (le token API, si l'API est protegee)
        Send-DeployReport lit ces fichiers a chaque heartbeat lorsqu'aucune URL
        n'est passee en parametre. Si l'URL est vide, on n'ecrit rien (suivi
        desactive ; le deploiement fonctionne quand meme).
    .PARAMETER ApiUrl     URL de l'API Pode.
    .PARAMETER ApiToken   Token API (optionnel ; identique a apiToken cote serveur).
    .PARAMETER RuntimeDir Dossier Runtime local (defaut C:\Deploy\Runtime).
    #>
    param(
        [string]$ApiUrl,
        [string]$ApiToken = '',
        [string]$RuntimeDir = 'C:\Deploy\Runtime'
    )
    if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
        Write-DRLog "Pas d'URL d'API fournie : suivi des deploiements desactive." 'INFO'
        return
    }
    if (-not (Test-Path $RuntimeDir)) {
        New-Item -ItemType Directory $RuntimeDir -Force -EA SilentlyContinue | Out-Null
    }
    try {
        Set-Content -Path (Join-Path $RuntimeDir 'api-url.txt') -Value $ApiUrl.Trim() -Encoding UTF8 -NoNewline -EA Stop
        Write-DRLog "URL de l'API deposee pour le suivi : $ApiUrl" 'OK'
    } catch {
        Write-DRLog "Impossible d'ecrire api-url.txt : $($_.Exception.Message)" 'WARN'
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
        try {
            Set-Content -Path (Join-Path $RuntimeDir 'api-token.txt') -Value $ApiToken.Trim() -Encoding UTF8 -NoNewline -EA Stop
            Write-DRLog "Token API depose pour le suivi." 'OK'
        } catch {
            Write-DRLog "Impossible d'ecrire api-token.txt : $($_.Exception.Message)" 'WARN'
        }
    }
}

function Send-DeployReport {
    <#
    .SYNOPSIS Envoie un rapport d'avancement (heartbeat) a l'API web, si une URL
        d'API est configuree. Silencieux en cas d'echec (le deploiement continue
        meme si l'API est injoignable). Permet le suivi temps reel + historique
        dans l'interface web.
    .PARAMETER Status   'running' | 'rebooting' | 'done' | 'error'
    .PARAMETER Step     identifiant du step courant
    .PARAMETER Percent  avancement 0-100
    .PARAMETER Message  message court
    .PARAMETER ApiUrl   URL de base de l'API (ex http://10.0.8.111:8080). Si vide,
        on tente de la lire depuis <RuntimeDir>\api-url.txt.
    .PARAMETER RuntimeDir Dossier ou lire api-url.txt / api-token.txt (defaut
        C:\Deploy\Runtime). En phase 1 (WinPE), passer plutot -ApiUrl directement.
    #>
    param(
        [string]$Status = 'running',
        [string]$Step = '',
        [int]$Percent = 0,
        [string]$Message = '',
        [string]$ApiUrl = '',
        [string]$ApiToken = '',
        [string]$RuntimeDir = 'C:\Deploy\Runtime'
    )
    # Resoudre l'URL de l'API : parametre, sinon fichier depose au deploiement.
    if (-not $ApiUrl) {
        $urlFile = Join-Path $RuntimeDir 'api-url.txt'
        if (Test-Path $urlFile -EA SilentlyContinue) {
            try { $ApiUrl = (Get-Content $urlFile -Raw -EA SilentlyContinue).Trim() } catch {}
        }
    }
    if (-not $ApiUrl) { return }   # pas d'API configuree -> on ne fait rien

    try {
        $mac = ''
        # Detection MAC robuste : plusieurs methodes en fallback. Crucial car la
        # MAC sert d'identifiant stable du deploiement (P1 + P2). On prend la MAC
        # de l'adaptateur actif (celui qui a une IP), via la 1ere methode qui marche.
        try {
            # Methode 1 : adaptateur avec IP active (le plus fiable, y compris WinPE).
            $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
                   Where-Object { $_.IPEnabled -and $_.MACAddress } | Select-Object -First 1
            if ($cfg -and $cfg.MACAddress) { $mac = $cfg.MACAddress }
        } catch {}
        if (-not $mac) {
            try {
                # Methode 2 : adaptateur physique actif.
                $a = Get-CimInstance Win32_NetworkAdapter -EA SilentlyContinue |
                     Where-Object { $_.PhysicalAdapter -and $_.MACAddress -and $_.NetEnabled } |
                     Select-Object -First 1
                if ($a -and $a.MACAddress) { $mac = $a.MACAddress }
            } catch {}
        }
        if (-not $mac) {
            try {
                # Methode 3 : Get-NetAdapter (adaptateur Up).
                $na = Get-NetAdapter -EA SilentlyContinue |
                      Where-Object { $_.Status -eq 'Up' -and $_.MacAddress } | Select-Object -First 1
                if ($na -and $na.MacAddress) { $mac = $na.MacAddress }
            } catch {}
        }
        # Normaliser : majuscules, sans separateur (AABBCCDDEEFF).
        if ($mac) { $mac = ($mac -replace '[:-]', '').ToUpper() }

        $body = @{
            computerName = $env:COMPUTERNAME
            mac          = $mac
            status       = $Status
            step         = $Step
            percent      = $Percent
            message      = $Message
            timestamp    = (Get-Date -Format 'o')
        } | ConvertTo-Json -Compress

        $uri = "$($ApiUrl.TrimEnd('/'))/api/deploy/report"

        # Si l'API est en HTTPS avec un cert auto-signe (objectif : chiffrer le
        # trafic), on accepte le certificat sans validation stricte. PS 5.1 :
        # callback global. Best effort, sans casser si deja defini.
        if ($uri -like 'https:*') {
            try {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            } catch {}
        }

        # Token d'API (si l'API est securisee) : priorite au parametre -ApiToken
        # (utile en phase 1 WinPE ou api-token.txt n'existe pas encore), sinon
        # lu depuis le fichier depose au deploiement. Envoye dans X-Deploy-Token.
        $headers = @{}
        $tok = $ApiToken
        if (-not $tok) {
            $tokFile = Join-Path $RuntimeDir 'api-token.txt'
            if (Test-Path $tokFile -EA SilentlyContinue) {
                try { $tok = (Get-Content $tokFile -Raw -EA SilentlyContinue).Trim() } catch {}
            }
        }
        if ($tok) { $headers['X-Deploy-Token'] = "$tok".Trim() }

        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -Headers $headers -TimeoutSec 5 -EA SilentlyContinue | Out-Null
    } catch {
        # Silencieux : l'API peut etre injoignable, le deploiement continue.
    }
}

Export-ModuleMember -Function @(
    'Send-DeployReport'
    'Set-DeployApiEndpoint'
)
