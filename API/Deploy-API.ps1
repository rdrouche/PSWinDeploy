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
# Pode 2.13.4 : on NE peut PAS utiliser $using: dans le corps de Start-PodeServer
# (rejete par Invoke-PodeScriptBlock), et Start-PodeServer n'a PAS -ArgumentList.
# On passe donc les valeurs via des variables GLOBALES (lues dans le corps du
# bloc, qui s'execute dans le runspace courant), puis on les stocke dans le
# State Pode (Set-PodeState) pour que les routes (autres runspaces) les lisent
# avec Get-PodeState.
$global:PSWD_Port         = $Port
$global:PSWD_Https        = [bool]$Https
$global:PSWD_CertPath     = $CertPath
$global:PSWD_CertPassword = $CertPassword
$global:PSWD_ProjectRoot  = $ProjectRoot
$global:PSWD_ModulesRoot  = $ModulesRoot

Start-PodeServer -Threads 2 {

    # Recuperer les valeurs globales (definies avant le demarrage du serveur).
    $Port         = $global:PSWD_Port
    $Https        = $global:PSWD_Https
    $CertPath     = $global:PSWD_CertPath
    $CertPassword = $global:PSWD_CertPassword
    $ProjectRoot  = $global:PSWD_ProjectRoot
    $ModulesRoot  = $global:PSWD_ModulesRoot

    # Stocker dans le State Pode (partage entre tous les runspaces de routes).
    Set-PodeState -Name 'ProjectRoot' -Value $ProjectRoot | Out-Null
    Set-PodeState -Name 'ModulesRoot' -Value $ModulesRoot | Out-Null
    Set-PodeState -Name 'Port'        -Value $Port        | Out-Null

    # Charger l'apiToken : variable d'environnement PSWD_API_TOKEN en priorite
    # (recommande -- secrets hors fichier), repli sur la config .psd1 (dev).
    $apiToken = "$env:PSWD_API_TOKEN"
    if ([string]::IsNullOrWhiteSpace($apiToken)) {
        try {
            $cfgTok = Import-PowerShellDataFile (Join-Path $ProjectRoot 'PSWinDeploy.psd1')
            if ($cfgTok.ContainsKey('apiToken')) { $apiToken = "$($cfgTok.apiToken)" }
        } catch {}
    }
    Set-PodeState -Name 'ApiToken' -Value $apiToken | Out-Null
    if ($apiToken) {
        Write-Host "  Securite API : token requis pour les modifications (POST/PUT/DELETE)." -ForegroundColor Yellow
    } else {
        Write-Host "  Securite API : acces libre (aucun apiToken configure)." -ForegroundColor DarkGray
    }

    # -- Transport --
    if ($Https -and $CertPath) {
        Add-PodeEndpoint -Address '*' -Port $Port -Protocol Https `
            -CertificateFile $CertPath -CertificatePassword $CertPassword
    } else {
        Add-PodeEndpoint -Address '*' -Port $Port -Protocol Http
    }

    # -- CORS (pour le front Docker) -- middleware manuel (compatible toutes
    # versions de Pode : ajoute les en-tetes Access-Control-* sur chaque reponse).
    Add-PodeMiddleware -Name 'Cors' -ScriptBlock {
        Add-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Add-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, PUT, DELETE, OPTIONS'
        Add-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization, X-Deploy-Token'
        return $true
    }
    # Repondre OK aux requetes preflight OPTIONS (sinon le navigateur bloque).
    Add-PodeRoute -Method Options -Path '*' -ScriptBlock {
        Set-PodeResponseStatus -Code 200
    }

    # -- Middleware AUTH : protege les methodes qui MODIFIENT des donnees --
    # Regle : si un apiToken est configure, toute requete POST/PUT/DELETE/PATCH
    # doit fournir ce token (en-tete 'X-Deploy-Token' ou 'Authorization: Bearer').
    # Les GET (lecture) et OPTIONS (preflight) passent toujours. Si aucun token
    # n'est configure, tout passe (acces libre).
    Add-PodeMiddleware -Name 'AuthGuard' -ScriptBlock {
        $method = "$($WebEvent.Method)".ToUpper()
        # Methodes en lecture seule : toujours autorisees.
        if ($method -in @('GET','OPTIONS','HEAD')) { return $true }

        $token = Get-PodeState -Name 'ApiToken'
        # Pas de token configure -> acces libre (rien a verifier).
        if ([string]::IsNullOrWhiteSpace($token)) { return $true }

        # Recuperer le token fourni : en-tete X-Deploy-Token en priorite,
        # sinon Authorization: Bearer <token>.
        $provided = ''
        $hdrTok = Get-PodeHeader -Name 'X-Deploy-Token'
        if ($hdrTok) { $provided = "$hdrTok" }
        if (-not $provided) {
            $auth = Get-PodeHeader -Name 'Authorization'
            if ($auth -and "$auth" -like 'Bearer *') { $provided = ("$auth" -replace '^Bearer\s+', '') }
        }

        if ($provided -eq $token) { return $true }

        # Token absent ou invalide -> 401, on stoppe la requete.
        Set-PodeResponseStatus -Code 401
        Write-PodeJsonResponse -Value @{ success = $false; error = 'Token requis ou invalide pour cette operation.' }
        return $false
    }

    # NB : pas de middleware JSON custom -- Pode parse automatiquement le body
    # JSON dans $WebEvent.Data quand le Content-Type est application/json. Un
    # middleware qui relit InputStream entrerait en conflit (stream deja lu).

    # -- Logging --
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging

    # -- Import modules dans le contexte Pode --
    Import-DeployModule 'ProfileManager'
    Import-DeployModule 'WIM-Manager'
    Import-DeployModule 'TaskSequence'
    Import-DeployModule 'DiskSelector'
    Import-DeployModule 'PsdJson'      # conversion PSD1<->JSON
    Import-DeployModule 'ApiLogic'     # logique metier API (alignee refonte)

    # -- Initialiser la logique API avec les chemins de la config --
    try {
        Initialize-ApiLogicFromProject -ProjectRoot $ProjectRoot
    } catch { Write-Host "Init ApiLogic : $_" -ForegroundColor Yellow }

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
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $catalogue = @(Get-AppCatalogue)
            # Diagnostic : chemin reellement lu + existence (aide au depannage).
            $path = Get-CataloguePath
            Write-PodeJsonResponse -Value @{
                success = $true
                data    = $catalogue
                path    = $path
                exists  = [bool](Test-Path $path -EA SilentlyContinue)
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/catalogue/:category -- filtre par categorie
    Add-PodeRoute -Method Get -Path '/api/catalogue/:category' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $cat       = $WebEvent.Parameters['category']
            $catalogue = @(Get-AppCatalogue) | Where-Object { $cat -eq 'all' -or "$($_.Category)" -eq $cat }
            Write-PodeJsonResponse -Value @{ success = $true; data = @($catalogue) }
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
            $cfg = Import-PowerShellDataFile "$(Get-PodeState -Name ProjectRoot)\PSWinDeploy.psd1"
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
            $cfg         = Import-PowerShellDataFile "$(Get-PodeState -Name ProjectRoot)\PSWinDeploy.psd1"
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
            $cfg       = Import-PowerShellDataFile "$(Get-PodeState -Name ProjectRoot)\PSWinDeploy.psd1"
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
            $cfg     = Import-PowerShellDataFile "$(Get-PodeState -Name ProjectRoot)\PSWinDeploy.psd1"
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
            $seqPath = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Sequences'
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
    # =======================================================
    # ROUTE AUTH (compte admin simple -- OIDC plus tard)
    # =======================================================
    # POST /api/auth/login  -- corps { user, password }
    # Si OK, renvoie l'apiToken (le front le stocke et l'envoie ensuite dans
    # X-Deploy-Token pour les modifications). Auth lecture seule = pas besoin.
    Add-PodeRoute -Method Post -Path '/api/auth/login' -ScriptBlock {
        try {
            # Secrets depuis l'ENVIRONNEMENT en priorite (PSWD_ADMIN_USER,
            # PSWD_ADMIN_PASSWORD), repli sur la config .psd1 pour le dev local.
            $adminUser = "$env:PSWD_ADMIN_USER"
            $adminPass = "$env:PSWD_ADMIN_PASSWORD"
            $apiToken  = Get-PodeState -Name 'ApiToken'
            if ([string]::IsNullOrWhiteSpace($adminUser)) {
                try {
                    $proot = Get-PodeState -Name 'ProjectRoot'
                    $cfg = Import-PowerShellDataFile (Join-Path $proot 'PSWinDeploy.psd1')
                    if ($cfg.ContainsKey('adminUser'))     { $adminUser = "$($cfg.adminUser)" }
                    if ($cfg.ContainsKey('adminPassword')) { $adminPass = "$($cfg.adminPassword)" }
                } catch {}
            }

            $u = "$($WebEvent.Data.user)"
            $p = "$($WebEvent.Data.password)"

            # Auth desactivee si aucun compte configure -> on laisse passer.
            if ([string]::IsNullOrWhiteSpace($adminUser)) {
                Write-PodeJsonResponse -Value @{ success = $true; token = $apiToken; authDisabled = $true }
                return
            }

            # Validation cote SERVEUR : le mot de passe ne transite jamais dans
            # le bundle JS du navigateur.
            if ($u -eq $adminUser -and $p -eq $adminPass) {
                Write-PodeJsonResponse -Value @{ success = $true; token = $apiToken; user = $u }
            } else {
                Set-PodeResponseStatus -Code 401
                Write-PodeJsonResponse -Value @{ success = $false; error = 'Identifiants invalides.' }
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES DRIVERS (listing des modeles)
    # =======================================================
    Add-PodeRoute -Method Get -Path '/api/drivers' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $drivers = Get-DriverModelList
            Write-PodeJsonResponse -Value @{ success = $true; data = $drivers }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/scripts -- liste les scripts .ps1 du partage Scripts (pour
    # l'editeur de sequence, type RunScript).
    Add-PodeRoute -Method Get -Path '/api/scripts' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $scripts = Get-ScriptList
            Write-PodeJsonResponse -Value @{ success = $true; data = $scripts }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES SEQUENCES by-name / by-mac (generation)
    # =======================================================
    # POST /api/sequences/by-name/:name  -- corps = sequence (JSON)
    Add-PodeRoute -Method Post -Path '/api/sequences/by-name/:name' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $name = $WebEvent.Parameters['name']
            # $WebEvent.Data est deja un objet PowerShell (parse par Pode) -> on
            # le convertit directement en hashtable (sans detour JSON fragile).
            $seq = ConvertTo-HashtableDeep $WebEvent.Data
            $path = Save-SequenceByName -ComputerName $name -Sequence $seq
            Write-PodeJsonResponse -Value @{ success = $true; path = $path }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # POST /api/sequences/by-mac/:mac  -- corps = sequence (JSON)
    Add-PodeRoute -Method Post -Path '/api/sequences/by-mac/:mac' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $mac = $WebEvent.Parameters['mac']
            $seq = ConvertTo-HashtableDeep $WebEvent.Data
            $path = Save-SequenceByMac -Mac $mac -Sequence $seq
            Write-PodeJsonResponse -Value @{ success = $true; path = $path }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # POST /api/sequences/template/:name  -- enregistre une sequence TEMPLATE
    # a la racine du dossier Sequences (reutilisable directement en P2).
    Add-PodeRoute -Method Post -Path '/api/sequences/template/:name' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $name = $WebEvent.Parameters['name']
            $seq = ConvertTo-HashtableDeep $WebEvent.Data
            $path = Save-SequenceTemplate -Name $name -Sequence $seq
            Write-PodeJsonResponse -Value @{ success = $true; path = $path }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/sequences/list  -- liste templates + by-name + by-mac
    Add-PodeRoute -Method Get -Path '/api/sequences/list' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $list = @(Get-SequenceList)
            Write-PodeJsonResponse -Value @{ success = $true; data = $list }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/sequences/content/:type/:name  -- contenu brut d'une sequence
    # (lecture seule). type = template | by-name | by-mac.
    Add-PodeRoute -Method Get -Path '/api/sequences/content/:type/:name' -ScriptBlock {
        $dbgLog = {
            param($m)
            try {
                $ld = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Logs'
                Add-Content -Path (Join-Path $ld 'api-debug.log') -Value "$(Get-Date -Format 'o') [content] $m" -EA SilentlyContinue
            } catch {}
        }
        try {
            & $dbgLog "ENTREE route"
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            & $dbgLog "apres Initialize"
            $type = $WebEvent.Parameters['type']
            $name = $WebEvent.Parameters['name']
            & $dbgLog "type=$type name=$name -> avant Get-SequenceContent"
            $content = Get-SequenceContent -Type $type -Name $name
            & $dbgLog "apres Get-SequenceContent (len=$($content.Length))"
            if ($null -eq $content) {
                Set-PodeResponseStatus -Code 404
                Write-PodeJsonResponse -Value @{ success = $false; error = 'Sequence introuvable.' }
            } else {
                Write-PodeJsonResponse -Value @{ success = $true; content = $content }
            }
            & $dbgLog "reponse envoyee"
        } catch {
            & $dbgLog "CATCH : $($_.ToString())"
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/sequences/object/:type/:name  -- sequence en OBJET (JSON), pour
    # la charger dans l'editeur (ex : decliner un template en by-name/by-mac).
    Add-PodeRoute -Method Get -Path '/api/sequences/object/:type/:name' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $type = $WebEvent.Parameters['type']
            $name = $WebEvent.Parameters['name']
            $obj = Get-SequenceObject -Type $type -Name $name
            if ($null -eq $obj) {
                Set-PodeResponseStatus -Code 404
                Write-PodeJsonResponse -Value @{ success = $false; error = 'Sequence introuvable.' }
            } else {
                Write-PodeJsonResponse -Value @{ success = $true; data = $obj }
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/scripts/content?path=...  -- contenu brut d'un script .ps1
    # (lecture seule). 'path' = chemin relatif au partage Scripts.
    Add-PodeRoute -Method Get -Path '/api/scripts/content' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $rel = "$($WebEvent.Query['path'])"
            # Log debug : voir le path recu et le chemin reconstruit.
            try {
                $ld = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Logs'
                $ss = Get-ScriptShareDebug
                Add-Content -Path (Join-Path $ld 'api-debug.log') -Value "$(Get-Date -Format 'o') [scripts/content] rel='$rel' scriptShare='$ss' joined='$(Join-Path $ss $rel)'" -EA SilentlyContinue
            } catch {}
            $content = Get-ScriptContent -RelativePath $rel
            if ($null -eq $content) {
                Set-PodeResponseStatus -Code 404
                Write-PodeJsonResponse -Value @{ success = $false; error = 'Script introuvable.' }
            } else {
                Write-PodeJsonResponse -Value @{ success = $true; content = $content }
            }
        } catch {
            try {
                $ld = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Logs'
                Add-Content -Path (Join-Path $ld 'api-debug.log') -Value "$(Get-Date -Format 'o') [scripts/content] CATCH : $($_.ToString())`r`n$($_.ScriptStackTrace)" -EA SilentlyContinue
            } catch {}
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES CATALOGUE (synchro JSON <-> PSD1)
    # =======================================================
    # PUT /api/catalogue  -- remplace le catalogue (corps = { apps: [...] })
    Add-PodeRoute -Method Put -Path '/api/catalogue' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')

            # Recuperer la liste d'apps de facon robuste (peut etre vide/null).
            $appsData = $null
            if ($WebEvent.Data) {
                if ($WebEvent.Data.PSObject.Properties['apps']) { $appsData = $WebEvent.Data.apps }
                elseif ($WebEvent.Data -is [hashtable] -and $WebEvent.Data.ContainsKey('apps')) { $appsData = $WebEvent.Data['apps'] }
            }
            # Normaliser en tableau (vide si null).
            $appsArr = @()
            if ($null -ne $appsData) { $appsArr = @($appsData) }

            # Convertir chaque app en hashtable (recursif) pour le PSD1.
            $apps = @()
            foreach ($a in $appsArr) { $apps += ConvertTo-HashtableDeep $a }

            $path = Save-AppCatalogue -Apps $apps
            Write-PodeJsonResponse -Value @{ success = $true; path = $path; count = $apps.Count }
        } catch {
            # Log fichier detaille pour diagnostic.
            try {
                $logDir = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Logs'
                if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir -Force -EA SilentlyContinue | Out-Null }
                $msg = "$(Get-Date -Format 'o') [PUT /api/catalogue] $($_.ToString())`r`n$($_.ScriptStackTrace)"
                Add-Content -Path (Join-Path $logDir 'api-errors.log') -Value $msg -EA SilentlyContinue
            } catch {}
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # POST /api/catalogue/app  -- AJOUTE ou MET A JOUR une seule app (fusion).
    # Corps = l'objet app (ex { "Name":"Firefox", "WingetId":"Mozilla.Firefox" }).
    # Ne remplace PAS tout le catalogue : ajoute si nouveau, remplace si Name existe.
    Add-PodeRoute -Method Post -Path '/api/catalogue/app' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $app = ConvertTo-HashtableDeep $WebEvent.Data
            if (-not ($app -is [hashtable])) { throw 'Corps invalide : objet app attendu.' }
            $res = Add-AppToCatalogue -App $app
            Write-PodeJsonResponse -Value @{ success = $true; path = $res.path; count = $res.count; updated = $res.updated }
        } catch {
            try {
                $logDir = Join-Path (Get-PodeState -Name 'ProjectRoot') 'Logs'
                if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir -Force -EA SilentlyContinue | Out-Null }
                Add-Content -Path (Join-Path $logDir 'api-errors.log') -Value "$(Get-Date -Format 'o') [POST /api/catalogue/app] $($_.ToString())" -EA SilentlyContinue
            } catch {}
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # DELETE /api/catalogue/app/:name  -- retire une app par son Name.
    Add-PodeRoute -Method Delete -Path '/api/catalogue/app/:name' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $name = $WebEvent.Parameters['name']
            $res = Remove-AppFromCatalogue -Name $name
            Write-PodeJsonResponse -Value @{ success = $true; path = $res.path; count = $res.count; removed = $res.removed }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # =======================================================
    # ROUTES SUIVI / HISTORIQUE des deploiements
    # =======================================================
    # POST /api/deploy/report  -- heartbeat envoye par un PC en cours de deploiement
    # Corps : { computerName, mac, status, step, percent, message }
    Add-PodeRoute -Method Post -Path '/api/deploy/report' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $report = @{}
            foreach ($p in $WebEvent.Data.PSObject.Properties) { $report[$p.Name] = $p.Value }
            $id = Write-DeployReport -Report $report
            Write-PodeJsonResponse -Value @{ success = $true; id = $id }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/deploy/current  -- liste des deploiements en cours (dernier etat)
    Add-PodeRoute -Method Get -Path '/api/deploy/current' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $list = @(Get-DeployCurrentList)
            Write-PodeJsonResponse -Value @{ success = $true; data = $list }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    # GET /api/deploy/history/:id  -- historique complet d'un PC
    Add-PodeRoute -Method Get -Path '/api/deploy/history/:id' -ScriptBlock {
        try {
            Initialize-ApiLogicFromProject -ProjectRoot (Get-PodeState -Name 'ProjectRoot')
            $id = $WebEvent.Parameters['id']
            $hist = Get-DeployHistory -Id $id
            Write-PodeJsonResponse -Value @{ success = $true; data = $hist }
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
            Import-Module "$(Get-PodeState -Name ModulesRoot)\Notify\Notify.psm1" -Force
            $channel = if ($WebEvent.Data.channel) { $WebEvent.Data.channel } else { 'All' }
            Test-NotifyConfig -Channel $channel
            Write-PodeJsonResponse -Value @{ success = $true; channel = $channel }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ success = $false; error = $_.ToString() }
        }
    }

    Write-Host ""
    Write-Host "  PSWinDeploy API demarree sur le port $Port" -ForegroundColor Green
    Write-Host "  http://localhost:$Port/api/health" -ForegroundColor Cyan
    Write-Host ""
}

