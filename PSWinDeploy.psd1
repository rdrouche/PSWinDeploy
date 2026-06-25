@{
    # -- Version ------------------------------------------
    Version         = '0.6.9'
    ProjectName     = 'PSWinDeploy'

    # -- Debug --------------------------------------------
    # debugMode = $true affiche les informations de diagnostic detaillees
    # ([diag]...) dans la console pendant le deploiement (scan drivers, retours
    # de fonctions, etc.). Absent ou $false = sortie normale (recommande en prod).
    # Peut aussi etre active ponctuellement par le switch -DebugMode de Start-Deploy.
    debugMode       = $false

    # -- Securite API -------------------------------------
    # apiToken : token qui protege l'API. Si DEFINI (chaine non vide), toute
    # requete qui MODIFIE des donnees (POST/PUT/DELETE/PATCH) doit fournir ce
    # token dans l'en-tete 'X-Deploy-Token'. Les lectures (GET) restent libres.
    # Si VIDE, l'API est en acces libre (a eviter hors LAN de confiance).
    #
    # C'est CE token que le conteneur web recevra (variable TOKEN_API_PSWINDEPLOY)
    # pour pouvoir effectuer les modifications. C'est aussi lui que les postes en
    # deploiement utilisent pour le heartbeat.
    #
    # Genere un token : [guid]::NewGuid().ToString('N')
    # (On peut aussi le surcharger par la variable d'environnement PSWD_API_TOKEN
    #  sur le serveur qui lance l'API, qui a alors la priorite.)
    apiToken        = ''

    # -- Chemins LOCAUX pour l'API ------------------------
    # L'API web tourne sur le serveur de deploiement lui-meme. Pour eviter les
    # soucis de droits/double-hop UNC, on lui donne les chemins LOCAUX (memes
    # fichiers que ceux partages, mais acces direct au disque).
    # Si une cle est definie ici, l'API l'utilise. Sinon, elle resout l'UNC
    # (DNS/IP) du partage correspondant. Renseigne TES vrais chemins locaux :
    ApiPaths = @{
        # Catalogue d'applications (MEME fichier que le deploiement lit).
        CataloguePath = 'E:\Shares\Deploy\Catalogue\catalogue.psd1'
        # Dossier des sequences (templates + by-name + by-mac).
        SequencesPath = 'E:\Shares\Deploy\Sequences'
        # Dossier des drivers (modeles par poste).
        DriverShare   = 'E:\Shares\Drivers'
        # Dossier des scripts de sequence (type RunScript).
        ScriptShare   = 'E:\Shares\Scripts'
    }

    # -- ADK / WinPE --------------------------------------
    # x86 retire depuis ADK 2004 -- amd64 et arm64 seulement
    AdkPath         = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    Architecture    = 'amd64'          # amd64 | arm64
    WinPEWorkspace  = 'D:\WinPE-Work'
    WinPEOutputPath = 'D:\ISO'
    WinPEPackages   = @('PowerShell', 'WMI', 'NetFx', 'Scripting', 'StorageWMI', 'EnhancedStorage')
    WinPELocale     = 'fr-FR'


    # -- Compte acces partages WinPE (svc-winpe) ------------------------------
    # Compte en LECTURE SEULE sur les partages de deploiement.
    # Peut etre local au serveur (SERVEUR\svc-winpe) ou de domaine (CORP\svc-winpe).
    # Utilise par Invoke-WinPEBuild pour generer startnet.cmd.
    # WinPEShareServer   = 'SERVEUR'               # ou IP : 192.168.1.10
    # WinPEShareUser     = 'SERVEUR\svc-winpe'    # ou 'CORP\svc-winpe'
    # WinPESharePassword = 'MotDePassePartage'      # mode Plain -- comme MDT
    # Alternative : stocker dans le vault (cles winpeUser + winpePassword)
    #   et passer -VaultPath a Invoke-WinPEBuild

    # -- Reseau / Partages --------------------------------
    ImageShare      = '\\SERVEUR\Images'
    DeployShare     = '\\SERVEUR\Deploy'
    LogShare        = '\\SERVEUR\Logs'
    DriverShare     = '\\SERVEUR\Drivers'
    SoftwareShare   = '\\SERVEUR\Logiciels'
    ScriptShare     = '\\SERVEUR\Scripts'
    ProfilesPath    = '\\SERVEUR\Deploy\Profiles'
    CataloguePath   = '\\SERVEUR\Deploy\Catalogue\catalogue.json'
    SequencesPath   = '\\SERVEUR\Deploy\Sequences'
    RuntimePath     = '\\SERVEUR\Deploy\Runtime'

    # -- Deploiement --------------------------------------
    DefaultLocale   = 'fr-FR'
    DefaultTimezone = 'Romance Standard Time'
    FirmwareType    = 'UEFI'           # UEFI | BIOS
    DefaultDisk     = -1               # -1 = assistant interactif
    WindowsDrive    = 'W:'
    SystemDrive     = 'S:'
    RecoveryDrive   = 'R:'

    # -- Securite -----------------------------------------
    VaultPath       = 'C:\Deploy\secrets.vault'
    VaultMethod     = 'DPAPI'          # DPAPI | AES
    DeployUser      = 'deploy-temp'
    MaxReboots      = 5
    StateFile       = 'C:\Deploy\state.json'
    DeployLogPath   = 'C:\Deploy\Logs\deploy.log'

    # -- API ----------------------------------------------
    ApiPort         = 8080
    ApiAllowedOrigin = '*'

    # -- Chemins locaux (WinPE/Deploy) --------------------
    DeployRoot      = 'C:\Deploy'
    ModulesRoot     = 'C:\Deploy\Modules'
    ScriptsRoot     = 'C:\Deploy\Scripts'
}

# -- Notifications ------------------------------------------------------------
# Decommenter et adapter les sections souhaitees

# Notifications  = @{
#
#     Mail = @{
#         Enabled    = $true
#         SmtpServer = 'smtp.corp.local'
#         Port       = 587
#         UseTls     = $true
#         From       = 'pswindex@corp.local'
#         To         = @('it-admin@corp.local')
#         ToOnError  = @('it-admin@corp.local','it-manager@corp.local')
#         SmtpUser   = 'pswindex@corp.local'
#         SmtpPasswordKey = 'smtpPassword'   # cle dans secrets.vault
#     }
#
#     Teams = @{
#         Enabled    = $true
#         WebhookUrl = 'https://outlook.office.com/webhook/xxx/IncomingWebhook/yyy'
#         # ou lire depuis vault :
#         # WebhookKey = 'teamsWebhook'
#     }
#
#     Webhook = @{
#         Enabled = $false
#         Url     = 'https://hooks.slack.com/services/xxx'
#     }
# }

# -- Compte reseau WinPE ------------------------------------------------------
# Compte dedie acces lecture sur les partages de deploiement depuis WinPE.
# Peut etre un compte local du serveur de fichiers (SERVEUR\svc-winpe)
# ou un compte de domaine a faibles privileges (CORP\svc-winpe).
# Ce compte n'a AUCUN acces aux machines deployees.

# WinPEShareMode      = 'Auto'          # Auto | Plain | Vault | Prompt | Skip
# WinPEShareServer    = 'DEPLOYSRV'     # Nom ou IP du serveur de deploiement
# WinPEShareUser      = 'DEPLOYSRV\svc-winpe'
# WinPESharePassword  = 'MotDePasseShare!'   # Mode Plain -- decommenter si pas de vault
