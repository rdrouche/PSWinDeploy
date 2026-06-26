#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TaskSequence.psm1 -- Moteur d'execution des sequences de deploiement JSON
.DESCRIPTION
    Charge, valide et execute des fichiers task-sequence.json.
    Gere la persistance d'etat, les reboots automatiques/manuels,
    les secrets chiffres, les conditions et le logging structure.
.NOTES
    Prerequis : WIM-Manager.psm1, WinPE-Builder.psm1 (pour les steps WinPE)
    Usage     : Depuis WinPE (steps infra) ou Windows installe (steps post-deploiement)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CHEMINS CONSTANTS
# -----------------------------------------------------------------------------

# Calcul dynamique des chemins selon le contexte (WinPE vs Windows installe)
function Get-DeployRoot {
    # Helper : un drive existe-t-il ? (evite 'Cannot find drive' sous StrictMode)
    function Test-DriveExists { param([string]$Letter)
        return [bool](Get-PSDrive -Name $Letter -PSProvider FileSystem -EA SilentlyContinue)
    }
    if ((Test-DriveExists 'C') -and (Test-Path 'C:\Deploy' -EA SilentlyContinue))  { return 'C:\Deploy' }
    if ((Test-DriveExists 'W') -and (Test-Path 'W:\Windows' -EA SilentlyContinue)) { return 'W:\Deploy' }
    return 'X:\Deploy'
}

function Export-DeployLogs {
    <#
    .SYNOPSIS Copie les logs de deploiement + l'unattend genere vers le partage
    Logs, pour qu'ils survivent au reboot/BSOD (le X:\Deploy en WinPE est volatil).
    #>
    param([string]$NetworkShare = '', [string]$Tag = '')
    try {
        # Determiner le partage Logs (autonome : cherche un partage \\serveur\Logs)
        $logShare = ''
        if ($NetworkShare) {
            $cand = Join-Path (Split-Path $NetworkShare -Parent) 'Logs'
            if (Test-Path $cand -EA SilentlyContinue) { $logShare = $cand }
            elseif (Test-Path "$NetworkShare\Logs" -EA SilentlyContinue) { $logShare = "$NetworkShare\Logs" }
        }
        # Sinon, chercher un lecteur reseau monte avec un dossier Logs accessible
        if (-not $logShare) {
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue)) {
                if ($d.DisplayRoot -and $d.DisplayRoot -like '\\*') {
                    $base = Split-Path $d.DisplayRoot -Parent
                    foreach ($cand in @((Join-Path $base 'Logs'), "$($d.Root)Logs")) {
                        if (Test-Path $cand -EA SilentlyContinue) { $logShare = $cand; break }
                    }
                }
                if ($logShare) { break }
            }
        }
        if (-not $logShare) {
            Write-TSLog "Export logs : aucun partage Logs trouve" -Level WARN
            return
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $machine = $env:COMPUTERNAME
        $destDir = Join-Path $logShare "deploy_${machine}_${stamp}${Tag}"
        New-Item -ItemType Directory -Path $destDir -Force -EA SilentlyContinue | Out-Null

        # 1. Le log de deploiement
        $root = Get-DeployRoot
        $logFile = Join-Path $root 'Logs\deploy.log'
        if (Test-Path $logFile -EA SilentlyContinue) {
            Copy-Item $logFile (Join-Path $destDir 'deploy.log') -Force -EA SilentlyContinue
        }
        # 2. Le state.psd1
        $stateFile = Join-Path $root 'state.psd1'
        if (Test-Path $stateFile -EA SilentlyContinue) {
            Copy-Item $stateFile (Join-Path $destDir 'state.psd1') -Force -EA SilentlyContinue
        }
        # 3. L'unattend genere (sur W: si dispo)
        foreach ($u in @('W:\Windows\Panther\unattend.xml','C:\Windows\Panther\unattend.xml')) {
            if (Test-Path $u -EA SilentlyContinue) {
                Copy-Item $u (Join-Path $destDir 'unattend-genere.xml') -Force -EA SilentlyContinue
                break
            }
        }
        # 4. Les logs Panther de l'image (s'ils existent deja)
        foreach ($p in @('W:\Windows\Panther\setupact.log','W:\Windows\Panther\setuperr.log')) {
            if (Test-Path $p -EA SilentlyContinue) {
                Copy-Item $p (Join-Path $destDir (Split-Path $p -Leaf)) -Force -EA SilentlyContinue
            }
        }
        Write-TSLog "Logs exportes vers : $destDir" -Level SUCCESS
    } catch {
        Write-TSLog "Export des logs echoue : $_" -Level WARN
    }
}
$script:DeployRoot  = Get-DeployRoot
$script:StateFile   = Join-Path $script:DeployRoot 'state.psd1'
$script:SecretsFile = Join-Path $script:DeployRoot 'secrets.vault'
$script:DeployLog   = Join-Path $script:DeployRoot 'Logs\deploy.log'
$script:RunOnceKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$script:RunOnceName   = 'PSWinDeploy-Resume'
$script:UnattendHandlesResume = $false  # mis a $true si ApplyUnattend gere la phase 2

# Exit codes Microsoft standard
$script:ExitRebootRequired  = 3010
$script:ExitRebootInitiated = 1641

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

function Write-TSLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','STEP','DEBUG')]
        [string]$Level = 'INFO',
        [string]$StepId = ''
    )
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($StepId) { "[$StepId]" } else { '[-]' }
    $icons  = @{ INFO='[~]';WARN='[!]';ERROR='[X]';SUCCESS='[OK]';STEP='[>>]';DEBUG='[D]' }
    $colors = @{ INFO='Cyan';WARN='Yellow';ERROR='Red';SUCCESS='Green';STEP='Magenta';DEBUG='DarkGray' }
    $line   = "$ts $($icons[$Level]) $prefix $Message"
    Write-Host $line -ForegroundColor $colors[$Level]
    try {
        $logDir = Split-Path $script:DeployLog -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $script:DeployLog -Value $line -Encoding UTF8
    } catch {}
}

# -----------------------------------------------------------------------------
# GESTION DES SECRETS
# -----------------------------------------------------------------------------

function Initialize-SecretVault {
    <#
    .SYNOPSIS Cree ou recree le vault de secrets.
    .DESCRIPTION
        Quatre modes de stockage selon le contexte :

        Plain  -- Secrets en clair dans le JSON. Pratique pour les tests/lab.
                 NE PAS UTILISER en production. Avertissement affiche.

        DPAPI  -- Chiffrement Windows lie au compte ET a la machine qui cree le vault.
                 Non portable : seul ce meme compte sur cette meme machine peut dechiffrer.
                 Adapte uniquement si le vault est lu localement (ex : tache planifiee locale).

        AES    -- Chiffrement AES-256 avec un mot de passe. Le vault est portable entre
                 machines et comptes -- c'est le mode recommande pour un deploiement reseau.
                 Le mot de passe peut etre passe via -Password, via variable d'env
                 PSWINDEX_VAULT_PASSWORD, ou saisi interactivement au demarrage de WinPE.

        Prompt -- Pas de vault. Get-Secret demandera chaque secret interactivement.
                 Utile en WinPE quand aucun vault n'est disponible.

    .PARAMETER Secrets   Hashtable des secrets a stocker.
    .PARAMETER VaultPath Chemin du fichier vault (defaut : C:\Deploy\secrets.vault).
    .PARAMETER Password  Mot de passe AES. Si vide -> mode DPAPI.
    .PARAMETER Plain     Stocke les secrets en clair (tests uniquement).
    .EXAMPLE
        # Mode AES -- recommande en production reseau
        Initialize-SecretVault -Secrets @{
            domainJoinUser     = 'svc-joindomain'
            domainJoinPassword = 'P@ssw0rd!'
            deployPassword     = 'Deploy@2024!'
            localAdminPassword = 'Admin@2024!'
        } -Password 'MotDePasseVault!'

        # Mode Plain -- tests uniquement
        Initialize-SecretVault -Secrets @{ domainJoinPassword = 'test123' } -Plain
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Secrets,
        [string]$VaultPath = $script:SecretsFile,
        [string]$Password,
        [switch]$Plain
    )

    $vaultDir = Split-Path $VaultPath -Parent
    if (-not (Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir -Force | Out-Null }

    $json = $Secrets | ConvertTo-Json -Compress

    if ($Plain) {
        # -- Mode Plain (tests uniquement) ----------------------------------
        Write-TSLog "AVERTISSEMENT : vault en clair (mode Plain) -- NE PAS utiliser en production !" -Level WARN
        Write-TSLog "Fichier : $VaultPath" -Level WARN
        @{ method = 'Plain'; data = $json } | ConvertTo-Json | Set-Content $VaultPath -Encoding UTF8

    } elseif ($Password) {
        # -- Mode AES -- portable entre machines -----------------------------
        Write-TSLog "Creation vault AES (portable) : $VaultPath" -Level INFO
        $key       = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                         [System.Text.Encoding]::UTF8.GetBytes($Password))
        $secureStr = $json | ConvertTo-SecureString -AsPlainText -Force
        $encrypted = $secureStr | ConvertFrom-SecureString -Key $key
        @{ method = 'AES'; data = $encrypted } | ConvertTo-Json | Set-Content $VaultPath -Encoding UTF8

    } else {
        # -- Mode DPAPI -- lie au compte + machine courants ------------------
        Write-TSLog "Creation vault DPAPI (non portable) : $VaultPath" -Level INFO
        Write-TSLog "ATTENTION : Ce vault ne peut etre dechiffre QUE par le compte '$env:USERNAME' sur '$env:COMPUTERNAME'." -Level WARN
        Write-TSLog "Pour un deploiement reseau multi-machines, utilisez -Password (mode AES)." -Level WARN
        $secureStr = $json | ConvertTo-SecureString -AsPlainText -Force
        $encrypted = $secureStr | ConvertFrom-SecureString
        @{ method = 'DPAPI'; data = $encrypted } | ConvertTo-Json | Set-Content $VaultPath -Encoding UTF8
    }

    Write-TSLog "Vault cree -- $(@($Secrets).Count) secret(s) -- methode : $(if($Plain){'Plain'}elseif($Password){'AES'}else{'DPAPI'})" -Level SUCCESS
}

function Get-VaultSecretQuiet {
    <# Lit un secret du vault PSD1 SANS prompt (retourne `$null si absent). #>
    param([string]$Key)
    $vaultCandidates = @(
        $script:SecretsFile, "$($script:SecretsFile).psd1",
        'X:\Deploy\secrets.vault.psd1', 'X:\Deploy\secrets.vault',
        'C:\Deploy\secrets.vault.psd1', 'C:\Deploy\secrets.vault'
    )
    foreach ($vc in $vaultCandidates) {
        if ($vc -and (Test-Path $vc -EA SilentlyContinue) -and $vc -match '\.psd1$') {
            try {
                $ht = Import-PowerShellDataFile $vc -EA Stop
                if ($ht.ContainsKey($Key) -and $ht[$Key]) { return $ht[$Key] }
            } catch {}
        }
    }
    return $null
}

function Get-Secret {
    <#
    .SYNOPSIS Recupere un secret depuis le vault, une variable d'env, ou un prompt.
    .DESCRIPTION
        Sources disponibles :
          vault  -- Lit dans le fichier secrets.vault (Plain, AES, ou DPAPI selon le mode cree).
                   Pour AES, le mot de passe peut etre fourni via -Password ou la variable
                   d'environnement PSWINDEX_VAULT_PASSWORD (pratique pour WinPE).
          env    -- Lit une variable d'environnement Windows.
          prompt -- Demande la valeur interactivement (fallback WinPE sans vault).
          plain  -- Retourne la valeur telle quelle (alias interne pour les tests).
    .EXAMPLE
        $pass = Get-Secret -Source vault -Key domainJoinPassword
        $pass = Get-Secret -Source env   -Key DEPLOY_DOMAIN_PASS
        $pass = Get-Secret -Source prompt -Label "Mot de passe jonction domaine"
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('vault','env','prompt','plain')]
        [string]$Source    = 'vault',
        [string]$Key,
        [string]$Label     = $Key,
        [string]$VaultPath = $script:SecretsFile,
        [string]$Password  # Pour dechiffrer le vault AES (ou via $env:PSWINDEX_VAULT_PASSWORD)
    )

    switch ($Source) {
        'vault' {
            # Resoudre le chemin du vault : tester plusieurs emplacements et extensions
            $vaultCandidates = @()
            if ($VaultPath) {
                $vaultCandidates += $VaultPath
                if ($VaultPath -notmatch '\.psd1$') { $vaultCandidates += "$VaultPath.psd1" }
            }
            $vaultCandidates += 'X:\Deploy\secrets.vault.psd1'
            $vaultCandidates += 'X:\Deploy\secrets.vault'
            $vaultCandidates += 'C:\Deploy\secrets.vault.psd1'
            $vaultCandidates += 'C:\Deploy\secrets.vault'
            $resolvedVault = $null
            foreach ($vc in $vaultCandidates) {
                if ($vc -and (Test-Path $vc -EA SilentlyContinue)) { $resolvedVault = $vc; break }
            }
            if (-not $resolvedVault) {
                Write-TSLog "Vault introuvable (teste : $($vaultCandidates -join ', ')) -- fallback prompt" -Level WARN
                return Get-Secret -Source prompt -Key $Key -Label $Label
            }
            $VaultPath = $resolvedVault

            # Format PSD1 plat (@{ cle = 'valeur' }) -- format standard actuel
            if ($VaultPath -match '\.psd1$') {
                try {
                    $vaultHt = Import-PowerShellDataFile $VaultPath -EA Stop
                    if ($vaultHt.ContainsKey($Key) -and $vaultHt[$Key]) {
                        Write-TSLog "Secret '$Key' lu depuis le vault PSD1" -Level DEBUG
                        return $vaultHt[$Key]
                    } else {
                        Write-TSLog "Cle '$Key' absente du vault PSD1 -- fallback prompt" -Level WARN
                        return Get-Secret -Source prompt -Key $Key -Label $Label
                    }
                } catch {
                    Write-TSLog "Lecture vault PSD1 echouee : $_ -- fallback prompt" -Level WARN
                    return Get-Secret -Source prompt -Key $Key -Label $Label
                }
            }

            # Format JSON legacy (method/data) -- compatibilite ascendante
            try {
                $vault = Get-Content $VaultPath -Raw | ConvertFrom-Json

                switch ($vault.method) {

                    'Plain' {
                        # Vault en clair -- tests uniquement
                        Write-TSLog "Lecture vault Plain (non chiffre) -- cle '$Key'" -Level WARN
                        $secretsObj = $vault.data | ConvertFrom-Json
                        if ($null -eq $secretsObj.$Key) {
                            Write-TSLog "Cle '$Key' absente du vault -- fallback prompt" -Level WARN
                            return Get-Secret -Source prompt -Key $Key -Label $Label
                        }
                        return $secretsObj.$Key
                    }

                    'AES' {
                        # Resolution du mot de passe : param > variable d'env > prompt interactif
                        if (-not $Password) {
                            $Password = [System.Environment]::GetEnvironmentVariable('PSWINDEX_VAULT_PASSWORD')
                        }
                        if (-not $Password) {
                            Write-TSLog "Mot de passe vault AES requis" -Level INFO
                            $secPass  = Read-Host "Mot de passe vault" -AsSecureString
                            $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))
                        }
                        $key      = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                                        [System.Text.Encoding]::UTF8.GetBytes($Password))
                        $secrets  = $vault.data | ConvertTo-SecureString -Key $key |
                                        ForEach-Object {
                                            [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_))
                                        }
                        $secretsObj = $secrets | ConvertFrom-Json
                        if ($null -eq $secretsObj.$Key) {
                            Write-TSLog "Cle '$Key' absente du vault AES -- fallback prompt" -Level WARN
                            return Get-Secret -Source prompt -Key $Key -Label $Label
                        }
                        return $secretsObj.$Key
                    }

                    'DPAPI' {
                        $secrets = $vault.data | ConvertTo-SecureString |
                                        ForEach-Object {
                                            [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_))
                                        }
                        $secretsObj = $secrets | ConvertFrom-Json
                        if ($null -eq $secretsObj.$Key) {
                            Write-TSLog "Cle '$Key' absente du vault DPAPI -- fallback prompt" -Level WARN
                            return Get-Secret -Source prompt -Key $Key -Label $Label
                        }
                        return $secretsObj.$Key
                    }

                    default {
                        throw "Methode vault inconnue : $($vault.method)"
                    }
                }
            } catch {
                Write-TSLog "Erreur lecture vault : $_ -- fallback prompt" -Level WARN
                return Get-Secret -Source prompt -Key $Key -Label $Label
            }
        }

        'env' {
            $val = [System.Environment]::GetEnvironmentVariable($Key)
            if (-not $val) {
                Write-TSLog "Variable d'env '$Key' vide -- fallback prompt" -Level WARN
                return Get-Secret -Source prompt -Key $Key -Label $Label
            }
            return $val
        }

        'plain' {
            # Source interne -- retourne la valeur de Key directement (tests)
            return $Key
        }

        'prompt' {
            Write-Host ""
            $secure = Read-Host "  Entrez $Label" -AsSecureString
            return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        }
    }
}

