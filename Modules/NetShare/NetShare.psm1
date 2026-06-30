#Requires -Version 5.1
<#
.SYNOPSIS
    NetShare.psm1 -- Connexion aux partages reseau depuis WinPE
.DESCRIPTION
    Gere l'authentification et la connexion aux partages SMB de deploiement.
    Reproduit le comportement MDT (Bootstrap.ini) en supportant :

      Plain  -- Credentials en clair (comme MDT). Compte dedie lecture seule.
      Vault  -- Credentials chiffres dans X:\Deploy\secrets.vault (injecte dans ISO).
      Prompt -- Saisie interactive dans la console WinPE.
      Auto   -- Tente : vault -> variables d'env -> prompt.
      Env    -- Variables d'env PSWINDEX_SHARE_USER / PSWINDEX_SHARE_PASSWORD.

    Le compte svc-winpe n'a besoin que d'un acces lecture sur les partages de deploiement.
    Il peut etre local sur le serveur de fichiers ou compte de domaine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NSLogFile = 'X:\Deploy\Logs\netshare.log'

# Mapping nom DNS -> hote reellement utilise (IP si basculement)
# Permet de reecrire les chemins UNC dans TOUTE la suite du deploiement
$script:ShareHostMap = @{}

function Write-NSLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $icons  = @{ INFO='[~]'; WARN='[!]'; ERROR='[X]'; SUCCESS='[OK]'; STEP='[>>]' }
    $colors = @{ INFO='Cyan'; WARN='Yellow'; ERROR='Red'; SUCCESS='Green'; STEP='Magenta' }
    $line   = "$ts $($icons[$Level]) [NetShare] $Msg"
    Write-Host $line -ForegroundColor $colors[$Level]
    try { Add-Content -Path $script:NSLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# --- Resolution credentials ---------------------------------------------------

function Get-ShareCredentialFromVault {
    <#
    Lit les credentials depuis un vault.
    Formats supportes :
      - PSD1 simple (recommande) : @{ winpeUser='...'; winpePassword='...' }
      - JSON Plain               : { method:'Plain', data:'{...}' }
      - JSON AES                 : { method:'AES',   data:'chiffre' }
    Le format PSD1 est prefere : lisible, editable a la main, aucun wrapping.
    #>
    param([string]$VaultPath, [string]$VaultPassword)

    # Chercher le vault si chemin non specifie ou inexistant
    if (-not $VaultPath -or -not (Test-Path $VaultPath -ErrorAction SilentlyContinue)) {
        foreach ($candidate in @(
            'X:\Deploy\secrets.vault.psd1',
            'X:\Deploy\secrets.vault',
            'C:\Deploy\secrets.vault.psd1',
            'C:\Deploy\secrets.vault'
        )) {
            if (Test-Path $candidate -ErrorAction SilentlyContinue) {
                $VaultPath = $candidate
                Write-NSLog "Vault trouve : $VaultPath" -Level INFO
                break
            }
        }
    }
    if (-not (Test-Path $VaultPath -ErrorAction SilentlyContinue)) { throw "Vault introuvable : $VaultPath" }

    # Detecter le format : PSD1 ou JSON
    $ext = [System.IO.Path]::GetExtension($VaultPath).ToLower()
    $raw = Get-Content $VaultPath -Raw

    # Format PSD1 : commence par '@{' (apres BOM eventuel)
    $trimmed = $raw.TrimStart([char]0xFEFF, ' ', [char]13, [char]10)
    $isPsd1 = ($ext -eq '.psd1') -or $trimmed.StartsWith('@{')

    if ($isPsd1) {
        Write-NSLog "Vault PSD1 -- lecture directe" -Level INFO
        try {
            $data = Import-PowerShellDataFile $VaultPath -ErrorAction Stop
        } catch {
            # Fallback : Invoke-Expression si Import-PowerShellDataFile absent (WinPE minimal)
            $data = Invoke-Expression $raw
        }
        $u = if ($data.winpeUser)     { $data.winpeUser }
             elseif ($data.shareUser) { $data.shareUser }
             else { $null }
        $p = if ($data.winpePassword)     { $data.winpePassword }
             elseif ($data.sharePassword) { $data.sharePassword }
             else { $null }
    } else {
        # Format JSON (legacy)
        $vault = $raw | ConvertFrom-Json
        $json = switch ($vault.method) {
            'Plain' {
                Write-NSLog "Vault JSON Plain" -Level INFO
                $vault.data
            }
            'AES' {
                if (-not $VaultPassword) {
                    $VaultPassword = [System.Environment]::GetEnvironmentVariable('PSWINDEX_VAULT_PASSWORD')
                }
                if (-not $VaultPassword) {
                    $s = Read-Host "Mot de passe vault" -AsSecureString
                    $VaultPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
                }
                $key = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($VaultPassword))
                $vault.data | ConvertTo-SecureString -Key $key |
                    ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
            }
            'DPAPI' {
                $vault.data | ConvertTo-SecureString |
                    ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
            }
            default { throw "Methode vault inconnue : $($vault.method)" }
        }
        $s = $json | ConvertFrom-Json
        $u = if ($s.winpeUser)     { $s.winpeUser }     elseif ($s.shareUser)     { $s.shareUser }     else { $null }
        $p = if ($s.winpePassword) { $s.winpePassword } elseif ($s.sharePassword) { $s.sharePassword } else { $null }
    }

    if (-not $u -or -not $p) {
        throw "Cles winpeUser/winpePassword absentes du vault : $VaultPath"
    }
    Write-NSLog "Compte vault : $u" -Level INFO
    return @{ Username = $u; Password = $p }
}

