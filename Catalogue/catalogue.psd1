@{
    # Catalogue des applications deployables.
    # Chaque app declare sa methode preferee. L'assistant les liste, tu coches.
    # Le handler InstallApps essaie : winget -> choco -> exe/msi (cascade).
    #
    # Champs par app :
    #   Name        : nom affiche dans l'assistant
    #   Category    : categorie pour le filtrage (Navigateurs, Bureautique...)  [optionnel]
    #   WingetId    : identifiant winget (ex: 'Mozilla.Firefox')      [optionnel]
    #   ChocoId     : identifiant chocolatey (ex: 'firefox')          [optionnel]
    #   Installer   : nom du .exe/.msi sur le partage Logiciels       [optionnel]
    #   Args        : arguments silencieux pour l'installeur exe/msi  [optionnel]
    #   Script      : chemin d'un .ps1 d'installation DEDIE (UNC ou relatif).
    #                 Si present, installation UNIQUE par ce script (pas de
    #                 cascade winget/choco). Pour les installs complexes.       [optionnel]
    #   RebootAfter : 'Never' | 'IfRequired' | 'Always' (defaut IfRequired)
    Applications = @(
        @{
            Name     = 'Google Chrome'
            Category = 'Navigateurs'
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
        # Exemple d'application installee par SCRIPT dedie (install complexe).
        # @{
        #     Name     = 'MonAppComplexe'
        #     Category = 'Metier'
        #     Script   = '\\10.0.8.111\Logiciels\installs\mon-app.ps1'
        #     # OU chemin relatif : Script = 'installs\mon-app.ps1'
        # }
    )
}