# -----------------------------------------------------------------------------
# PERSISTANCE D'ETAT (REBOOT)
# -----------------------------------------------------------------------------

function Save-DeployState {
    <#
    .SYNOPSIS Persiste l'etat courant du deploiement avant un reboot.#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$State
    )
    # Recalculer StateFile selon contexte (WinPE avant format = X:, apres install = C:)
    $script:StateFile = Join-Path (Get-DeployRoot) 'state.psd1'
    $script:DeployLog = Join-Path (Get-DeployRoot) 'Logs\deploy.log'
    $stateDir = Split-Path $script:StateFile -Parent
    try {
        if (-not (Test-Path $stateDir -EA SilentlyContinue)) {
            New-Item -ItemType Directory -Path $stateDir -Force -EA Stop | Out-Null
        }
    } catch {
        Write-TSLog "Impossible de creer le dossier d'etat $stateDir : $_" -Level WARN
        return  # Ne pas planter si le dossier est inaccessible
    }
    # Sauvegarder en PSD1
    # Helper d'acces securise a une propriete (StrictMode)
    function Get-StateProp { param($Obj, $Name, $Default = '')
        if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
        return $Default
    }
    $spEsc = "$(Get-StateProp $State 'sequencePath')".Replace("'", "''")
    $seqId = "$(Get-StateProp $State 'sequenceId')".Replace("'", "''")
    $nextId = "$(Get-StateProp $State 'nextStepId')".Replace("'", "''")
    $winDrive = "$(Get-StateProp $State 'windowsDrive' 'W:')"
    $completed = @(Get-StateProp $State 'completedSteps' @())
    $compSteps = @($completed | ForEach-Object { "'$_'" }) -join ', '
    $rebootCnt = [int](Get-StateProp $State 'rebootCount' 0)
    $startedAt = "$(Get-StateProp $State 'startedAt')"

    # Sauvegarder le mapping nom DNS -> IP (basculement) pour la phase 2
    $hostMapLines = @()
    if (Get-Command Get-PSWDShareHostMap -EA SilentlyContinue) {
        $hm = Get-PSWDShareHostMap
        foreach ($k in $hm.Keys) {
            $kEsc = $k.Replace("'", "''"); $vEsc = "$($hm[$k])".Replace("'", "''")
            $hostMapLines += "        '$kEsc' = '$vEsc'"
        }
    }
    $stateLines = @('@{')
    $stateLines += "    sequenceId     = '$seqId'"
    $stateLines += "    sequencePath   = '$spEsc'"
    $stateLines += "    nextStepId     = '$nextId'"
    $stateLines += "    completedSteps = @($compSteps)"
    $stateLines += "    rebootCount    = $rebootCnt"
    $stateLines += "    windowsDrive   = '$winDrive'"
    $stateLines += "    startedAt      = '$startedAt'"
    $stateLines += "    lastUpdated    = '$(Get-Date -Format 'o')'"
    if ($hostMapLines.Count -gt 0) {
        $stateLines += '    ShareHostMap = @{'
        $stateLines += $hostMapLines
        $stateLines += '    }'
    } else {
        $stateLines += '    ShareHostMap = @{}'
    }
    $stateLines += '}'
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($script:StateFile, ($stateLines -join "`r`n"), $utf8Bom)
    Write-TSLog "Etat persiste : nextStep=$($State.nextStepId) rebootCount=$($State.rebootCount)" -Level DEBUG
}

function Get-DeployState {
    <#
    .SYNOPSIS Charge l'etat persiste si disponible.#>
    if (Test-Path $script:StateFile) {
        $state = Import-PowerShellDataFile $script:StateFile -ErrorAction Stop
        Write-TSLog "Etat charge : reprend a step '$($state.nextStepId)' (reboot #$($state.rebootCount))" -Level INFO
        return $state
    }
    return $null
}

function Remove-DeployState {
    <#
    .SYNOPSIS Supprime le fichier d'etat (deploiement termine ou abandonne).#>
    if (Test-Path $script:StateFile) {
        Remove-Item $script:StateFile -Force
        Write-TSLog "Fichier etat supprime (deploiement termine)" -Level DEBUG
    }
}

