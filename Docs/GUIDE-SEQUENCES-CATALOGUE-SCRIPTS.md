# PSWinDeploy - Sequences, catalogue applications et scripts

## 1. Modele 2 phases : ce qui va dans une sequence

PSWinDeploy fonctionne en DEUX phases. Comprendre cette separation evite
beaucoup de confusion sur le contenu des sequences.

### Phase 1 (WinPE, mode SIMPLE) - PAS de sequence

Ces etapes sont codees EN DUR dans le moteur (SimpleDeploy). On ne les met
PAS dans une sequence :
- Partitionnement du disque
- Application du WIM (image Windows)
- Bootloader (bcdboot)
- unattend.xml de base
- Copie de la config et du vault sur la cible

C'est le tronc commun fiable qui amene un Windows qui BOOTE.

### Phase 2 (Windows, apres le 1er reboot) - LA sequence

C'est ICI que la sequence agit. Une sequence ne doit contenir QUE des steps
POST-deploiement (avec `Phase = 'Windows'`) :
- Jonction au domaine
- Mises a jour Windows
- Installation d'applications
- Scripts personnalises
- Nettoyage de fin

### IMPORTANT : ne pas mettre FormatDisk / ApplyWIM dans une sequence

En mode SIMPLE, ces steps sont inutiles dans une sequence : le moteur les fait
deja en dur en phase 1. Si on les met quand meme, ils sont IGNORES en phase 2
(le filtre `Phase = 'Windows'` ne les execute pas). Pas de casse, mais autant
ne pas les mettre pour la clarte.

### Exemple de sequence phase 2 propre

```powershell
@{
    Id    = 'poste-standard'
    Name  = 'Poste standard'
    Steps = @(
        @{ Id='join';    Type='JoinDomain';     Phase='Windows'; RebootAfter='Always';
           Params=@{ domain='corp.local'; ou='OU=PCs,DC=corp,DC=local' } }
        @{ Id='updates'; Type='InstallUpdates'; Phase='Windows'; RebootAfter='IfRequired' }
        @{ Id='apps';    Type='InstallApps';    Phase='Windows'; RebootAfter='IfRequired';
           Params=@{ catalogApps=@( @{ Name='Chrome'; WingetId='Google.Chrome' } ) } }
        @{ Id='cleanup'; Type='Cleanup';        Phase='Windows'; RebootAfter='Never' }
    )
}
```

---

## 2. Jonction au domaine : toujours en phase 2

La jonction au domaine NE PEUT PAS se faire en WinPE (pas d'OS installe, pas
de machine a joindre). Elle se fait forcement APRES le 1er boot, en phase 2,
via un step `JoinDomain` (`Phase = 'Windows'`).

Il n'y a donc pas de "jonction pre-deploiement". Ce qui existe :
- Pre-provisionnement du compte d'ordinateur dans AD cote serveur (djoin
  /provision), optionnel et avance.
- La jonction effective par le step JoinDomain en phase 2.

Le step JoinDomain lit `DomainName` / `DomainOU` depuis PSWinDeploy.psd1 si
ses propres parametres sont vides (credentials toujours dans le vault).

---

## 3. Catalogue d'applications

### Emplacement (IMPORTANT)

Le catalogue est cherche via la cle `CataloguePath` de PSWinDeploy.psd1 :

```powershell
CataloguePath = @{ DNS = '\\S-PS-DEP-1\Deploy\Catalogue\catalogue.psd1';
                   IP  = '\\10.0.8.111\Deploy\Catalogue\catalogue.psd1' }
```

Le catalogue est dans **Deploy\Catalogue**, PAS dans Logiciels. (Logiciels
contient les binaires d'installation .exe/.msi ; Catalogue contient le
fichier .psd1 qui DECRIT les applications.)

`CataloguePath` peut pointer vers :
- un FICHIER .psd1 (lu directement), ex: `...\Catalogue\catalogue.psd1`
- un DOSSIER (on y cherche `applications.psd1` puis `catalogue.psd1`)

### Format du catalogue

```powershell
@{
    Applications = @(
        @{ Name='Google Chrome'; WingetId='Google.Chrome'; ChocoId='googlechrome' }
        @{ Name='7-Zip';         WingetId='7zip.7zip' }
        @{ Name='Appli metier';  Installer='\\serveur\Logiciels\AppMetier\setup.msi'; Args='/quiet' }
    )
}
```

Chaque application peut declarer une ou plusieurs methodes :
- `WingetId`  : installation via winget
- `ChocoId`   : installation via Chocolatey (installe automatiquement si absent)
- `Installer` : chemin vers un .exe/.msi (+ `Args` pour les parametres)

Dans l'assistant, le catalogue s'affiche avec le type disponible entre
crochets, ex: `Google Chrome [winget/choco]`. Si aucun catalogue n'est trouve,
l'assistant retombe sur une saisie manuelle des noms.

### Cascade d'installation

Pour chaque application, le moteur essaie dans l'ordre : winget -> choco ->
exe/msi, et s'arrete au premier qui reussit. Si ChocoId est requis et que
Chocolatey n'est pas installe, il est installe automatiquement (avec un reboot
ensuite pour fiabiliser le PATH).

---

## 4. Scripts pendant le deploiement (phase 1) vs phase 2

### Scripts en phase 2 (cas normal, recommande)

La quasi-totalite des besoins se traite en phase 2 via un step `RunScript`
dans la sequence : installation, configuration, personnalisation. Le script
tourne sur le Windows installe, avec acces reseau, domaine, etc.

```powershell
@{ Id='mon-script'; Type='RunScript'; Phase='Windows'; RebootAfter='IfRequired';
   Params=@{ Path='C:\Deploy\Scripts\MonScript.ps1' } }
```

Les scripts sont sur le partage `\\serveur\Scripts` et copies sur la cible.

### Scripts en phase 1 (WinPE) : cas RARE et avance

Executer un script pendant la phase 1 (WinPE, avant le 1er boot Windows) n'a
d'interet que pour des actions qui DOIVENT se faire avant que Windows demarre :
- pre-formatage tres specifique
- copie de fichiers sur la partition Windows AVANT le boot
- injection de pilotes particuliers

Pour tout le reste (apps, MAJ, config, domaine, scripts metier), utilisez la
phase 2. Si vous hesitez, c'est de la phase 2.

---

## 5. Assistant post-installation : comportement

L'assistant (menu interactif) propose :
1. Partir d'un modele de sequence
2. Construire a la volee (MAJ / applications / scripts)
3. Terminer et nettoyer C:\Deploy (supprime les fichiers sensibles, garde Logs)
4. Ne rien faire (terminer)

En cas d'erreur pendant une action, l'assistant REVIENT au menu principal
(il ne se ferme plus sur le step en echec). On ne quitte que sur choix explicite.
