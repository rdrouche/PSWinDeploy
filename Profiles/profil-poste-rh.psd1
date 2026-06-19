# PSWinDeploy -- profil-poste-rh.json
@{
    Id = 'profil-poste-rh'
    Name = 'Poste RH'
    Description = 'Poste bureautique RH avec Office 365, SAP GUI et acces domaine RH'
    Icon = 'briefcase'
    Color = 'teal'
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
        Metadata.domain = 'rh.corp.local'
        Metadata.locale = 'fr-FR'
        Options.logShare = '\\SERVEUR\Logs\RH'
    }
    StepOverrides = @{
        Step-05 = @{
            Params = @{
                Domain = 'rh.corp.local'
                Ou = 'OU=Postes,OU=RH,DC=rh,DC=corp,DC=local'
                Username = 'svc-joindomain-rh'
                Credential = @{
                    Source = 'vault'
                    UsernameKey = 'domainJoinUserRH'
                    Key = 'domainJoinPasswordRH'
                }
            }
        }
    }
    RequiredApps = @(
        'app-7zip'
        'app-office365'
    )
    DefaultApps = @(
        'app-chrome'
        'app-sap-gui'
    )
    RequiredScripts = @(
        'script-bitlocker'
    )
    DefaultScripts = @(
        'script-post-config'
        'script-wallpaper'
    )
}