function Copy-DeployToTarget {
    <#
    .SYNOPSIS Copie le deploiement (scripts, modules, runtime, vault) sur la partition Windows.
    .DESCRIPTION
        En WinPE, le deploiement tourne depuis X:. Apres reboot, W: devient C:.
        Cette fonction copie tout le necessaire vers W:\Deploy pour que la phase 2
        (lancee via RunOnce sur C:) trouve les scripts, modules, sequence et etat.
    #>
    [CmdletBinding()]
    param([string]$TargetDrive = 'W:')
    if (-not (Test-IsWinPE)) { return }  # deja sur le disque en phase 2

    $drive = $TargetDrive.TrimEnd('\').TrimEnd(':') + ':'
    $targetDeploy = Join-Path $drive 'Deploy'
    $sourceDeploy = Get-DeployRoot   # X:\Deploy en WinPE

    if (-not (Test-Path $sourceDeploy -EA SilentlyContinue)) {
        Write-TSLog "Source deploiement introuvable : $sourceDeploy" -Level WARN
        return
    }
    try {
        if (-not (Test-Path $targetDeploy -EA SilentlyContinue)) {
            New-Item -ItemType Directory $targetDeploy -Force | Out-Null
        }
        # Copier Scripts, Modules, Runtime, vault
        foreach ($sub in @('Scripts','Modules','Runtime')) {
            $src = Join-Path $sourceDeploy $sub
            if (Test-Path $src -EA SilentlyContinue) {
                Copy-Item $src $targetDeploy -Recurse -Force -EA SilentlyContinue
            }
        }
        # Vault et state
        foreach ($file in @('secrets.vault.psd1','secrets.vault','state.psd1')) {
            $src = Join-Path $sourceDeploy $file
            if (Test-Path $src -EA SilentlyContinue) {
                Copy-Item $src $targetDeploy -Force -EA SilentlyContinue
            }
        }
        Write-TSLog "Deploiement copie sur $targetDeploy (phase 2 apres reboot)" -Level SUCCESS
    } catch {
        Write-TSLog "Copie deploiement vers $targetDeploy echouee : $_" -Level WARN
    }
}

function Get-LocalAdminName {
    <#
    .SYNOPSIS Retourne le nom REEL du compte administrateur local (SID -500).
    .DESCRIPTION
        Le compte admin integre s'appelle 'Administrator' (EN), 'Administrateur'
        (FR), 'Administrador' (ES)... Son SID se termine TOUJOURS par '-500'.
        On resout le nom via le SID pour etre independant de la langue de l'OS.
        Repli : 'Administrator' si la detection echoue.
    #>
    try {
        $admin = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -EA Stop |
            Where-Object { $_.SID -like 'S-1-5-21-*-500' } | Select-Object -First 1
        if ($admin -and $admin.Name) { return $admin.Name }
    } catch {}
    # Repli WMI classique
    try {
        $admin = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" -EA Stop |
            Where-Object { $_.SID -like 'S-1-5-21-*-500' } | Select-Object -First 1
        if ($admin -and $admin.Name) { return $admin.Name }
    } catch {}
    return 'Administrator'
}

function Enable-DeployResume {
    <#
    .SYNOPSIS Arme la reprise (autologon + tache) pour le deploiement en cours.
        Centralise : appele UNE fois au debut de la sequence (phase 2), re-arme
        a chaque reboot. Ecrit aussi un script de secours Reset-PSWinDeploy.ps1.
    #>
    if (Test-IsWinPE) { return }
    try {
        $adminPwd = $null
        try { $adminPwd = Get-Secret -Source vault -Key 'localAdminPassword' } catch { Write-TSLog "Enable-DeployResume : lecture localAdminPassword echouee : $_" -Level WARN }
        $autoOk = $false
        if ($adminPwd) {
            $adminUser = Get-LocalAdminName
            Write-TSLog "Armement autologon (compte : $adminUser)..." -Level INFO
            $autoOk = Set-DeployAutologon -Username $adminUser -Password $adminPwd
            if (-not $autoOk) { Write-TSLog "Set-DeployAutologon a retourne faux -- repli sur tache SYSTEM." -Level WARN }
        } else {
            Write-TSLog "localAdminPassword absent du vault -- autologon non arme (repli tache SYSTEM)." -Level WARN
        }
        # DEUX mecanismes EN MEME TEMPS (comportement eprouve) :
        #  - autologon + RunOnce -> reprise en fenetre visible (si la session ouvre)
        #  - tache planifiee SYSTEM -> filet FIABLE (se declenche au boot, toujours)
        # Le RunOnce peut ne pas se declencher (consomme, timing), donc on GARDE
        # la tache en filet. Le bug de double execution venait d'ailleurs (IndexOf),
        # corrige. La tache et le RunOnce lancent le meme -Resume, idempotent.
        Set-DeployResumeTask | Out-Null
        Write-DeployResetScript   # filet de securite (script de desarmement)
    } catch { Write-TSLog "Enable-DeployResume : $_" -Level WARN }
}

function Write-DeployResetScript {
    <#
    .SYNOPSIS Depose un script de secours Reset-PSWinDeploy.ps1 (sur le disque
        ET sur le Bureau public) qui desarme l'autologon et la reprise. A lancer
        manuellement si le deploiement reboucle ou se bloque.
    #>
    if (Test-IsWinPE) { return }
    $script = @'
# Reset-PSWinDeploy.ps1 -- desarme l'autologon et la reprise PSWinDeploy.
# A lancer en tant qu'administrateur si le deploiement reboucle ou se bloque.
Write-Host "Desarmement de l'autologon et de la reprise PSWinDeploy..." -ForegroundColor Yellow
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
try { Set-ItemProperty $wl -Name 'AutoAdminLogon' -Value '0' -Type String -Force -EA SilentlyContinue } catch {}
try { Remove-ItemProperty $wl -Name 'DefaultPassword' -Force -EA SilentlyContinue } catch {}
$ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
try { Remove-ItemProperty $ro -Name 'PSWinDeployResume' -Force -EA SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue | Out-Null } catch {}
Write-Host "Termine. L'autologon et la reprise sont desactives." -ForegroundColor Green
Write-Host "Pour relancer l'assistant : C:\Deploy\Scripts\Start-Deploy.ps1 -PostInstallWizard" -ForegroundColor Cyan
Read-Host "Appuyez sur Entree pour fermer"
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

function Disable-DeployResume {
    <#
    .SYNOPSIS Desarme la reprise : autologon OFF + RunOnce + tache planifiee
        supprimes. A appeler quand la boucle de reprise est terminee (0 MAJ,
        fin de sequence...) pour ne pas reboucler ni laisser le mdp en clair.
    #>
    if (Test-IsWinPE) { return }
    try {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $wl -Name 'AutoAdminLogon' -Value '0' -Type String -Force -EA SilentlyContinue
        Remove-ItemProperty $wl -Name 'DefaultPassword' -Force -EA SilentlyContinue
        $runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty $runOnce -Name 'PSWinDeployResume' -Force -EA SilentlyContinue
        Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue
        Write-TSLog "Reprise desarmee (autologon + tache supprimes)." -Level INFO
    } catch {}
}

function Set-DeployAutologon {
    <#
    .SYNOPSIS Re-arme l'autologon pour le PROCHAIN boot + lance la reprise en
        fenetre PowerShell VISIBLE via RunOnce.
    .DESCRIPTION
        Permet a la phase 2 de reprendre dans une SESSION interactive (fenetre
        PowerShell visible) apres un reboot, au lieu d'une tache SYSTEM invisible.
        Indispensable pour l'assistant interactif (ShowWizard) et pour voir ce
        qui se passe. On re-arme a CHAQUE reboot tant que la sequence n'est pas
        finie (AutoAdminLogon=1 + AutoLogonCount=1).
    .PARAMETER Username Compte autologon (defaut Administrator).
    .PARAMETER Password Mot de passe du compte (obligatoire pour l'autologon).
    #>
    [CmdletBinding()]
    param(
        [string]$Username = 'Administrator',
        [string]$Password,
        [string]$ResumeScript = 'C:\Deploy\Scripts\Start-Deploy.ps1'
    )
    if (Test-IsWinPE) { return $false }
    try {
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $winlogon -Name 'AutoAdminLogon' -Value '1' -Type String -Force
        Set-ItemProperty $winlogon -Name 'DefaultUserName' -Value $Username -Type String -Force
        if ($Password) { Set-ItemProperty $winlogon -Name 'DefaultPassword' -Value $Password -Type String -Force }
        # AutoLogonCount = 1 : un seul autologon, qu'on re-arme a chaque reboot.
        Set-ItemProperty $winlogon -Name 'AutoLogonCount' -Value 1 -Type DWord -Force
        # RunOnce : lance la reprise en fenetre PowerShell VISIBLE a l'ouverture de session.
        $localSeq = 'C:\Deploy\Runtime\sequence.psd1'
        $runArg = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$ResumeScript`" -Resume"
        if (Test-Path $localSeq -EA SilentlyContinue) { $runArg += " -SequencePath `"$localSeq`"" }
        $runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Set-ItemProperty $runOnce -Name 'PSWinDeployResume' -Value "powershell.exe $runArg" -Type String -Force
        Write-TSLog "Autologon re-arme + reprise en fenetre PowerShell visible (RunOnce)." -Level SUCCESS
        return $true
    } catch {
        Write-TSLog "Set-DeployAutologon erreur : $_" -Level WARN
        return $false
    }
}

function Set-DeployResumeTask {
    <#
    .SYNOPSIS Cree une tache planifiee qui relance la phase 2 au prochain demarrage.
    .DESCRIPTION
        Mecanisme de reprise FIABLE en phase 2 (Windows demarre) : contrairement
        a l'autologon (LogonCount=1, consomme au 1er boot) ou au RunOnce (necessite
        une session), une tache planifiee 'au demarrage' s'execute a CHAQUE boot
        sans dependre d'un logon. On la supprime quand la sequence est terminee.

        La tache tourne en SYSTEM. Pour l'assistant interactif (qui a besoin d'une
        fenetre), on re-arme aussi l'autologon. Mais pour les etapes auto (MAJ,
        apps), la tache SYSTEM suffit et est plus robuste.
    #>
    [CmdletBinding()]
    param([string]$ResumeScript = 'C:\Deploy\Scripts\Start-Deploy.ps1')
    if (Test-IsWinPE) { return $false }  # seulement en phase 2 (Windows)
    try {
        # Chemin de la sequence : TOUJOURS le chemin fixe local (blindage).
        # On n'utilise PAS $SequencePath (variable de module potentiellement vide
        # dans ce scope -> Split-Path plantait avec 'fichier introuvable').
        $seqArg = 'C:\Deploy\Runtime\sequence.psd1'
        # Localiser le script de reprise (plusieurs emplacements possibles).
        if (-not (Test-Path $ResumeScript -EA SilentlyContinue)) {
            $alt = @('C:\Deploy\Scripts\Start-Deploy.ps1', 'C:\Deploy\Start-Deploy.ps1') |
                   Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
            if ($alt) { $ResumeScript = $alt }
            else {
                Write-TSLog "Set-DeployResumeTask : Start-Deploy.ps1 introuvable -- tache non creee (l'autologon prend le relais)." -Level WARN
                return $false
            }
        }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $psExe -EA SilentlyContinue)) { $psExe = 'powershell.exe' }
        # Utiliser l'API native Register-ScheduledTask : gere proprement les
        # arguments avec guillemets (schtasks /TR les cassait -> 'fichier introuvable').
        # La tache attend 45s avant de lancer -Resume : cela laisse l'AUTOLOGON
        # (fenetre PowerShell visible) demarrer en PREMIER et prendre le verrou.
        # La tache SYSTEM ne prend le relais QUE si l'autologon n'a pas demarre
        # (compte admin desactive, pas de session). Ainsi on garde la fenetre
        # visible quand c'est possible, et un filet fiable sinon.
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Sleep -Seconds 45; & '$ResumeScript' -Resume -SequencePath '$seqArg'`""
        try {
            Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue
        } catch {}
        $taskAction    = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
        $taskTrigger   = New-ScheduledTaskTrigger -AtStartup
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $taskSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'PSWinDeployResume' -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force -EA Stop | Out-Null
        Write-TSLog "Tache de reprise creee (PSWinDeployResume, au demarrage, SYSTEM)." -Level SUCCESS
        return $true
    } catch {
        Write-TSLog "Set-DeployResumeTask erreur (non bloquant) : $_" -Level WARN
        return $false
    }
}

function Remove-DeployResumeTask {
    <# .SYNOPSIS Supprime la tache de reprise (sequence terminee). #>
    try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue | Out-Null } catch {}
}

function Set-DeployRunOnce {
    <#
    .SYNOPSIS Enregistre la reprise du deploiement dans RunOnce.
    .DESCRIPTION Au prochain demarrage Windows, Start-Deploy.ps1 sera relance automatiquement.#>
    [CmdletBinding()]
    param([string]$StartDeployPath = 'C:\Deploy\Scripts\Start-Deploy.ps1')
    # Adapter le chemin Start-Deploy selon contexte
    if (-not (Test-Path $StartDeployPath -EA SilentlyContinue)) {
        $StartDeployPath = Join-Path (Get-DeployRoot) 'Scripts\Start-Deploy.ps1'
    }

    # Utiliser la copie locale de la sequence pour la reprise
    $localSeq = Join-Path (Join-Path (Get-DeployRoot) 'Runtime') (Split-Path $SequencePath -Leaf)
    $seqForResume = if (Test-Path $localSeq -EA SilentlyContinue) { $localSeq } else { $SequencePath }
    # Apres reboot, le deploiement reprend depuis C: (Windows installe)
    $resumeScript = if ($StartDeployPath -match '^C:') { $StartDeployPath } else { 'C:\Deploy\Scripts\Start-Deploy.ps1' }
    $resumeSeq    = if ($seqForResume -match '^C:') { $seqForResume } else { 'C:\Deploy\Runtime\' + (Split-Path $SequencePath -Leaf) }
    $cmd = "PowerShell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$resumeScript`" -Resume -SequencePath `"$resumeSeq`""

    # Si l'unattend gere deja la reprise (FirstLogonCommands), ne pas toucher la ruche
    if ($script:UnattendHandlesResume) {
        Write-TSLog "Reprise phase 2 geree par l'unattend (FirstLogonCommands) -- RunOnce offline non necessaire" -Level INFO
        return
    }

    if (Test-IsWinPE) {
        # WinPE : ecrire dans la ruche SOFTWARE offline de W: (le Windows installe)
        # IMPORTANT : manipuler la ruche avec precaution pour eviter la corruption (BSOD)
        $hivePath = 'W:\Windows\System32\config\SOFTWARE'
        if (Test-Path $hivePath -EA SilentlyContinue) {
            $loaded = $false
            try {
                # Charger la ruche -- verifier le succes via le code de sortie
                $loadOut = reg load 'HKLM\OFFLINE_SW' $hivePath 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $loaded = $true
                    $offRunOnce = 'HKLM:\OFFLINE_SW\Microsoft\Windows\CurrentVersion\RunOnce'
                    if (-not (Test-Path $offRunOnce -EA SilentlyContinue)) { New-Item -Path $offRunOnce -Force | Out-Null }
                    Set-ItemProperty -Path $offRunOnce -Name $script:RunOnceName -Value $cmd
                    Write-TSLog "RunOnce (offline W:) configure : $cmd" -Level INFO
                } else {
                    Write-TSLog "reg load SOFTWARE echoue (code $LASTEXITCODE) : $loadOut" -Level WARN
                }
            } catch {
                Write-TSLog "RunOnce offline erreur : $_" -Level WARN
            } finally {
                # TOUJOURS decharger proprement (sinon ruche verrouillee/corrompue)
                if ($loaded) {
                    [gc]::Collect()
                    Start-Sleep -Milliseconds 500
                    $unloadOut = reg unload 'HKLM\OFFLINE_SW' 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        # Retry apres un GC supplementaire
                        [gc]::Collect(); Start-Sleep -Milliseconds 500
                        reg unload 'HKLM\OFFLINE_SW' 2>&1 | Out-Null
                    }
                }
            }
        } else {
            Write-TSLog "Ruche SOFTWARE offline introuvable -- RunOnce non configure" -Level WARN
        }
    } else {
        # Windows demarre : RunOnce du systeme courant
        Set-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceName -Value $cmd
        Write-TSLog "RunOnce configure : $cmd" -Level DEBUG
    }
}

function Remove-DeployRunOnce {
    <#
    .SYNOPSIS Supprime l'entree RunOnce (nettoyage apres deploiement complet).#>
    try {
        Remove-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceName -ErrorAction SilentlyContinue
    } catch {}
}

function Invoke-DeployReboot {
    <#
    .SYNOPSIS Persiste l'etat, configure RunOnce et redemarre.#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$State,
        [int]$DelaySeconds = 5,
        [switch]$NoCopyDeploy,   # diagnostic : sauter Copy-DeployToTarget
        [switch]$NoRunOnce       # diagnostic : sauter Set-DeployRunOnce
    )
    Write-TSLog "=== REBOOT dans $DelaySeconds secondes ===" -Level WARN
    Write-TSLog "Reprise prevue au step : $($State.nextStepId)" -Level WARN

    Save-DeployState -State $State
    # Copier scripts/modules/runtime/vault/state sur W: (deviendra C: apres reboot).
    # UNIQUEMENT en phase 1 (WinPE) : en phase 2, on est deja sur C:, W: n'existe
    # pas, et le state est deja sauve au bon endroit par Save-DeployState.
    if ($NoCopyDeploy) {
        Write-TSLog "Copy-DeployToTarget SAUTE (diagnostic)" -Level WARN
    } elseif (Test-IsWinPE) {
        Copy-DeployToTarget -TargetDrive 'W:'
    }
    if ($NoRunOnce) {
        Write-TSLog "Set-DeployRunOnce SAUTE (diagnostic)" -Level WARN
    } elseif (Test-IsWinPE) {
        # WinPE : reprise via RunOnce/unattend (1er boot)
        Set-DeployRunOnce
    } else {
        # PHASE 2 (Windows demarre) : DOUBLE mecanisme de reprise.
        #  1. AUTOLOGON + RunOnce -> reprise en fenetre PowerShell VISIBLE (pour
        #     voir le deroulement et permettre l'assistant interactif).
        #  2. Tache planifiee SYSTEM -> filet de securite (si l'autologon echoue).
        # On re-arme l'autologon a CHAQUE reboot (AutoLogonCount=1).
        $adminPwd = $null
        try { $adminPwd = Get-Secret -Source vault -Key 'localAdminPassword' } catch {}
        $autoOk = $false
        if ($adminPwd) {
            $adminName = Get-LocalAdminName   # 'Administrateur' en FR, etc.
            Write-TSLog "Autologon avec le compte admin local : $adminName" -Level INFO
            $autoOk = Set-DeployAutologon -Username $adminName -Password $adminPwd
        } else {
            Write-TSLog "localAdminPassword absent du vault -- autologon non arme." -Level WARN
        }
        # DEUX mecanismes EN MEME TEMPS (comportement eprouve qui marchait) :
        #  - autologon (fenetre visible) si l'admin a un mot de passe
        #  - tache planifiee SYSTEM (filet fiable, se declenche au boot)
        # Ils lancent le meme Start-Deploy -Resume (idempotent). Avoir les DEUX
        # garantit la reprise meme si le RunOnce ne se declenche pas.
        $taskOk = Set-DeployResumeTask
        if (-not $autoOk -and -not $taskOk) { Set-DeployRunOnce }
    }

    Write-TSLog "Sauvegarde etat OK -- redemarrage..." -Level WARN
    Start-Sleep -Seconds $DelaySeconds

    # IMPORTANT : en WinPE, utiliser 'wpeutil reboot' (methode standard WinPE)
    # PLUTOT que Restart-Computer -Force. Restart-Computer -Force peut rebooter
    # AVANT que les ecritures disque (BCD, unattend, partitions) soient flushees,
    # laissant le disque dans un etat incoherent -> BSOD au boot AVANT l'OS
    # (pas de logs Windows). C'est exactement le symptome observe.
    # Le test qui boote utilise wpeutil reboot (manuel) et fonctionne.
    if (Test-IsWinPE) {
        # Forcer le flush des ecritures disque avant le reboot
        try {
            Write-TSLog "Flush des ecritures disque avant reboot..." -Level INFO
            # Synchroniser tous les volumes (equivalent d'un sync)
            foreach ($vol in @('S','W','R')) {
                if (Test-Path "${vol}:\" -EA SilentlyContinue) {
                    # Ouvrir/fermer un handle force le flush du cache d'ecriture
                    try { [System.IO.File]::WriteAllText("${vol}:\.flush", '1'); Remove-Item "${vol}:\.flush" -Force -EA SilentlyContinue } catch {}
                }
            }
            Start-Sleep -Seconds 2
        } catch {}
        Write-TSLog "Reboot via wpeutil (methode WinPE standard)" -Level INFO
        & wpeutil.exe reboot
        Start-Sleep -Seconds 30   # laisser le temps au reboot de s'effectuer
    } else {
        Restart-Computer -Force
    }
}

# -----------------------------------------------------------------------------
# EVALUATION DES CONDITIONS
# -----------------------------------------------------------------------------

function Test-StepCondition {
    <#
    .SYNOPSIS Evalue une expression de condition de step.
    .DESCRIPTION
        Supporte les expressions simples :
          {{ metadata.domain != null }}
          {{ env.MODEL == "OptiPlex" }}
          {{ state.rebootCount < 3 }}
        Retourne $true si la condition est remplie (ou si absente).
    #>
    [CmdletBinding()]
    param(
        [string]$Condition,
        [PSCustomObject]$Sequence,
        [PSCustomObject]$State,
        [hashtable]$Context = @{}
    )

    if ([string]::IsNullOrWhiteSpace($Condition)) { return $true }

    try {
        # Substitution des variables {{ ... }}
        $expr = $Condition -replace '\{\{\s*', '' -replace '\s*\}\}', ''

        # Injection des namespaces dans le scope
        $metadata = $Sequence.metadata
        $options  = $Sequence.options
        $env_ctx  = $Context  # evite collision avec $env: PS
        $rb_count = if ($State) { $State.rebootCount } else { 0 }

        # Remplacement syntaxique
        $expr = $expr -replace 'metadata\.', '$metadata.'
        $expr = $expr -replace 'options\.',  '$options.'
        $expr = $expr -replace 'state\.rebootCount', '$rb_count'
        $expr = $expr -replace '!= null',    '-ne $null'
        $expr = $expr -replace '== null',    '-eq $null'
        $expr = $expr -replace '!=',         '-ne'
        $expr = $expr -replace '==',         '-eq'
        $expr = $expr -replace '&&',         '-and'
        $expr = $expr -replace '\|\|',       '-or'

        $result = Invoke-Expression $expr
        Write-TSLog "Condition '$Condition' -> $result" -Level DEBUG
        return [bool]$result
    } catch {
        Write-TSLog "Erreur evaluation condition '$Condition' : $_ -> step ignore" -Level WARN
        return $false
    }
}

# -----------------------------------------------------------------------------
# HANDLERS DE STEPS
# -----------------------------------------------------------------------------

function Invoke-StepFormatDisk {
    param([PSCustomObject]$Step, [PSCustomObject]$Sequence)
    $p = $Step.params

    # Import WIM-Manager si pas encore charge
    $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'WIM-Manager\WIM-Manager.psm1'
    if (Get-Module -Name WIM-Manager -ErrorAction SilentlyContinue) {} else {
        Import-Module $modPath -Force
    }

    # Recuperer diskNumber -- peut etre string "0" depuis PSD1 ou int depuis JSON
    $rawDiskNum = if ($p.PSObject.Properties['diskNumber']) { $p.diskNumber } `
                  elseif ($p.PSObject.Properties['DiskNumber']) { $p.DiskNumber } `
                  else { -1 }
    # Convertir en int (PSD1 peut retourner string)
    $diskNumber = try { [int]$rawDiskNum } catch { -1 }

    # Si -1 ou non specifie : selectionner interactivement
    if ($diskNumber -lt 0) {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DiskSelector\DiskSelector.psm1') -Force -EA SilentlyContinue
        $diskNumber = Select-TargetDisk
    }

    $firmware = if ($p.PSObject.Properties['firmwareType'] -and $p.firmwareType) { $p.firmwareType } `
                elseif ($p.PSObject.Properties['FirmwareType'] -and $p.FirmwareType) { $p.FirmwareType } `
                else { 'UEFI' }

    Write-TSLog "FormatDisk : disque=$diskNumber firmware=$firmware" -Level INFO -StepId $Step.id
    Initialize-DeployDisk -DiskNumber $diskNumber -FirmwareType $firmware -Force | Out-Null
    Write-TSLog "Disque $diskNumber partitionne" -Level SUCCESS -StepId $Step.id
}

function Resolve-DeployPath {
    <# Reecrit un chemin UNC avec l'IP si basculement DNS->IP, et normalise les backslashes. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Resoudre le nom DNS -> IP si necessaire
    if (Get-Command Resolve-PSWDShareHost -EA SilentlyContinue) {
        $Path = Resolve-PSWDShareHost -Path $Path
    }
    # Normaliser les backslashes multiples (ceinture+bretelles)
    $isUnc = $Path.StartsWith('\\')
    # Reduire TOUS les backslashes multiples a un seul
    while ($Path.Contains('\\')) { $Path = $Path.Replace('\\', '\') }
    # Restaurer le prefixe UNC \\ si necessaire
    if ($isUnc -and -not $Path.StartsWith('\\')) {
        $Path = '\' + $Path
    }
    return $Path
}

function Invoke-StepApplyWIM {
    param([PSCustomObject]$Step, [PSCustomObject]$Sequence, [PSCustomObject]$State)
    $p = $Step.params

    $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'WIM-Manager\WIM-Manager.psm1'
    if (-not (Get-Module WIM-Manager -ErrorAction SilentlyContinue)) {
        Import-Module $modPath -Force | Out-Null
    }

    # Lecture s?curis?e des parametres (PSD1 = case insensitive)
    $wimPath = Get-StepParam $Step 'wimPath'
    if ([string]::IsNullOrWhiteSpace($wimPath)) { throw "ApplyWIM : wimPath manquant" }
    # Reecrire le chemin avec l'IP si basculement DNS->IP au montage des partages
    $wimPath = Resolve-DeployPath $wimPath

    $idxRaw = Get-StepParam $Step 'index' -Default 1
    $index  = try { [int]$idxRaw } catch { 1 }
    $target = Get-StepParam $Step 'targetDrive' -Default 'W:'
    if ($target -notmatch '\\$') { $target = $target.TrimEnd(':') + ':\' }

    Write-TSLog "ApplyWIM : $wimPath index=$index -> $target" -Level INFO -StepId $Step.id

    # Selection interactive si index = 0
    if ($index -eq 0) {
        $index = Invoke-WIMIndexSelector -WimPath $wimPath
    }

    Apply-WIMImage -WimPath $wimPath -Index $index -TargetPath $target -Verify | Out-Null

    # Bootloader automatique
    $systemDrive = Get-StepParam $Step 'systemDrive' -Default 'S:'
    $recoveryDrive = Get-StepParam $Step 'recoveryDrive' -Default 'R:'
    $firmware = 'UEFI'
    if ($Sequence.PSObject.Properties['metadata'] -and $Sequence.metadata -and `
        $Sequence.metadata.PSObject.Properties['firmwareType'] -and $Sequence.metadata.firmwareType) {
        $firmware = $Sequence.metadata.firmwareType
    }
    Write-TSLog "Bootloader : $target (system=$systemDrive, recovery=$recoveryDrive, $firmware)" -Level INFO -StepId $Step.id
    Set-WindowsBootloader -WindowsDrive $target -SystemDrive $systemDrive -FirmwareType $firmware -RecoveryDrive $recoveryDrive | Out-Null

    # Mise a jour de l'etat (avec verification d'existence)
    if ($State) {
        if (-not $State.PSObject.Properties['deployedWimPath'])  { $State | Add-Member -NotePropertyName 'deployedWimPath'  -NotePropertyValue '' -Force }
        if (-not $State.PSObject.Properties['windowsDrive'])     { $State | Add-Member -NotePropertyName 'windowsDrive'     -NotePropertyValue '' -Force }
        $State.deployedWimPath = $wimPath
        $State.windowsDrive    = $target
    }
    Write-TSLog "Windows applique sur $target" -Level SUCCESS -StepId $Step.id
}

