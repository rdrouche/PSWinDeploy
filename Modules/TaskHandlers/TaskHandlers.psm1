# TaskHandlers.psm1 -- Les TACHES (handlers), une fonction par type de step.
#
# PRINCIPE : chaque handler FAIT une action et retourne TOUJOURS un resultat
# standard via New-TaskResult (contrat TaskContract). Un handler ne touche JAMAIS
# au state, au reboot systeme, a l'autologon : c'est le role du moteur (TaskEngine).
# Un handler dit seulement "j'ai reussi / j'ai besoin d'un reboot / j'ai ete saute".
#
# Tous les handlers suivent la signature : param($Step, $Context)
#   $Step    = le step courant (hashtable ou objet)
#   $Context = infos partagees fournies par le moteur (logger, helpers, vault...)

Set-StrictMode -Version Latest

# Helper : lire une cle d'un Context (hashtable) de facon SURE en StrictMode.
# Retourne $null si la cle n'existe pas, au lieu de lever une erreur.
function Get-Ctx {
    param($Context, [string]$Key)
    if ($null -eq $Context) { return $null }
    if ($Context -is [hashtable] -or $Context -is [System.Collections.IDictionary]) {
        if ($Context.ContainsKey($Key)) { return $Context[$Key] } else { return $null }
    }
    $p = $Context.PSObject.Properties[$Key]
    if ($p) { return $p.Value } else { return $null }
}

# --- Log fichier DETAILLE : capture tout (commandes, sorties, codes) dans un
# fichier dedie, pour diagnostiquer sans polluer la console. Fichier :
# C:\Deploy\Logs\install-detail.log
function Write-TaskFileLog {
    param([string]$Message, [string]$Category = 'INFO')
    try {
        $logDir = 'C:\Deploy\Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir -Force -EA SilentlyContinue | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path (Join-Path $logDir 'install-detail.log') -Value "$stamp [$Category] $Message" -EA SilentlyContinue
    } catch {}
}

