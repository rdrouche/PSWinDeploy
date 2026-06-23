# Cadrage API PowerShell + Interface Web (preparation)

Ce document fait le point sur l'alignement de l'API et de l'interface web avec
l'architecture actuelle (refonte phase 2). Il sert de base a la session de
travail dedicacee.

---

## 1. Principe general

```
   [ Interface Web ]              [ API PowerShell (Pode) ]          [ PC en deploiement ]
   React, Docker Linux  <--JSON-->  Deploy-API.ps1, Windows  <--PSD1-->  WinPE / Windows P2
        :3000                            :8080                          (lit les sequences,
                                                                         POST son avancement)
```

- L'interface web parle **JSON** a l'API.
- L'API ecrit/lit des fichiers **PSD1** (sequences, catalogue) que le moteur de
  deploiement consomme directement.
- Le PC en cours de deploiement **POST son avancement** a l'API (heartbeat),
  ce qui alimente le suivi temps reel et l'historique dans le web.
- **Conversion JSON<->PSD1** : module `PsdJson` (ConvertTo-Psd1String,
  ConvertFrom-JsonToHashtable, Save-Psd1File, etc.), toujours BOM UTF-8 + ASCII.

L'interface web gere **uniquement la phase 2** (post-installation). La phase 1
est un deploiement simple (disque/WIM/boot) pilote en local sur le poste, pas
depuis le web.

---

## 2. Routes API disponibles (alignees)

### Lecture
- `GET /api/health` -- etat de l'API
- `GET /api/catalogue` -- catalogue d'applications (avec Category, Script)
- `GET /api/catalogue/:category` -- filtre par categorie
- `GET /api/drivers` -- liste des dossiers modeles de drivers (+ nb .inf)
- `GET /api/sequences/list` -- toutes les sequences (templates, by-name, by-mac)
- `GET /api/wim` -- images WIM disponibles
- `GET /api/profiles` -- profils

### Ecriture / generation
- `PUT /api/catalogue` -- remplace le catalogue (corps `{ apps: [...] }`)
- `POST /api/sequences/by-name/:name` -- genere une sequence by-name (corps = sequence JSON)
- `POST /api/sequences/by-mac/:mac` -- genere une sequence by-mac (MAC normalisee AABBCCDDEEFF)
- `POST /api/deploy/prepare` -- resout profil + sequence

### Suivi / historique
- `POST /api/deploy/report` -- heartbeat envoye par un PC en deploiement
  Corps : `{ computerName, mac, status, step, percent, message }`
  status : `running` | `rebooting` | `done` | `error`
- `GET /api/deploy/current` -- deploiements en cours (dernier etat de chaque PC)
- `GET /api/deploy/history/:id` -- historique complet d'un PC

---

## 3. Format des sequences (rappel)

Une sequence est un PSD1 avec une liste de steps. Types geres par le moteur P2 :

| Type            | Params principaux                       |
|-----------------|-----------------------------------------|
| JoinDomain      | domain, ou, newName                     |
| InstallApps     | apps[] / catalogApps[] / noChoco        |
| InstallUpdates  | maxPasses                               |
| RunScript       | path, args                              |
| CopyFiles       | source, dest                            |
| SetRegistry     | key, value, type                        |
| SetComputerName | name                                    |
| SetLocale       | timezone, locale                        |
| InjectDrivers   | model (ou path)                         |
| WaitForNetwork  | timeoutSec, target                      |
| Reboot          | (aucun)                                 |
| Cleanup         | keepLogs                                |
| ShowWizard      | (aucun)                                 |

Chaque step : `@{ Id; Name; Type; Phase='Windows'; RebootAfter; Enabled; Params=@{...} }`

Le format MAC pour by-mac est **AABBCCDDEEFF** (sans separateur, majuscules),
identique cote generation (API + PostInstall) et cote resolution (resolver).

---

## 4. Catalogue d'applications (champs)

```
@{
    Name     = 'Google Chrome'        # affiche
    Category = 'Navigateurs'          # filtrage web
    WingetId = 'Google.Chrome'        # methode 1
    ChocoId  = 'googlechrome'         # methode 2 (repli)
    Installer= 'chrome_setup.exe'     # methode 3 (exe/msi sur partage)
    Args     = '/silent'              # args installeur
    Script   = '\\IP\Logiciels\x.ps1' # methode UNIQUE (install complexe)
    RebootAfter = 'IfRequired'
}
```

