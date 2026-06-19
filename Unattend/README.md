# Unattend.xml — Configuration Windows automatisée

PSWinDeploy génère un `unattend.xml` à la volée pour appliquer, au premier
démarrage de Windows, les paramètres qui se gèrent mal depuis WinPE :
nom machine, jonction domaine, OOBE, admin local, autologon, locale.

## Pourquoi unattend plutôt que le registre offline ?

| Aspect | Registre offline | unattend.xml |
|--------|------------------|--------------|
| Méthode | Manipulation de ruche | Officielle Microsoft |
| Moment | Avant boot (fragile) | specialize/oobeSystem (bon timing) |
| Jonction domaine | Complexe | Native (UnattendedJoin) |
| Autologon | Non | Oui (enchaîne la phase 2) |
| Risque | Élevé | Faible |

## Le step ApplyUnattend

```powershell
@{
    Type   = 'ApplyUnattend'
    Params = @{
        targetDrive   = 'W:'
        computerName  = 'PC-RH-01'      # VIDE = Windows génère un nom aléatoire
        domain        = 'corp.local'
        ou            = 'OU=PC,DC=corp,DC=local'
        phase2Command = 'powershell -File C:\Deploy\Scripts\Start-Deploy.ps1 -Resume'
        # -- Extensibilité --
        templatePath        = '\\SRV\Deploy\Unattend\mon-template.xml'
        extraSpecializeFile = '\\SRV\Deploy\Unattend\extra-specialize.xml'
        extraOobeFile       = '\\SRV\Deploy\Unattend\extra-oobe.xml'
        timeZone            = 'Romance Standard Time'
        uiLanguage          = 'fr-FR'
    }
}
```

## Nom machine aléatoire (déploiements simultanés)

Laissez `computerName` **vide** pour que Windows génère un nom unique aléatoire
(`DESKTOP-XXXXXXX`). Indispensable pour déployer plusieurs postes en parallèle
avec jonction AD — évite que deux machines portent le même nom et s'écrasent
dans l'annuaire.

## Trois niveaux d'extensibilité

### 1. Template complet custom

Créez votre propre `template.xml` avec des variables `{{CLE}}` :

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" ...>
            <ComputerName>{{COMPUTERNAME}}</ComputerName>
            <TimeZone>{{TIMEZONE}}</TimeZone>
            <RegisteredOrganization>Mon Entreprise</RegisteredOrganization>
        </component>
    </settings>
    ...
</unattend>
```

Variables disponibles : `{{COMPUTERNAME}}`, `{{DOMAIN}}`, `{{DOMAINOU}}`,
`{{DOMAINUSER}}`, `{{DOMAINPASSWORD}}`, `{{WORKGROUP}}`, `{{ADMINPASSWORD}}`,
`{{TIMEZONE}}`, `{{UILANGUAGE}}`, `{{INPUTLOCALE}}`, `{{ARCH}}`, `{{PHASE2CMD}}`.

Placez-le dans `\\SRV\Deploy\Unattend\template.xml` (détecté automatiquement)
ou pointez `templatePath` vers votre fichier.

### 2. Fragments XML additionnels

Gardez le template par défaut mais injectez des composants supplémentaires.
Créez `extra-specialize.xml` (un ou plusieurs `<component>`) :

```xml
<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
           publicKeyToken="31bf3856ad364e35" language="neutral"
           xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
            <Order>1</Order>
            <Path>reg add HKLM\SOFTWARE\MonApp /v Licence /d ABC123</Path>
        </RunSynchronousCommand>
    </RunSynchronous>
</component>
```

Pointez `extraSpecializeFile` / `extraOobeFile` vers ces fichiers.

### 3. Remplacements custom

Pour un template avec vos propres variables :

```powershell
Params = @{
    templatePath = '\\SRV\Deploy\Unattend\template.xml'
    replacements = @{
        'SOCIETE'   = 'ACME Corp'
        'DEPARTEMENT' = 'Informatique'
    }
}
```

Dans le template : `<RegisteredOrganization>{{SOCIETE}}</RegisteredOrganization>`

## Référence des passes Windows Setup

- **specialize** : nom machine, domaine, timezone (après application du WIM)
- **oobeSystem** : OOBE skip, admin local, autologon, locale, FirstLogonCommands

Voir la doc Microsoft pour la liste complète des composants disponibles.