# --- Logger : le moteur fournit un logger dans $Context.Log ; sinon Write-Host ---
function Write-TaskLog {
    param([string]$Message, [string]$Level = 'INFO', $Context = $null, [string]$StepId = '')
    $logCb = Get-Ctx $Context 'Log'
    if ($logCb) {
        & $logCb $Message $Level $StepId
        return
    }
    $color = switch ($Level) { 'SUCCESS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

# ===========================================================================
#  JoinDomain -- jonction au domaine Active Directory (idempotente)
# ===========================================================================
function Invoke-TaskJoinDomain {
    param($Step, $Context)

    $domain  = Get-StepParam $Step 'domain'
    $ou      = Get-StepParam $Step 'ou'
    $newName = Get-StepParam $Step 'newName'

    # Repli sur la config globale si les params du step sont vides.
    $gc = Get-Ctx $Context 'GetConfig'
    if ([string]::IsNullOrWhiteSpace("$domain") -and $gc) {
        try { $domain = & $gc 'DomainName' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace("$ou") -and $gc) {
        try { $ou = & $gc 'DomainOU' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace("$domain")) {
        return New-TaskResult -Success:$false -Message "JoinDomain : 'domain' obligatoire (step ou config DomainName)"
    }

    # IDEMPOTENCE (double securite) :
    #  1. marqueur fichier '.domain-joined' ecrit apres une jonction reussie
    #  2. verification Win32_ComputerSystem.PartOfDomain
    $logsDir = Get-Ctx $Context 'LogsDir'; if (-not $logsDir) { $logsDir = 'C:\Deploy\Logs' }
    $joinedMarker = Join-Path $logsDir '.domain-joined'
    if (Test-Path $joinedMarker -EA SilentlyContinue) {
        Write-TaskLog "Jonction deja effectuee (marqueur present) -- step saute." 'SUCCESS' $Context $Step.id
        return New-TaskResult -Skipped -Message 'deja joint (marqueur)'
    }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -EA Stop
        if ($cs.PartOfDomain) {
            $currentDomain = "$($cs.Domain)"
            $targetShort = ($domain -split '\.')[0]
            $currentShort = ($currentDomain -split '\.')[0]
            if ($currentDomain -ieq $domain -or $currentShort -ieq $targetShort) {
                Write-TaskLog "Machine deja jointe au domaine '$currentDomain' -- step saute." 'SUCCESS' $Context $Step.id
                # Ecrire le marqueur pour les prochaines fois
                try { Set-Content -Path $joinedMarker -Value "$currentDomain $(Get-Date -Format 'o')" -Encoding UTF8 -EA SilentlyContinue } catch {}
                return New-TaskResult -Skipped -Message "deja joint ($currentDomain)"
            }
        }
    } catch {
        Write-TaskLog "Verification appartenance domaine impossible : $_ -- on tente la jonction." 'INFO' $Context $Step.id
    }

    # Credentials de jonction depuis le vault.
    $userJ = $null; $passJ = $null
    $gs = Get-Ctx $Context 'GetSecret'
    if ($gs) {
        try { $userJ = & $gs 'domainJoinUser' } catch {}
        try { $passJ = & $gs 'domainJoinPassword' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace("$userJ") -or [string]::IsNullOrWhiteSpace("$passJ")) {
        # Pas de credentials : en session interactive on pourrait demander, mais
        # en SYSTEM non. On echoue proprement.
        if ([Environment]::UserInteractive) {
            return New-TaskResult -Success:$false -Message 'Credentials de jonction absents du vault (domainJoinUser/Password)'
        } else {
            return New-TaskResult -Success:$false -Message 'Credentials de jonction absents et pas de session interactive'
        }
    }

    Write-TaskLog "JoinDomain (via Add-Computer) : $domain" 'INFO' $Context $Step.id
    Write-TaskLog "Jonction avec le compte '$userJ'" 'INFO' $Context $Step.id
    try {
        $sec = ConvertTo-SecureString "$passJ" -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$userJ", $sec)
        $addArgs = @{ DomainName = "$domain"; Credential = $cred; Force = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace("$ou"))      { $addArgs['OUPath']  = "$ou" }
        if (-not [string]::IsNullOrWhiteSpace("$newName")) { $addArgs['NewName'] = "$newName" }
        Add-Computer @addArgs
        Write-TaskLog "Jonction domaine '$domain' reussie" 'SUCCESS' $Context $Step.id
        # Marqueur de double securite
        try { Set-Content -Path $joinedMarker -Value "$domain $(Get-Date -Format 'o')" -Encoding UTF8 -EA SilentlyContinue } catch {}
        # La jonction necessite un redemarrage.
        return New-TaskResult -RebootRequired -Message "joint a $domain"
    } catch {
        return New-TaskResult -Success:$false -Message "Echec jonction : $_"
    }
}

# ===========================================================================
#  WaitForNetwork -- attendre que le reseau soit pret
# ===========================================================================
function Invoke-TaskWaitForNetwork {
    param($Step, $Context)
    $timeout = [int](Get-StepParam $Step 'timeoutSec' -Default 60)
    $target  = "$(Get-StepParam $Step 'target' -Default '')"
    Write-TaskLog "Attente du reseau (timeout ${timeout}s)..." 'INFO' $Context $Step.id
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try {
            if ($target) { $ok = Test-Connection -ComputerName $target -Count 1 -Quiet -EA SilentlyContinue }
            else { $ok = (Get-NetConnectionProfile -EA SilentlyContinue | Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv4Connectivity -eq 'LocalNetwork' }).Count -gt 0 }
        } catch {}
        if ($ok) { Write-TaskLog "Reseau pret." 'SUCCESS' $Context $Step.id; return New-TaskResult }
        Start-Sleep -Seconds 3
    }
    Write-TaskLog "Reseau non disponible apres ${timeout}s (on continue)." 'WARN' $Context $Step.id
    return New-TaskResult -Message 'reseau timeout'
}

# ===========================================================================
#  Reboot -- redemarrage explicite
# ===========================================================================
function Invoke-TaskReboot {
    param($Step, $Context)
    Write-TaskLog "Redemarrage demande par la sequence." 'INFO' $Context $Step.id
    return New-TaskResult -RebootRequired -Message 'reboot explicite'
}

# ===========================================================================
#  Cleanup -- nettoyage de fin (supprime fichiers sensibles, garde Logs)
# ===========================================================================
function Invoke-TaskCleanup {
    param($Step, $Context)
    $keepLogs = [bool](Get-StepParam $Step 'keepLogs' -Default $true)
    $root = 'C:\Deploy'
    if (-not (Test-Path $root)) { return New-TaskResult }
    Write-TaskLog "Nettoyage de fin de deploiement..." 'STEP' $Context $Step.id

    # Le nettoyage des fichiers sensibles. Les dossiers Scripts/Modules contenant
    # le script en cours peuvent etre verrouilles -> on tente, sans mentir.
    $deleted = @(); $deferred = @()
    foreach ($item in @('secrets.vault.psd1','secrets.vault','PSWinDeploy.psd1')) {
        $p = Join-Path $root $item
        if (Test-Path $p -EA SilentlyContinue) {
            try { Remove-Item $p -Recurse -Force -EA Stop; $deleted += $item } catch { $deferred += $item }
        }
    }
    foreach ($mk in @('.domain-joined','.current-step','.updates-passes','.resume-lock')) {
        try { Remove-Item (Join-Path $root "Logs\$mk") -Force -EA SilentlyContinue } catch {}
    }
    foreach ($d in $deleted) { Write-TaskLog "  Supprime : $d" 'INFO' $Context }
    if ($deferred.Count -gt 0) { Write-TaskLog "  Restants (a nettoyer au prochain boot) : $($deferred -join ', ')" 'WARN' $Context }
    return New-TaskResult -Message "nettoye: $($deleted.Count)"
}

# ===========================================================================
#  ShowWizard -- lance l'assistant post-installation (fenetre visible)
# ===========================================================================
function Invoke-TaskShowWizard {
    param($Step, $Context)
    # Signale au flux appelant qu'il faut basculer sur l'assistant interactif.
    Write-TaskLog "Bascule vers l'assistant post-installation." 'INFO' $Context $Step.id
    return New-TaskResult -Message 'show-wizard' -Data 'wizard'
}

# ===========================================================================
#  Outils winget / choco (internes)
# ===========================================================================
function Resolve-WingetExe {
    <#
    .SYNOPSIS Prepare l'environnement pour winget et retourne le NOM 'winget'
        (PAS le chemin complet). C'est LE point cle : appeler 'winget' via le
        PATH utilise l'alias d'execution (contexte MSIX correct), alors que
        lancer le binaire par son chemin complet echoue souvent (0xC0000135).
    .OUTPUTS [string] 'winget' si disponible/prepare, sinon $null.
    #>

    # 1) Deja resoluble par le PATH ? (alias d'execution present) -> on l'utilise.
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }

    # 2) Ajouter le dossier WindowsApps utilisateur au PATH (alias par compte).
    $userApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ((Test-Path $userApps -EA SilentlyContinue) -and ($env:Path -notlike "*$userApps*")) {
        $env:Path = "$userApps;$env:Path"
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }

    # 3) Recherche RECURSIVE du winget.exe le plus recent dans Program Files\
    #    WindowsApps, puis ajout de SON DOSSIER au PATH (methode de ton script).
    #    On NE retourne PAS le chemin complet : on ajoute au PATH et on renvoie
    #    le nom 'winget', pour passer par l'alias d'execution (contexte correct).
    $base = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path $base -EA SilentlyContinue) {
        $wgExe = Get-ChildItem -Path $base -Filter 'winget.exe' -Recurse -EA SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($wgExe) {
            if ($env:Path -notlike "*$($wgExe.DirectoryName)*") {
                $env:Path += ";$($wgExe.DirectoryName)"
            }
            # Verifier que 'winget' (le nom) repond maintenant
            if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
            # En dernier recours seulement, le chemin complet (peut echouer MSIX)
            return $wgExe.FullName
        }
    }
    return $null
}

