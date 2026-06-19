# PSWinDeploy -- profil-kiosque.json
@{
    Id = 'profil-kiosque'
    Name = 'Kiosque / Borne'
    Description = 'Poste standalone en mode kiosque, sans domaine, verrouille'
    Icon = 'device-desktop'
    Color = 'amber'
    SequencePath = '\\SERVEUR\Deploy\Sequences\Win11-Standalone.json'
    Security = @{
        LocalAdmin = @{
            SetPassword = $true
            Credential = @{
                Source = 'vault'
                Key = 'kioskAdminPassword'
            }
        }
        Autologon = @{
            Enabled = $true
            User = 'deploy-temp'
            Credential = @{
                Source = 'vault'
                Key = 'deployPassword'
            }
            MaxReboots = 3
            DeleteAfterDeploy = $true
        }
    }
    Overrides = @{
        Metadata.domain = $null
        Options.continueOnError = $true
    }
    RequiredApps = @(
        'app-7zip'
        'app-chrome'
    )
    DefaultApps = @()
    RequiredScripts = @(
        'script-kiosque-lock'
    )
    DefaultScripts = @()
}