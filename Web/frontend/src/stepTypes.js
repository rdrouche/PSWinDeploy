// stepTypes.js -- definition des types de steps de sequence P2.
// Aligne sur les handlers du moteur (TaskHandlers.psm1). Chaque type declare
// ses champs de parametres pour generer le formulaire d'edition.

export const STEP_TYPES = {
  InstallApps: {
    label: "Installer des applications",
    desc: "Installe une liste d'apps du catalogue (winget / choco / exe / script).",
    fields: [
      { key: "apps", label: "Applications (noms du catalogue)", type: "appList" },
    ],
  },
  RunScript: {
    label: "Executer un script",
    desc: "Lance un script PowerShell du partage Scripts. exit 3010 = reboot.",
    fields: [
      { key: "path", label: "Script (.ps1 du partage)", type: "scriptPick" },
      { key: "args", label: "Arguments", type: "text", placeholder: "-Param valeur" },
    ],
  },
  InstallUpdates: {
    label: "Windows Update",
    desc: "Installe les mises a jour Windows (plusieurs passes possibles).",
    fields: [
      { key: "maxPasses", label: "Passes maximum", type: "number", default: 3 },
    ],
  },
  JoinDomain: {
    label: "Joindre le domaine",
    desc: "Jonction au domaine Active Directory (idempotent).",
    fields: [
      { key: "domain", label: "Domaine", type: "text" },
      { key: "ou", label: "Unite d'organisation (OU)", type: "text", placeholder: "OU=Postes,DC=..." },
      { key: "newName", label: "Nouveau nom de machine", type: "text" },
    ],
  },
  SetComputerName: {
    label: "Renommer la machine",
    desc: "Definit le nom de l'ordinateur.",
    fields: [
      { key: "name", label: "Nom de la machine", type: "text" },
    ],
  },
  InjectDrivers: {
    label: "Injecter des drivers",
    desc: "Injecte les drivers d'un modele (online).",
    fields: [
      { key: "model", label: "Modele de drivers", type: "driverPick" },
    ],
  },
  CopyFiles: {
    label: "Copier des fichiers",
    desc: "Copie un fichier ou dossier vers une destination.",
    fields: [
      { key: "source", label: "Source", type: "text" },
      { key: "dest", label: "Destination", type: "text" },
    ],
  },
  SetRegistry: {
    label: "Cle de registre",
    desc: "Definit une valeur de registre.",
    fields: [
      { key: "key", label: "Cle", type: "text", placeholder: "HKLM:\\SOFTWARE\\..." },
      { key: "name", label: "Nom de la valeur", type: "text" },
      { key: "value", label: "Valeur", type: "text" },
      { key: "type", label: "Type", type: "select", options: ["String", "DWord", "QWord", "Binary", "MultiString", "ExpandString"] },
    ],
  },
  SetLocale: {
    label: "Langue & fuseau",
    desc: "Configure la langue, le clavier et le fuseau horaire.",
    fields: [
      { key: "locale", label: "Locale", type: "text", placeholder: "fr-FR" },
      { key: "timezone", label: "Fuseau horaire", type: "text", placeholder: "Romance Standard Time" },
    ],
  },
  WaitForNetwork: {
    label: "Attendre le reseau",
    desc: "Attend que le reseau soit disponible.",
    fields: [
      { key: "timeoutSec", label: "Delai max (secondes)", type: "number", default: 120 },
      { key: "target", label: "Cible a tester (host)", type: "text", placeholder: "10.0.8.111" },
    ],
  },
  Reboot: {
    label: "Redemarrer",
    desc: "Redemarre la machine et reprend a l'etape suivante.",
    fields: [],
  },
  Cleanup: {
    label: "Nettoyage final",
    desc: "Retire l'autologon, les fichiers temporaires, etc.",
    fields: [
      { key: "keepLogs", label: "Conserver les logs", type: "checkbox", default: true },
    ],
  },
  ShowWizard: {
    label: "Assistant post-installation",
    desc: "Affiche l'assistant interactif sur le poste.",
    fields: [],
  },
}

// Cree un step vierge pour un type donne.
export function newStep(type) {
  const def = STEP_TYPES[type]
  const params = {}
  if (def) {
    for (const f of def.fields) {
      if (f.default !== undefined) params[f.key] = f.default
      else if (f.type === "appList") params[f.key] = []
      else params[f.key] = ""
    }
  }
  return {
    Id: `step-${Math.random().toString(36).slice(2, 8)}`,
    Name: def ? def.label : type,
    Type: type,
    Phase: "Windows",
    Enabled: true,
    RebootAfter: "IfRequired",
    Params: params,
  }
}
