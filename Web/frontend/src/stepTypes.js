// stepTypes.js -- definition des types de steps de sequence P2.
// Aligne sur les handlers du moteur (TaskHandlers.psm1). Chaque type declare
// ses champs de parametres pour generer le formulaire d'edition.

export const STEP_TYPES = {
  InstallApps: {
    label: "Install applications",
    desc: "Installs a list of catalogue apps (winget / choco / exe / script).",
    fields: [
      { key: "apps", label: "Applications (catalogue names)", type: "appList" },
    ],
  },
  RunScript: {
    label: "Run a script",
    desc: "Runs a PowerShell script from the Scripts share. exit 3010 = reboot.",
    fields: [
      { key: "path", label: "Script (.ps1 from the share)", type: "scriptPick" },
      { key: "args", label: "Arguments", type: "text", placeholder: "-Param value" },
    ],
  },
  InstallUpdates: {
    label: "Windows Update",
    desc: "Installs Windows updates (multiple passes possible).",
    fields: [
      { key: "maxPasses", label: "Maximum passes", type: "number", default: 3 },
    ],
  },
  JoinDomain: {
    label: "Join the domain",
    desc: "Joins the Active Directory domain (idempotent).",
    fields: [
      { key: "domain", label: "Domain", type: "text" },
      { key: "ou", label: "Organizational unit (OU)", type: "text", placeholder: "OU=Postes,DC=..." },
      { key: "newName", label: "New machine name", type: "text" },
    ],
  },
  SetComputerName: {
    label: "Rename the machine",
    desc: "Sets the computer name.",
    fields: [
      { key: "name", label: "Machine name", type: "text" },
    ],
  },
  InjectDrivers: {
    label: "Inject drivers",
    desc: "Injects a model's drivers (online).",
    fields: [
      { key: "model", label: "Driver model", type: "driverPick" },
    ],
  },
  CopyFiles: {
    label: "Copy files",
    desc: "Copies a file or folder to a destination.",
    fields: [
      { key: "source", label: "Source", type: "text" },
      { key: "dest", label: "Destination", type: "text" },
    ],
  },
  SetRegistry: {
    label: "Registry key",
    desc: "Sets a registry value.",
    fields: [
      { key: "key", label: "Cle", type: "text", placeholder: "HKLM:\\SOFTWARE\\..." },
      { key: "name", label: "Value name", type: "text" },
      { key: "value", label: "Value", type: "text" },
      { key: "type", label: "Type", type: "select", options: ["String", "DWord", "QWord", "Binary", "MultiString", "ExpandString"] },
    ],
  },
  SetLocale: {
    label: "Language & time zone",
    desc: "Sets the language, keyboard and time zone.",
    fields: [
      { key: "locale", label: "Locale", type: "text", placeholder: "fr-FR" },
      { key: "timezone", label: "Time zone", type: "text", placeholder: "Romance Standard Time" },
    ],
  },
  WaitForNetwork: {
    label: "Wait for network",
    desc: "Waits for the network to be available.",
    fields: [
      { key: "timeoutSec", label: "Max timeout (seconds)", type: "number", default: 120 },
      { key: "target", label: "Target to test (host)", type: "text", placeholder: "10.0.8.111" },
    ],
  },
  Reboot: {
    label: "Reboot",
    desc: "Reboots the machine and resumes at the next step.",
    fields: [],
  },
  Cleanup: {
    label: "Final cleanup",
    desc: "Removes autologon, temporary files, etc.",
    fields: [
      { key: "keepLogs", label: "Keep the logs", type: "checkbox", default: true },
    ],
  },
  ShowWizard: {
    label: "Assistant post-installation",
    desc: "Shows the interactive assistant on the machine.",
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
