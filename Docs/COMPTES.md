# Architecture des comptes — PSWinDeploy

Suite à simplification : **aucun compte temporaire créé/supprimé**. On réutilise
les comptes existants, c'est plus propre et sans trace.

## Les comptes utilisés

| Compte | Rôle | Où | Obligatoire |
|--------|------|-----|-------------|
| **svc-winpe** | Accès SMB en lecture aux partages depuis WinPE | Serveur de déploiement | Oui |
| **Administrateur** (builtin) | Admin local de la machine + autologon phase 2 | Machine déployée | Oui |
| **svc-join** (ou autre) | Jonction au domaine AD | AD | Si jonction domaine |

## Pourquoi pas de compte de déploiement temporaire ?

L'ancienne approche créait un compte `deploy-temp` au premier démarrage, puis le
supprimait en fin de séquence. Problèmes :
- Création + suppression = étapes supplémentaires qui peuvent échouer
- Laisse potentiellement des traces (profil, SID résiduel)
- Complexité inutile

**Nouvelle approche** : le compte **Administrateur local builtin** existe déjà dans
tout Windows. On définit simplement son mot de passe via l'unattend.xml, et il sert :
1. À l'**autologon** de la phase 2 (enchaînement post-reboot automatique)
2. Comme **administrateur de la machine** ensuite (pas de suppression)

Rien n'est créé, rien n'est supprimé.

## Le vault (secrets.vault.psd1)

Format PSD1 plat, chiffré par les droits d'accès réseau et l'accès physique :

```powershell
@{
    winpeUser          = 'S-PS-DEP-1\svc-winpe'   # accès SMB
    winpePassword      = '...'
    localAdminPassword = '...'                     # Administrateur builtin
    # Optionnel (jonction domaine) :
    domainJoinUser     = 'CORP\svc-join'
    domainJoinPassword = '...'
}
```

## Flux d'authentification

```
WinPE (phase 1)
  └─ svc-winpe → monte les partages SMB (lecture WIM, drivers, logiciels)
  └─ unattend.xml définit le mdp Administrateur builtin

Reboot → Windows (phase 2)
  └─ autologon Administrateur (mdp depuis unattend)
  └─ RunOnce relance Start-Deploy.ps1 -Resume
  └─ pour accéder aux partages : reconnexion SMB via svc-winpe (vault local)
```

## Note sur l'accès SMB en phase 2

Après reboot, Windows est démarré mais doit re-monter les partages pour récupérer
logiciels et scripts. Le vault (copié sur `C:\Deploy\secrets.vault.psd1` avant
reboot) fournit à nouveau `svc-winpe`. Pas besoin que l'Administrateur local ait
des droits réseau particuliers.