function Resolve-ShareCredential {
    <#
    .SYNOPSIS Resout les credentials reseau WinPE selon le mode demande.
    .PARAMETER Mode        Plain | Vault | Prompt | Auto | Env
    .PARAMETER Username    Compte en clair (mode Plain)
    .PARAMETER Password    Mot de passe en clair (mode Plain)
    .PARAMETER VaultPath   Chemin du vault WinPE (defaut : X:\Deploy\secrets.vault)
    .PARAMETER VaultPassword Mot de passe AES du vault
    .OUTPUTS [hashtable] @{ Username; Password }
    .EXAMPLE
        # Mode Auto (vault -> env -> prompt)
        $cred = Resolve-ShareCredential -Mode Auto

        # Mode Plain
        $cred = Resolve-ShareCredential -Mode Plain -Username 'SRV\svc-winpe' -Password 'test'
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Plain','Vault','Prompt','Auto','Env')]
        [string]$Mode          = 'Auto',
        [string]$Username,
        [string]$Password,
        [string]$VaultPath     = '',
        [string]$VaultPassword
    )

    switch ($Mode) {
        'Plain' {
            if (-not $Username -or -not $Password) { throw "Mode Plain : -Username et -Password obligatoires" }
            Write-NSLog "Mode Plain : $Username" -Level WARN
            Write-NSLog "Tip: use Vault mode in production" -Level WARN
            return @{ Username = $Username; Password = $Password }
        }
        'Vault' {
            return Get-ShareCredentialFromVault -VaultPath $VaultPath -VaultPassword $VaultPassword
        }
        'Env' {
            $u = [System.Environment]::GetEnvironmentVariable('PSWINDEX_SHARE_USER')
            $p = [System.Environment]::GetEnvironmentVariable('PSWINDEX_SHARE_PASSWORD')
            if (-not $u -or -not $p) { throw "PSWINDEX_SHARE_USER / PSWINDEX_SHARE_PASSWORD non definies" }
            Write-NSLog "Credentials depuis variables d'env" -Level INFO
            return @{ Username = $u; Password = $p }
        }
        'Prompt' {
            Write-Host ""
            Write-Host "  Connecting deployment network share" -ForegroundColor Yellow
            Write-Host "  Compte (ex: SERVEUR\svc-winpe) : " -ForegroundColor Cyan -NoNewline
            $u  = Read-Host
            $sp = Read-Host "  Mot de passe" -AsSecureString
            $p  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
            return @{ Username = $u; Password = $p }
        }
        'Auto' {
            # 1. Vault
            if (Test-Path $VaultPath -ErrorAction SilentlyContinue) {
                try { return Get-ShareCredentialFromVault -VaultPath $VaultPath -VaultPassword $VaultPassword }
                catch { Write-NSLog "Vault inaccessible : $_ -- essai suivant" -Level WARN }
            } else {
                Write-NSLog "Vault non trouve : $VaultPath" -Level WARN
            }
            # 2. Variables d'env
            $u = [System.Environment]::GetEnvironmentVariable('PSWINDEX_SHARE_USER')
            $p = [System.Environment]::GetEnvironmentVariable('PSWINDEX_SHARE_PASSWORD')
            if ($u -and $p) {
                Write-NSLog "Credentials depuis variables d'env" -Level SUCCESS
                return @{ Username = $u; Password = $p }
            }
            # 3. Prompt
            Write-NSLog "No automatic credential -- operator prompt" -Level WARN
            return Resolve-ShareCredential -Mode Prompt
        }
    }
}

