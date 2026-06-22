# TaskHandlers.Apps.psm1 -- Handlers pour applications, mises a jour, scripts,
# nettoyage. Charges en plus de TaskHandlers.psm1. Tous retournent New-TaskResult.

Set-StrictMode -Version Latest

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
    'Resolve-WingetExe'
    'Initialize-WingetEngine'
    'Install-ChocoEngine'
    'Install-OneApp'
    'Invoke-Task-InstallApps'
    'Invoke-Task-InstallUpdates'
    'Invoke-Task-RunScript'
)
