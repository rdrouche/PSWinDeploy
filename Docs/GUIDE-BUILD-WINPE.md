# Guide : construction du WinPE (Build-WinPE-Assistant.ps1)

## Lancer le script

    powershell -ExecutionPolicy Bypass -File Build-WinPE-Assistant.ps1

Au demarrage, on choisit le MODE :
- **[1] RAPIDE** : aucune question, valeurs par defaut. Reconstruit vite un WinPE
  standard (amd64, packages habituels, locale fr-FR, sortie ISO + boot.wim PXE).
  C'est le choix recommande pour la plupart des cas.
- **[2] PERSONNALISE** : chaque option est demandee pas a pas (architecture,
  packages, drivers, reseau, customisation, formats de sortie).

Raccourcis en ligne de commande :
    Build-WinPE-Assistant.ps1 -QuickMode     # force le mode rapide
    Build-WinPE-Assistant.ps1 -Unattended    # idem, pour scripts/automatisation

## Les valeurs par defaut du mode rapide
- Architecture : amd64 (depuis PSWinDeploy.psd1)
- Packages : PowerShell, WMI, NetFx, Scripting, StorageWMI, EnhancedStorage
- Locale : fr-FR (ou WinPELocale du .psd1)
- Reseau : credentials du partage depuis le vault / .psd1
- Sortie : ISO + boot.wim (PXE). Pas de cle USB.
- Aucune commande startnet supplementaire, aucun fichier supplementaire.

---

## Les 2 fonctionnalites de l'etape "Customisation" expliquees

### 1. Commandes supplementaires dans startnet.cmd

**startnet.cmd** est le tout premier script execute quand le WinPE demarre
(avant meme l'invite). Par defaut, PSWinDeploy y met automatiquement :
    wpeinit                          (initialise le reseau et le materiel)
    PowerShell ... Start-Deploy.ps1  (lance l'assistant de deploiement)

La question "Ajouter des commandes personnalisees dans startnet.cmd ?" permet
d'INSERER TES PROPRES COMMANDES qui s'executeront AU DEMARRAGE du WinPE, avant
le lancement de l'assistant. Elles sont saisies une par une.

**Exemples concrets d'utilisation :**
- Mapper un lecteur reseau supplementaire au boot :
      net use T: \\monserveur\outils /user:dom\compte MotDePasse
- Charger un pilote reseau specifique :
      drvload X:\drivers\carte-reseau.inf
- Definir une variable d'environnement :
      set DEPLOY_ENV=production
- Lancer un outil de diagnostic avant le deploiement :
      X:\Tools\check-materiel.cmd
- Fixer la resolution ecran :
      wpeutil SetMouseResolution ...

Si tu n'as besoin de rien de special : reponds non (ou prends le mode rapide).
99% des cas n'en ont pas besoin -- l'assistant fait deja le necessaire.

### 2. Copier des fichiers supplementaires dans le WIM

Le WinPE est une mini-image Windows en lecture seule. Tout ce dont il a besoin
doit etre A L'INTERIEUR de l'image (ou sur le partage reseau). Cette option
permet d'INCLURE DES FICHIERS directement dans le WIM, accessibles des le boot
sous X:\ (X: = la racine du WinPE en memoire).

Pour chaque fichier/dossier, on donne :
- **Source** : le chemin sur TON PC (ex: C:\mes-outils\diskpart-auto.txt)
- **Destination dans WIM** : le sous-dossier dans le WinPE (ex: Deploy\Scripts)
  -> le fichier sera accessible a X:\Deploy\Scripts\diskpart-auto.txt au boot.

**Exemples concrets :**
- Inclure un script de diagnostic perso accessible hors ligne :
      Source : C:\outils\Test-Materiel.ps1
      Destination : Deploy\Scripts
      -> dispo a X:\Deploy\Scripts\Test-Materiel.ps1
- Embarquer un fichier de config :
      Source : C:\configs\reseau-usine.xml
      Destination : Deploy\Config
- Ajouter un utilitaire portable (ex: un .exe) :
      Source : C:\tools\7za.exe
      Destination : Tools

**Quand l'utiliser ?** Si tu veux qu'un outil soit disponible MEME sans reseau
(le partage SMB n'est pas encore monte au tout debut du boot). Sinon, il est
souvent plus simple de laisser les scripts sur le partage \\serveur\Scripts et
d'y acceder une fois le reseau monte.

PSWinDeploy copie deja automatiquement ses propres scripts et modules dans le
WIM (Deploy\Scripts, Deploy\Modules). Cette option est pour TES ajouts perso.

---

## Difference startnet.cmd vs fichiers supplementaires (resume)
- **startnet.cmd** = des COMMANDES qui s'EXECUTENT au demarrage.
- **fichiers supplementaires** = des FICHIERS COPIES dans l'image (qui ne
  s'executent pas tout seuls ; tu les lances quand tu veux, ou via startnet).

Les deux sont OPTIONNELS. En mode rapide, aucun des deux n'est ajoute, et le
WinPE fonctionne parfaitement pour un deploiement standard.