function Invoke-StepInjectDrivers {
    param([PSCustomObject]$Step, [PSCustomObject]$Sequence)
    $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'WIM-Manager\WIM-Manager.psm1'
    if (-not (Get-Module WIM-Manager -ErrorAction SilentlyContinue)) { Import-Module $modPath -Force | Out-Null }

    $mountOrTarget = Get-StepParam $Step 'targetDrive' -Default 'W:'
    if ($mountOrTarget -notmatch '\\$') { $mountOrTarget = $mountOrTarget.TrimEnd(':') + ':\' }

    $driverPath = Resolve-DeployPath (Get-StepParam $Step 'path')
    if ([string]::IsNullOrWhiteSpace($driverPath)) { throw "InjectDrivers : 'path' manquant" }
    $recurse = [bool](Get-StepParam $Step 'recurse' -Default $false)

    Write-TSLog "InjectDrivers : $driverPath -> $mountOrTarget" -Level INFO -StepId $Step.id
    $dismArgs = @("/Image:$mountOrTarget", '/Add-Driver', "/Driver:$driverPath")
    if ($recurse) { $dismArgs += '/Recurse' }
    Invoke-DISMCommand $dismArgs | Out-Null
}

function Invoke-StepSetLocale {
    param([PSCustomObject]$Step, [PSCustomObject]$Sequence)
    $p      = $Step.params
    $locale = if ($p.locale) { $p.locale } else { $Sequence.metadata.locale }
    $tz     = if ($p.timezone) { $p.timezone } else { $Sequence.metadata.timezone }
    $target = if ($p.targetDrive) { $p.targetDrive } else { 'W:\' }

    # Injection locale dans l'image offline via DISM
    if ($locale) {
        Invoke-DISMCommand @("/Image:$target", '/Set-UILang:{0}' -f $locale) | Out-Null
        Invoke-DISMCommand @("/Image:$target", '/Set-InputLocale:{0}' -f $locale) | Out-Null
    }
    if ($tz) {
        Invoke-DISMCommand @("/Image:$target", '/Set-TimeZone:{0}' -f $tz) | Out-Null
    }
    Write-TSLog "Locale=$locale Timezone=$tz appliques sur $target" -Level SUCCESS
}

function Invoke-StepJoinDomain {
    param([PSCustomObject]$Step, [PSCustomObject]$Sequence)
    $p = $Step.params

    $domain = Get-StepParam $Step 'domain'
    $ou      = Get-StepParam $Step 'ou'
    $newName = Get-StepParam $Step 'newName'
    # Repli sur la config globale (PSWinDeploy.psd1) si les params du step sont vides.
    if ([string]::IsNullOrWhiteSpace($domain) -and (Get-Command Get-PSWinDeployConfig -EA SilentlyContinue)) {
        try { $domain = Get-PSWinDeployConfig -Key 'DomainName' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($ou) -and (Get-Command Get-PSWinDeployConfig -EA SilentlyContinue)) {
        try { $ou = Get-PSWinDeployConfig -Key 'DomainOU' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($domain)) { throw "JoinDomain : 'domain' obligatoire (step ou config DomainName)" }

    # IDEMPOTENCE : si la machine est DEJA jointe au domaine cible, ne rien faire.
    # Indispensable car le step est rejoue apres le reboot de jonction (sinon il
    # echouerait : 'poste deja joint'). On compare le domaine actuel au cible.
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -EA Stop
        if ($cs.PartOfDomain) {
            $currentDomain = "$($cs.Domain)"
            # Comparaison souple : 'corp.local' vs 'CORP' (NetBIOS) vs FQDN.
            $targetShort = ($domain -split '\.')[0]
            $currentShort = ($currentDomain -split '\.')[0]
            if ($currentDomain -ieq $domain -or $currentShort -ieq $targetShort) {
                Write-TSLog "Machine deja jointe au domaine '$currentDomain' -- step JoinDomain saute." -Level SUCCESS -StepId $Step.id
                return @{ Success = $true; RebootRequired = $false; Skipped = $true }
            } else {
                Write-TSLog "Machine jointe a '$currentDomain' mais cible = '$domain' -- on continue." -Level WARN -StepId $Step.id
            }
        }
    } catch {
        Write-TSLog "Verification appartenance domaine impossible : $_ -- on tente la jonction." -Level INFO -StepId $Step.id
    }

    Write-TSLog "JoinDomain (via Add-Computer PowerShell) : $domain" -Level INFO -StepId $Step.id

    # Detecter si on a une SESSION INTERACTIVE (sinon, pas de prompt possible :
    # la tache de reprise tourne en SYSTEM, un Read-Host bloquerait indefiniment).
    $interactive = [Environment]::UserInteractive -and -not ($env:USERNAME -eq "$env:COMPUTERNAME$")

    # -- Compte de jonction : params.username, puis vault --------------------
    $username = Get-StepParam $Step 'username'
    if (-not $username) {
        try { $username = Get-Secret -Source vault -Key 'domainJoinUser' -Label "Compte jonction $domain" } catch {}
    }
    # -- Mot de passe : vault -------------------------------------------------
    $password = $null
    try { $password = Get-Secret -Source vault -Key 'domainJoinPassword' -Label "Mot de passe" } catch {}

    # Si credentials manquants : prompt SEULEMENT si session interactive, sinon
    # echec propre avec message clair (pas de blocage en SYSTEM).
    if (-not $username -or -not $password) {
        if ($interactive) {
            Write-TSLog "Credentials de jonction absents du vault -- saisie interactive." -Level WARN -StepId $Step.id
            if (-not $username) { $username = Read-Host "  Compte de jonction $domain (ex: CORP\svc-join)" }
            if (-not $password) {
                $sec = Read-Host "  Mot de passe pour $username" -AsSecureString
                $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
            }
        } else {
            Write-TSLog "ECHEC jonction : credentials absents du vault et pas de session interactive." -Level ERROR -StepId $Step.id
            Write-TSLog "Ajoutez 'domainJoinUser' et 'domainJoinPassword' dans secrets.vault.psd1." -Level ERROR -StepId $Step.id
            throw "JoinDomain : domainJoinUser / domainJoinPassword absents du vault"
        }
    }

    Write-TSLog "Jonction avec le compte '$username'" -Level INFO -StepId $Step.id
    $secPass = ConvertTo-SecureString $password -AsPlainText -Force
    # Si username contient deja le domaine (CORP\user), l'utiliser tel quel
    $fullUser = if ($username -match '\\') { $username } else { "$domain\$username" }
    $creds   = New-Object PSCredential($fullUser, $secPass)

    $addArgs = @{
        DomainName = $domain
        Credential = $creds
        Force      = $true
    }
    if ($ou)      { $addArgs.OUPath  = $ou }
    if ($newName) { $addArgs.NewName = $newName }

    Add-Computer @addArgs -EA Stop
    Write-TSLog "Jonction domaine '$domain' reussie" -Level SUCCESS -StepId $Step.id
    # Marqueur de double securite : la jonction est faite. Au prochain passage
    # (rejeu eventuel), le step sera saute meme si PartOfDomain tarde a refleter
    # la jonction (DNS/replication AD).
    try {
        $jm = Join-Path (Get-DeployRoot) 'Logs\.domain-joined'
        $jmDir = Split-Path $jm -Parent
        if (-not (Test-Path $jmDir -EA SilentlyContinue)) { New-Item -ItemType Directory $jmDir -Force -EA SilentlyContinue | Out-Null }
        Set-Content -Path $jm -Value "$domain $(Get-Date -Format 'o')" -Encoding UTF8 -EA SilentlyContinue
    } catch {}
    # La jonction necessite un reboot : on le signale explicitement.
    return @{ Success = $true; RebootRequired = $true }
}

function Test-IsWinPE {
    <# Detecte si on s'execute dans WinPE (Windows pas encore demarre). #>
    # WinPE : la cle de registre MiniNT existe, ou pas de C:\Windows installe
    if (Test-Path 'HKLM:\SYSTEM\ControlSet001\Control\MiniNT' -EA SilentlyContinue) { return $true }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' -EA SilentlyContinue) { return $true }
    # Pas de C:\Windows\explorer.exe = pas de Windows complet
    if (-not (Get-PSDrive -Name 'C' -PSProvider FileSystem -EA SilentlyContinue)) { return $true }
    if (-not (Test-Path 'C:\Windows\explorer.exe' -EA SilentlyContinue)) { return $true }
    return $false
}

function Invoke-StepInstallUpdates {
    param([PSCustomObject]$Step)

    # En WinPE, Windows Update n'existe pas -- ce step est DEFERE en phase 2
    if (Test-IsWinPE) {
        Write-TSLog "InstallUpdates defere : sera execute apres le premier demarrage de Windows" -Level INFO -StepId $Step.id
        return @{ Success = $true; RebootRequired = $false; Deferred = $true }
    }

    # Limite de cycles reboot+reprise pour ce step (anti-boucle infinie).
    # Compteur persiste dans un fichier (survit aux reboots).
    $maxPasses = Get-StepParam $Step 'maxPasses' -Default 5
    $passFile = 'C:\Deploy\Logs\.updates-passes'
    $passCount = 0
    try { if (Test-Path $passFile -EA SilentlyContinue) { $passCount = [int](Get-Content $passFile -Raw -EA SilentlyContinue) } } catch {}
    if ($passCount -ge $maxPasses) {
        Write-TSLog "Limite de $maxPasses passes de MAJ atteinte -- on arrete (evite la boucle infinie)." -Level WARN -StepId $Step.id
        try { Remove-Item $passFile -Force -EA SilentlyContinue } catch {}
        return @{ Success = $true; RebootRequired = $false }
    }

    # (L'armement de la reprise est CENTRALISE au niveau de la sequence :
    #  arme une fois au debut de Invoke-TaskSequence, desarme a la fin. Voir
    #  Enable-DeployResume / Disable-DeployResume.)

    # Phase 2 : Windows demarre. API COM native Microsoft.Update (AUCUNE
    # dependance : pas besoin de PSWindowsUpdate ni d'Internet si WSUS configure).
    try {
        Write-TSLog "Recherche des mises a jour (passe $($passCount+1)/$maxPasses)..." -Level INFO -StepId $Step.id
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")

        if (@($result.Updates).Count -eq 0) {
            # 0 MAJ = termine. Nettoyer le compteur, DESARMER la reprise, et
            # passer au step suivant SANS reboot. C'est la condition d'arret.
            Write-TSLog "Aucune mise a jour disponible -- etape MAJ terminee." -Level SUCCESS -StepId $Step.id
            try { Remove-Item $passFile -Force -EA SilentlyContinue } catch {}
            return @{ Success = $true; RebootRequired = $false }
        }
        Write-TSLog "$(@($result.Updates).Count) mise(s) a jour trouvee(s)" -Level INFO -StepId $Step.id

        # Telecharger
        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $result.Updates) {
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
            [void]$toDownload.Add($u)
            Write-TSLog "  + $($u.Title)" -Level INFO -StepId $Step.id
        }
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        [void]$downloader.Download()

        # Installer
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $result.Updates) { if ($u.IsDownloaded) { [void]$toInstall.Add($u) } }
        if (@($toInstall).Count -eq 0) {
            Write-TSLog "Aucune mise a jour telechargee." -Level WARN -StepId $Step.id
            return @{ Success = $true; RebootRequired = $false }
        }
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult = $installer.Install()
        Write-TSLog "Installation terminee (code $($installResult.ResultCode), 2=succes)" -Level SUCCESS -StepId $Step.id
        if ($installResult.RebootRequired) {
            # Incrementer le compteur de passes (persiste pour la reprise).
            try {
                $pf = 'C:\Deploy\Logs\.updates-passes'
                $pc = 0; if (Test-Path $pf -EA SilentlyContinue) { $pc = [int](Get-Content $pf -Raw -EA SilentlyContinue) }
                Set-Content $pf -Value ($pc + 1) -Force -EA SilentlyContinue
            } catch {}
            Write-TSLog "Un redemarrage est requis -- le step MAJ reprendra apres le reboot pour une nouvelle passe." -Level WARN -StepId $Step.id
            $script:RebootRequired = $true
            # IMPORTANT : ne PAS marquer le step comme termine -> il sera rejoue
            # apres reboot pour chercher d'autres MAJ. On signale 'StayOnStep'.
            return @{ Success = $true; RebootRequired = $true; StayOnStep = $true }
        }
        # Pas de reboot requis : il peut rester des MAJ a installer immediatement.
        # On RE-boucle dans le meme step (sans reboot) jusqu'a 0 MAJ.
        try {
            $pf = 'C:\Deploy\Logs\.updates-passes'
            $pc = 0; if (Test-Path $pf -EA SilentlyContinue) { $pc = [int](Get-Content $pf -Raw -EA SilentlyContinue) }
            Set-Content $pf -Value ($pc + 1) -Force -EA SilentlyContinue
        } catch {}
        Write-TSLog "Passe de MAJ installee sans reboot -- nouvelle recherche..." -Level INFO -StepId $Step.id
        return (Invoke-StepInstallUpdates -Step $Step)
    } catch {
        Write-TSLog "Windows Update (API native) a echoue : $_" -Level WARN -StepId $Step.id
        return @{ Success = $false; RebootRequired = $false }
    }
}

function Invoke-StepInstallSoftware {
    param([PSCustomObject]$Step)
    $p = $Step.params

    # Format 'catalogApps' : objets riches du catalogue (WingetId/ChocoId/Installer).
    # CASCADE par app selon ce qui est declare : winget -> choco -> exe/msi.
    $catalogApps = Get-StepParam $Step 'catalogApps'
    $softwareShare0 = Get-StepParam $Step 'softwareShare' -Default ''
    # Helper : lire une cle d'une app (hashtable OU objet) sans planter en StrictMode.
    $gv = {
        param($obj, $key)
        if ($null -eq $obj) { return $null }
        if ($obj -is [hashtable] -or $obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return $obj[$key] } else { return $null }
        }
        $p = $obj.PSObject.Properties[$key]
        if ($p) { return $p.Value } else { return $null }
    }
    # Option : forcer winget et NE PAS basculer sur choco (NoChoco / PreferWinget).
    $noChoco = [bool](Get-StepParam $Step 'noChoco' -Default $false)
    # Initialiser winget UNE fois (enregistre App Installer, verifie qu'il repond).
    # Ainsi winget fonctionne en deploiement au lieu d'echouer (0xC0000135).
    $wingetReady = $false
    if (Get-Command Initialize-Winget -EA SilentlyContinue) { $wingetReady = Initialize-Winget }

    if ($catalogApps) {
        foreach ($app in @($catalogApps)) {
            $nm = & $gv $app 'Name'; if (-not $nm) { $nm = 'app' }
            $wingetId = & $gv $app 'WingetId'
            $chocoId  = & $gv $app 'ChocoId'
            $installer = & $gv $app 'Installer'
            $appArgs  = & $gv $app 'Args'
            Write-TSLog "Installation : $nm" -Level INFO -StepId $Step.id
            $ok = $false

            # 1) winget (si WingetId declare). winget est natif Windows et
            # prioritaire. On le cherche meme hors PATH (Resolve-WingetPath).
            if (-not $ok -and $wingetId) {
                $wg = Resolve-WingetPath
                if ($wg) {
                    Write-TSLog "  Tentative winget : $wingetId ($wg)" -Level INFO -StepId $Step.id
                    try {
                        # Commande SIMPLE d'abord (exactement comme en terminal, ce
                        # qui marche). La sortie est capturee pour diagnostic.
                        $wgOut = & $wg install --id $wingetId --silent --accept-package-agreements --accept-source-agreements 2>&1
                        if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TSLog "  winget OK : $nm" -Level SUCCESS -StepId $Step.id }
                        else {
                            # Repli : forcer le scope machine (utile en contexte deploiement)
                            $wgOut2 = & $wg install --id $wingetId --scope machine --silent --accept-package-agreements --accept-source-agreements 2>&1
                            if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TSLog "  winget OK (scope machine) : $nm" -Level SUCCESS -StepId $Step.id }
                            else { Write-TSLog "  winget echec (code $LASTEXITCODE) : $($wgOut2 | Select-Object -Last 1) -- repli choco" -Level WARN -StepId $Step.id }
                        }
                    } catch { Write-TSLog "  winget erreur : $_ -- repli choco si dispo" -Level WARN -StepId $Step.id }
                } else {
                    Write-TSLog "  winget introuvable sur ce poste -- repli choco si dispo" -Level INFO -StepId $Step.id
                }
            }
            # 2) choco (si ChocoId declare et si choco autorise) -- installer si absent
            if ($noChoco -and -not $ok -and $chocoId) {
                Write-TSLog "  choco desactive (noChoco) -- $nm non installe via choco" -Level WARN -StepId $Step.id
            }
            if (-not $noChoco -and -not $ok -and $chocoId -and -not (Get-Command choco -EA SilentlyContinue)) { Install-Chocolatey | Out-Null }
            if (-not $noChoco -and -not $ok -and $chocoId -and (Get-Command choco -EA SilentlyContinue)) {
                try {
                    & choco install $chocoId -y --no-progress 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TSLog "  choco OK : $nm" -Level SUCCESS -StepId $Step.id }
                } catch {}
            }
            # 3) exe/msi (si Installer declare) sur le partage Logiciels
            if (-not $ok -and $installer -and $softwareShare0) {
                $inst = $null
                $direct = Join-Path $softwareShare0 $installer
                if (Test-Path $direct -EA SilentlyContinue) { $inst = $direct }
                else {
                    $f = @(Get-ChildItem $softwareShare0 -Recurse -Filter $installer -EA SilentlyContinue | Select-Object -First 1)
                    if ($f.Count -gt 0) { $inst = $f[0].FullName }
                }
                if ($inst) {
                    $ext  = [System.IO.Path]::GetExtension($inst).ToLower()
                    $iArgs = if ($appArgs) { $appArgs } elseif ($ext -eq '.msi') { '/quiet /norestart' } else { '/S' }
                    Write-TSLog "  Installeur : $inst ($iArgs)" -Level INFO -StepId $Step.id
                    try {
                        $proc = if ($ext -eq '.msi') {
                            Start-Process msiexec.exe -ArgumentList "/i `"$inst`" $iArgs" -Wait -PassThru
                        } else {
                            Start-Process $inst -ArgumentList $iArgs -Wait -PassThru
                        }
                        if ($proc.ExitCode -in @(0,3010)) {
                            $ok = $true; Write-TSLog "  exe/msi OK : $nm (code $($proc.ExitCode))" -Level SUCCESS -StepId $Step.id
                            if ($proc.ExitCode -eq 3010) { $script:RebootRequired = $true }
                        } else { Write-TSLog "  exe/msi code $($proc.ExitCode) : $nm" -Level WARN -StepId $Step.id }
                    } catch { Write-TSLog "  exe/msi erreur : $_" -Level WARN -StepId $Step.id }
                } else {
                    Write-TSLog "  Installeur '$installer' introuvable sur $softwareShare0" -Level WARN -StepId $Step.id
                }
            }

            # RebootAfter declare au niveau de l'app
            $appReboot = & $gv $app 'RebootAfter'
            if ($ok -and $appReboot -and "$appReboot".ToLower() -eq 'always') {
                $script:RebootRequired = $true
            }
            if (-not $ok) { Write-TSLog "ECHEC installation : $nm" -Level WARN -StepId $Step.id }
        }
        return
    }

    # Format simple 'apps' : liste de NOMS. Pour chaque nom, on cherche d'abord
    # ses details dans le CATALOGUE (CataloguePath du psd1) : ainsi on peut juste
    # ecrire apps = @('Google Chrome') sans repeter WingetId/ChocoId/Installer.
    # Si le nom n'est pas dans le catalogue, il est traite comme un WingetId direct.
    $apps = Get-StepParam $Step 'apps'
    if ($apps) {
        # Charger le catalogue (une fois) pour resoudre les noms -> objets riches.
        $catalogIndex = @{}
        try {
            $catPath = $null
            if (Get-Command Get-PSWinDeployConfig -EA SilentlyContinue) {
                try { $catPath = Get-PSWinDeployConfig -Key 'CataloguePath' } catch {}
            }
            $catCandidates = @()
            if ($catPath) {
                if ($catPath -match '\.psd1$') { $catCandidates += $catPath }
                else { $catCandidates += (Join-Path $catPath 'applications.psd1'); $catCandidates += (Join-Path $catPath 'catalogue.psd1') }
            }
            $catCandidates += 'C:\Deploy\Catalogue\applications.psd1'
            foreach ($cc in $catCandidates) {
                if ($cc -and (Test-Path $cc -EA SilentlyContinue)) {
                    $catData = Import-PowerShellDataFile $cc -EA Stop
                    $appList = if ($catData.Applications) { $catData.Applications } else { $catData }
                    foreach ($ca in @($appList)) {
                        $caName = & $gv $ca 'Name'
                        if ($caName) { $catalogIndex["$caName".ToLower()] = $ca }
                    }
                    Write-TSLog "Catalogue charge pour resolution par nom : $($catalogIndex.Count) app(s)" -Level INFO -StepId $Step.id
                    break
                }
            }
        } catch { Write-TSLog "Lecture catalogue (resolution par nom) : $_" -Level DEBUG -StepId $Step.id }

        # Si une app nommee est dans le catalogue -> on la traite via la cascade
        # riche (comme catalogApps). Sinon -> WingetId direct (comportement actuel).
        $resolvedFromCatalog = @()
        $plainNames = @()
        foreach ($app in @($apps)) {
            $key = "$app".ToLower()
            if ($catalogIndex.ContainsKey($key)) { $resolvedFromCatalog += $catalogIndex[$key] }
            else { $plainNames += "$app" }
        }
        # Traiter les apps resolues du catalogue via le meme moteur que catalogApps
        if ($resolvedFromCatalog.Count -gt 0) {
            $subStep = [PSCustomObject]@{ id = $Step.id; params = @{ catalogApps = $resolvedFromCatalog; softwareShare = (Get-StepParam $Step 'softwareShare' -Default '') } }
            Invoke-StepInstallSoftware -Step $subStep | Out-Null
        }
        # Continuer avec les noms non trouves (traites comme WingetId direct)
        $apps = $plainNames
    }
    if ($apps) {
        # Partage Logiciels (pour le repli exe/msi) : <serveur>\Logiciels
        $softwareShare = Get-StepParam $Step 'softwareShare' -Default ''
        foreach ($app in @($apps)) {
            $appName = "$app"
            Write-TSLog "Installation app : $appName" -Level INFO -StepId $Step.id
            $ok = $false

            # 1) winget (cherche meme hors PATH, --scope machine pour le deploiement)
            $wg = Resolve-WingetPath
            if (-not $ok -and $wg) {
                try {
                    $out = & $wg install --id $appName --silent --accept-package-agreements --accept-source-agreements 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $out = & $wg install --id $appName --scope machine --silent --accept-package-agreements --accept-source-agreements 2>&1
                    }
                    if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TSLog "  winget OK : $appName" -Level SUCCESS -StepId $Step.id }
                    else { Write-TSLog "  winget n'a pas installe $appName (code $LASTEXITCODE) : $($out | Select-Object -Last 1), essai suivant" -Level INFO -StepId $Step.id }
                } catch { Write-TSLog "  winget erreur : $_" -Level INFO -StepId $Step.id }
            }

            # 2) chocolatey -- installer si absent
            if (-not $ok -and -not (Get-Command choco -EA SilentlyContinue)) { Install-Chocolatey | Out-Null }
            if (-not $ok -and (Get-Command choco -EA SilentlyContinue)) {
                try {
                    & choco install $appName -y --no-progress 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TSLog "  choco OK : $appName" -Level SUCCESS -StepId $Step.id }
                    else { Write-TSLog "  choco n'a pas installe $appName (code $LASTEXITCODE), essai suivant" -Level INFO -StepId $Step.id }
                } catch { Write-TSLog "  choco erreur : $_" -Level INFO -StepId $Step.id }
            }

            # 3) exe/msi sur le partage Logiciels (cherche un fichier au nom de l'app)
            if (-not $ok -and $softwareShare -and (Test-Path $softwareShare -EA SilentlyContinue)) {
                $found = @(Get-ChildItem $softwareShare -Recurse -Include '*.exe','*.msi' -EA SilentlyContinue |
                           Where-Object { $_.BaseName -like "*$appName*" } | Select-Object -First 1)
                if ($found.Count -gt 0) {
                    $inst = $found[0].FullName
                    $ext  = $found[0].Extension.ToLower()
                    Write-TSLog "  Installeur local trouve : $inst" -Level INFO -StepId $Step.id
                    try {
                        $proc = if ($ext -eq '.msi') {
                            Start-Process msiexec.exe -ArgumentList "/i `"$inst`" /quiet /norestart" -Wait -PassThru
                        } else {
                            Start-Process $inst -ArgumentList '/S /quiet /norestart' -Wait -PassThru
                        }
                        if ($proc.ExitCode -in @(0, 3010)) {
                            $ok = $true
                            Write-TSLog "  exe/msi OK : $appName (code $($proc.ExitCode))" -Level SUCCESS -StepId $Step.id
                            if ($proc.ExitCode -eq 3010) { $script:RebootRequired = $true }
                        } else {
                            Write-TSLog "  exe/msi code $($proc.ExitCode) pour $appName" -Level WARN -StepId $Step.id
                        }
                    } catch { Write-TSLog "  exe/msi erreur : $_" -Level WARN -StepId $Step.id }
                } else {
                    Write-TSLog "  Aucun installeur pour '$appName' sur $softwareShare" -Level INFO -StepId $Step.id
                }
            }

            if (-not $ok) {
                Write-TSLog "ECHEC : impossible d'installer $appName (winget/choco/exe-msi tous indispo ou en echec)" -Level WARN -StepId $Step.id
            }
        }
        return
    }

    # Format avance 'packages' : objets avec installer/source
    $packages = Get-StepParam $Step 'packages'
    $source   = Resolve-DeployPath (Get-StepParam $Step 'source' -Default '')
    if (-not $packages) {
        Write-TSLog "InstallSoftware : aucun package specifie" -Level WARN -StepId $Step.id
        return
    }
    foreach ($pkg in @($packages)) {
        $installer = Join-Path $source $pkg.installer
        if (-not (Test-Path $installer)) {
            Write-TSLog "Installeur introuvable : $installer" -Level WARN
            if ($Step.continueOnError) { continue } else { throw "Installeur manquant : $installer" }
        }

        Write-TSLog "Installation : $($pkg.name)" -Level INFO
        $ext  = [System.IO.Path]::GetExtension($installer).ToLower()
        $args = if ($pkg.args) { $pkg.args } else { '/quiet /norestart' }

        $proc = switch ($ext) {
            '.msi'  { Start-Process msiexec.exe -ArgumentList "/i `"$installer`" $args" -Wait -PassThru }
            '.exe'  { Start-Process $installer  -ArgumentList $args -Wait -PassThru }
            '.msp'  { Start-Process msiexec.exe -ArgumentList "/p `"$installer`" $args" -Wait -PassThru }
            default { throw "Extension non geree : $ext" }
        }

        $exitCode = $proc.ExitCode
        Write-TSLog "$($pkg.name) -- exit code : $exitCode" -Level INFO

        if ($exitCode -in @($script:ExitRebootRequired, $script:ExitRebootInitiated)) {
            Write-TSLog "$($pkg.name) requiert un reboot" -Level WARN
            $script:RebootRequired = $true
        } elseif ($exitCode -ne 0) {
            $msg = "Echec installation $($pkg.name) (exit $exitCode)"
            if ($Step.continueOnError -or $pkg.continueOnError) {
                Write-TSLog $msg -Level WARN
            } else {
                throw $msg
            }
        } else {
            Write-TSLog "$($pkg.name) installe" -Level SUCCESS
        }
    }
}

