@{
    # Catalogue des applications deployables.
    # Chaque app declare sa methode preferee. L'assistant les liste, tu coches.
    # Le handler InstallApps essaie : winget -> choco -> exe/msi (cascade).
    #
    # Champs par app :
    #   Name        : nom affiche dans l'assistant
    #   WingetId    : identifiant winget (ex: 'Mozilla.Firefox')      [optionnel]
    #   ChocoId     : identifiant chocolatey (ex: 'firefox')          [optionnel]
    #   Installer   : nom du .exe/.msi sur le partage Logiciels       [optionnel]
    #   Args        : arguments silencieux pour l'installeur exe/msi  [optionnel]
    #   RebootAfter : 'Never' | 'IfRequired' | 'Always' (defaut IfRequired)
    Applications = @(
        @{
            Name     = 'Google Chrome'
            WingetId = 'Google.Chrome'
            ChocoId  = 'googlechrome'
        }
        @{
            Name     = 'Mozilla Firefox'
            WingetId = 'Mozilla.Firefox'
            ChocoId  = 'firefox'
        }
        @{
            Name     = '7-Zip'
            WingetId = '7zip.7zip'
            ChocoId  = '7zip'
        }
        @{
            Name      = 'Adobe Reader'
            WingetId  = 'Adobe.Acrobat.Reader.64-bit'
            Installer = 'AcroRdrDC.exe'
            Args      = '/sAll /rs /msi EULA_ACCEPT=YES'
        }
        @{
            Name        = 'Notre logiciel metier'
            Installer   = 'MetierSetup.msi'
            Args        = '/quiet /norestart'
            RebootAfter = 'Always'
        }
    )
}
