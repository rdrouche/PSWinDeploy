// index.js -- BFF PSWinDeploy (Backend For Frontend).
//
// Role : SEUL composant qui detient les secrets. Il les lit dans les variables
// d'environnement du conteneur et ne les expose JAMAIS au navigateur.
//   - valide le login admin (PASSWORD_ADMIN) et ouvre une session (cookie httpOnly)
//   - proxifie /api/* vers l'API PowerShell en injectant le token (X-Deploy-Token)
//   - sert le frontend statique (build Vite)
//
// Le navigateur ne connait qu'un cookie de session opaque. Ni le token API ni
// le mot de passe ne transitent cote client.
//
// Variables d'environnement (passees par docker-compose) :
//   URL_API_PSWINDEPLOY    URL de l'API Pode (ex http://10.0.8.111:8080)   [requis]
//   TOKEN_API_PSWINDEPLOY  token de l'API (== apiToken du .psd1)           [requis si API protegee]
//   PASSWORD_ADMIN         mot de passe du compte admin                    [requis]
//   ADMIN_USER             identifiant admin (defaut: 'admin')             [optionnel]
//   SESSION_TTL_HOURS      duree de validite d'une session (defaut: 12)    [optionnel]
//   PORT                   port d'ecoute (defaut: 3000)                    [optionnel]
//
// NOTE persistance : les sessions sont en MEMOIRE (suffisant pour un compte
// admin -- un redemarrage du conteneur oblige juste a se reconnecter). Si un
// jour tu veux plusieurs comptes, de l'audit ou des sessions persistantes,
// branche SQLite ici (table sessions { id, username, created_at, expires_at })
// sur un volume /data ; le reste du code ne change pas.

import express from "express"
import cookieParser from "cookie-parser"
import crypto from "node:crypto"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { initDb, upsertDeployments, computeStats, listCompleted, deleteDeployment, purgeOlderThan, debugDump, unhideDeployment } from "./stats-db.js"

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// ─── Configuration (env) ───────────────────────────────────
const API_URL    = (process.env.URL_API_PSWINDEPLOY || "").replace(/\/+$/, "")
const API_TOKEN  = process.env.TOKEN_API_PSWINDEPLOY || ""
const ADMIN_USER = process.env.ADMIN_USER || "admin"
// Mot de passe : on privilegie un HASH (scrypt) stocke dans l'environnement.
// PASSWORD_ADMIN_HASH a la forme "scrypt$<saltHex>$<hashHex>". Si absent, on
// retombe sur PASSWORD_ADMIN en clair (compat/dev), deconseille en prod.
const ADMIN_HASH = process.env.PASSWORD_ADMIN_HASH || ""
const ADMIN_PASS = process.env.PASSWORD_ADMIN || ""
const TTL_MS     = Number(process.env.SESSION_TTL_HOURS || 12) * 3600 * 1000
const PORT       = Number(process.env.PORT || 3000)
const STATIC_DIR = path.join(__dirname, "public")
const SQLITE_PATH = process.env.SQLITE_PATH || "/data/pswd-stats.db"

// Liens de pied de page (sidebar), configurables au build (ARG -> ENV) OU au
// runtime (compose/-e). Chaque lien a une URL et un label personnalisable ;
// on n'affiche que ceux dont l'URL est renseignee.
const FOOTER_LINKS = [
  { key: "github", label: process.env.LINK_GITHUB_LABEL || "GitHub",        url: process.env.LINK_GITHUB || "" },
  { key: "kofi",   label: process.env.LINK_KOFI_LABEL   || "Ko-fi",         url: process.env.LINK_KOFI || "" },
  { key: "docs",   label: process.env.LINK_DOCS_LABEL   || "Documentation", url: process.env.LINK_DOCS || "" },
  { key: "site",   label: process.env.LINK_SITE_LABEL   || "Site web",      url: process.env.LINK_SITE || "" },
].filter((l) => l.url)

