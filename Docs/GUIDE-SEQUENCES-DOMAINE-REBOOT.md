# PSWinDeploy - Guide sequences, domaine et reprise

## 1. Sequence par defaut et affectation par MAC (point 6)

En phase 2 (apres le reboot, Windows demarre), le moteur cherche quelle
sequence executer, dans cet ordre de priorite :

1. **Sequence locale** : `C:\Deploy\Runtime\sequence.psd1`
   (si une sequence a ete choisie/copiee pendant la phase 1)

2. **Par adresse MAC** : `\\serveur\Deploy\Sequences\by-mac\<MAC>.psd1`
   ou `<MAC>` est l'adresse MAC de la carte reseau principale, sans separateur,
   en majuscules (ex: `\\serveur\Deploy\Sequences\by-mac\00155D8A2C01.psd1`).
   -> Permet d'affecter une sequence precise a une machine precise.

3. **Sequence par defaut** : `\\serveur\Deploy\Sequences\_default.psd1`
   -> Utilisee si aucune sequence par MAC n'existe. C'est le cas general.

4. **Assistant interactif** : si rien n'est trouve (et machine avec session),
   le menu propose de choisir un modele ou de construire a la volee.

### Comment affecter une sequence a une machine

- **Pour toutes les machines** : deposer `_default.psd1` dans
  `\\serveur\Deploy\Sequences\`.
- **Pour une machine specifique** : creer le dossier `by-mac` et y deposer
  `<MAC>.psd1`. Cette sequence a la PRIORITE sur `_default.psd1`.

### ATTENTION (source de confusion frequente)

Si une machine recoit toujours la "mauvaise" sequence, verifier qu'il ne
traine pas un vieux fichier `by-mac\<MAC>.psd1` d'un test precedent : il
court-circuite `_default.psd1`. Nettoyer le dossier `by-mac` au besoin.

---

## 2. Systeme de reboot et reprise (point 5)

Le deploiement enchaine plusieurs etapes qui peuvent necessiter des reboots
(MAJ Windows, installation d'applications, jonction domaine). Le moteur gere
la reprise automatique apres chaque reboot.

### Codes de sortie des scripts (RunScript)

Un script lance par un step `RunScript` communique avec le moteur par son
**code de sortie** :

- **exit 0** : succes, pas de reboot demande.
- **exit 3010** : succes MAIS un reboot est necessaire. Le moteur reboote la
  machine puis REPREND la sequence a l'etape suivante.
- **autre code** : echec. Selon `ContinueOnError`, le moteur continue ou stoppe.

Le code 3010 est la convention Windows standard (ERROR_SUCCESS_REBOOT_REQUIRED).

### Champ RebootAfter d'un step

Chaque step peut declarer `RebootAfter` :

- `'Never'`   : jamais de reboot apres ce step (defaut pour RunScript de test).
- `'IfRequired'` : reboot seulement si le step l'a demande (exit 3010, ou MAJ
  qui pose un reboot en attente). C'est le mode recommande pour MAJ et apps.
- `'Always'`  : reboot systematique apres ce step.

### Neutralisation des reboots sauvages

Si un script appelle lui-meme `Restart-Computer` ou `shutdown`, cela
couperait la reprise. Le moteur NEUTRALISE ces commandes pendant l'execution
d'un RunScript : un script qui fait `Restart-Computer -Force` ne reboote pas
directement -- il signale un reboot au moteur (exit 3010), et c'est le MOTEUR
qui gere le reboot proprement avec reprise.

### Mecanisme de reprise apres reboot

Deux mecanismes selon la phase :

- **Phase 1 (WinPE)** : RunOnce + autologon (via unattend).
- **Phase 2 (Windows)** : **tache planifiee** `PSWinDeployResume` qui relance
  `Start-Deploy -Resume` au demarrage (`schtasks /SC ONSTART /RU SYSTEM`).
  -> Cette tache s'execute a CHAQUE boot, sans dependre de l'autologon
  (l'autologon LogonCount=1 ne marche qu'une fois et ne suffit pas pour
  plusieurs reboots de MAJ).

La tache est SUPPRIMEE automatiquement quand la sequence se termine, et un
marqueur `C:\Deploy\Logs\DEPLOYMENT-COMPLETE.txt` est ecrit.

### Limite a connaitre

La tache de reprise tourne en compte SYSTEM (pas de session interactive).
C'est parfait pour les etapes automatiques (MAJ, apps, scripts). Pour
l'assistant INTERACTIF (qui a besoin d'une fenetre), un reboot en plein milieu
necessiterait de re-armer l'autologon -- a evaluer si ce cas se presente.

---

## 3. Jonction au domaine (point 4)

### Etat actuel

Le step `JoinDomain` est fonctionnel. Il gere :
- le domaine cible (`domain`)
- l'unite d'organisation / OU (`ou`, au format DN)
- le renommage optionnel de la machine (`newName`)
- les credentials de jonction (depuis le vault : `domainJoinUser` /
  `domainJoinPassword`, ou saisie interactive)

### Exemple de step JoinDomain dans une sequence

```powershell
@{
    Id    = 'join-domain'
    Type  = 'JoinDomain'
    Name  = 'Jonction au domaine'
    Phase = 'Windows'
    Params = @{
        domain  = 'corp.example.local'
        ou      = 'OU=PCs,OU=Paris,DC=corp,DC=example,DC=local'
        newName = ''   # vide = garder le nom actuel
    }
    RebootAfter = 'Always'   # la jonction necessite un reboot
}
```

### Configuration globale recommandee (a ajouter dans PSWinDeploy.psd1)

Pour ne pas repeter l'OU et le domaine dans chaque sequence, on peut les
centraliser dans `PSWinDeploy.psd1` :

```powershell
    # Domaine Active Directory (laisser vide pour standalone)
    DomainName     = 'corp.example.local'
    DomainOU       = 'OU=PCs,OU=Paris,DC=corp,DC=example,DC=local'
    # Les credentials de jonction vont dans le vault :
    #   domainJoinUser     = 'CORP\svc-join'
    #   domainJoinPassword = '...'
```

Les credentials (`domainJoinUser` / `domainJoinPassword`) doivent etre dans
le **vault** (`secrets.vault.psd1`), jamais en clair dans le psd1.

### A FAIRE (evolution)

Brancher le step JoinDomain pour qu'il lise `DomainName` / `DomainOU` depuis
la config globale si les params du step sont vides. Actuellement il faut les
indiquer dans le step.
