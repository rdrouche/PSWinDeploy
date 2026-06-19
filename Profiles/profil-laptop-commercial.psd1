# PSWinDeploy -- profil-laptop-commercial.json
@{
    Id = 'profil-laptop-commercial'
    Name = 'Laptop commercial'
    Description = 'Laptop mobile avec CRM, VPN et Teams pour les equipes commerciales'
    Icon = 'device-laptop'
    Color = 'purple'
    SequencePath = '\\SERVEUR\Deploy\Sequences\Win11-Domaine-Standard.json'
    Security = @{
        LocalAdmin = @{
            SetPassword = $true
            Credential = @{
                Source = 'vault'
                Key = 'localAdminPassword'
            }
        }
        Autologon = @{
            Enabled = $true
            User = 'deploy-temp'
            Credential = @{
                Source = 'vault'
                Key = 'deployPassword'
            }
            MaxReboots = 5
            DeleteAfterDeploy = $true
        }
    }
    Overrides = @{
        Metadata.domain = 'corp.local'
        Options.logShare = '\\SERVEUR\Logs\Commercial'
    }
    StepOverrides = @{
        Step-05 = @{
            Params = @{
                Ou = 'OU=Laptops,OU=Commercial,DC=corp,DC=local'
            }
        }
    }
    RequiredApps = @(
        'app-7zip'
        'app-office365'
        'app-vpn'
    )
    DefaultApps = @(
        'app-chrome'
        'app-teams'
        'app-salesforce'
    )
    RequiredScripts = @(
        'script-bitlocker'
        'script-post-config'
    )
    DefaultScripts = @()
}