// Si l'API est en HTTPS avec un certificat auto-signe (objectif : chiffrer le
// trafic, pas valider une PKI), on autorise le BFF a l'appeler sans rejeter le
// certificat. Active uniquement quand l'URL API est en https ET que
// API_TLS_INSECURE n'est pas explicitement "false".
let insecureAgent = null
if (API_URL.startsWith("https://") && String(process.env.API_TLS_INSECURE || "true").toLowerCase() !== "false") {
  try {
    const { Agent } = await import("undici")
    insecureAgent = new Agent({ connect: { rejectUnauthorized: false } })
    console.log("[bff] API en HTTPS : certificat auto-signe accepte (trafic chiffre).")
  } catch (e) {
    console.warn(`[bff] impossible d'activer l'agent TLS permissif : ${e?.message || e}`)
  }
}

if (!API_URL)   console.warn("[bff] URL_API_PSWINDEPLOY non defini : les appels API echoueront.")
if (!ADMIN_HASH && !ADMIN_PASS) console.warn("[bff] Aucun mot de passe admin configure (ni HASH ni clair) : le login refusera tout le monde.")
if (!ADMIN_HASH && ADMIN_PASS) console.warn("[bff] PASSWORD_ADMIN en clair : preferez PASSWORD_ADMIN_HASH (voir hash-password).")

// ─── Sessions en memoire ───────────────────────────────────
const sessions = new Map()   // id -> { username, expiresAt }
function purge() {
  const now = Date.now()
  for (const [id, s] of sessions) if (s.expiresAt < now) sessions.delete(id)
}
setInterval(purge, 3600 * 1000)

// ─── SQLite (stats de deploiement, persistantes) ───────────
const PURGE_MONTHS = Number(process.env.PURGE_MONTHS || 0)   // 0 = pas de purge auto
let dbReady = false
let dbError = ""
try {
  initDb(SQLITE_PATH)
  dbReady = true
  console.log(`[bff] base stats : ${SQLITE_PATH}`)
  // Purge auto au demarrage puis une fois par jour (si configuree).
  if (PURGE_MONTHS > 0) {
    const runPurge = () => {
      try {
        const n = purgeOlderThan(PURGE_MONTHS)
        if (n > 0) console.log(`[bff] purge auto : ${n} deploiement(s) > ${PURGE_MONTHS} mois supprime(s)`)
      } catch (e) { console.error(`[bff] purge auto KO : ${e?.message || e}`) }
    }
    runPurge()
    setInterval(runPurge, 24 * 3600 * 1000)
    console.log(`[bff] purge auto active : > ${PURGE_MONTHS} mois`)
  }
} catch (e) {
  dbError = e?.message || String(e)
  // Erreur VISIBLE : si la base ne s'initialise pas (souvent un probleme de
  // chargement du module natif better-sqlite3), les stats resteront vides.
  // On le signale clairement dans les logs pour faciliter le diagnostic.
  console.error(`[bff] ERREUR init SQLite (${SQLITE_PATH}) : ${dbError}`)
  console.error(`[bff] -> les statistiques ne fonctionneront pas. Verifie que`)
  console.error(`[bff]    better-sqlite3 se charge (libstdc++ presente dans l'image).`)
}

// Appel interne a l'API PowerShell (avec token), utilise par la sync.
async function apiGet(pathname) {
  if (!API_URL) throw new Error("URL_API_PSWINDEPLOY non defini")
  const headers = {}
  if (API_TOKEN) headers["X-Deploy-Token"] = API_TOKEN
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  try {
    const r = await fetch(`${API_URL}${pathname}`, { headers, signal: ctrl.signal, ...(insecureAgent ? { dispatcher: insecureAgent } : {}) })
    clearTimeout(timer)
    const data = await r.json()
    return data
  } finally { clearTimeout(timer) }
}

// Appel interne POST/DELETE (ecritures : token requis cote API). Retourne
// { status, data } pour relayer le code HTTP au navigateur.
async function apiSend(method, pathname, body) {
  if (!API_URL) throw new Error("URL_API_PSWINDEPLOY non defini")
  const headers = { "Content-Type": "application/json" }
  if (API_TOKEN) headers["X-Deploy-Token"] = API_TOKEN
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  try {
    const init = { method, headers, signal: ctrl.signal, ...(insecureAgent ? { dispatcher: insecureAgent } : {}) }
    if (body !== undefined) init.body = JSON.stringify(body)
    const r = await fetch(`${API_URL}${pathname}`, init)
    clearTimeout(timer)
    let data = {}
    try { data = await r.json() } catch { data = { success: r.ok } }
    return { status: r.status, data }
  } finally { clearTimeout(timer) }
}

