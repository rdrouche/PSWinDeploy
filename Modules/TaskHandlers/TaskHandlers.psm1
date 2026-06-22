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

# --- Logger : le moteur fournit un logger dans $Context.Log ; sinon Write-Host ---
function Write-TaskLog {
    param([string]$Message, [string]$Level = 'INFO', $Context = $null, [string]$StepId = '')
    if ($Context -and $Context.Log) {
        & $Context.Log $Message $Level $StepId
        return
    }
    $color = switch ($Level) { 'SUCCESS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

# ===========================================================================
#  JoinDomain -- jonction au domaine Active Directory (idempotente)
# ===========================================================================
function Invoke-Task-JoinDomain {
    param($Step, $Context)

    $domain  = Get-StepParam $Step 'domain'
    $ou      = Get-StepParam $Step 'ou'
    $newName = Get-StepParam $Step 'newName'

    # Repli sur la config globale si les params du step sont vides.
    if ([string]::IsNullOrWhiteSpace("$domain") -and $Context.GetConfig) {
        try { $domain = & $Context.GetConfig 'DomainName' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace("$ou") -and $Context.GetConfig) {
        try { $ou = & $Context.GetConfig 'DomainOU' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace("$domain")) {
        return New-TaskResult -Success:$false -Message "JoinDomain : 'domain' obligatoire (step ou config DomainName)"
    }

    # IDEMPOTENCE (double securite) :
    #  1. marqueur fichier '.domain-joined' ecrit apres une jonction reussie
    #  2. verification Win32_ComputerSystem.PartOfDomain
    $joinedMarker = Join-Path $Context.LogsDir '.domain-joined'
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
    if ($Context.GetSecret) {
        try { $userJ = & $Context.GetSecret 'domainJoinUser' } catch {}
        try { $passJ = & $Context.GetSecret 'domainJoinPassword' } catch {}
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
function Invoke-Task-WaitForNetwork {
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
function Invoke-Task-Reboot {
    param($Step, $Context)
    Write-TaskLog "Redemarrage demande par la sequence." 'INFO' $Context $Step.id
    return New-TaskResult -RebootRequired -Message 'reboot explicite'
}

# ===========================================================================
#  Cleanup -- nettoyage de fin (supprime fichiers sensibles, garde Logs)
# ===========================================================================
function Invoke-Task-Cleanup {
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
function Invoke-Task-ShowWizard {
    param($Step, $Context)
    # Signale au flux appelant qu'il faut basculer sur l'assistant interactif.
    Write-TaskLog "Bascule vers l'assistant post-installation." 'INFO' $Context $Step.id
    return New-TaskResult -Message 'show-wizard' -Data 'wizard'
}

# ===========================================================================
#  Outils winget / choco (internes)
# ===========================================================================
function Resolve-WingetExe {
    # 1) 'winget' dans le PATH (alias d'execution) -- ce qui marche en terminal
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
    # 2) alias d'execution du profil utilisateur
    $userAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $userAlias -EA SilentlyContinue) { return $userAlias }
    # 3) binaire brut (dernier recours)
    $base = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path $base -EA SilentlyContinue) {
        $cand = Get-ChildItem $base -Filter 'Microsoft.DesktopAppInstaller_*' -Directory -EA SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        if ($cand) {
            $exe = Join-Path $cand.FullName 'winget.exe'
            if (Test-Path $exe -EA SilentlyContinue) { return $exe }
        }
    }
    return $null
}

function Initialize-WingetEngine {
    param($Context)
    $wg = Resolve-WingetExe
    if ($wg) {
        try { $null = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { return $true } } catch {}
    }
    Write-TaskLog "Initialisation de winget (enregistrement App Installer)..." 'INFO' $Context
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
            if (Test-Path $manifest -EA SilentlyContinue) { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -EA SilentlyContinue }
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        Start-Sleep -Seconds 2
        $wg = Resolve-WingetExe
        if ($wg) {
            try { $v = & $wg --version 2>&1; if ($LASTEXITCODE -eq 0) { Write-TaskLog "winget pret : $v" 'SUCCESS' $Context; return $true } } catch {}
        }
    } catch { Write-TaskLog "Initialisation winget echouee : $_" 'WARN' $Context }
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
    $ok = $false

    Write-TaskLog "Installation : $name" 'INFO' $Context

    # 1) winget
    if (-not $ok -and $wingetId -and $WingetReady) {
        $wg = Resolve-WingetExe
        if ($wg) {
            Write-TaskLog "  Tentative winget : $wingetId" 'INFO' $Context
            try {
                $out = & $wg install --id $wingetId --silent --accept-package-agreements --accept-source-agreements 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $out = & $wg install --id $wingetId --scope machine --silent --accept-package-agreements --accept-source-agreements 2>&1
                }
                if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TaskLog "  winget OK : $name" 'SUCCESS' $Context }
                else { Write-TaskLog "  winget echec (code $LASTEXITCODE) : $($out | Select-Object -Last 1)" 'WARN' $Context }
            } catch { Write-TaskLog "  winget erreur : $_" 'WARN' $Context }
        }
    }

    # 2) choco
    if (-not $ok -and $chocoId -and $NoChoco) {
        Write-TaskLog "  choco desactive (noChoco) -- $name non installe via choco" 'WARN' $Context
    } elseif (-not $ok -and $chocoId) {
        if (Install-ChocoEngine $Context) {
            Write-TaskLog "  Tentative choco : $chocoId" 'INFO' $Context
            try {
                & choco install $chocoId -y --no-progress 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $ok = $true; Write-TaskLog "  choco OK : $name" 'SUCCESS' $Context }
                else { Write-TaskLog "  choco echec (code $LASTEXITCODE)" 'WARN' $Context }
            } catch { Write-TaskLog "  choco erreur : $_" 'WARN' $Context }
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
function Invoke-Task-InstallApps {
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
            if ($Context.GetConfig) { try { $catPath = & $Context.GetConfig 'CataloguePath' } catch {} }
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
function Invoke-Task-InstallUpdates {
    param($Step, $Context)

    $maxPasses = [int](Get-StepParam $Step 'maxPasses' -Default 5)
    $passFile = Join-Path $Context.LogsDir '.updates-passes'
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
        return (Invoke-Task-InstallUpdates -Step $Step -Context $Context)
    } catch {
        return New-TaskResult -Success:$false -Message "Erreur MAJ : $_"
    }
}

# ===========================================================================
#  RunScript -- executer un script PowerShell (gere exit 3010 = reboot)
# ===========================================================================
function Invoke-Task-RunScript {
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

Export-ModuleMember -Function @(
    'Invoke-Task-Cleanup'
    'Invoke-Task-ShowWizard'
    'Write-TaskLog'
    'Invoke-Task-JoinDomain'
    'Invoke-Task-WaitForNetwork'
    'Invoke-Task-Reboot'

    'Resolve-WingetExe'
    'Initialize-WingetEngine'
    'Install-ChocoEngine'
    'Install-OneApp'
    'Invoke-Task-InstallApps'
    'Invoke-Task-InstallUpdates'
    'Invoke-Task-RunScript'
)