function Invoke-StepCleanup {
    <#
    .SYNOPSIS Nettoyage de fin de deploiement : supprime les fichiers sensibles
        de C:\Deploy (vault, config, scripts...), conserve C:\Deploy\Logs.
    .DESCRIPTION
        A mettre en DERNIER step d'une sequence (RebootAfter='Never'). Supprime
        le vault (credentials !), la config, les modules, scripts, runtime, state.
        Garde uniquement les logs pour tracabilite. Peut aussi supprimer la tache
        de reprise.
    #>
    param([PSCustomObject]$Step)
    Write-TSLog "Nettoyage de fin de deploiement (C:\Deploy)..." -Level STEP -StepId $Step.id
    $keepLogs = Get-StepParam $Step 'keepLogs' -Default $true
    $root = 'C:\Deploy'
    if (-not (Test-Path $root)) { return @{ Success = $true } }
    # Desarmer la reprise (autologon + tache) et retirer le script de secours.
    if (Get-Command Disable-DeployResume -EA SilentlyContinue) { Disable-DeployResume }
    try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue | Out-Null } catch {}
    try { Remove-Item "$env:PUBLIC\Desktop\Reset-PSWinDeploy.ps1" -Force -EA SilentlyContinue } catch {}
    # Nettoyer les marqueurs internes (jonction, step en cours, passes MAJ)
    foreach ($mk in @('.domain-joined','.current-step','.updates-passes')) {
        try { Remove-Item (Join-Path $root "Logs\$mk") -Force -EA SilentlyContinue } catch {}
    }
    # Elements a supprimer (sensibles ou inutiles apres deploiement)
    $toRemove = @('secrets.vault.psd1','secrets.vault','deploy-config.psd1','PSWinDeploy.psd1','state.psd1','Scripts','Modules','Runtime')
    foreach ($item in $toRemove) {
        $p = Join-Path $root $item
        if (Test-Path $p -EA SilentlyContinue) {
            try { Remove-Item $p -Recurse -Force -EA SilentlyContinue; Write-TSLog "  Supprime : $item" -Level INFO -StepId $Step.id } catch {}
        }
    }
    if (-not $keepLogs) {
        try { Remove-Item (Join-Path $root 'Logs') -Recurse -Force -EA SilentlyContinue } catch {}
    } else {
        Write-TSLog "  Logs conserves : C:\Deploy\Logs" -Level INFO -StepId $Step.id
    }
    Write-TSLog "Nettoyage termine." -Level SUCCESS -StepId $Step.id
    return @{ Success = $true; RebootRequired = $false }
}