// Synchronise la base SQLite depuis l'API : pull des deploiements termines puis
// UPSERT. Appelee a l'ouverture de la page Stats. Ne jette pas : en cas d'echec
// API, on garde ce qui est deja en base.
async function syncDeployments() {
  try {
    const res = await apiGet("/api/deploy/completed")
    if (res && res.success && Array.isArray(res.data)) {
      upsertDeployments(res.data)
      return { ok: true, synced: res.data.length }
    }
    return { ok: false, error: "Reponse API invalide." }
  } catch (e) {
    return { ok: false, error: e?.message || String(e) }
  }
}

// ─── App ───────────────────────────────────────────────────
const app = express()
app.use(express.json({ limit: "2mb" }))
app.use(cookieParser())

const COOKIE = "pswd_sess"
const cookieOpts = {
  httpOnly: true,          // inaccessible au JS -> pas de vol par XSS
  sameSite: "lax",
  // secure=true en HTTPS (recommande en prod derriere un reverse-proxy TLS).
  // Active-le avec COOKIE_SECURE=true dans l'environnement.
  secure: String(process.env.COOKIE_SECURE || "").toLowerCase() === "true",
  maxAge: TTL_MS,
  path: "/",
}

// Comparaison a temps constant (anti timing-attack).
function safeEqual(a, b) {
  const ba = Buffer.from(String(a))
  const bb = Buffer.from(String(b))
  if (ba.length !== bb.length) return false
  return crypto.timingSafeEqual(ba, bb)
}

// Verifie un mot de passe contre le hash scrypt "scrypt$<saltHex>$<hashHex>".
// Comparaison a temps constant. Retourne true/false.
function verifyPassword(password) {
  if (ADMIN_HASH) {
    try {
      const parts = ADMIN_HASH.split("$")
      // format attendu : ["scrypt", saltHex, hashHex]
      if (parts.length !== 3 || parts[0] !== "scrypt") return false
      const salt = Buffer.from(parts[1], "hex")
      const expected = Buffer.from(parts[2], "hex")
      const actual = crypto.scryptSync(String(password), salt, expected.length)
      return crypto.timingSafeEqual(actual, expected)
    } catch {
      return false
    }
  }
  // Repli : comparaison en clair (si seul PASSWORD_ADMIN est defini).
  if (ADMIN_PASS) return safeEqual(password || "", ADMIN_PASS)
  return false
}

function currentSession(req) {
  const sid = req.cookies?.[COOKIE]
  if (!sid) return null
  const s = sessions.get(sid)
  if (!s) return null
  if (s.expiresAt < Date.now()) { sessions.delete(sid); return null }
  return s
}

function requireAuth(req, res, next) {
  const s = currentSession(req)
  if (!s) return res.status(401).json({ success: false, error: "Non authentifie." })
  req.user = s.username
  next()
}

// ─── Outil PUBLIC de generation de hash ────────────────────
// Page simple : on saisit un mot de passe, on obtient le hash scrypt a coller
// dans PASSWORD_ADMIN_HASH. Public (pas de secret expose : ca ne fait que
// hasher une saisie). Le hashage se fait cote SERVEUR (le mot de passe ne reste
// pas dans l'URL ni dans l'historique).
app.post("/hash", (req, res) => {
  const { password } = req.body || {}
  if (!password) return res.status(400).json({ success: false, error: "Mot de passe vide." })
  const salt = crypto.randomBytes(16)
  const derived = crypto.scryptSync(String(password), salt, 32)
  res.json({ success: true, hash: `scrypt$${salt.toString("hex")}$${derived.toString("hex")}` })
})

