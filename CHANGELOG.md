# Journal des modifications

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/).
La version est gouvernee par le fichier `VERSION` a la racine (source unique).

## [0.7.0]

### Ajoute
- **Mode "en attente" (pull interactif)** : un poste en phase 2 peut attendre
  une sequence poussee depuis l'interface web. Nouveau module `DeployQueue`
  (file d'attente par poste), section "En attente de configuration" dans le
  Suivi, et bouton pour pousser une sequence ou annuler l'attente.
- **API en HTTPS optionnel** : generation d'un certificat auto-signe (ou apport
  du sien) depuis la console ; clients (interface web, postes) configures pour
  accepter le certificat afin de chiffrer le trafic.
- **Statistiques** : volumes par jour / semaine / mois / annee et durees, avec
  pagination, suppression manuelle et purge automatique (SQLite cote conteneur).
- **Suivi phase 1** : le poste remonte son avancement des WinPE (preparation
  disque, application de l'image, redemarrage).
- **Outil de version** : `Update-Version.ps1` propage la version partout et
  peut generer l'archive ; la version d'affichage est lue dynamiquement depuis
  `VERSION`.

### Modifie
- **Identite des deploiements basee sur la MAC** : un poste = un deploiement,
  de la phase 1 a la phase 2, meme apres renommage. Resout les collisions entre
  machines simultanees et le doublon phase 1 / phase 2.
- **Editeur de sequences** entierement recentre sur la phase 2 (plus de profils
  ni de choix d'OS/disque, qui relevent de la phase 1).
- **Console** : section "Sequences" (au lieu de "Profils"), avec activation /
  desactivation de la sequence par defaut ; menu Drivers rendu accessible.
- **Securite** : mot de passe administrateur de l'interface stocke en hash
  scrypt ; page publique de generation de hash.
- Modeles de sequence nettoyes (phase 2 uniquement).

### Corrige
- Temps de deploiement parfois negatif (fuseaux horaires entre phases +
  deploiements multiples dans un meme historique).
- Suppression d'un suivi annulee par la synchronisation (masquage persistant).
- Tache planifiee de reprise non supprimee en fin de deploiement.
- Double demande du compte de jonction domaine dans l'assistant d'installation.

## [0.6.x]
- Socle initial : deploiement en deux phases, API Pode, interface web (catalogue,
  sequences, suivi), vault de secrets, build WinPE.