function Initialize-WingetEngine {
    param($Context)
    # S'assurer d'abord que le dossier WindowsApps de l'UTILISATEUR COURANT est
    # dans le PATH (c'est la que vit l'alias d'execution 'winget' qui fonctionne).
    $userApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ((Test-Path $userApps -EA SilentlyContinue) -and ($env:Path -notlike "*$userApps*")) {
        $env:Path = "$userApps;$env:Path"
    }

    $wg = Resolve-WingetExe
    if ($wg) {
        try { $v0 = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { Write-TaskLog "winget deja pret ($wg) : $v0" 'SUCCESS' $Context; return $true } } catch {}
    }

    Write-TaskLog "Initialisation de winget (enregistrement App Installer pour ce compte)..." 'INFO' $Context
    try {
        # Enregistrer le package App Installer POUR LE COMPTE COURANT. L'alias
        # d'execution winget est PAR UTILISATEUR : sur une session admin fraiche,
        # il faut l'enregistrer sinon 'winget' n'existe pas / echoue (0xC0000135).
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue | Select-Object -First 1
        if (-not $pkg) {
            # Provisionne au niveau machine mais pas enregistre pour ce compte :
            # on l'enregistre depuis le package provisionne.
            $prov = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue | Select-Object -First 1
            if ($prov) {
                $manifest = Join-Path $prov.InstallLocation 'AppXManifest.xml'
                if (Test-Path $manifest -EA SilentlyContinue) { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -EA SilentlyContinue }
            }
        } else {
            $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
            if (Test-Path $manifest -EA SilentlyContinue) { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -EA SilentlyContinue }
        }

        # Rafraichir le PATH (machine + user) et re-ajouter WindowsApps utilisateur
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        if ((Test-Path $userApps -EA SilentlyContinue) -and ($env:Path -notlike "*$userApps*")) { $env:Path = "$userApps;$env:Path" }
        Start-Sleep -Seconds 3

        $wg = Resolve-WingetExe
        if ($wg) {
            try { $v = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { Write-TaskLog "winget pret ($wg) : $v" 'SUCCESS' $Context; return $true } } catch {}
            Write-TaskLog "winget trouve ($wg) mais ne repond pas (code $LASTEXITCODE)." 'WARN' $Context
        } else {
            Write-TaskLog "winget introuvable apres enregistrement." 'WARN' $Context
        }
    } catch { Write-TaskLog "Initialisation winget echouee : $_" 'WARN' $Context }
    Write-TaskLog "winget indisponible -- repli sur choco pour les installations." 'WARN' $Context
    return $false
}