Si `Script` est present, c'est la SEULE methode utilisee (pas de cascade).

---

## 5. Communication PC <-> API (suivi)

Le moteur (`TaskEngine`) appelle `Send-DeployReport` :
- au debut de chaque step (status running + %)
- avant chaque reboot (status rebooting)
- a la fin (status done, 100%)

L'URL de l'API est lue depuis `C:\Deploy\Runtime\api-url.txt` (a deposer lors
du deploiement, ou via la config). Si absente, le heartbeat est silencieux (le
deploiement fonctionne sans l'API).

**A faire cote deploiement** : deposer `api-url.txt` (ex contenu
`http://10.0.8.111:8080`) lors de la copie P1, ou ajouter une cle `ApiUrl` a la
config et la propager.

---

## 6. Authentification (a implementer)

Objectif : au minimum un **compte admin**, et prevoir **OIDC** (SSO externe).

### Etape 1 -- compte admin local (simple)
- Stocker un compte admin (login + hash de mot de passe) dans un fichier
  protege (ex `API\users.psd1`, hash bcrypt/PBKDF2).
- Route `POST /api/auth/login` -> retourne un token (JWT ou session Pode).
- Middleware Pode qui protege les routes d'ecriture (PUT/POST sequences,
  catalogue) et le suivi. Les routes de heartbeat (`/api/deploy/report`)
  peuvent utiliser un secret partage (les PC ne font pas de login interactif).

### Etape 2 -- OIDC (SSO)
- Pode supporte l'authentification OAuth2/OIDC via `Add-PodeAuth`.
- Provider externe : Authelia, Keycloak, Azure AD, Google...
- Flux : le web redirige vers le provider, recoit un code, l'API valide le
  token OIDC, cree une session.
- Prevoir la config : `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
  `OIDC_REDIRECT_URI` (dans .env / variables d'environnement).

### Securite des heartbeats
- Les PC en deploiement ne s'authentifient pas en interactif. Prevoir un
  **secret partage** (header `X-Deploy-Token`) verifie par l'API sur
  `/api/deploy/report`, ou restreindre par plage IP du LAN de deploiement.

---

## 7. Interface web -- ce qui reste a aligner

Pages a avoir (P2 uniquement) :
- **Sequences** : editeur connaissant TOUS les types de steps ci-dessus.
  Generation by-name / by-mac via les routes POST.
- **Catalogue** : liste filtrable par Category, edition (champ Script inclus),
  sauvegarde via PUT /api/catalogue.
- **Drivers** : listing des modeles (GET /api/drivers) -- lecture seule pour
  commencer (les fichiers sont deposes sur le partage manuellement).
- **Suivi** : deploiements en cours (GET /api/deploy/current), rafraichi
  periodiquement. Barre de progression par PC.
- **Historique** : par PC (GET /api/deploy/history/:id), chronologie des events.
- **Login** : page de connexion (admin, puis OIDC).

Retirer toute notion de phase 1 (deploiement simple) de l'interface.

---

## 8. Etat actuel (fait)

- [x] Module `PsdJson` (conversion JSON<->PSD1 robuste, BOM, ASCII)
- [x] Module `ApiLogic` (catalogue, sequences by-name/mac, drivers, suivi)
- [x] Routes API : drivers, sequences by-name/mac, catalogue PUT, suivi/historique
- [x] Heartbeat PC->API dans le moteur (`Send-DeployReport`)
- [x] Catalogue aligne (Script + Category)
- [x] Format MAC unifie (AABBCCDDEEFF) entre generation et resolution

## 9. A faire demain

- [ ] Auth : compte admin + middleware, puis OIDC
- [ ] Frontend : aligner l'editeur de sequences (tous les types), catalogue
      editable, page drivers, suivi temps reel, historique, login
- [ ] Depot de `api-url.txt` (+ secret heartbeat) lors du deploiement
- [ ] Dockerfile API (optionnel) ou doc de lancement de l'API sur Windows
- [ ] Tester le flux complet : web cree une sequence by-name -> PC deploie ->
      heartbeat -> suivi web -> historique
