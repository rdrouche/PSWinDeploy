@{
    # -- Version ------------------------------------------
    Version         = '0.6.9'
    ProjectName     = 'PSWinDeploy'

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