function Install-ChocoEngine {
    param($Context)
    if (Get-Command choco -EA SilentlyContinue) { return $true }
    Write-TaskLog "Chocolatey absent -- installation..." 'INFO' $Context
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force -EA SilentlyContinue
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        $chocoBin = Join-Path $env:ProgramData 'chocolatey\bin'
        if ((Test-Path $chocoBin) -and ($env:Path -notlike "*$chocoBin*")) { $env:Path += ";$chocoBin" }
        if (Get-Command choco -EA SilentlyContinue) {
            Write-TaskLog "Chocolatey installe (PATH rafraichi, pas de reboot)." 'SUCCESS' $Context
            return $true
        }
    } catch { Write-TaskLog "Installation Chocolatey echouee : $_" 'WARN' $Context }
    return $false
}

function Install-OneApp {
    # Installe UNE app (objet riche : Name/WingetId/ChocoId/Installer/Args).
    # Cascade winget -> choco -> exe/msi. Retourne $true si reussie.
    param($App, $Context, [bool]$WingetReady, [bool]$NoChoco, [string]$SoftwareShare)

    $name     = "$(Get-StepProperty $App 'Name')"; if (-not $name) { $name = 'app' }
    $wingetId = "$(Get-StepProperty $App 'WingetId')"
    $chocoId  = "$(Get-StepProperty $App 'ChocoId')"
    $installer= "$(Get-StepProperty $App 'Installer')"
    $insArgs  = "$(Get-StepProperty $App 'Args')"
    $script   = "$(Get-StepProperty $App 'Script')"
    $ok = $false

    Write-TaskLog "Installation : $name" 'INFO' $Context

    # 0) METHODE SCRIPT (UNIQUE et PRIORITAIRE) : si l'app definit 'Script', on
    #    installe UNIQUEMENT via ce script .ps1 dedie -- pas de cascade winget/
    #    choco/exe. Pour les installations complexes qui ne rentrent pas dans le
    #    moule standard. Convention : exit 0 = succes, exit 3010 = succes + reboot.
    #    Le chemin 'Script' accepte DEUX formes :
    #      - chemin UNC/absolu complet : '\\IP\Logiciels\mon-app.ps1' (utilise tel quel)
    #      - chemin relatif : 'installs\mon-app.ps1' (resolu sur le partage Logiciels)
    if ($script) {
        $scriptPath = $script
        # Si le chemin n'existe pas tel quel ET qu'il est relatif (pas UNC/absolu),
        # on le resout sur le partage Logiciels.
        $isAbsolute = ($script -like '\\*') -or ($script -match '^[A-Za-z]:\\')
        if (-not $isAbsolute -and $SoftwareShare -and -not (Test-Path $scriptPath -EA SilentlyContinue)) {
            $scriptPath = Join-Path $SoftwareShare $script
        }
        if (-not (Test-Path $scriptPath -EA SilentlyContinue)) {
            Write-TaskLog "  Script d'installation introuvable : $scriptPath" 'WARN' $Context
            return $false
        }
        Write-TaskLog "  Installation par script dedie : $scriptPath" 'INFO' $Context
        try {
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $p = Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $insArgs" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                Write-TaskLog "  Script OK : $name (code $($p.ExitCode))" 'SUCCESS' $Context
                return $true
            }
            Write-TaskLog "  Script echec : $name (code $($p.ExitCode))" 'WARN' $Context
            return $false
        } catch {
            Write-TaskLog "  Script erreur : $_" 'WARN' $Context
            return $false
        }
    }

    # 1) winget
    if (-not $ok -and $wingetId -and $WingetReady) {
        $wg = Resolve-WingetExe
        Write-TaskFileLog "=== APP: $name (wingetId=$wingetId) ===" 'WINGET'
        Write-TaskFileLog "winget resolu = '$wg' ; PATH winget = $((Get-Command winget -EA SilentlyContinue).Source)" 'WINGET'
        if ($wg) {
            # Verifier si DEJA installe (evite de reinstaller / gagne du temps).
            try {
                $listOut = & $wg list --id $wingetId --exact --accept-source-agreements 2>&1
                Write-TaskFileLog "list code=$LASTEXITCODE out=$($listOut -join ' | ')" 'WINGET'
                if ($LASTEXITCODE -eq 0 -and ($listOut | Select-String -Pattern $wingetId -Quiet)) {
                    Write-TaskLog "  Deja installe (winget) : $name" 'SUCCESS' $Context
                    return $true
                }
            } catch { Write-TaskFileLog "list exception: $_" 'WINGET' }

            Write-TaskLog "  Tentative winget : $wingetId" 'INFO' $Context
            try {
                # Installation avec scope machine + source winget explicite.
                Write-TaskFileLog "CMD: winget install --id $wingetId --exact --silent --accept-package-agreements --accept-source-agreements --scope machine --source winget" 'WINGET'
                $out = & $wg install --id $wingetId --exact --silent --accept-package-agreements --accept-source-agreements --scope machine --source winget 2>&1
                $code1 = $LASTEXITCODE
                Write-TaskFileLog "install(scope machine) code=$code1 out=$($out -join ' | ')" 'WINGET'
                if ($code1 -ne 0) {
                    # Repli sans scope machine
                    Write-TaskFileLog "CMD(repli): winget install --id $wingetId --exact --silent (sans scope)" 'WINGET'
                    $out = & $wg install --id $wingetId --exact --silent --accept-package-agreements --accept-source-agreements 2>&1
                    Write-TaskFileLog "install(repli) code=$LASTEXITCODE out=$($out -join ' | ')" 'WINGET'
                }
                if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TaskLog "  winget OK : $name" 'SUCCESS' $Context }
                else { Write-TaskLog "  winget echec (code $LASTEXITCODE) -- voir install-detail.log" 'WARN' $Context }
            } catch { Write-TaskLog "  winget erreur : $_" 'WARN' $Context; Write-TaskFileLog "install exception: $_" 'WINGET' }
        } else {
            Write-TaskFileLog "winget INTROUVABLE (Resolve-WingetExe a retourne null)" 'WINGET'
        }
    }

    # 2) choco
    if (-not $ok -and $chocoId -and $NoChoco) {
        Write-TaskLog "  choco desactive (noChoco) -- $name non installe via choco" 'WARN' $Context
    } elseif (-not $ok -and $chocoId) {
        $chocoReady = Install-ChocoEngine $Context
        Write-TaskFileLog "=== APP: $name (chocoId=$chocoId) chocoReady=$chocoReady ===" 'CHOCO'
        Write-TaskFileLog "choco PATH = $((Get-Command choco -EA SilentlyContinue).Source)" 'CHOCO'
        if ($chocoReady) {
            Write-TaskLog "  Tentative choco : $chocoId" 'INFO' $Context
            try {
                Write-TaskFileLog "CMD: choco install $chocoId -y --no-progress" 'CHOCO'
                $cout = & choco install $chocoId -y --no-progress 2>&1
                Write-TaskFileLog "choco code=$LASTEXITCODE out=$($cout -join ' | ')" 'CHOCO'
                # choco : 0 = OK, 3010 = OK + reboot, 1641 = OK + reboot
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010 -or $LASTEXITCODE -eq 1641) {
                    $ok = $true; Write-TaskLog "  choco OK : $name" 'SUCCESS' $Context
                } else {
                    Write-TaskLog "  choco echec (code $LASTEXITCODE) -- voir install-detail.log" 'WARN' $Context
                }
            } catch { Write-TaskLog "  choco erreur : $_" 'WARN' $Context; Write-TaskFileLog "choco exception: $_" 'CHOCO' }
        } else {
            Write-TaskFileLog "choco INDISPONIBLE (Install-ChocoEngine a echoue)" 'CHOCO'
        }
    }

    # 3) installeur exe/msi sur le partage Logiciels
    if (-not $ok -and $installer) {
        $path = $installer
        if ($SoftwareShare -and -not (Test-Path $path -EA SilentlyContinue)) { $path = Join-Path $SoftwareShare $installer }
        if (Test-Path $path -EA SilentlyContinue) {
            Write-TaskLog "  Tentative installeur : $path" 'INFO' $Context
            try {
                if ($path -match '\.msi$') {
                    $p = Start-Process 'msiexec.exe' -ArgumentList "/i `"$path`" /qn $insArgs" -Wait -PassThru
                } else {
                    $p = Start-Process $path -ArgumentList $insArgs -Wait -PassThru
                }
                if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { $ok = $true; Write-TaskLog "  Installeur OK : $name" 'SUCCESS' $Context }
                else { Write-TaskLog "  Installeur code $($p.ExitCode)" 'WARN' $Context }
            } catch { Write-TaskLog "  Installeur erreur : $_" 'WARN' $Context }
        }
    }

    if (-not $ok) { Write-TaskLog "ECHEC installation : $name" 'WARN' $Context }
    return $ok
}

# ===========================================================================
#  InstallApps (alias InstallSoftware)
# ===========================================================================
function Invoke-TaskInstallApps {
    param($Step, $Context)

    $noChoco       = [bool](Get-StepParam $Step 'noChoco' -Default $false)
    $softwareShare = "$(Get-StepParam $Step 'softwareShare' -Default '')"
    $wingetReady   = Initialize-WingetEngine $Context

    # Construire la liste d'apps (objets riches) a partir des 3 formats.
    $appsToInstall = @()

    # Format 1 : catalogApps (objets riches directs)
    $catalogApps = Get-StepParam $Step 'catalogApps'
    if ($catalogApps) { foreach ($a in @($catalogApps)) { $appsToInstall += $a } }

    # Format 2 : apps (liste de noms) -> resolus depuis le catalogue
    $apps = Get-StepParam $Step 'apps'
    if ($apps) {
        $catalogIndex = @{}
        try {
            $catPath = $null
            $gcfg = Get-Ctx $Context 'GetConfig'
            if ($gcfg) { try { $catPath = & $gcfg 'CataloguePath' } catch {} }
            $cands = @()
            if ($catPath) {
                if ($catPath -match '\.psd1$') { $cands += $catPath }
                else { $cands += (Join-Path $catPath 'applications.psd1') }
            }
            $cands += 'C:\Deploy\Catalogue\applications.psd1'
            foreach ($cc in $cands) {
                if ($cc -and (Test-Path $cc -EA SilentlyContinue)) {
                    $catData = Import-PowerShellDataFile $cc -EA Stop
                    $appList = if ($catData.Applications) { $catData.Applications } else { $catData }
                    foreach ($ca in @($appList)) {
                        $caName = Get-StepProperty $ca 'Name'
                        if ($caName) { $catalogIndex["$caName".ToLower()] = $ca }
                    }
                    Write-TaskLog "Catalogue charge : $($catalogIndex.Count) app(s)" 'INFO' $Context $Step.id
                    break
                }
            }
        } catch { Write-TaskLog "Lecture catalogue : $_" 'INFO' $Context $Step.id }

        foreach ($app in @($apps)) {
            $key = "$app".ToLower()
            if ($catalogIndex.ContainsKey($key)) { $appsToInstall += $catalogIndex[$key] }
            else { $appsToInstall += @{ Name = "$app"; WingetId = "$app" } }  # nom = WingetId direct
        }
    }

    if ($appsToInstall.Count -eq 0) {
        Write-TaskLog "Aucune application a installer." 'WARN' $Context $Step.id
        return New-TaskResult -Message 'aucune app'
    }

    $allOk = $true
    foreach ($app in $appsToInstall) {
        $r = Install-OneApp -App $app -Context $Context -WingetReady $wingetReady -NoChoco $noChoco -SoftwareShare $softwareShare
        if (-not $r) { $allOk = $false }
    }
    return New-TaskResult -Success:$allOk -Message "apps : $($appsToInstall.Count) traitee(s)"
}

# ===========================================================================
#  InstallUpdates -- Windows Update (multi-passes, StayOnStep)
# ===========================================================================
function Invoke-TaskInstallUpdates {
    param($Step, $Context)

    $maxPasses = [int](Get-StepParam $Step 'maxPasses' -Default 5)
    $logsDir2 = Get-Ctx $Context 'LogsDir'; if (-not $logsDir2) { $logsDir2 = 'C:\Deploy\Logs' }
    $passFile = Join-Path $logsDir2 '.updates-passes'
    $passCount = 0
    try { if (Test-Path $passFile -EA SilentlyContinue) { $passCount = [int](Get-Content $passFile -Raw -EA SilentlyContinue) } } catch {}
    if ($passCount -ge $maxPasses) {
        Write-TaskLog "Limite de $maxPasses passes atteinte -- arret." 'WARN' $Context $Step.id
        try { Remove-Item $passFile -Force -EA SilentlyContinue } catch {}
        return New-TaskResult -Message 'limite passes atteinte'
    }

    try {
        Write-TaskLog "Recherche des mises a jour (passe $($passCount+1)/$maxPasses)..." 'INFO' $Context $Step.id
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")

        if (@($result.Updates).Count -eq 0) {
            Write-TaskLog "Aucune mise a jour disponible -- etape terminee." 'SUCCESS' $Context $Step.id
            try { Remove-Item $passFile -Force -EA SilentlyContinue } catch {}
            return New-TaskResult -Message '0 MAJ'
        }
        Write-TaskLog "$(@($result.Updates).Count) mise(s) a jour trouvee(s)" 'INFO' $Context $Step.id

        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $result.Updates) {
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
            $toDownload.Add($u) | Out-Null
        }
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        $downloader.Download() | Out-Null

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $result.Updates) { if ($u.IsDownloaded) { $toInstall.Add($u) | Out-Null } }
        if ($toInstall.Count -eq 0) { return New-TaskResult -Message 'rien telecharge' }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult = $installer.Install()
        Write-TaskLog "Installation terminee (code $($installResult.ResultCode))" 'INFO' $Context $Step.id

        # Incrementer le compteur de passes (persiste pour la reprise)
        try { Set-Content $passFile -Value ($passCount + 1) -Force -EA SilentlyContinue } catch {}

        if ($installResult.RebootRequired) {
            Write-TaskLog "Un redemarrage est requis -- le step reprendra pour une nouvelle passe." 'WARN' $Context $Step.id
            return New-TaskResult -RebootRequired -StayOnStep -Message 'MAJ installees, reboot requis'
        }
        # Pas de reboot : re-chercher immediatement (boucle interne)
        Write-TaskLog "Passe installee sans reboot -- nouvelle recherche..." 'INFO' $Context $Step.id
        return (Invoke-TaskInstallUpdates -Step $Step -Context $Context)
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur MAJ : $_"
    }
}

# ===========================================================================
#  RunScript -- executer un script PowerShell (gere exit 3010 = reboot)
# ===========================================================================
function Invoke-TaskRunScript {
    param($Step, $Context)
    $scriptPath = "$(Get-StepParam $Step 'path')"
    $scriptArgs = "$(Get-StepParam $Step 'args' -Default '')"
    if (-not $scriptPath) { return New-TaskResult -Success:$false -Message "RunScript : 'path' obligatoire" }

    Write-TaskLog "RunScript : $scriptPath" 'INFO' $Context $Step.id
    if (-not (Test-Path $scriptPath -EA SilentlyContinue)) {
        return New-TaskResult -Success:$false -Message "Script introuvable : $scriptPath"
    }
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $scriptArgs"
        $p = Start-Process $psExe -ArgumentList $argLine -Wait -PassThru -NoNewWindow
        $code = $p.ExitCode
        if ($code -eq 3010) {
            Write-TaskLog "Reboot en attente detecte apres le script (code 3010)." 'INFO' $Context $Step.id
            return New-TaskResult -RebootRequired -Message 'script exit 3010'
        }
        if ($code -eq 0) { return New-TaskResult -Message 'script OK' }
        return New-TaskResult -Success:$false -Message "script exit $code"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur script : $_"
    }
}

# ===========================================================================
#  CopyFiles -- copie de fichiers/dossiers
# ===========================================================================
function Invoke-TaskCopyFiles {
    param($Step, $Context)
    $source = "$(Get-StepParam $Step 'source')"
    $dest   = "$(Get-StepParam $Step 'dest')"
    if (-not $source -or -not $dest) {
        return New-TaskResult -Success:$false -Message "CopyFiles : 'source' et 'dest' obligatoires"
    }
    if (-not (Test-Path $source -EA SilentlyContinue)) {
        return New-TaskResult -Success:$false -Message "CopyFiles : source introuvable ($source)"
    }
    try {
        $destParent = Split-Path $dest -Parent
        if ($destParent -and -not (Test-Path $destParent -EA SilentlyContinue)) {
            New-Item -ItemType Directory -Path $destParent -Force -EA SilentlyContinue | Out-Null
        }
        Copy-Item $source $dest -Recurse -Force -EA Stop
        Write-TaskLog "Copie : $source -> $dest" 'SUCCESS' $Context $Step.id
        return New-TaskResult -Message "copie OK"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur copie : $_"
    }
}

# ===========================================================================
#  SetRegistry -- ecrire une valeur de registre
# ===========================================================================
function Invoke-TaskSetRegistry {
    param($Step, $Context)
    $key   = "$(Get-StepParam $Step 'key')"     # ex: HKLM:\SOFTWARE\Corp\Param
    $value = Get-StepParam $Step 'value'
    $type  = "$(Get-StepParam $Step 'type' -Default 'String')"
    if (-not $key) { return New-TaskResult -Success:$false -Message "SetRegistry : 'key' obligatoire" }
    try {
        $regPath = Split-Path $key -Parent
        $regName = Split-Path $key -Leaf
        if (-not (Test-Path $regPath -EA SilentlyContinue)) { New-Item -Path $regPath -Force -EA Stop | Out-Null }
        Set-ItemProperty -Path $regPath -Name $regName -Value $value -Type $type -Force -EA Stop
        Write-TaskLog "Registre : $key = $value" 'SUCCESS' $Context $Step.id
        return New-TaskResult -Message "registre OK"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur registre : $_"
    }
}

# ===========================================================================
#  SetComputerName -- renommer la machine (reboot requis pour appliquer)
# ===========================================================================
function Invoke-TaskSetComputerName {
    param($Step, $Context)
    $newName = "$(Get-StepParam $Step 'name')"
    if (-not $newName) { return New-TaskResult -Success:$false -Message "SetComputerName : 'name' obligatoire" }

    # Idempotence : si la machine porte deja ce nom, ne rien faire.
    if ("$env:COMPUTERNAME" -ieq $newName) {
        Write-TaskLog "La machine s'appelle deja '$newName' -- step saute." 'SUCCESS' $Context $Step.id
        return New-TaskResult -Skipped -Message "deja nomme $newName"
    }
    try {
        Rename-Computer -NewName $newName -Force -EA Stop
        Write-TaskLog "Machine renommee en '$newName' (effectif apres reboot)." 'SUCCESS' $Context $Step.id
        return New-TaskResult -RebootRequired -Message "renomme $newName"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur renommage : $_"
    }
}

# ===========================================================================
#  SetLocale -- langue / clavier / fuseau (utile aussi en phase 2)
# ===========================================================================
function Invoke-TaskSetLocale {
    param($Step, $Context)
    $tz   = "$(Get-StepParam $Step 'timezone')"
    $loc  = "$(Get-StepParam $Step 'locale')"
    $changed = @()
    try {
        if ($tz) { Set-TimeZone -Id $tz -EA SilentlyContinue; $changed += "tz=$tz" }
        if ($loc) {
            try { Set-WinSystemLocale -SystemLocale $loc -EA SilentlyContinue; $changed += "locale=$loc" } catch {}
            try { Set-Culture $loc -EA SilentlyContinue } catch {}
        }
        Write-TaskLog "Locale appliquee : $($changed -join ', ')" 'SUCCESS' $Context $Step.id
        return New-TaskResult -Message "locale : $($changed -join ', ')"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur locale : $_"
    }
}

# ===========================================================================
#  InjectDrivers -- injecter les drivers d'un modele (phase 2, online)
# ===========================================================================
function Invoke-TaskInjectDrivers {
    param($Step, $Context)
    # Dossier modele : soit fourni en parametre, soit deduit du partage Drivers
    # + nom de modele. Les sous-dossiers DEDANS n'ont pas d'importance (recursif).
    $driverPath = "$(Get-StepParam $Step 'path')"
    $model      = "$(Get-StepParam $Step 'model')"

    if (-not $driverPath -and $model) {
        # Construire depuis le partage Drivers (config DriverShare) + modele
        $gcfg = Get-Ctx $Context 'GetConfig'
        $base = ''
        if ($gcfg) { try { $base = & $gcfg 'DriverShare' } catch {} }
        if (-not $base) { $base = '\\SERVEUR\Drivers' }
        $driverPath = Join-Path $base $model
    }
    if (-not $driverPath) {
        return New-TaskResult -Success:$false -Message "InjectDrivers : 'path' ou 'model' requis"
    }
    if (-not (Test-Path $driverPath -EA SilentlyContinue)) {
        return New-TaskResult -Success:$false -Message "InjectDrivers : dossier introuvable ($driverPath)"
    }

    $infCount = @(Get-ChildItem $driverPath -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
    Write-TaskLog "Injection drivers (online) depuis : $driverPath ($infCount .inf)" 'INFO' $Context $Step.id
    if ($infCount -eq 0) {
        return New-TaskResult -Message "aucun .inf dans $driverPath"
    }
    try {
        # pnputil : installe tous les .inf du dossier (et sous-dossiers) sur le
        # Windows EN LIGNE. /subdirs = recursif, /install = installe vraiment.
        $out = & pnputil.exe /add-driver (Join-Path $driverPath '*.inf') /subdirs /install 2>&1
        Write-TaskLog "pnputil termine (code $LASTEXITCODE)." 'INFO' $Context $Step.id
        # pnputil peut demander un reboot pour certains drivers.
        $needReboot = ($out | Select-String -Pattern 'reboot|redemarr' -Quiet)
        if ($needReboot) {
            return New-TaskResult -RebootRequired -Message "drivers injectes (reboot conseille)"
        }
        return New-TaskResult -Message "drivers injectes ($infCount .inf)"
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur injection drivers : $_"
    }
}

Export-ModuleMember -Function @(
    'Invoke-TaskInjectDrivers'
    'Invoke-TaskCopyFiles'
    'Invoke-TaskSetRegistry'
    'Invoke-TaskSetComputerName'
    'Invoke-TaskSetLocale'
    'Invoke-TaskCleanup'
    'Invoke-TaskShowWizard'
    'Write-TaskLog'
    'Invoke-TaskJoinDomain'
    'Invoke-TaskWaitForNetwork'
    'Invoke-TaskReboot'

    'Resolve-WingetExe'
    'Initialize-WingetEngine'
    'Install-ChocoEngine'
    'Install-OneApp'
    'Invoke-TaskInstallApps'
    'Invoke-TaskInstallUpdates'
    'Invoke-TaskRunScript'
)