app.get("/hash", (req, res) => {
  res.set("Content-Type", "text/html; charset=utf-8")
  res.send(`<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PSWinDeploy - Generateur de hash</title>
<style>
  body{font-family:system-ui,sans-serif;background:#11151c;color:#e4e9f0;display:flex;
       align-items:center;justify-content:center;min-height:100vh;margin:0}
  .card{background:#1a212c;border:1px solid #2c3848;border-radius:10px;padding:32px;width:min(520px,92%)}
  h1{font-size:18px;margin:0 0 4px}.sub{color:#8a98ad;font-size:13px;margin-bottom:20px}
  label{display:block;font-size:12px;color:#8a98ad;margin:14px 0 4px}
  input{width:100%;box-sizing:border-box;background:#11151c;border:1px solid #2c3848;color:#e4e9f0;
        border-radius:6px;padding:9px 11px;font-size:14px}
  input:focus{outline:none;border-color:#f0a830}
  button{margin-top:16px;background:#f0a830;color:#1a1206;border:none;border-radius:6px;
         padding:9px 16px;font-weight:600;cursor:pointer;font-size:14px}
  .out{margin-top:18px;display:none}
  .out code{display:block;background:#11151c;border:1px solid #2c3848;border-radius:6px;
            padding:12px;font-family:ui-monospace,monospace;font-size:12.5px;word-break:break-all;color:#3ec46d}
  .hint{color:#8a98ad;font-size:12px;margin-top:8px}
  .copy{background:#222b38;color:#e4e9f0;border:1px solid #2c3848;margin-top:8px}
</style></head><body>
<div class="card">
  <h1>Generateur de hash admin</h1>
  <div class="sub">PSWinDeploy // a coller dans PASSWORD_ADMIN_HASH</div>
  <label>Mot de passe</label>
  <input id="pwd" type="password" autofocus autocomplete="new-password" placeholder="Saisis le mot de passe admin">
  <button onclick="go()">Generer le hash</button>
  <div class="out" id="out">
    <label>Hash a copier dans ton .env / docker-compose :</label>
    <code id="hash"></code>
    <button class="copy" onclick="cp()">Copier</button>
    <div class="hint">PASSWORD_ADMIN_HASH=&lt;ce hash&gt; -- le mot de passe en clair n'est stocke nulle part.</div>
  </div>
</div>
<script>
async function go(){
  const p=document.getElementById('pwd').value
  if(!p)return
  const r=await fetch('/hash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:p})})
  const d=await r.json()
  if(d.hash){document.getElementById('hash').textContent=d.hash;document.getElementById('out').style.display='block'}
}
function cp(){navigator.clipboard.writeText(document.getElementById('hash').textContent)}
document.getElementById('pwd').addEventListener('keydown',e=>{if(e.key==='Enter')go()})
</script>
</body></html>`)
})

// ─── Auth ──────────────────────────────────────────────────
app.post("/auth/login", (req, res) => {
  const { user, password } = req.body || {}
  if (!ADMIN_HASH && !ADMIN_PASS) return res.status(503).json({ success: false, error: "Authentification non configuree." })

  const okUser = safeEqual(user || "", ADMIN_USER)
  const okPass = verifyPassword(password || "")
  if (!okUser || !okPass) return res.status(401).json({ success: false, error: "Identifiants invalides." })

  const sid = crypto.randomBytes(32).toString("hex")
  sessions.set(sid, { username: ADMIN_USER, expiresAt: Date.now() + TTL_MS })
  res.cookie(COOKIE, sid, cookieOpts)
  res.json({ success: true, user: ADMIN_USER })
})

app.post("/auth/logout", (req, res) => {
  const sid = req.cookies?.[COOKIE]
  if (sid) sessions.delete(sid)
  res.clearCookie(COOKIE, { path: "/" })
  res.json({ success: true })
})

app.get("/auth/me", (req, res) => {
  const s = currentSession(req)
  if (!s) return res.status(401).json({ success: false })
  res.json({ success: true, user: s.username, links: FOOTER_LINKS })
})