# --- Connexion / deconnexion --------------------------------------------------

function Connect-DeployShare {
    <#
    .SYNOPSIS
        Connecte les partages reseau PSWinDeploy depuis WinPE.
    .DESCRIPTION
        Execute net use pour chaque partage. Les partages critiques (Deploy, Images, Drivers)
        font echouer la fonction si inaccessibles. Les partages optionnels (Logs, Logiciels,
        Scripts) signalent un avertissement et continuent.
    .PARAMETER Server
        Nom ou IP du serveur. Extrait automatiquement depuis PSWinDeploy.psd1 si absent.
    .PARAMETER Mode
        Plain | Vault | Prompt | Auto (defaut) | Env
    .PARAMETER Username    Compte en clair (mode Plain).
    .PARAMETER SharePassword Mot de passe en clair (mode Plain).
    .PARAMETER VaultPath   Chemin du vault WinPE.
    .PARAMETER VaultPassword Mot de passe AES du vault.
    .PARAMETER Shares      Liste UNC custom. Si absent, utilise les partages standards.
    .EXAMPLE
        # Mode Auto -- vault si dispo, sinon prompt
        Connect-DeployShare -Server 'DEPLOYSRV'

        # Mode Plain
        Connect-DeployShare -Server 'DEPLOYSRV' -Mode Plain `
            -Username 'DEPLOYSRV\svc-winpe' -SharePassword 'test123'

        # Mode Vault avec mot de passe AES
        Connect-DeployShare -Server 'DEPLOYSRV' -Mode Vault -VaultPassword 'VaultPass!'
    .OUTPUTS
        [PSCustomObject] @{ Server; ConnectedShares; FailedShares; Username }
    #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [ValidateSet('Plain','Vault','Prompt','Auto','Env')]
        [string]$Mode           = 'Auto',
        [string]$Username,
        [string]$SharePassword,
        [string]$VaultPath      = '',
        [string]$VaultPassword,
        [string[]]$Shares,
    [string]$ServerIPFallback = ''   # IP pre-resolue (depuis NetworkShareFallback)
    )

    Write-NSLog "=== Connecting deployment shares ===" -Level STEP

    # Resolution serveur depuis psd1 si non fourni
    if (-not $Server) {
        foreach ($cfg in @('X:\Deploy\PSWinDeploy.psd1','C:\Deploy\PSWinDeploy.psd1')) {
            if (Test-Path $cfg) {
                try {
                    $psd = Import-PowerShellDataFile $cfg
                    if ($psd.DeployShare -match '\\\\([^\\]+)\\') { $Server = $Matches[1]; break }
                } catch {}
            }
        }
    }
    if (-not $Server) { throw "Serveur non determine. Specifier -Server ou configurer DeployShare dans PSWinDeploy.psd1" }
    Write-NSLog "Serveur : $Server" -Level INFO

    # Resolution credentials
    $cred = Resolve-ShareCredential `
        -Mode          $Mode `
        -Username      $Username `
        -Password      $SharePassword `
        -VaultPath     $VaultPath `
        -VaultPassword $VaultPassword
    Write-NSLog "Compte reseau : $($cred.Username)" -Level INFO

    # Partages optionnels (echec non bloquant)
    $optionalPattern = '\\(Logs|Logiciels|Scripts)$'

    $connected = @()
    $failed    = @()

    # Tester la connectivite SMB (port 445) avant net use
    # Tester sur le nom ET sur l'IP fallback si disponible
    $smbOk     = $false
    $smbTarget = $Server
    $ServerIP = $ServerIPFallback   # IP fallback pour test port 445
    foreach ($testTarget in @($Server, $ServerIP) | Where-Object { $_ }) {
        if ($smbOk) { break }
        try {
            $tcpClient   = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($testTarget, 445, $null, $null)
            $wait = $asyncResult.AsyncWaitHandle.WaitOne(1500)
            if ($wait -and $tcpClient.Connected) {
                $smbOk     = $true
                $smbTarget = $testTarget
                Write-NSLog "Port 445 (SMB) accessible sur $testTarget" -Level INFO
            } else {
                Write-NSLog "Port 445 (SMB) INACCESSIBLE sur $testTarget" -Level WARN
            }
            try { $tcpClient.Close() } catch {}
        } catch {
            Write-NSLog "Test port 445 ($testTarget) : $_" -Level WARN
        }
    }
    # Si l'IP est plus accessible que le nom, l'utiliser directement
    if ($smbOk -and $smbTarget -ne $Server) {
        Write-NSLog "Basculement sur IP : $smbTarget (nom $Server inaccessible)" -Level INFO
        # Enregistrer le mapping pour reecrire les UNC dans toute la suite
        $script:ShareHostMap[$Server] = $smbTarget
        $Server = $smbTarget
    }

    # Construire les partages APRES le basculement eventuel sur IP
    # (sinon on connait les partages avec le nom DNS qui est inaccessible)
    if (-not $Shares) {
        $Shares = @(
            "\\$Server\Deploy",
            "\\$Server\Images",
            "\\$Server\Drivers",
            "\\$Server\Logiciels",
            "\\$Server\Scripts",
            "\\$Server\Logs"
        )
        Write-NSLog "Partages cibles : $($Shares[0]) ..." -Level INFO
    }

    foreach ($share in $Shares) {
        Write-NSLog "Connexion : $share" -Level INFO

        # Deconnecter si deja present
        try { Remove-SmbMapping $share -Force -ErrorAction SilentlyContinue } catch {}
        try { & net use $share /delete /yes 2>&1 | Out-Null } catch {}

        Write-NSLog "  Compte : $($cred.Username)  Pwd : $(if($cred.Password){'***'}else{'(vide)'})" -Level INFO

        # Methode 1 : New-SmbMapping (PS natif, pas de NativeCommandError)
        $smbOk = $false
        try {
            $secPwd = ConvertTo-SecureString $cred.Password -AsPlainText -Force
            $smbCred = New-Object System.Management.Automation.PSCredential($cred.Username, $secPwd)
            New-SmbMapping -RemotePath $share -UserName $cred.Username -Password $cred.Password `
                -Persistent $false -ErrorAction Stop | Out-Null
            $smbOk = $true
            Write-NSLog "  OK (SmbMapping) : $share" -Level SUCCESS
        } catch {
            Write-NSLog "  SmbMapping echoue : $_ -- tentative net use" -Level WARN

            # Methode 2 : net use (fallback)
            try {
                $netResult = & net use $share $cred.Password /user:$($cred.Username) /persistent:no 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $smbOk = $true
                    Write-NSLog "  OK (net use) : $share" -Level SUCCESS
                } else {
                    Write-NSLog "  net use code $LASTEXITCODE : $($netResult -join ' ')" -Level WARN
                }
            } catch {
                Write-NSLog "  net use exception : $_" -Level WARN
            }
        }

        if (-not $smbOk) {
            $failed += $share
            if ($share -notmatch $optionalPattern) {
                throw "Partage critique inaccessible : $share`nCompte : $($cred.Username)`nVerifier : partage SMB existant, compte valide, port 445 ouvert."
            }
            Write-NSLog "  (optional share -- continuing)" -Level INFO
        } else {
            $connected += $share
        }
    }

    Write-NSLog "$(@($connected).Count) connecte(s), $(@($failed).Count) echec(s)" `
        -Level $(if (@($failed).Count -eq 0) { 'SUCCESS' } else { 'WARN' })

    return [PSCustomObject]@{
        Server          = $Server
        ConnectedShares = $connected
        FailedShares    = $failed
        Username        = $cred.Username
    }
}

function Disconnect-DeployShare {
    <#
    .SYNOPSIS Deconnecte tous les partages PSWinDeploy.#>
    param([Parameter(Mandatory)][string]$Server)
    Write-NSLog "Deconnexion partages de $Server..." -Level INFO
    @('Deploy','Images','Drivers','Logiciels','Scripts','Logs') | ForEach-Object {
        & net use "\\$Server\$_" /delete /yes 2>&1 | Out-Null
    }
    Write-NSLog "Deconnexion terminee" -Level SUCCESS
}

function Test-DeployShareAccess {
    <#
    .SYNOPSIS Teste l'accessibilite d'un partage (avec timeout).#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SharePath, [int]$TimeoutSec = 5)
    try {
        $job    = Start-Job { Test-Path $using:SharePath }
        $result = Wait-Job $job -Timeout $TimeoutSec | Receive-Job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return [bool]$result
    } catch { return $false }
}

# --- Helper build WinPE -------------------------------------------------------

function New-WinPEShareVault {
    <#
    .SYNOPSIS
        Cree le vault WinPE contenant les credentials d'acces aux partages.
    .DESCRIPTION
        Ce vault (secrets.vault) est injecte dans l'ISO WinPE lors du build
        via Invoke-WinPEBuild / Set-WinPECustomization.
        Il contient au minimum winpeUser + winpePassword.
        On peut y ajouter d'autres secrets (VaultPassword AES du vault de deploiement).

        Trois modes :
          -Plain        : vault en clair. Protege par acces physique et droits reseau.
          -VaultPassword: vault AES chiffre. Seul quelqu'un connaissant le mot de passe peut lire.
          (aucun)       : vault DPAPI -- non portable, deconseille.

    .PARAMETER Username    Compte reseau WinPE (ex: 'DEPLOYSRV\svc-winpe').
    .PARAMETER Password    Mot de passe du compte.
    .PARAMETER OutputPath  Dossier de sortie. Le vault sera cree a OutputPath\secrets.vault.
    .PARAMETER VaultPassword Mot de passe AES. Si absent -> DPAPI (non portable).
    .PARAMETER Plain       Vault en clair (tests uniquement).
    .PARAMETER AdditionalSecrets Secrets supplementaires a inclure.
    .EXAMPLE
        # Production : vault AES injecte dans l'ISO
        New-WinPEShareVault `
            -Username      'DEPLOYSRV\svc-winpe' `
            -Password      'P@ssw0rd!' `
            -OutputPath    'D:\WinPE-Work\extra' `
            -VaultPassword 'MotDePasseVault!'

        # Lab : vault en clair
        New-WinPEShareVault `
            -Username   'DEPLOYSRV\svc-winpe' `
            -Password   'lab123' `
            -OutputPath 'D:\WinPE-Work\extra' `
            -Plain
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$VaultPassword,
        [switch]$Plain,
        [hashtable]$AdditionalSecrets = @{}
    )

    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $vaultPath = Join-Path $OutputPath 'secrets.vault'

    $secrets = @{ winpeUser = $Username; winpePassword = $Password }
    foreach ($k in $AdditionalSecrets.Keys) { $secrets[$k] = $AdditionalSecrets[$k] }

    $json = $secrets | ConvertTo-Json -Compress

    if ($Plain) {
        # Format PSD1 -- lisible, editable a la main, aucun wrapping JSON
        $vaultPath = Join-Path $OutputPath 'secrets.vault.psd1'
        Write-NSLog "Vault WinPE Plain (PSD1) : $vaultPath" -Level INFO
        $psd1Lines = @('@{')
        foreach ($k in $secrets.Keys) {
            $v = $secrets[$k] -replace "'", "''"
            $psd1Lines += "    $k = '$v'"
        }
        $psd1Lines += '}'
        # BOM UTF-8 requis par Import-PowerShellDataFile
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($vaultPath, ($psd1Lines -join "`r`n"), $utf8Bom)
    } elseif ($VaultPassword) {
        Write-NSLog "Vault WinPE AES : $vaultPath" -Level INFO
        $key  = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($VaultPassword))
        $enc  = ($json | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString -Key $key
        @{ method = 'AES'; data = $enc } | ConvertTo-Json | Set-Content $vaultPath -Encoding UTF8
    } else {
        Write-NSLog "Vault WinPE DPAPI (non portable) : $vaultPath" -Level WARN
        $enc  = ($json | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString
        @{ method = 'DPAPI'; data = $enc } | ConvertTo-Json | Set-Content $vaultPath -Encoding UTF8
    }

    Write-NSLog "Vault WinPE cree : $vaultPath ($(@($secrets).Count) secret(s))" -Level SUCCESS
    return $vaultPath
}

function Resolve-PSWDShareHost {
    <#
    .SYNOPSIS Reecrit un chemin UNC en remplacant le nom DNS par l'IP si un basculement a eu lieu.
    .DESCRIPTION
        Si la connexion initiale a bascule du nom DNS vers une IP (nom inaccessible),
        ce helper applique le meme remplacement a n'importe quel chemin UNC.
    .PARAMETER Path Chemin UNC (ex: \\S-PS-DEP-1\Images\x.wim).
    .OUTPUTS [string] chemin reecrit, ou identique si aucun mapping.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Doit commencer par \\ (UNC)
    if (-not $Path.StartsWith('\\')) { return $Path }

    # Extraire l'hote : ce qui est entre les \\ initiaux et le \ suivant
    $rest  = $Path.Substring(2)               # retirer les 2 backslashes initiaux
    $slash = $rest.IndexOf('\')
    if ($slash -lt 1) { return $Path }
    $uncHost  = $rest.Substring(0, $slash)    # nom d'hote
    $tail     = $rest.Substring($slash)       # reste du chemin (commence par \)

    if ($script:ShareHostMap.ContainsKey($uncHost)) {
        $newHost   = $script:ShareHostMap[$uncHost]
        $rewritten = '\\' + $newHost + $tail
        Write-NSLog "UNC reecrit : $Path -> $rewritten" -Level INFO
        return $rewritten
    }
    return $Path
}

function Resolve-Share {
    <#
    .SYNOPSIS
        Resout un partage en testant le NOM DNS d'abord, puis l'IP.
    .DESCRIPTION
        Accepte DEUX formes :
          - une hashtable @{ DNS = '\\NOM\Part'; IP = '\\1.2.3.4\Part' }
            -> teste DNS (accessible ?), sinon IP. Le plus fiable et explicite.
          - une simple string '\\NOM\Part'
            -> teste tel quel, sinon bascule par la table de mapping nom->IP.
        UN SEUL endroit gere nom vs IP. Tous les modules appellent ceci.
    .OUTPUTS Le chemin accessible (string), ou le 1er candidat si rien ne repond.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Share,   # string OU @{DNS;IP}
        [hashtable]$Map
    )
    if (-not $Share) { return $Share }
    if (-not $Map) { $Map = $script:ShareHostMap }

    # Forme hashtable @{ DNS; IP }
    if ($Share -is [hashtable] -or $Share -is [System.Collections.IDictionary]) {
        $dns = $Share['DNS']; $ip = $Share['IP']
        if ($dns -and (Test-Path $dns -ErrorAction SilentlyContinue)) { return $dns }
        if ($ip  -and (Test-Path $ip  -ErrorAction SilentlyContinue)) { return $ip }
        # Aucun accessible : preferer l'IP (plus fiable hors domaine), sinon DNS
        if ($ip) { return $ip }
        return $dns
    }

    # Forme string
    $Path = "$Share"
    if (Test-Path $Path -ErrorAction SilentlyContinue) { return $Path }
    if ($Path -match '^\\\\([^\\]+)\\(.*)$') {
        $srv = $Matches[1]; $rest = $Matches[2]
        $ip = $null
        if ($Map -and $Map.ContainsKey($srv)) { $ip = $Map[$srv] }
        if (-not $ip) {
            try {
                $r = [System.Net.Dns]::GetHostAddresses($srv) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                if ($r) { $ip = $r.IPAddressToString }
            } catch {}
        }
        if ($ip -and $ip -ne $srv) {
            $byIp = "\\$ip\$rest"
            if (Test-Path $byIp -ErrorAction SilentlyContinue) { $script:ShareHostMap[$srv] = $ip; return $byIp }
        }
    }
    return $Path
}

function Get-PSWDSharePath {
    <#
    .SYNOPSIS
        Lit une cle de partage dans une config et retourne le chemin accessible.
    .DESCRIPTION
        Point d'entree UNIQUE pour obtenir un chemin de partage. Lit la cle
        demandee (ex: 'DeployShare') dans la hashtable de config, qui peut etre
        au format @{ DNS; IP } ou une simple string, puis applique Resolve-Share.
        Tous les modules utilisent ceci -- aucun bricolage de chemin ailleurs.
    .PARAMETER Config Hashtable de config (PSWinDeploy.psd1 ou deploy-config.psd1).
    .PARAMETER Key Nom de la cle (ex: 'DeployShare', 'ScriptShare', 'SequencesPath').
    .PARAMETER SubPath Sous-chemin a ajouter (ex: 'by-mac\xx.psd1'). Optionnel.
    .OUTPUTS Chemin accessible (string), ou $null si la cle est absente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Key,
        [string]$SubPath = ''
    )
    if (-not $Config) { return $null }
    $raw = $null
    if ($Config -is [hashtable] -or $Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Key)) { $raw = $Config[$Key] }
    } else {
        if ($Config.PSObject.Properties[$Key]) { $raw = $Config.$Key }
    }
    if (-not $raw) { return $null }
    $resolved = Resolve-Share $raw
    if ($SubPath) {
        $resolved = (Join-Path $resolved $SubPath)
    }
    return $resolved
}

function Get-PSWDShareHostMap {
    <# .SYNOPSIS Retourne le mapping nom DNS -> IP des basculements effectues. #>
    return $script:ShareHostMap
}

function Set-PSWDShareHostMap {
    <# .SYNOPSIS Definit/restaure le mapping (pour la reprise apres reboot). #>
    param([hashtable]$Map)
    if ($Map) { $script:ShareHostMap = $Map }
}

Export-ModuleMember -Function @(
    'Connect-DeployShare'
    'Disconnect-DeployShare'
    'Test-DeployShareAccess'
    'Resolve-ShareCredential'
    'New-WinPEShareVault'
    'Resolve-PSWDShareHost'
    'Resolve-Share'
    'Get-PSWDSharePath'
    'Get-PSWDShareHostMap'
    'Set-PSWDShareHostMap'
)
