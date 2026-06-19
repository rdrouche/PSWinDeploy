# PSWinDeploy -- Win11-Domaine-Standard.json
@{
    Id = 'ts-win11-domaine-standard'
    Name = 'Windows 11 Pro - Poste domaine standard'
    Version = '1.0.0'
    Description = 'Deploiement Windows 11 Pro avec jonction domaine, MAJ et logiciels'
    Metadata = @{
        Os = 'Windows 11 Pro'
        Arch = 'amd64'
        Locale = 'fr-FR'
        Timezone = 'Romance Standard Time'
        Domain = 'corp.local'
    }
    Options = @{
        ContinueOnError = $false
        LogLevel = 'Info'
        LogShare = '\\SERVEUR\Logs'
    }
    Steps = @(
        @{
            Id = 'step-01'
            Type = 'FormatDisk'
            Name = 'Partitionner le disque'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                DiskNumber = -1
                FirmwareType = 'UEFI'
            }
        }
        @{
            Id = 'step-02'
            Type = 'ApplyWIM'
            Name = 'Appliquer Windows 11 Pro'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                WimPath = '\\SERVEUR\Images\Win11Pro.wim'
                Index = 0
                TargetDrive = 'W:\'
            }
        }
        @{
            Id = 'step-03'
            Type = 'InjectDrivers'
            Name = 'Injection drivers'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                Path = '\\SERVEUR\Drivers'
                Recurse = $true
                TargetDrive = 'W:\'
            }
        }
        @{
            Id = 'step-04'
            Type = 'SetLocale'
            Name = 'Langue et fuseau horaire'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                Locale = 'fr-FR'
                Timezone = 'Romance Standard Time'
                TargetDrive = 'W:\'
            }
        }
        @{
            Id = 'step-05'
            Type = 'WaitForNetwork'
            Phase = 'Windows'
            Name = 'Attente connexion reseau'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                TimeoutSec = 60
            }
        }
        @{
            Id = 'step-06'
            Type = 'JoinDomain'
            Phase = 'Windows'
            Name = 'Jonction domaine corp.local'
            Enabled = $true
            Condition = '{{ metadata.domain != null }}'
            RebootAfter = 'Always'
            Params = @{
                Domain = 'corp.local'
                Ou = 'OU=Postes,OU=IT,DC=corp,DC=local'
                Credential = @{
                    Source = 'vault'
                    UsernameKey = 'domainJoinUser'
                    Key = 'domainJoinPassword'
                }
                Username = 'svc-joindomain'
            }
        }
        @{
            Id = 'step-07'
            Type = 'InstallUpdates'
            Phase = 'Windows'
            Name = 'Mises a jour Windows'
            Enabled = $true
            ContinueOnError = $true
            RebootAfter = 'IfRequired'
            Params = @{
                Categories = @(
                    'Security'
                    'Critical'
                )
                RebootIfNeeded = $true
            }
        }
        @{
            Id = 'step-08'
            Type = 'InstallSoftware'
            Phase = 'Windows'
            Name = 'Logiciels standards'
            Enabled = $true
            RebootAfter = 'IfRequired'
            Params = @{
                Source = '\\SERVEUR\Logiciels'
                Packages = @(
                    @{
                        Name = '7-Zip 23'
                        Installer = '7z-x64.msi'
                        Args = '/quiet /norestart'
                    }
                    @{
                        Name = 'Chrome'
                        Installer = 'chrome.msi'
                        Args = '/quiet /norestart'
                    }
                    @{
                        Name = 'VLC'
                        Installer = 'vlc.msi'
                        Args = '/quiet /norestart'
                    }
                    @{
                        Name = 'Office 365'
                        Installer = 'setup.exe'
                        Args = '/configure config.xml'
                        ContinueOnError = $true
                    }
                )
            }
        }
        @{
            Id = 'step-09'
            Type = 'RunScript'
            Phase = 'Windows'
            Name = 'Post-configuration'
            Enabled = $true
            ContinueOnError = $true
            RebootAfter = 'Never'
            Params = @{
                Path = '\\SERVEUR\Scripts\Post-Config.ps1'
                Shell = 'PowerShell'
                Args = ''
            }
        }
    )
}