// Diagnostic : teste la connexion du conteneur vers l'API PowerShell.
// Accessible apres login. Renvoie un verdict clair (ok / cause de l'echec).
app.get("/diag", requireAuth, async (req, res) => {
  const out = {
    apiUrl: API_URL || "(non defini)",
    tokenConfigured: !!API_TOKEN,
    dbReady,
    dbError: dbError || undefined,
  }
  if (!API_URL) return res.json({ ...out, ok: false, error: "URL_API_PSWINDEPLOY non defini." })
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  try {
    const r = await fetch(`${API_URL}/api/health`, { signal: ctrl.signal, ...(insecureAgent ? { dispatcher: insecureAgent } : {}) })
    clearTimeout(timer)
    const text = await r.text()
    out.health = { ok: r.ok, status: r.status, sample: text.slice(0, 200) }
  } catch (e) {
    clearTimeout(timer)
    const cause = e?.cause?.code || e?.code || (e?.name === "AbortError" ? "TIMEOUT" : e?.message)
    out.health = { ok: false, error: `${cause}` }
  }

  // Diagnostic des STATS : que renvoie l'API completed, et que contient la base ?
  try {
    const apiCompleted = await apiGet("/api/deploy/completed")
    out.apiCompleted = {
      ok: !!(apiCompleted && apiCompleted.success),
      count: Array.isArray(apiCompleted?.data) ? apiCompleted.data.length : 0,
    }
    // Forcer une sync et regarder le resultat + l'etat de la base apres.
    const sync = await syncDeployments()
    out.sync = sync
    try {
      const stats = computeStats()
      out.statsTotal = stats ? stats.Total : null
    } catch (e) { out.statsError = e?.message || String(e) }
    try {
      const { total } = listCompleted({ limit: 1, offset: 0 })
      out.dbRows = total
    } catch (e) { out.dbError = e?.message || String(e) }
    // Etat BRUT de la base (revele les lignes masquees qui n'apparaissent pas
    // dans les stats : cause frequente d'un deploiement "done" absent des stats).
    try { out.dbDump = debugDump() } catch (e) { out.dbDumpError = e?.message || String(e) }
  } catch (e) {
    out.statsDiagError = e?.message || String(e)
  }

  res.json({ ...out, ok: out.health?.ok !== false })
})

// Re-affiche les deploiements masques (hidden=1) : utile si on a supprime en
// test et que les stats restent vides. Sans :id -> reaffiche TOUS les masques.
app.post("/api/deploy/unhide", requireAuth, (req, res) => {
  try {
    const n = unhideDeployment(req.body?.id)
    res.json({ success: true, unhidden: n })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || String(e) })
  }
})
app.post("/api/deploy/unhide/:id", requireAuth, (req, res) => {
  try {
    const n = unhideDeployment(req.params.id)
    res.json({ success: true, unhidden: n })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || String(e) })
  }
})

// ─── Proxy securise vers l'API PowerShell ──────────────────
// /api/* exige une session. Le BFF injecte le token API (cote serveur) avant
// de relayer. Le navigateur ne voit jamais ce token.
// ─── Stats de deploiement (SQLite cote conteneur) ─────────
// IMPORTANT : ces routes sont AVANT le proxy /api generique pour qu'il ne les
// relaie pas a l'API. Elles synchronisent depuis l'API puis lisent SQLite.
app.get("/api/deploy/stats", requireAuth, async (req, res) => {
  const sync = await syncDeployments()   // pull + upsert (best effort)
  try {
    const stats = computeStats()
    res.json({ success: true, data: stats, sync })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || "Erreur stats." })
  }
})

app.get("/api/deploy/completed", requireAuth, async (req, res) => {
  await syncDeployments()
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 25, 1), 200)
    const offset = Math.max(parseInt(req.query.offset) || 0, 0)
    const { rows, total } = listCompleted({ limit, offset })
    res.json({ success: true, data: rows, total, limit, offset })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || "Erreur lecture." })
  }
})

// Suppression manuelle d'un suivi (SQLite uniquement -- l'API garde son historique).
app.delete("/api/deploy/completed/:id", requireAuth, (req, res) => {
  try {
    const n = deleteDeployment(req.params.id)
    res.json({ success: true, deleted: n })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || "Erreur suppression." })
  }
})

// Purge manuelle des deploiements plus vieux que N mois (defaut : PURGE_MONTHS,
// sinon 12). Body optionnel : { months: N }.
app.post("/api/deploy/purge", requireAuth, (req, res) => {
  try {
    const months = Number(req.body?.months) || PURGE_MONTHS || 12
    const n = purgeOlderThan(months)
    res.json({ success: true, purged: n, months })
  } catch (e) {
    res.status(500).json({ success: false, error: e?.message || "Erreur purge." })
  }
})

