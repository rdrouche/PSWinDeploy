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
  res.json({ success: true, user: s.username })
})

// Diagnostic : teste la connexion du conteneur vers l'API PowerShell.
// Accessible apres login. Renvoie un verdict clair (ok / cause de l'echec).
app.get("/diag", requireAuth, async (req, res) => {
  const out = { apiUrl: API_URL || "(non defini)", tokenConfigured: !!API_TOKEN }
  if (!API_URL) return res.json({ ...out, ok: false, error: "URL_API_PSWINDEPLOY non defini." })
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  try {
    const r = await fetch(`${API_URL}/api/health`, { signal: ctrl.signal })
    clearTimeout(timer)
    const text = await r.text()
    res.json({ ...out, ok: r.ok, status: r.status, sample: text.slice(0, 200) })
  } catch (e) {
    clearTimeout(timer)
    const cause = e?.cause?.code || e?.code || (e?.name === "AbortError" ? "TIMEOUT" : e?.message)
    res.json({ ...out, ok: false, error: `${cause}` })
  }
})

// ─── Proxy securise vers l'API PowerShell ──────────────────
// /api/* exige une session. Le BFF injecte le token API (cote serveur) avant
// de relayer. Le navigateur ne voit jamais ce token.
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
    const r = await fetch(target, init)
    clearTimeout(timer)
    const text = await r.text()
    res.status(r.status)
    res.set("Content-Type", r.headers.get("content-type") || "application/json")
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