function Invoke-StepShowWizard {
    <#
    .SYNOPSIS Ouvre l'assistant post-installation (menu principal) depuis une
        sequence. Permet : derouler une sequence PUIS proposer l'assistant pour
        continuer (apps/scripts/MAJ a la volee).
    .DESCRIPTION
        Lance Start-Deploy.ps1 -PostInstallWizard dans une fenetre visible.
        A utiliser comme step (souvent en fin de sequence) quand on veut laisser
        l'operateur ajouter des actions apres les steps automatiques.
    #>
    param([PSCustomObject]$Step)
    Write-TSLog "Ouverture de l'assistant post-installation (depuis la sequence)..." -Level STEP -StepId $Step.id
    $selfPath = 'C:\Deploy\Scripts\Start-Deploy.ps1'
    if (-not (Test-Path $selfPath)) { Write-TSLog "Start-Deploy introuvable pour l'assistant" -Level WARN -StepId $Step.id; return @{ Success = $false } }
    # SUIVI : signaler "en attente d'une action utilisateur" pendant que
    # l'assistant interactif est ouvert (le deploiement est en pause cote
    # operateur). Best effort, silencieux si l'API est injoignable.
    if (Get-Command Send-DeployReport -EA SilentlyContinue) {
        Send-DeployReport -Status 'waiting' -Step $Step.id -Percent 0 -Message 'En attente d''une action utilisateur (assistant ouvert)'
    }
    try {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$selfPath`"", '-PostInstallWizard') -Wait
        # L'operateur a termine : on repasse en cours d'execution.
        if (Get-Command Send-DeployReport -EA SilentlyContinue) {
            Send-DeployReport -Status 'running' -Step $Step.id -Percent 100 -Message 'Action utilisateur terminee (assistant ferme)'
        }
        return @{ Success = $true }
    } catch {
        Write-TSLog "Lancement assistant echoue : $_" -Level WARN -StepId $Step.id
        return @{ Success = $false }
    }
}

function Initialize-Winget {
    <#
    .SYNOPSIS Prepare winget pour qu'il fonctionne en deploiement : enregistre
        le package App Installer pour l'utilisateur courant et verifie que winget
        repond. Retourne $true si winget est utilisable.
    .DESCRIPTION
        Sur une image fraiche, le package Microsoft.DesktopAppInstaller est
        provisionne mais pas toujours ENREGISTRE pour le compte courant, ce qui
        fait echouer winget (0xC0000135 DLL introuvable). On l'enregistre, on
        rafraichit le PATH, puis on teste 'winget --version'.
    #>
    # Deja fonctionnel ?
    $wg = Resolve-WingetPath
    if ($wg) {
        try { $v = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { return $true } } catch {}
    }
    Write-TSLog "Initialisation de winget (enregistrement App Installer)..." -Level INFO
    try {
        # Enregistrer le package App Installer pour l'utilisateur courant
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
            if (Test-Path $manifest -EA SilentlyContinue) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -EA SilentlyContinue
            }
        } else {
            # Tenter de provisionner depuis le package provisionne (machine)
            $prov = Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' } | Select-Object -First 1
            if ($prov) { Add-AppxPackage -Register $prov.InstallLocation -DisableDevelopmentMode -EA SilentlyContinue }
        }
        # Rafraichir le PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        Start-Sleep -Seconds 2
        $wg = Resolve-WingetPath
        if ($wg) {
            try { $v = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { Write-TSLog "winget pret : $v" -Level SUCCESS; return $true } } catch {}
        }
        Write-TSLog "winget toujours indisponible apres initialisation." -Level WARN
    } catch {
        Write-TSLog "Initialisation winget echouee : $_" -Level WARN
    }
    return $false
}

function Resolve-WingetPath {
    <#
    .SYNOPSIS Retourne le chemin de winget.exe, meme s'il n'est pas dans le PATH.
    .DESCRIPTION
        winget est souvent un App Execution Alias dans WindowsApps, pas toujours
        present dans le PATH du process (surtout en SYSTEM ou juste apres install).
        On le cherche dans l'ordre : commande PATH, puis le vrai binaire sous
        Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*. Retourne le
        chemin utilisable, ou $null si introuvable.
    #>
    # PRIORITE 1 : 'winget' dans le PATH (alias d'execution utilisateur) -- c'est
    # ce qui fonctionne en terminal. On le retourne tel quel.
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
    # PRIORITE 2 : l'alias d'execution dans le profil utilisateur courant. C'est
    # le bon point d'entree (le binaire brut WindowsApps echoue souvent : DLL
    # introuvable / 0xC0000135).
    $userAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $userAlias -EA SilentlyContinue) { return $userAlias }
    # PRIORITE 3 (dernier recours) : le binaire brut hors PATH (la version recente)
    $base = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path $base -EA SilentlyContinue) {
        $candidate = Get-ChildItem $base -Filter 'Microsoft.DesktopAppInstaller_*' -Directory -EA SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
            Where-Object { Test-Path $_ -EA SilentlyContinue } |
            Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    return $null
}

function Install-Chocolatey {
    <#
    .SYNOPSIS Installe Chocolatey si absent. Retourne $true si dispo apres coup.
    .DESCRIPTION
        Telecharge et installe choco depuis le depot officiel. Necessite Internet
        (ou un depot interne configure). Apres installation, choco est disponible
        dans la session via rafraichissement du PATH.
    #>
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    Write-TSLog "Chocolatey absent -- installation..." -Level INFO
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        $script = (New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
        Invoke-Expression $script 2>&1 | Out-Null
        # Rafraichir le PATH de la session
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        $choco = "$env:ProgramData\chocolatey\bin"
        if ((Test-Path $choco) -and ($env:Path -notlike "*$choco*")) { $env:Path += ";$choco" }
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-TSLog "Chocolatey installe (PATH rafraichi dans la session, pas de reboot)." -Level SUCCESS
            # PAS de reboot : choco fonctionne immediatement, le PATH est deja
            # rafraichi ci-dessus. Forcer un reboot ici cassait la sequence en cours.
            return $true
        }
    } catch {
        Write-TSLog "Installation Chocolatey echouee : $_" -Level WARN
    }
    return $false
}

function Test-PendingReboot {
    <#
    .SYNOPSIS Detecte si Windows a un redemarrage en attente (pending reboot).
    Permet de rattraper un script qui a demande/declenche un reboot sans le
    signaler proprement (ex: Restart-Computer, ou une install qui pose le flag).
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k -EA SilentlyContinue) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) { return $true }
    return $false
}

function Invoke-StepRunScript {
    param([PSCustomObject]$Step)
    $path     = Get-StepParam $Step 'path'
    $scrArgs  = Get-StepParam $Step 'args' -Default ''
    $shell    = Get-StepParam $Step 'shell' -Default 'PowerShell'

    if ([string]::IsNullOrWhiteSpace($path)) { throw "RunScript : 'path' manquant" }
    $path = Resolve-DeployPath $path
    if (-not (Test-Path $path -EA SilentlyContinue)) { throw "Script introuvable : $path" }

    Write-TSLog "RunScript : $path" -Level INFO -StepId $Step.id

    $proc = switch ($shell) {
        'PowerShell' {
            # NEUTRALISER Restart-Computer / shutdown DANS le script : on prepend
            # une redefinition qui transforme un reboot direct en 'exit 3010'.
            # Ainsi, meme un script qui fait Restart-Computer -Force NE reboote PAS
            # tout seul -- il rend la main avec 3010, et c'est le MOTEUR qui gere
            # le reboot + la reprise proprement (pas de boucle, pas de perte d'etat).
            $guard = @'
function Restart-Computer { param([switch]$Force,[string]$ComputerName,[int]$Delay,[switch]$Wait,[Parameter(ValueFromRemainingArguments=$true)]$Rest) Write-Host '[PSWinDeploy] Restart-Computer intercepte -> signal reboot au moteur (exit 3010)'; exit 3010 }
function Stop-Computer  { param([switch]$Force,[Parameter(ValueFromRemainingArguments=$true)]$Rest) Write-Host '[PSWinDeploy] Stop-Computer intercepte (ignore en phase 2)'; exit 0 }
$__shutdownExe = "$env:SystemRoot\System32\shutdown.exe"
function shutdown { Write-Host '[PSWinDeploy] shutdown intercepte -> signal reboot au moteur (exit 3010)'; exit 3010 }
'@
            # Ecrire un wrapper temporaire : guard + appel du script reel.
            $wrap = Join-Path $env:TEMP "pswd-runscript-$([guid]::NewGuid().ToString('N')).ps1"
            $pathEsc = $path.Replace("'", "''")
            $callLine = "& '" + $pathEsc + "' " + $scrArgs
            $wrapContent = $guard + "`r`n" + $callLine + "`r`nexit `$LASTEXITCODE"
            Set-Content -Path $wrap -Value $wrapContent -Encoding UTF8
            try {
                Start-Process powershell.exe `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$wrap`"" `
                    -Wait -PassThru
            } finally {
                Remove-Item $wrap -Force -EA SilentlyContinue
            }
        }
        'CMD' {
            # En CMD, on ne peut pas neutraliser shutdown aussi finement, mais on
            # detectera un pending reboot apres coup (voir plus bas).
            Start-Process cmd.exe -ArgumentList "/c `"$path`" $scrArgs" -Wait -PassThru
        }
        default { throw "Shell non supporte : $shell" }
    }

    if ($proc.ExitCode -in @($script:ExitRebootRequired, $script:ExitRebootInitiated)) {
        Write-TSLog "Script demande un reboot (exit $($proc.ExitCode)) -> gere par le moteur" -Level INFO -StepId $Step.id
        $script:RebootRequired = $true
    } elseif ($proc.ExitCode -ne 0) {
        $msg = "Script $path termine avec exit $($proc.ExitCode)"
        if ($Step.continueOnError) { Write-TSLog $msg -Level WARN }
        else { throw $msg }
    }

    # FILET DE SECURITE : meme si le script n'a pas retourne 3010, si Windows a
    # un reboot en attente (install, Restart-Computer en CMD...), on le gere.
    if (-not $script:RebootRequired -and (Test-PendingReboot)) {
        Write-TSLog "Reboot en attente detecte apres le script -> gere par le moteur" -Level INFO -StepId $Step.id
        $script:RebootRequired = $true
    }
}