// ─── Mode "en attente" (pull interactif) ──────────────────
// La GUI liste les postes en attente, pousse une sequence, ou annule.
app.get("/api/deploy/waiting", requireAuth, async (req, res) => {
  try {
    const r = await apiGet("/api/deploy/waiting")
    res.json(r)
  } catch (e) {
    res.status(502).json({ success: false, error: e?.message || "API injoignable." })
  }
})

app.post("/api/deploy/pending/:id", requireAuth, async (req, res) => {
  try {
    const r = await apiSend("POST", `/api/deploy/pending/${encodeURIComponent(req.params.id)}`, req.body)
    res.status(r.status).json(r.data)
  } catch (e) {
    res.status(502).json({ success: false, error: e?.message || "API injoignable." })
  }
})

app.delete("/api/deploy/waiting/:id", requireAuth, async (req, res) => {
  try {
    const r = await apiSend("DELETE", `/api/deploy/waiting/${encodeURIComponent(req.params.id)}`)
    res.status(r.status).json(r.data)
  } catch (e) {
    res.status(502).json({ success: false, error: e?.message || "API injoignable." })
  }
})

app.use("/api", requireAuth, async (req, res) => {
  if (!API_URL) {
    return res.status(503).json({ success: false, error: "URL_API_PSWINDEPLOY non configuree dans le conteneur." })
  }
  const target = `${API_URL}${req.originalUrl}`   // conserve /api/...
  const headers = { "Content-Type": "application/json" }
  if (API_TOKEN) headers["X-Deploy-Token"] = API_TOKEN

  const init = { method: req.method, headers }
  if (!["GET", "HEAD"].includes(req.method) && req.body !== undefined) {
    init.body = JSON.stringify(req.body)
  }

  // Timeout explicite : sans ca, une API injoignable laisse la requete pendre.
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  init.signal = ctrl.signal

  try {
    if (insecureAgent) init.dispatcher = insecureAgent
    const r = await fetch(target, init)
    clearTimeout(timer)
    const text = await r.text()
    const ctype = r.headers.get("content-type") || ""
    // L'API doit repondre en JSON. Si elle renvoie du HTML (page d'erreur Pode,
    // route inconnue...), on ne le relaie pas tel quel (le front planterait en
    // tentant de le parser) : on renvoie une erreur JSON exploitable.
    if (ctype.includes("text/html") || /^\s*</.test(text)) {
      console.error(`[bff] reponse non-JSON de l'API (${r.status}) sur ${target}`)
      return res.status(502).json({
        success: false,
        error: `L'API a renvoye une reponse inattendue (HTTP ${r.status}) sur ${req.originalUrl}. Verifie que la route existe et que l'API a bien demarre.`,
      })
    }
    res.status(r.status)
    res.set("Content-Type", ctype || "application/json")
    res.send(text)
  } catch (e) {
    clearTimeout(timer)
    // Message precis selon la cause -> aide au diagnostic reseau.
    const isTimeout = e?.name === "AbortError"
    const cause = e?.cause?.code || e?.code || ""
    console.error(`[bff] proxy KO -> ${target} : ${isTimeout ? "timeout (8s)" : (cause || e?.message || e)}`)
    let msg = "API PowerShell injoignable."
    if (isTimeout) msg = `Delai depasse en joignant l'API (${API_URL}). Verifie le reseau conteneur->API et le firewall.`
    else if (cause === "ECONNREFUSED") msg = `Connexion refusee par ${API_URL}. L'API ecoute-t-elle et sur la bonne interface (pas localhost) ?`
    else if (cause === "EHOSTUNREACH" || cause === "ENETUNREACH") msg = `Hote injoignable (${API_URL}). Probleme de routage reseau depuis le conteneur.`
    else if (cause === "ENOTFOUND") msg = `Nom d'hote introuvable dans URL_API_PSWINDEPLOY (${API_URL}).`
    res.status(502).json({ success: false, error: msg })
  }
})

// ─── Frontend statique + SPA fallback ──────────────────────
app.use(express.static(STATIC_DIR))
app.get("*", (req, res) => res.sendFile(path.join(STATIC_DIR, "index.html")))

app.listen(PORT, () => {
  console.log(`[bff] PSWinDeploy console sur :${PORT}`)
  console.log(`[bff] API cible : ${API_URL || "(non defini)"} | token : ${API_TOKEN ? "fourni" : "absent"} | admin : ${ADMIN_USER}`)
})
