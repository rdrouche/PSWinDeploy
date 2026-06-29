// api.js -- client vers le BFF (backend du conteneur), PAS directement l'API
// PowerShell. Le BFF garde les secrets (token API) cote serveur et gere la
// session via cookie httpOnly. Le navigateur n'a donc aucun secret.
//
// Tous les appels sont en MEME ORIGINE (le BFF sert le front et proxifie l'API),
// donc chemins relatifs et cookies envoyes automatiquement (credentials).

async function call(method, path, body) {
  const opts = {
    method,
    headers: { "Content-Type": "application/json" },
    credentials: "include",   // envoie le cookie de session
  }
  if (body !== undefined) opts.body = JSON.stringify(body)

  let res
  try {
    res = await fetch(path, opts)
  } catch {
    return { success: false, error: "Service injoignable." }
  }
  if (res.status === 401) return { success: false, status: 401, error: "Non authentifie." }

  let data = null
  try { data = await res.json() } catch { data = null }
  if (!res.ok) return { success: false, status: res.status, error: (data && data.error) || `Erreur ${res.status}` }
  return data || { success: true }
}

export const api = {
  // -- Auth (geree par le BFF, cookie de session httpOnly) --
  login: (user, password) => call("POST", "/auth/login", { user, password }),
  logout: () => call("POST", "/auth/logout"),
  me: () => call("GET", "/auth/me"),

  // -- Donnees (le BFF proxifie vers l'API PowerShell en injectant le token) --
  catalogue: () => call("GET", "/api/catalogue"),
  saveApp: (app) => call("POST", "/api/catalogue/app", app),
  deleteApp: (name) => call("DELETE", `/api/catalogue/app/${encodeURIComponent(name)}`),
  replaceCatalogue: (apps) => call("PUT", "/api/catalogue", { apps }),
  drivers: () => call("GET", "/api/drivers"),
  scripts: () => call("GET", "/api/scripts"),
  sequences: () => call("GET", "/api/sequences/list"),
  saveSequenceByName: (name, seq) => call("POST", `/api/sequences/by-name/${encodeURIComponent(name)}`, seq),
  saveSequenceByMac: (mac, seq) => call("POST", `/api/sequences/by-mac/${encodeURIComponent(mac)}`, seq),
  saveSequenceTemplate: (name, seq) => call("POST", `/api/sequences/template/${encodeURIComponent(name)}`, seq),
  sequenceContent: (type, name) => call("GET", `/api/sequences/content/${encodeURIComponent(type)}/${encodeURIComponent(name)}`),
  sequenceObject: (type, name) => call("GET", `/api/sequences/object/${encodeURIComponent(type)}/${encodeURIComponent(name)}`),
  scriptContent: (relPath) => call("GET", `/api/scripts/content?path=${encodeURIComponent(relPath)}`),
  deployCurrent: () => call("GET", "/api/deploy/current"),
  deployHistory: (id) => call("GET", `/api/deploy/history/${encodeURIComponent(id)}`),
  deployStats: () => call("GET", "/api/deploy/stats"),
  deployCompleted: (limit = 25, offset = 0) => call("GET", `/api/deploy/completed?limit=${limit}&offset=${offset}`),
  deleteDeployment: (id) => call("DELETE", `/api/deploy/completed/${encodeURIComponent(id)}`),
  purgeDeployments: (months) => call("POST", "/api/deploy/purge", { months }),
  deployWaiting: () => call("GET", "/api/deploy/waiting"),
  pushSequence: (id, sequenceText, label) => call("POST", `/api/deploy/pending/${encodeURIComponent(id)}`, { sequenceText, label }),
  cancelWaiting: (id) => call("DELETE", `/api/deploy/waiting/${encodeURIComponent(id)}`),
}