function Invoke-StepCopyFiles {
    param([PSCustomObject]$Step)
    $p = $Step.params
    if (-not (Test-Path (Split-Path $p.dest -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path $p.dest -Parent) -Force | Out-Null
    }
    Copy-Item $p.source $p.dest -Recurse -Force
    Write-TSLog "Copie : $($p.source) -> $($p.dest)" -Level SUCCESS
}

function Invoke-StepSetRegistry {
    param([PSCustomObject]$Step)
    $p = $Step.params
    $regPath = Split-Path $p.key -Parent
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $type = if ($p.type) { $p.type } else { 'String' }
    Set-ItemProperty -Path $regPath -Name (Split-Path $p.key -Leaf) -Value $p.value -Type $type
    Write-TSLog "Registre : $($p.key) = $($p.value)" -Level SUCCESS
}

function Invoke-StepWaitForNetwork {
    param([PSCustomObject]$Step)
    $timeout = if ($Step.params.timeoutSec) { $Step.params.timeoutSec } else { 60 }
    $elapsed = 0
    Write-TSLog "Attente reseau (max ${timeout}s)..." -Level INFO
    while ($elapsed -lt $timeout) {
        # Get-NetAdapter absent en WinPE -- WMI ou ipconfig
        $netOk = $false
        try {
            $adapters = Get-WmiObject Win32_NetworkAdapter -EA SilentlyContinue |
                        Where-Object { $_.NetConnectionStatus -eq 2 -and $_.PhysicalAdapter -eq $true }
            if ($adapters) { $netOk = $true; Write-TSLog "Reseau : $($adapters[0].Name)" -Level SUCCESS }
        } catch {}
        if (-not $netOk) {
            $ip = & ipconfig 2>&1 | Out-String
            if ($ip -match 'IPv4') { $netOk = $true; Write-TSLog "Reseau actif (IPv4)" -Level SUCCESS }
        }
        if ($netOk) { return }
        Start-Sleep 5
        $elapsed += 5
        Write-TSLog "  Attente... ${elapsed}s/${timeout}s" -Level DEBUG
    }
    throw "Reseau non disponible apres ${timeout}s"
}

# -----------------------------------------------------------------------------
# DISPATCHER PRINCIPAL
# -----------------------------------------------------------------------------

function Invoke-DeployStep {
    <#
    .SYNOPSIS Execute un step selon son type.
    .OUTPUTS $true = succes, $false = erreur geree (continueOnError)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Step,
        [Parameter(Mandatory)]
        [PSCustomObject]$Sequence,
        [PSCustomObject]$State
    )

    $script:RebootRequired = $false

    Write-TSLog "--- $($Step.name) [$($Step.type)]" -Level STEP -StepId $Step.id

    try {
        switch ($Step.type) {
            'FormatDisk'      { Invoke-StepFormatDisk     -Step $Step -Sequence $Sequence | Out-Null }
            'ApplyWIM'        { Invoke-StepApplyWIM        -Step $Step -Sequence $Sequence -State $State | Out-Null }
            'InjectDrivers'   { Invoke-StepInjectDrivers   -Step $Step -Sequence $Sequence | Out-Null }
            'SetLocale'       { Invoke-StepSetLocale       -Step $Step -Sequence $Sequence | Out-Null }
            'JoinDomain'      { Invoke-StepJoinDomain      -Step $Step -Sequence $Sequence | Out-Null }
            'InstallUpdates'  { Invoke-StepInstallUpdates  -Step $Step | Out-Null }
            'InstallSoftware' { Invoke-StepInstallSoftware -Step $Step | Out-Null }
            'InstallApps'     { Invoke-StepInstallSoftware -Step $Step | Out-Null }
            'ApplyUnattend'   {
                # Generer et ecrire un unattend.xml sur la partition Windows
                $umod = Join-Path (Split-Path $PSScriptRoot -Parent) 'Unattend\Unattend.psm1'
                if (Test-Path $umod -EA SilentlyContinue) { Import-Module $umod -Force | Out-Null }
                $target = Get-StepParam $Step 'targetDrive' -Default 'W:'
                # Rassembler les parametres depuis le step + vault
                # ComputerName : NE PAS utiliser $env:COMPUTERNAME comme defaut --
                # en WinPE il vaut 'MINWINPC' (nom generique) qui se retrouverait
                # alors dans l'OS deploye. Si non fourni, generer un nom aleatoire
                # base sur le serial/MAC, ou laisser un nom explicite.
                $cn = Get-StepParam $Step 'computerName'
                if (-not $cn -or $cn -eq 'MINWINPC') {
                    # Nom de secours unique (evite les doublons et MINWINPC)
                    $suffix = -join ((48..57) + (65..90) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
                    $cn = "WIN-$suffix"
                    Write-TSLog "ComputerName non fourni -- nom genere : $cn (a personnaliser via le wizard)" -Level WARN -StepId $Step.id
                }
                $uParams = @{
                    ComputerName = $cn
                }
                $dom = Get-StepParam $Step 'domain'
                if ($dom) {
                    $uParams.Domain   = $dom
                    $uParams.DomainOU = Get-StepParam $Step 'ou'
                    $du = Get-VaultSecretQuiet 'domainJoinUser'
                    $dp = Get-VaultSecretQuiet 'domainJoinPassword'
                    if ($du) { $uParams.DomainUser = $du }
                    if ($dp) { $uParams.DomainPassword = $dp }
                }
                # Mot de passe admin local : optionnel (pas de prompt si absent du vault)
                $localPwd = Get-VaultSecretQuiet 'localAdminPassword'
                if ($localPwd) { $uParams.LocalAdminPassword = $localPwd }
                # Autologon + phase 2 : enchainer le deploiement apres reboot
                $p2cmd = Get-StepParam $Step 'phase2Command'
                if ($p2cmd) {
                    $uParams.FirstLogonCommand = $p2cmd
                    if ($localPwd) { $uParams.AutoLogonPassword = $localPwd }
                    Write-TSLog "Phase 2 enchainee via unattend (FirstLogonCommands + autologon)" -Level INFO -StepId $Step.id
                }
                # Mode diagnostic : permettre de desactiver l'autologon (suspect BSOD)
                $noAuto = Get-StepParam $Step 'noAutoLogon'
                if ($noAuto) {
                    $uParams.FirstLogonCommand = ''  # pas d'autologon ni FirstLogon
                    Write-TSLog "Autologon DESACTIVE (mode diagnostic) -- OOBE standard" -Level WARN -StepId $Step.id
                }
                # Extensibilite : template custom depuis le partage ou les params
                $tmpl = Get-StepParam $Step 'templatePath'
                if (-not $tmpl) {
                    # Chercher un template par defaut sur le partage
                    $defaultTmpl = "$NetworkShare\Unattend\template.xml"
                    if (Test-Path $defaultTmpl -EA SilentlyContinue) { $tmpl = $defaultTmpl }
                }
                if ($tmpl) { $uParams.TemplatePath = $tmpl }

                # Fragments XML additionnels (depuis un fichier .xml sur le partage)
                $extraSpecFile = Get-StepParam $Step 'extraSpecializeFile'
                if ($extraSpecFile -and (Test-Path $extraSpecFile -EA SilentlyContinue)) {
                    $uParams.ExtraSpecializeXml = Get-Content $extraSpecFile -Raw
                }
                $extraOobeFile = Get-StepParam $Step 'extraOobeFile'
                if ($extraOobeFile -and (Test-Path $extraOobeFile -EA SilentlyContinue)) {
                    $uParams.ExtraOobeXml = Get-Content $extraOobeFile -Raw
                }
                # Remplacements custom passes en hashtable
                $repl = Get-StepParam $Step 'replacements'
                if ($repl) { $uParams.Replacements = $repl }
                # Locale/timezone custom
                $tz = Get-StepParam $Step 'timeZone'
                if ($tz) { $uParams.TimeZone = $tz }
                $loc = Get-StepParam $Step 'uiLanguage'
                if ($loc) { $uParams.UILanguage = $loc }

                $xmlPath = Write-UnattendFile -TargetDrive $target -Parameters $uParams
                Write-TSLog "unattend.xml genere : $xmlPath" -Level SUCCESS -StepId $Step.id

                # Mode debug : copier l'unattend genere sur le partage (nom horodate)
                $dbgCopy = Get-StepParam $Step 'debugCopyUnattend'
                if ($dbgCopy) {
                    try {
                        $dbgDir = "$NetworkShare\Logs"
                        if (-not (Test-Path $dbgDir -EA SilentlyContinue)) { $dbgDir = $NetworkShare }
                        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                        $cn = if ($uParams.ContainsKey('ComputerName')) { $uParams.ComputerName } else { 'unknown' }
                        $dbgName = "unattend-debug_${cn}_${stamp}.xml"
                        $dbgPath = Join-Path $dbgDir $dbgName
                        Copy-Item $xmlPath $dbgPath -Force -EA Stop
                        Write-TSLog "Unattend copie pour debug : $dbgPath" -Level INFO -StepId $Step.id
                    } catch {
                        Write-TSLog "Copie debug de l'unattend echouee : $_" -Level WARN -StepId $Step.id
                    }
                }
                # Si phase2Command est dans l'unattend, FirstLogonCommands gere la reprise
                # -> pas besoin du RunOnce offline (evite double config + manipulation ruche)
                if ($p2cmd) { $script:UnattendHandlesResume = $true }
            }
            'SetComputerName' {
                $newName = Get-StepParam $Step 'name' -Default $env:COMPUTERNAME
                try {
                    if (Test-Path 'C:\Windows' -EA SilentlyContinue) {
                        # Windows demarre -- renommer directement
                        Rename-Computer -NewName $newName -Force -EA Stop
                        Write-TSLog "Machine renommee : $newName" -Level SUCCESS -StepId $Step.id
                    } else {
                        # WinPE -- charger la ruche SYSTEM offline et modifier
                        $hivePath = 'W:\Windows\System32\config\SYSTEM'
                        if (Test-Path $hivePath -EA SilentlyContinue) {
                            reg load 'HKLM\OFFLINE_SYS' $hivePath 2>&1 | Out-Null
                            $regBase = 'HKLM:\OFFLINE_SYS\ControlSet001\Control\ComputerName'
                            if (Test-Path "$regBase\ComputerName" -EA SilentlyContinue) {
                                Set-ItemProperty "$regBase\ComputerName"       -Name 'ComputerName' -Value $newName -EA SilentlyContinue
                            }
                            if (Test-Path "$regBase\ActiveComputerName" -EA SilentlyContinue) {
                                Set-ItemProperty "$regBase\ActiveComputerName" -Name 'ComputerName' -Value $newName -EA SilentlyContinue
                            }
                            [gc]::Collect()
                            reg unload 'HKLM\OFFLINE_SYS' 2>&1 | Out-Null
                            Write-TSLog "Nom machine (offline) : $newName" -Level SUCCESS -StepId $Step.id
                        } else {
                            Write-TSLog "Ruche SYSTEM introuvable, nom applique au prochain boot" -Level WARN -StepId $Step.id
                        }
                    }
                } catch { Write-TSLog "SetComputerName : $_" -Level WARN -StepId $Step.id }
            }
            'RunScript'       { Invoke-StepRunScript       -Step $Step }
            'CopyFiles'       { Invoke-StepCopyFiles       -Step $Step }
            'SetRegistry'     { Invoke-StepSetRegistry     -Step $Step }
            'WaitForNetwork'  { Invoke-StepWaitForNetwork  -Step $Step }
            'Reboot'          {
                # Reboot explicite dans la sequence
                $script:RebootRequired = $true
            }
            'Cleanup'         { Invoke-StepCleanup     -Step $Step | Out-Null }
            'ShowWizard'      { Invoke-StepShowWizard  -Step $Step | Out-Null }
            default { Write-TSLog "Type de step inconnu : $($Step.type)" -Level WARN }
        }

        $State.completedSteps += $Step.id
        Write-TSLog "Step termine : $($Step.name)" -Level SUCCESS -StepId $Step.id
        return @{ Success = $true; RebootRequired = $script:RebootRequired }

    } catch {
        Write-TSLog "ERREUR step $($Step.id) : $_" -Level ERROR -StepId $Step.id
        $continueOnErr = ($Step.PSObject.Properties['continueOnError'] -and $Step.continueOnError)
        $seqContinue   = ($Sequence.PSObject.Properties['options'] -and $Sequence.options -and $Sequence.options.PSObject.Properties['continueOnError'] -and $Sequence.options.continueOnError)
        if ($continueOnErr -or $seqContinue) {
            Write-TSLog "continueOnError -> poursuite" -Level WARN -StepId $Step.id
            return @{ Success = $false; RebootRequired = $false; Error = $_.ToString() }
        }
        throw
    }
}

# -----------------------------------------------------------------------------
# MOTEUR PRINCIPAL
# -----------------------------------------------------------------------------

# Helper : acc?s s?curis? aux param?tres d'un step (evite PropertyNotFound)
function Get-StepParam {
    param($Step, [string]$Key, $Default = $null)
    if ($null -eq $Step -or $null -eq $Step.params) { return $Default }
    $p = $Step.params
    # Essayer PascalCase et camelCase
    $keyPascal = $Key.Substring(0,1).ToUpper() + $Key.Substring(1)
    if ($p.PSObject.Properties[$keyPascal]) { return $p.$keyPascal }
    if ($p.PSObject.Properties[$Key])       { return $p.$Key }
    if ($p -is [hashtable]) {
        if ($p.ContainsKey($keyPascal)) { return $p[$keyPascal] }
        if ($p.ContainsKey($Key))       { return $p[$Key] }
    }
    return $Default
}


function Initialize-PSWDHooks {
    <# Charge le module Hooks et un eventuel profil de surcharge (GUI). #>
    $hooksMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'Hooks\Hooks.psm1'
    if (Test-Path $hooksMod -EA SilentlyContinue) {
        Import-Module $hooksMod -Force -Global -EA SilentlyContinue
        # Chercher et charger un profil de surcharge (gui.ps1, overrides.ps1...)
        if (Get-Command Find-PSWDOverrideProfile -EA SilentlyContinue) {
            $profile = Find-PSWDOverrideProfile
            if ($profile) {
                Import-PSWDOverrideProfile -Path $profile
            }
        }
    }
}

# Helper : declencher un hook seulement si le module Hooks est charge
function Invoke-HookSafe {
    param([string]$Event, [hashtable]$Context = @{})
    if (Get-Command Invoke-PSWDHook -EA SilentlyContinue) {
        Invoke-PSWDHook -Event $Event -Context $Context
    }
}

function Invoke-TaskSequence {
    <#
    .SYNOPSIS
        Charge et execute une task sequence JSON complete.
    .DESCRIPTION
        - Charge le JSON
        - Reprend depuis l'etat persiste si -Resume
        - Execute chaque step active, dans l'ordre
        - Gere les reboots automatiques (exit 3010) et explicites (type Reboot)
        - Gere rebootAfter Never / IfRequired / Always par step
    .PARAMETER SequencePath
        Chemin vers le fichier task-sequence.json
    .PARAMETER Resume
        Reprend depuis le dernier etat persiste (apres reboot)
    .PARAMETER DryRun
        Simule l'execution sans rien faire (validation)
    .EXAMPLE
        Invoke-TaskSequence -SequencePath '\\srv\deploy\Win11-Standard.json'
    .EXAMPLE
        Invoke-TaskSequence -SequencePath 'C:\Deploy\sequence.json' -Resume
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SequencePath,
        [switch]$Resume,
        [switch]$DryRun,
        [ValidateSet('All','WinPE','Windows')]
        [string]$PhaseFilter = 'All'   # 'Windows' en phase 2 : ne traite que les steps post-OS
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-TSLog "+==============================================+" -Level STEP
    Write-TSLog "|       PSWINDEX -- Task Sequence Engine         |" -Level STEP
    Write-TSLog "+==============================================+" -Level STEP
    Write-TSLog "Sequence : $SequencePath" -Level INFO
    if ($DryRun) { Write-TSLog "MODE DRY-RUN -- aucune action reelle" -Level WARN }

    # Initialiser les hooks (charge la GUI si un profil de surcharge existe)
    Initialize-PSWDHooks
    Invoke-HookSafe -Event 'OnDeployStart' -Context @{ SequencePath = $SequencePath }

    # Chargement PSD1 ou JSON
    if (-not (Test-Path $SequencePath -EA SilentlyContinue)) {
        Invoke-HookSafe -Event 'OnDeployError' -Context @{ Error = "Sequence introuvable : $SequencePath" }
        throw "Sequence introuvable : $SequencePath"
    }
    if ($SequencePath -match '\.psd1$') {
        $seqData = Import-PowerShellDataFile $SequencePath -ErrorAction Stop
        # Normaliser les cles -- accepter minuscules (scratch) et majuscules (profils)
        function Get-SeqProp($obj, $key) {
            if ($null -ne $obj.$key)                        { return $obj.$key }
            if ($null -ne $obj.($key.ToLower()))            { return $obj.($key.ToLower()) }
            if ($null -ne $obj.($key.Substring(0,1).ToUpper()+$key.Substring(1))) {
                return $obj.($key.Substring(0,1).ToUpper()+$key.Substring(1))
            }
            return $null
        }
        # Normaliser hashtable PSD1 -> objet avec cles minuscules
        # Import-PowerShellDataFile retourne une hashtable case-insensitive
        # On force tout en minuscule pour etre coherent avec le code JSON
        $ht = $seqData  # hashtable depuis PSD1
        $stepsRaw = if ($ht.Steps) { $ht.Steps } elseif ($ht.steps) { $ht.steps } else { @() }
        $sequence = [PSCustomObject]@{
            id      = "$( if ($ht['Id'])   {$ht['Id']}   else {$ht['id']  } )"
            name    = "$( if ($ht['Name']) {$ht['Name']} else { if ($ht['name']) {$ht['name']} else {'Sequence'} } )"
            version = "$( if ($ht['Version']) {$ht['Version']} elseif ($ht['version']) {$ht['version']} else {'1.0'} )"
            steps   = @($stepsRaw | ForEach-Object {
                $sh = if ($_ -is [hashtable]) { $_ } else { $null }
                if ($sh) {
                    $paramsHt = if ($sh['Params']) { $sh['Params'] } elseif ($sh['params']) { $sh['params'] } else { @{} }
                    $stepId      = if ($sh['Id'])        {$sh['Id']}        else {if ($sh['id'])   {$sh['id']}   else {''}}
                    $stepType    = if ($sh['Type'])      {$sh['Type']}      else {if ($sh['type']) {$sh['type']} else {''}}
                    $stepName    = if ($sh['Name'])      {$sh['Name']}      elseif ($sh['name']) {$sh['name']} elseif ($stepId) {$stepId} else {'step'}
                    $stepEnabled = if ($sh['Enabled']    -ne $null) {[bool]$sh['Enabled']}   elseif ($sh['enabled']    -ne $null) {[bool]$sh['enabled']}   else {$true}
                    $stepCond    = if ($sh['Condition']  -ne $null) {$sh['Condition']}        elseif ($sh['condition']  -ne $null) {$sh['condition']}        else {$null}
                    $stepReboot  = if ($sh['RebootAfter']) {$sh['RebootAfter']} elseif ($sh['rebootAfter']) {$sh['rebootAfter']} else {'IfRequired'}
                    $stepPhase   = if ($sh['Phase']) {$sh['Phase']} elseif ($sh['phase']) {$sh['phase']} else {'WinPE'}
                    [PSCustomObject]@{
                        id          = $stepId
                        name        = $stepName
                        type        = $stepType
                        enabled     = $stepEnabled
                        condition   = $stepCond
                        rebootAfter = $stepReboot
                        phase       = $stepPhase
                        params      = [PSCustomObject]$paramsHt
                    }
                } else { $_ }
            })
        }
    } else {
        $sequence = Get-Content $SequencePath -Raw | ConvertFrom-Json
    }

    # Copier la sequence en local (C:\Deploy\) pour la reprise apres reboot
    # Necessaire si la sequence vient de X:\Windows\Temp (WinPE) ou d'un partage reseau
        $localSeqDir = Join-Path (Get-DeployRoot) 'Runtime'
    $localSeqPath = Join-Path $localSeqDir (Split-Path $SequencePath -Leaf)
    if ($SequencePath -ne $localSeqPath) {
        try {
            if (-not (Test-Path $localSeqDir -EA SilentlyContinue)) {
                New-Item -ItemType Directory $localSeqDir -Force | Out-Null
            }
            Copy-Item $SequencePath $localSeqPath -Force
            Write-TSLog "Sequence copiee en local : $localSeqPath" -Level DEBUG
        } catch {
            Write-TSLog "Copie locale impossible : $_ -- on continue depuis l'original" -Level WARN
            $localSeqPath = $SequencePath
        }
    }
    Write-TSLog "Sequence '$($sequence.name)' v$($sequence.version) -- $(@($sequence.steps).Count) step(s)" -Level INFO

    # Etat initial ou reprise
    $state = if ($Resume) { Get-DeployState } else { $null }

    # Restaurer le mapping nom DNS -> IP (phase 2 apres reboot)
    if ($state -and $state.PSObject.Properties['ShareHostMap'] -and $state.ShareHostMap) {
        if (Get-Command Set-PSWDShareHostMap -EA SilentlyContinue) {
            $mapHt = @{}
            foreach ($k in $state.ShareHostMap.Keys) { $mapHt[$k] = $state.ShareHostMap[$k] }
            Set-PSWDShareHostMap -Map $mapHt
            Write-TSLog "Mapping DNS->IP restaure : $($mapHt.Count) entree(s)" -Level INFO
        }
    }
    if (-not $state) {
        $state = [PSCustomObject]@{
            sequenceId     = $sequence.id
            sequencePath   = $SequencePath
            nextStepId     = $sequence.steps[0].id
            completedSteps = @()
            rebootCount    = 0
            startedAt      = (Get-Date -Format 'o')
            lastUpdated    = (Get-Date -Format 'o')
            windowsDrive   = 'W:'
            errors         = @()
        }
    }

    # Filtrage des steps a executer
    $startIdx = 0
    if ($state.nextStepId) {
        $idx = 0
        foreach ($s in $sequence.steps) {
            if ($s.id -eq $state.nextStepId) { $startIdx = $idx; break }
            $idx++
        }
    }

    $stepsToRun = $sequence.steps[$startIdx..(@($sequence.steps).Count - 1)]

    # Filtre de PHASE : en phase 2 (Windows demarre), on ne traite QUE les steps
    # de phase 'Windows'. Les steps de phase 'WinPE' (FormatDisk, ApplyWIM...) ont
    # deja ete faits par SimpleDeploy avant le reboot -- ne pas les rejouer.
    # Regle : un step est 'WinPE' par defaut, 'Windows' seulement s'il le declare.
    if ($PhaseFilter -ne 'All') {
        $stepsToRun = @($stepsToRun | Where-Object {
            $ph = 'WinPE'
            if ($_.PSObject.Properties['phase'] -and $_.phase) { $ph = "$($_.phase)" }
            elseif ($_.PSObject.Properties['Phase'] -and $_.Phase) { $ph = "$($_.Phase)" }
            (@($ph).Trim().ToLower() -eq $PhaseFilter.ToLower()) -or
            ($PhaseFilter -eq 'Windows' -and $ph.Trim().ToLower() -eq 'windows')
        })
        Write-TSLog "Filtre de phase '$PhaseFilter' : $(@($stepsToRun).Count) step(s) retenu(s)" -Level INFO
    }

    Write-TSLog "Demarrage au step index $startIdx / $(@($sequence.steps).Count - 1)" -Level INFO

    # CENTRALISATION DE LA REPRISE : en phase 2, armer l'autologon + la tache
    # UNE fois au debut de la sequence (re-arme a chaque reboot via Invoke-DeployReboot).
    # Depose aussi le script de secours Reset-PSWinDeploy.ps1. Desarme a la fin.
    if (-not (Test-IsWinPE) -and $PhaseFilter -ne 'WinPE') {
        Enable-DeployResume
    }

    foreach ($step in $stepsToRun) {

        # Step desactive
        if ($step.enabled -eq $false) {
            Write-TSLog "Step desactive : $($step.name)" -Level DEBUG -StepId $step.id
            continue
        }

        # Evaluation condition
        if ($step.condition -ne $null -and -not (Test-StepCondition -Condition $step.condition -Sequence $sequence -State $state)) {
            Write-TSLog "Condition non remplie, step ignore : $($step.name)" -Level INFO -StepId $step.id
            continue
        }

        $state.lastUpdated = Get-Date -Format 'o'

        if ($DryRun) {
            Write-TSLog "[DRY-RUN] Executerait : $($step.name) [$($step.type)]" -Level INFO -StepId $step.id
            continue
        }

        # MARQUEUR "JE COMMENCE CETTE ACTION" : ecrire AVANT l'execution quel
        # step est en cours. Si reboot inopine ou plantage, ce fichier indique
        # exactement quel step etait actif (diagnostic + reprise au bon endroit).
        $markerFile = Join-Path (Get-DeployRoot) 'Logs\.current-step'
        try {
            $markerInfo = @(
                "stepId=$($step.id)"
                "stepName=$($step.name)"
                "stepType=$($step.type)"
                "startedAt=$(Get-Date -Format 'o')"
                "computer=$env:COMPUTERNAME"
            ) -join "`r`n"
            $mkDir = Split-Path $markerFile -Parent
            if (-not (Test-Path $mkDir -EA SilentlyContinue)) { New-Item -ItemType Directory $mkDir -Force -EA SilentlyContinue | Out-Null }
            Set-Content -Path $markerFile -Value $markerInfo -Encoding UTF8 -EA SilentlyContinue
            Write-TSLog "[DEBUT] Step '$($step.name)' [$($step.type)]" -Level STEP -StepId $step.id
        } catch {}

        # Execution
        # Capturer uniquement le hashtable de resultat (eviter pollution pipeline)
        # Hook : debut d'etape (GUI)
        Invoke-HookSafe -Event 'OnStepStart' -Context @{ StepId=$step.id; StepName=$step.name; StepType=$step.type }

        $resultRaw = @(Invoke-DeployStep -Step $step -Sequence $sequence -State $state)
        $result = $resultRaw | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        if (-not $result) { $result = @{ Success = $true; RebootRequired = $false } }

        # Helper : lire une cle de resultat, que $result soit un HASHTABLE
        # (cas des handlers, @{...}) ou un PSCustomObject. Le test PSObject.Properties
        # ne marche PAS de facon fiable sur un hashtable -> on teste .Contains d'abord.
        $resGet = {
            param($key)
            if ($null -eq $result) { return $null }
            if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
                if ($result.Contains($key)) { return $result[$key] } else { return $null }
            }
            $p = $result.PSObject.Properties[$key]
            if ($p) { return $p.Value } else { return $null }
        }
        $stepSkipped   = [bool](& $resGet 'Skipped')
        $stepRebootReq = (& $resGet 'RebootRequired')
        $stepStayOn    = [bool](& $resGet 'StayOnStep')

        # Step termine sans reboot : retirer le marqueur "en cours". Si un reboot
        # suit, on LAISSE le marqueur (il indique qu'on a redemarre pendant ce step).
        $stepWillReboot = ($null -ne $stepRebootReq -and [bool]$stepRebootReq)
        if (-not $stepWillReboot) {
            try { Remove-Item $markerFile -Force -EA SilentlyContinue } catch {}
        }

        # Gestion du reboot
        $rebootPolicy = if ($step.rebootAfter) { $step.rebootAfter } else { 'IfRequired' }
        $needReboot   = $false
        # Un step SAUTE (Skipped) ne reboote jamais, meme si rebootAfter='Always'.
        switch ($rebootPolicy) {
            'Always'      { $needReboot = -not $stepSkipped }
            'IfRequired'  { $needReboot = if ($null -ne $stepRebootReq) { [bool]$stepRebootReq } else { $false } }
            'Never'       { $needReboot = $false }
        }

        if ($needReboot) {
            # Trouver le step suivant PAR ID (et non par reference d'objet :
            # le filtrage de phase recree les objets, donc IndexOf par reference
            # retournait -1 -> nextStep = premier step -> JoinDomain rejoue en
            # boucle + autologon re-arme. Bug corrige en cherchant l'ID).
            $allSteps = @($sequence.steps)
            $currentIdx = -1
            for ($ii = 0; $ii -lt $allSteps.Count; $ii++) {
                if ("$($allSteps[$ii].id)" -eq "$($step.id)") { $currentIdx = $ii; break }
            }
            $nextStep = if ($currentIdx -ge 0 -and ($currentIdx + 1) -lt $allSteps.Count) {
                            $allSteps[$currentIdx + 1]
                        } else { $null }

            # Si c'est un Reboot explicite avec continueAt, utiliser ca
            $continueAt = Get-StepParam $step 'continueAt'
            # StayOnStep : le step demande a etre REJOUE apres le reboot (ex:
            # InstallUpdates qui fait plusieurs passes jusqu'a 0 MAJ).
            if ($stepStayOn) {
                $state.nextStepId = $step.id   # rejouer le MEME step apres reboot
            } elseif ($step.type -eq 'Reboot' -and $continueAt) {
                $state.nextStepId = $continueAt
            } elseif ($nextStep) {
                $state.nextStepId = $nextStep.id
            } else {
                # Dernier step -- on flag "termine" puis reboot
                $state.nextStepId = '__done__'
            }

            $state.rebootCount++
            Write-TSLog "Reboot #$($state.rebootCount) -- reprise sur '$($state.nextStepId)'" -Level WARN

            if ($state.rebootCount -gt 10) {
                throw "Trop de reboots ($($state.rebootCount)) -- boucle detectee, abandon"
            }

            # VERROU NO-REBOOT (diagnostic) : si la metadata de la sequence demande
            # de ne PAS rebooter automatiquement, on s'arrete ici sans rebooter.
            $noReboot = $false
            if ($sequence.PSObject.Properties['metadata'] -and $sequence.metadata -and `
                $sequence.metadata.PSObject.Properties['noReboot'] -and $sequence.metadata.noReboot) {
                $noReboot = [bool]$sequence.metadata.noReboot
            }
            if ($noReboot) {
                Save-DeployState -State $state
                if (Test-IsWinPE) {
                    foreach ($vol in @('S','W','R')) {
                        if (Test-Path "${vol}:\" -EA SilentlyContinue) {
                            try { [System.IO.File]::WriteAllText("${vol}:\.flush", '1'); Remove-Item "${vol}:\.flush" -Force -EA SilentlyContinue } catch {}
                        }
                    }
                }
                Write-TSLog "==============================================" -Level WARN
                Write-TSLog "MODE NO-REBOOT : reboot automatique BLOQUE (diagnostic)." -Level WARN
                Write-TSLog "Ecritures disque flushees. Reprise prevue sur : $($state.nextStepId)" -Level WARN
                Write-TSLog "Tape MAINTENANT :  wpeutil reboot" -Level WARN
                Write-TSLog "==============================================" -Level WARN
                Export-DeployLogs -NetworkShare $NetworkShare -Tag '_noreboot'
                return $state
            }

            $noCopy = $false; $noRO = $false
            if ($sequence.PSObject.Properties['metadata'] -and $sequence.metadata) {
                if ($sequence.metadata.PSObject.Properties['noCopyDeploy'] -and $sequence.metadata.noCopyDeploy) { $noCopy = [bool]$sequence.metadata.noCopyDeploy }
                if ($sequence.metadata.PSObject.Properties['noRunOnce'] -and $sequence.metadata.noRunOnce) { $noRO = [bool]$sequence.metadata.noRunOnce }
            }
            Invoke-DeployReboot -State $state -NoCopyDeploy:$noCopy -NoRunOnce:$noRO
            return  # Ne sera jamais atteint (machine redemarre)
        }
    }

    # -- Fin de sequence (aucun step Reboot dans la sequence) --
    # IMPORTANT : on arrive ici si la sequence n'a PAS de step Reboot final
    # (mode diagnostic 'pas de reboot auto'). Dans ce cas, on a fait le minimum :
    # disque + WIM + boot + unattend. On NE fait PAS Copy-DeployToTarget ni
    # Set-DeployRunOnce (operations de reprise) pour rester au plus proche de
    # Test-ModuleDirect (qui boote). L'utilisateur reboote manuellement.
    $sw.Stop()

    if (Test-IsWinPE) {
        # Flush des ecritures avant de rendre la main (comme avant un reboot)
        foreach ($vol in @('S','W','R')) {
            if (Test-Path "${vol}:\" -EA SilentlyContinue) {
                try { [System.IO.File]::WriteAllText("${vol}:\.flush", '1'); Remove-Item "${vol}:\.flush" -Force -EA SilentlyContinue } catch {}
            }
        }
        Write-TSLog "==============================================" -Level SUCCESS
        Write-TSLog "Sequence terminee SANS reboot auto (mode diagnostic)." -Level WARN
        Write-TSLog "Ecritures disque flushees. Tu peux maintenant taper :" -Level WARN
        Write-TSLog "    wpeutil reboot" -Level WARN
        Write-TSLog "NOTE : la phase 2 n'a PAS ete preparee (pas de Copy/RunOnce)." -Level INFO
        Write-TSLog "==============================================" -Level SUCCESS
    } else {
        Remove-DeployState
        Remove-DeployRunOnce
        Remove-DeployResumeTask   # supprimer la tache de reprise (sinon relance a chaque boot)
        # SEQUENCE TERMINEE : supprimer les marqueurs de progression (le step en
        # cours n'a plus lieu d'etre, la sequence est finie). On garde les logs.
        foreach ($mk in @('.current-step','.updates-passes')) {
            try { Remove-Item (Join-Path (Get-DeployRoot) "Logs\$mk") -Force -EA SilentlyContinue } catch {}
        }
        # Marqueur de fin pour la phase 2 (info a l'operateur)
        try {
            $doneFile = 'C:\Deploy\Logs\DEPLOYMENT-COMPLETE.txt'
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Set-Content -Path $doneFile -Value "Deploiement termine le $stamp sur $env:COMPUTERNAME" -Encoding UTF8 -EA SilentlyContinue
        } catch {}
        Write-TSLog "==============================================" -Level SUCCESS
        Write-TSLog "  DEPLOIEMENT TERMINE : '$($sequence.name)'" -Level SUCCESS
        Write-TSLog "  Toutes les etapes de post-installation sont faites." -Level SUCCESS
        Write-TSLog "  Duree totale : $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min" -Level SUCCESS
        Write-TSLog "==============================================" -Level SUCCESS
    }

    # SEQUENCE TERMINEE : desarmer la reprise (autologon OFF, tache supprimee,
    # mot de passe retire du registre). Centralise : un seul endroit de desarmement.
    if (-not (Test-IsWinPE)) {
        Disable-DeployResume
        # Le script de secours n'est plus utile -- le retirer.
        try { Remove-Item 'C:\Deploy\Reset-PSWinDeploy.ps1' -Force -EA SilentlyContinue } catch {}
        try { Remove-Item "$env:PUBLIC\Desktop\Reset-PSWinDeploy.ps1" -Force -EA SilentlyContinue } catch {}
    }

    return $state
}

function Test-TaskSequence {
    <#
    .SYNOPSIS Valide la structure d'un fichier task-sequence.json sans l'executer.#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SequencePath)
    Invoke-TaskSequence -SequencePath $SequencePath -DryRun
}

Export-ModuleMember -Function @(
    'Invoke-TaskSequence'
    'Test-TaskSequence'
    'Initialize-SecretVault'
    'Get-Secret'
    'Save-DeployState'
    'Get-DeployState'
    'Remove-DeployState'
    'Invoke-DeployReboot'
    'Set-DeployResumeTask'
    'Set-DeployAutologon'
    'Get-LocalAdminName'
    'Disable-DeployResume'
    'Enable-DeployResume'
    'Write-DeployResetScript'
    'Remove-DeployResumeTask'
    'Install-Chocolatey'
    'Initialize-Winget'
)
