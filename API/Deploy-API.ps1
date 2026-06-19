<#
.SYNOPSIS
    Deploy-API.ps1 -- API REST PSWinDeploy via Pode
.DESCRIPTION
    Expose les fonctions de deploiement en endpoints HTTP/JSON.
    Lance sur le serveur Windows, consommable par le front Docker.
    Port : 8080 (HTTP) ou 8443 (HTTPS si cert fourni)
.EXAMPLE
    # Installation Pode (une seule fois)
    Install-Module -Name Pode -Scope CurrentUser -Force

    # Lancement
    pwsh -File Deploy-API.ps1
    # ou
    powershell -File Deploy-API.ps1
#>

param(
    [int]$Port      = 8080,
    [switch]$Https,
    [string]$CertPath,
    [string]$CertPassword
)

# Import Pode
if (-not (Get-Module -ListAvailable Pode -ErrorAction SilentlyContinue)) {
    Write-Host "Installation de Pode..." -ForegroundColor Yellow
    Install-Module Pode -Scope AllUsers -Force -AllowClobber
}
Import-Module Pode

# Racine du projet
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$ModulesRoot = Join-Path $ProjectRoot 'Modules'

function Import-DeployModule { param([string]$Name)
    $p = Join-Path $ModulesRoot "$Name\$Name.psm1"
    if (Test-Path $p) { Import-Module $p -Force -Global }
}

# -----------------------------------------------------------------------------
# Helper : sauvegarder une sequence en PSD1 (BOM, lu par WinPE)
function Save-DeploySequencePsd1 {
    param($Sequence, [string]$Path)
    function ConvertTo-Psd1 {
        param($Obj, [int]$Indent = 0)
        $sp = '    ' * $Indent; $sp1 = '    ' * ($Indent + 1)
        if ($null -eq $Obj) { return '$null' }
        if ($Obj -is [bool]) { return $(if ($Obj) { '$true' } else { '$false' }) }
        if ($Obj -is [int] -or $Obj -is [long] -or $Obj -is [double]) { return "$Obj" }
        if ($Obj -is [string]) { return "'$($Obj -replace ""'"",""''"")'" }
        if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
            $items = @($Obj | ForEach-Object { "$sp1$(ConvertTo-Psd1 $_ ($Indent+1))" })
            if ($items.Count -eq 0) { return '@()' }
            return "@(`n$($items -join "`n")`n$sp)"
        }
        if ($Obj -is [PSCustomObject] -or $Obj -is [hashtable]) {
            $props = if ($Obj -is [hashtable]) { $Obj.GetEnumerator() } else { $Obj.PSObject.Properties }
            $pairs = @($props | ForEach-Object { "$sp1$($_.Name) = $(ConvertTo-Psd1 $_.Value ($Indent+1))" })
            if ($pairs.Count -eq 0) { return '@{}' }
            return "@{`n$($pairs -join "`n")`n$sp}"
        }
        return "'$Obj'"
    }
    $content = ConvertTo-Psd1 $Sequence
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, $content, $utf8Bom)
}

