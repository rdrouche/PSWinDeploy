# PSWinDeploy -- Win11-Standalone.json
@{
    Id = 'ts-win11-standalone'
    Name = 'Windows 11 Pro - Poste standalone (sans domaine)'
    Version = '1.0.0'
    Description = 'Deploiement minimal sans jonction domaine'
    Metadata = @{
        Os = 'Windows 11 Pro'
        Arch = 'amd64'
        Locale = 'fr-FR'
        Timezone = 'Romance Standard Time'
    }
    Options = @{
        ContinueOnError = $true
        LogLevel = 'Info'
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
            }
        }
        @{
            Id = 'step-03'
            Type = 'SetLocale'
            Name = 'Langue et timezone'
            Enabled = $true
            RebootAfter = 'Never'
            Params = @{
                Locale = 'fr-FR'
                Timezone = 'Romance Standard Time'
            }
        }
        @{
            Id = 'step-04'
            Type = 'InstallSoftware'
            Phase = 'Windows'
            Name = 'Logiciels de base'
            Enabled = $true
            RebootAfter = 'IfRequired'
            Params = @{
                Source = '\\SERVEUR\Logiciels'
                Packages = @(
                    @{
                        Name = '7-Zip'
                        Installer = '7z-x64.msi'
                        Args = '/quiet /norestart'
                    }
                )
            }
        }
    )
}