# -----------------------------------------------------------------------------
Start-PodeServer -Threads 2 {

    # -- Transport --
    if ($using:Https -and $using:CertPath) {
        Add-PodeEndpoint -Address '*' -Port $using:Port -Protocol Https `
            -CertificateFile $using:CertPath -CertificatePassword $using:CertPassword
    } else {
        Add-PodeEndpoint -Address '*' -Port $using:Port -Protocol Http
    }

    # -- CORS (pour le front Docker) --
    Set-PodeCorsMiddleware -Origin '*' -Methods @('GET','POST','PUT','DELETE','OPTIONS')

    # -- Middleware JSON --
    Add-PodeMiddleware -Name 'JsonBody' -ScriptBlock {
        if ($WebEvent.Request.ContentType -like '*json*') {
            try {
                $raw = [System.IO.StreamReader]::new($WebEvent.Request.InputStream).ReadToEnd()
                $WebEvent.Data = $raw | ConvertFrom-Json
            } catch {}
        }
        return $true
    }

    # -- Logging --
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging

    # -- Import modules dans le contexte Pode --
    Import-DeployModule 'ProfileManager'
    Import-DeployModule 'WIM-Manager'
    Import-DeployModule 'TaskSequence'
    Import-DeployModule 'DiskSelector'

    # =======================================================
    # ROUTES PROFILS
    # =======================================================

    # GET /api/profiles -- liste tous les profils
    Add-PodeRoute -Method Get -Path '/api/profiles' -ScriptBlock {
        try {
            $profiles = Get-DeployProfile
            Write-PodeJsonResponse -Value @{ success = $true; data = $profiles }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/profiles/:id -- detail d'un profil
    Add-PodeRoute -Method Get -Path '/api/profiles/:id' -ScriptBlock {
        try {
            $profile = Get-DeployProfile -ProfileId $WebEvent.Parameters['id']
            Write-PodeJsonResponse -Value @{ success = $true; data = $profile }
        } catch {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES CATALOGUE
    # =======================================================

    # GET /api/catalogue -- liste le catalogue complet
    Add-PodeRoute -Method Get -Path '/api/catalogue' -ScriptBlock {
        try {
            $catalogue = Get-DeployCatalogue
            Write-PodeJsonResponse -Value @{ success = $true; data = $catalogue }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/catalogue/:category -- filtre par categorie
    Add-PodeRoute -Method Get -Path '/api/catalogue/:category' -ScriptBlock {
        try {
            $cat       = $WebEvent.Parameters['category']
            $catalogue = Get-DeployCatalogue | Where-Object { $cat -eq 'all' -or $_.category -eq $cat }
            Write-PodeJsonResponse -Value @{ success = $true; data = $catalogue }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES IMAGES WIM
    # =======================================================

    # GET /api/wim -- liste les WIM disponibles sur le partage
    Add-PodeRoute -Method Get -Path '/api/wim' -ScriptBlock {
        try {
            $cfg = Import-PowerShellDataFile "$using:ProjectRoot\PSWinDeploy.psd1"
            $sharePath = if ($cfg.ImageShare -is [hashtable]) { $cfg.ImageShare['DNS'] } else { $cfg.ImageShare }
            $wims = Get-ChildItem $sharePath -Filter '*.wim' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $info = Get-WIMInfo -WimPath $_.FullName
                        @{
                            fileName = $_.Name
                            path     = $_.FullName
                            sizeMB   = [Math]::Round($_.Length / 1MB, 0)
                            images   = $info
                        }
                    }
            Write-PodeJsonResponse -Value @{ success = $true; data = $wims }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES DEPLOIEMENT
    # =======================================================

    # POST /api/deploy/prepare -- resout profil + sequence, retourne la sequence finale
    Add-PodeRoute -Method Post -Path '/api/deploy/prepare' -ScriptBlock {
        try {
            $body         = $WebEvent.Data
            $profileId    = $body.profileId
            $selectedApps = $body.selectedApps   # array d'ids
            $machineName  = $body.machineName

            $profile      = Get-DeployProfile -ProfileId $profileId
            $sequence     = Resolve-ProfileSequence -Profile $profile `
                                -SelectedApps $selectedApps `
                                -MachineName $machineName

            # Sauvegarder la sequence runtime sur le partage (WinPE ira la lire)
            $cfg         = Import-PowerShellDataFile "$using:ProjectRoot\PSWinDeploy.psd1"
            $runtimeId   = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
            $runtimeDir  = if ($cfg.RuntimePath) { if ($cfg.RuntimePath -is [hashtable]) { $cfg.RuntimePath['DNS'] } else { $cfg.RuntimePath } } else { $ds = if ($cfg.DeployShare -is [hashtable]) { $cfg.DeployShare['DNS'] } else { $cfg.DeployShare }; "$ds\Runtime" }
            if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory $runtimeDir -Force | Out-Null }
            $runtimePath = Join-Path $runtimeDir "seq-$runtimeId.psd1"
            # Sauvegarder en PSD1 (BOM) -- lu par WinPE via Import-PowerShellDataFile
            Save-DeploySequencePsd1 -Sequence $sequence -Path $runtimePath

            Write-PodeJsonResponse -Value @{
                success      = $true
                runtimeId    = $runtimeId
                runtimePath  = $runtimePath
                sequenceName = $sequence.name
                stepCount    = @($sequence.steps).Count
                steps        = $sequence.steps | Select-Object id, name, type, enabled
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/deploy/status/:runtimeId -- etat d'un deploiement en cours
    Add-PodeRoute -Method Get -Path '/api/deploy/status/:runtimeId' -ScriptBlock {
        try {
            $cfg       = Import-PowerShellDataFile "$using:ProjectRoot\PSWinDeploy.psd1"
            $rid       = $WebEvent.Parameters['runtimeId']
            $runtimeDir = if ($cfg.RuntimePath) { if ($cfg.RuntimePath -is [hashtable]) { $cfg.RuntimePath['DNS'] } else { $cfg.RuntimePath } } else { $ds = if ($cfg.DeployShare -is [hashtable]) { $cfg.DeployShare['DNS'] } else { $cfg.DeployShare }; "$ds\Runtime" }
            $statePath = Join-Path $runtimeDir "state-$rid.psd1"

            if (Test-Path $statePath) {
                $state = Import-PowerShellDataFile $statePath
                Write-PodeJsonResponse -Value @{ success = $true; data = $state }
            } else {
                Write-PodeJsonResponse -Value @{ success = $true; data = $null; status = 'not_started' }
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/deploy/logs/:runtimeId -- dernieres lignes de log
    Add-PodeRoute -Method Get -Path '/api/deploy/logs/:runtimeId' -ScriptBlock {
        try {
            $cfg     = Import-PowerShellDataFile "$using:ProjectRoot\PSWinDeploy.psd1"
            $rid     = $WebEvent.Parameters['runtimeId']
            $logShare = if ($cfg.LogShare) { $cfg.LogShare } else { "\\$($cfg.WinPEShareServer)\Logs" }
            $logPath = Join-Path $logShare "deploy-$rid.log"
            $lines   = if (Test-Path $logPath) {
                           Get-Content $logPath -Tail 100
                       } else { @() }
            Write-PodeJsonResponse -Value @{ success = $true; lines = $lines }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES SEQUENCES
    # =======================================================

    # GET /api/sequences -- liste les sequences disponibles
    Add-PodeRoute -Method Get -Path '/api/sequences' -ScriptBlock {
        try {
            $seqPath = Join-Path $using:ProjectRoot 'Sequences'
            $seqs = Get-ChildItem $seqPath -Filter '*.psd1' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        try {
                            $s = Import-PowerShellDataFile $_.FullName
                            $sid  = if ($s.Id) { $s.Id } elseif ($s.id) { $s.id } else { $_.BaseName }
                            $snm  = if ($s.Name) { $s.Name } elseif ($s.name) { $s.name } else { $_.BaseName }
                            $sver = if ($s.Version) { $s.Version } elseif ($s.version) { $s.version } else { '1.0' }
                            $stp  = if ($s.Steps) { @($s.Steps).Count } elseif ($s.steps) { @($s.steps).Count } else { 0 }
                            @{ id = $sid; name = $snm; version = $sver; stepCount = $stp; path = $_.FullName }
                        } catch { $null }
                    } | Where-Object { $_ }
            Write-PodeJsonResponse -Value @{ success = $true; data = $seqs }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # HEALTHCHECK
    # =======================================================

    Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
        Write-PodeJsonResponse -Value @{
            status    = 'ok'
            version   = '0.6.9'
            timestamp = (Get-Date -Format 'o')
            host      = $env:COMPUTERNAME
        }
    }

    # =======================================================
    # ROUTE NOTIFICATIONS
    # =======================================================

    # POST /api/notify/test -- teste les canaux de notification configures
    Add-PodeRoute -Method Post -Path '/api/notify/test' -ScriptBlock {
        try {
            Import-Module "$using:ModulesRoot\Notify\Notify.psm1" -Force
            $channel = if ($WebEvent.Data.channel) { $WebEvent.Data.channel } else { 'All' }
            Test-NotifyConfig -Channel $channel
            Write-PodeJsonResponse -Value @{ success = $true; channel = $channel }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    Write-Host ""
    Write-Host "  PSWinDeploy API demarree sur le port $using:Port" -ForegroundColor Green
    Write-Host "  http://localhost:$using:Port/api/health" -ForegroundColor Cyan
    Write-Host ""
}

