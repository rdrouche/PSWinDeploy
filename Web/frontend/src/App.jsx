// App.jsx -- PSWinDeploy console (P2). Login admin + pages de gestion.
import { useState, useEffect, useCallback } from "react"
import { api } from "./api.js"
import { STEP_TYPES, newStep } from "./stepTypes.js"
import { useT } from "./i18n.js"
import "./styles.css"

// Normalise une reponse en tableau (PowerShell/Pode peut renvoyer un objet
// unique ou null au lieu d'un tableau a 0/1 element).
function asArray(v) { return Array.isArray(v) ? v : (v == null ? [] : [v]) }

// ─── Toast minimal ─────────────────────────────────────────
function useToast() {
  const [toast, setToast] = useState(null)
  const show = useCallback((msg, kind = "ok") => {
    setToast({ msg, kind })
    setTimeout(() => setToast(null), 3200)
  }, [])
  const node = toast ? <div className={`toast ${toast.kind}`}>{toast.msg}</div> : null
  return [show, node]
}

// ─── Login ─────────────────────────────────────────────────
function Login({ onAuthed }) {
  const [user, setUser] = useState("")
  const [password, setPassword] = useState("")
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState(false)

  async function submit(e) {
    e.preventDefault()
    setErr(""); setBusy(true)
    const r = await api.login(user, password)
    setBusy(false)
    if (r && r.success) { onAuthed() }
    else setErr((r && r.error) || "Connection failed.")
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <div className="logo">PSWin<b>Deploy</b></div>
        <div className="sub">deployment console // phase 2</div>
        <label className="field">
          <span>Identifiant</span>
          <input type="text" value={user} onChange={e => setUser(e.target.value)} autoFocus />
        </label>
        <label className="field">
          <span>Mot de passe</span>
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} />
        </label>
        <button className="btn primary" style={{ width: "100%", marginTop: 6 }} disabled={busy}>
          {busy ? "Connexion..." : "Se connecter"}
        </button>
        {err && <div className="login-err">{err}</div>}
      </form>
    </div>
  )
}

// ─── Page : Catalogue ──────────────────────────────────────
function CataloguePage({ toast }) {
  const [apps, setApps] = useState([])
  const [filter, setFilter] = useState("")
  const [editing, setEditing] = useState(null)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    const r = await api.catalogue()
    setLoading(false)
    if (r && r.success) setApps(asArray(r.data))
    else toast((r && r.error) || "Could not read the catalogue.", "err")
  }, [toast])

  useEffect(() => { load() }, [load])

  const categories = [...new Set(apps.map(a => a.Category).filter(Boolean))].sort()
  const shown = apps.filter(a => !filter || a.Category === filter)

  async function save(app) {
    const r = await api.saveApp(app)
    if (r && r.success) { toast(r.updated ? "Application mise a jour." : "Application added."); setEditing(null); load() }
    else toast((r && r.error) || "Save failed.", "err")
  }
  async function remove(name) {
    if (!confirm(`Retirer "${name}" du catalogue ?`)) return
    const r = await api.deleteApp(name)
    if (r && r.success) { toast("Application removed."); load() }
    else toast((r && r.error) || "Delete failed.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Application catalogue</h1>
        <p>Applications offered for deployment. Each app declares its method (winget, choco, exe or script).</p>
      </div>

      <div className="panel">
        <div className="row" style={{ marginBottom: 14 }}>
          <select value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 200 }}>
            <option value="">All categories</option>
            {categories.map(c => <option key={c} value={c}>{c}</option>)}
          </select>
          <div className="spacer" />
          <button className="btn primary" onClick={() => setEditing(newApp())}>Add an application</button>
        </div>

        {loading ? <div className="empty">Loading...</div> :
          shown.length === 0 ? (
            <div className="empty">
              <p>Aucune application{filter ? " in this category" : ""}.</p>
              <p>Add your first application to make it deployable.</p>
            </div>
          ) : (
            <table>
              <thead><tr><th>Name</th><th>Category</th><th>Methode</th><th></th></tr></thead>
              <tbody>
                {shown.map((a, i) => (
                  <tr key={i}>
                    <td><b>{a.Name}</b></td>
                    <td>{a.Category ? <span className="badge cat">{a.Category}</span> : <span className="text-dim">—</span>}</td>
                    <td className="mono" style={{ color: "var(--text-dim)", fontSize: 12 }}>{methodOf(a)}</td>
                    <td style={{ textAlign: "right" }}>
                      <button className="btn sm ghost" onClick={() => setEditing({ ...a })}>Edit</button>
                      <button className="btn sm danger" onClick={() => remove(a.Name)} style={{ marginLeft: 6 }}>Retirer</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
      </div>

      {editing && <AppEditor app={editing} onCancel={() => setEditing(null)} onSave={save} categories={categories} />}
    </div>
  )
}

function newApp() { return { Name: "", Category: "", WingetId: "", ChocoId: "", Installer: "", Args: "", Script: "" } }
function methodOf(a) {
  if (a.Script) return "script"
  const m = []
  if (a.WingetId) m.push("winget")
  if (a.ChocoId) m.push("choco")
  if (a.Installer) m.push("exe")
  return m.join(" → ") || "—"
}

function AppEditor({ app, onCancel, onSave, categories }) {
  const [a, setA] = useState(app)
  const set = (k, v) => setA(p => ({ ...p, [k]: v }))
  const useScript = !!a.Script

  return (
    <div className="panel" style={{ borderColor: "var(--accent-dim)" }}>
      <h2>{app.Name ? `Modifier : ${app.Name}` : "New application"}</h2>
      <div className="row wrap" style={{ alignItems: "flex-start", gap: 16 }}>
        <div style={{ flex: 1, minWidth: 220 }}>
          <label className="field"><span>Name (displayed)</span>
            <input type="text" value={a.Name} onChange={e => set("Name", e.target.value)} /></label>
          <label className="field"><span>Category</span>
            <input type="text" list="cats" value={a.Category || ""} onChange={e => set("Category", e.target.value)} placeholder="Browsers, Office..." />
            <datalist id="cats">{categories.map(c => <option key={c} value={c} />)}</datalist></label>
        </div>
        <div style={{ flex: 1, minWidth: 220 }}>
          <label className="field"><span>Script d'installation dedie (.ps1) — methode unique</span>
            <input type="text" value={a.Script || ""} onChange={e => set("Script", e.target.value)} placeholder="\\IP\Software\x.ps1 or installs\x.ps1" /></label>
          {useScript && <p style={{ color: "var(--text-dim)", fontSize: 12, marginTop: -6 }}>Script set: other methods are ignored.</p>}
        </div>
      </div>

      {!useScript && (
        <div className="row wrap" style={{ alignItems: "flex-start", gap: 16 }}>
          <div style={{ flex: 1, minWidth: 180 }}>
            <label className="field"><span>WingetId</span>
              <input type="text" value={a.WingetId || ""} onChange={e => set("WingetId", e.target.value)} placeholder="Mozilla.Firefox" /></label>
            <label className="field"><span>ChocoId</span>
              <input type="text" value={a.ChocoId || ""} onChange={e => set("ChocoId", e.target.value)} placeholder="firefox" /></label>
          </div>
          <div style={{ flex: 1, minWidth: 180 }}>
            <label className="field"><span>Installer (exe/msi from the Software share)</span>
              <input type="text" value={a.Installer || ""} onChange={e => set("Installer", e.target.value)} /></label>
            <label className="field"><span>Arguments silencieux</span>
              <input type="text" value={a.Args || ""} onChange={e => set("Args", e.target.value)} placeholder="/S" /></label>
          </div>
        </div>
      )}

      <div className="row" style={{ marginTop: 8 }}>
        <div className="spacer" />
        <button className="btn ghost" onClick={onCancel}>Cancel</button>
        <button className="btn primary" onClick={() => onSave(a)} disabled={!a.Name}>Save</button>
      </div>
    </div>
  )
}

// ─── Page : Drivers ────────────────────────────────────────
function DriversPage({ toast }) {
  const [drivers, setDrivers] = useState([])
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    (async () => {
      const r = await api.drivers()
      setLoading(false)
      if (r && r.success) setDrivers(asArray(r.data))
      else toast((r && r.error) || "Could not read the drivers.", "err")
    })()
  }, [toast])

  return (
    <div>
      <div className="page-head">
        <h1>Drivers</h1>
        <p>Driver models available on the share. Drop the folders on the server; they appear here.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Loading...</div> :
          drivers.length === 0 ? (
            <div className="empty"><p>No driver model found.</p><p>Create one folder per model under the Drivers share (e.g. Dell-Latitude-5540).</p></div>
          ) : (
            <table>
              <thead><tr><th>Model</th><th>.inf files</th><th>Chemin</th></tr></thead>
              <tbody>
                {drivers.map((d, i) => (
                  <tr key={i}>
                    <td><b>{d.Name}</b></td>
                    <td><span className="badge info">{d.InfCount} .inf</span></td>
                    <td className="mono" style={{ color: "var(--text-dim)", fontSize: 12 }}>{d.Path}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
      </div>
    </div>
  )
}

// ─── Page : Suivi ──────────────────────────────────────────
function MonitorPage({ toast, t }) {
  if (!t) t = (k) => k   // securite si appele sans t
  const [list, setList] = useState([])
  const [waiting, setWaiting] = useState([])
  const [loading, setLoading] = useState(true)
  const [pushFor, setPushFor] = useState(null)   // poste cible du push (objet) ou null
  const [seqList, setSeqList] = useState([])
  const [busy, setBusy] = useState("")

  useEffect(() => {
    let stop = false
    let timer = null

    // Boucle de rafraichissement QUI N'EMPILE PAS : on attend la fin de chaque
    // appel avant de reprogrammer le suivant (5s apres la reponse). Si l'API est
    // lente, les requetes ne s'accumulent pas.
    async function tick() {
      const [r, w] = await Promise.all([api.deployCurrent(), api.deployWaiting()])
      if (stop) return
      setLoading(false)
      if (r && r.success) setList(asArray(r.data))
      if (w && w.success) setWaiting(asArray(w.data))
      timer = setTimeout(tick, 5000)
    }
    tick()

    return () => { stop = true; if (timer) clearTimeout(timer) }
  }, [])

  // Ouvre la modale de push : charge la liste des sequences disponibles.
  async function openPush(node) {
    setPushFor(node)
    const r = await api.sequences()
    if (r && r.success) setSeqList(asArray(r.data))
    else setSeqList([])
  }

  // Pousse une sequence existante vers le poste en attente.
  async function doPush(seqRef) {
    if (!pushFor) return
    setBusy(pushFor.Id)
    // L'API renvoie les sequences avec les champs Type et Name (majuscules).
    const seqType = seqRef.Type || seqRef.type || "template"
    const seqName = seqRef.Name || seqRef.name
    // Recuperer le contenu .psd1 de la sequence choisie. La route le renvoie
    // dans le champ "content".
    const c = await api.sequenceContent(seqType, seqName)
    const psd1 = c && c.success ? (c.content || c.data) : null
    if (!psd1) {
      setBusy(""); toast(t("monitor.push.read_err"), "err"); return
    }
    const r = await api.pushSequence(pushFor.Id, psd1, seqName)
    setBusy("")
    if (r && r.success) { toast(t("monitor.push.ok", pushFor.ComputerName || pushFor.Id)); setPushFor(null) }
    else toast((r && r.error) || t("monitor.push.err"), "err")
  }

  async function cancelWait(node) {
    setBusy(node.Id)
    const r = await api.cancelWaiting(node.Id)
    setBusy("")
    if (r && r.success) toast(t("monitor.cancel.ok"))
    else toast((r && r.error) || "Cancel failed.", "err")
  }

  const statusBadge = (s) => {
    const m = { running: "info", rebooting: "warn", waiting: "warn", done: "ok", error: "err" }
    const lbl = { waiting: "attente utilisateur" }
    return <span className={`badge ${m[s] || ""}`}>{lbl[s] || s || "?"}</span>
  }

  return (
    <div>
      <div className="page-head">
        <h1>Deployment monitoring</h1>
        <p>Machines currently deploying. Auto-refresh every 5 seconds.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Loading...</div> :
          list.length === 0 ? (
            <div className="empty"><p>No deployment in progress.</p><p>Machines appear here as soon as they start phase 2.</p></div>
          ) : (
            <table>
              <thead><tr><th>Machine</th><th>MAC</th><th>Etat</th><th>Step</th><th style={{ width: 160 }}>Avancement</th></tr></thead>
              <tbody>
                {list.map((d, i) => (
                  <tr key={i}>
                    <td><b>{d.computerName || "?"}</b></td>
                    <td className="mono" style={{ fontSize: 12 }}>{d.mac || "—"}</td>
                    <td>{statusBadge(d.status)}</td>
                    <td style={{ fontSize: 12.5 }}>{d.message || d.step || "—"}</td>
                    <td>
                      <div className="row" style={{ gap: 8 }}>
                        <span className="mono" style={{ fontSize: 12, width: 34 }}>{d.percent || 0}%</span>
                        <div className="progress" style={{ flex: 1 }}><div style={{ width: `${d.percent || 0}%` }} /></div>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
      </div>

      {/* Section : postes en attente d'une sequence poussee depuis le web */}
      <div className="panel">
        <h2 style={{ marginTop: 0 }}>{t("monitor.waiting.title")}</h2>
        {waiting.length === 0 ? (
          <div className="empty"><p>{t("monitor.waiting.empty")}</p><p>{t("monitor.waiting.hint")}</p></div>
        ) : (
          <table>
            <thead><tr><th>Machine</th><th>MAC</th><th>Depuis</th><th>Etat</th><th style={{ width: 220 }}></th></tr></thead>
            <tbody>
              {waiting.map((n, i) => (
                <tr key={n.Id || i}>
                  <td><b>{n.ComputerName || n.Id}</b></td>
                  <td className="mono" style={{ fontSize: 12 }}>{n.Mac || n.Id}</td>
                  <td style={{ fontSize: 12.5 }}>{n.Since ? new Date(n.Since).toLocaleTimeString() : "—"}</td>
                  <td>{n.Pushed ? <span className="badge ok">sequence envoyee</span> : <span className="badge warn">en attente</span>}</td>
                  <td style={{ textAlign: "right" }}>
                    <div className="row" style={{ gap: 8, justifyContent: "flex-end" }}>
                      <button className="btn sm" onClick={() => openPush(n)} disabled={busy === n.Id || n.Pushed}>{t("monitor.waiting.push")}</button>
                      <button className="btn sm ghost" onClick={() => cancelWait(n)} disabled={busy === n.Id}>{t("monitor.waiting.cancel")}</button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Modale : choisir la sequence a pousser */}
      {pushFor && (
        <div className="modal-backdrop" onClick={() => setPushFor(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()} style={{ padding: 20 }}>
            <div className="row" style={{ marginBottom: 12 }}>
              <h2 style={{ margin: 0 }}>{t("monitor.push.title", pushFor.ComputerName || pushFor.Id)}</h2>
              <div className="spacer" />
              <button className="btn ghost sm" onClick={() => setPushFor(null)}>Close</button>
            </div>
            <p style={{ color: "var(--text-dim)", fontSize: 13, marginTop: 0 }}>
              Choisis une sequence existante. Le poste la recevra et la jouera immediatement.
            </p>
            {seqList.length === 0 ? (
              <div className="empty">
                <p>No sequence available.</p>
                <p>Create it first in the editor, then come back to push it.</p>
              </div>
            ) : (
              <div style={{ maxHeight: 360, overflowY: "auto" }}>
                {seqList.map((s, i) => (
                  <div key={i} className="row" style={{ padding: "8px 0", borderBottom: "1px solid var(--border)" }}>
                                    <div>
                      <b>{s.Name || s.name}</b>
                      {(s.Type || s.type) && <span className="badge cat" style={{ marginLeft: 8 }}>{s.Type || s.type}</span>}
                    </div>
                    <div className="spacer" />
                    <button className="btn sm" onClick={() => doPush(s)} disabled={busy === pushFor.Id}>
                      {busy === pushFor.Id ? "Envoi..." : "Push"}
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

// ─── Page : Sequences ──────────────────────────────────────
function SequencesPage({ toast }) {
  const [steps, setSteps] = useState([])
  const [target, setTarget] = useState({ kind: "template", value: "" })
  const [catalogue, setCatalogue] = useState([])
  const [scripts, setScripts] = useState([])
  const [drivers, setDrivers] = useState([])
  const [seqList, setSeqList] = useState([])
  const [loadFrom, setLoadFrom] = useState("")   // "type::name" of the template to load
  const [addType, setAddType] = useState("InstallApps")

  const loadSeqList = useCallback(async () => {
    const r = await api.sequences()
    if (r && r.success) setSeqList(asArray(r.data))
  }, [])

  useEffect(() => {
    (async () => {
      const [c, s, d] = await Promise.all([api.catalogue(), api.scripts(), api.drivers()])
      if (c && c.success) setCatalogue(asArray(c.data))
      if (s && s.success) setScripts(asArray(s.data))
      if (d && d.success) setDrivers(asArray(d.data))
    })()
    loadSeqList()
  }, [loadSeqList])

  // Charge une sequence existante (souvent un template) dans l'editeur, pour la
  // decliner. On normalise les steps et on genere un Id si absent.
  async function loadTemplate() {
    if (!loadFrom) return
    const [type, name] = loadFrom.split("::")
    const r = await api.sequenceObject(type, name)
    if (!(r && r.success && r.data)) { toast((r && r.error) || "Loading failed.", "err"); return }
    const seq = r.data
    const loadedSteps = asArray(seq.Steps).map(s => ({
      Id: s.Id || `step-${Math.random().toString(36).slice(2, 8)}`,
      Name: s.Name || s.Type || "Step",
      Type: s.Type,
      Phase: s.Phase || "Windows",
      Enabled: s.Enabled !== false,
      RebootAfter: s.RebootAfter || "IfRequired",
      Params: s.Params || {},
    }))
    setSteps(loadedSteps)
    toast(`Charge depuis ${type} / ${name} (${loadedSteps.length} etape(s)). Choisis une cible et enregistre.`)
  }

  const addStep = () => setSteps(p => [...p, newStep(addType)])
  const updateStep = (idx, s) => setSteps(p => p.map((x, i) => i === idx ? s : x))
  const removeStep = (idx) => setSteps(p => p.filter((_, i) => i !== idx))
  const move = (idx, dir) => setSteps(p => {
    const n = [...p]; const j = idx + dir
    if (j < 0 || j >= n.length) return p
    ;[n[idx], n[j]] = [n[j], n[idx]]; return n
  })

  async function save() {
    if (target.kind === "template") {
      if (!target.value) { toast("Give the template a name.", "err"); return }
      const seq = { Name: target.value, Steps: steps }
      const r = await api.saveSequenceTemplate(target.value, seq)
      if (r && r.success) { toast(`Template enregistre : ${r.path}`); loadSeqList() }
      else toast((r && r.error) || "Save failed.", "err")
      return
    }
    if (!target.value) { toast("Enter the target machine name or MAC.", "err"); return }
    const seq = { Name: `Sequence ${target.value}`, Steps: steps }
    const r = target.kind === "by-name"
      ? await api.saveSequenceByName(target.value, seq)
      : await api.saveSequenceByMac(target.value, seq)
    if (r && r.success) toast(`Sequence enregistree : ${r.path}`)
    else toast((r && r.error) || "Save failed.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Editeur de sequence</h1>
        <p>Compose the post-installation sequence step by step, then save it for a machine (by name or by MAC).</p>
      </div>

      <div className="panel">
        <h2>Target</h2>
        <div className="row wrap">
          <select value={target.kind} onChange={e => setTarget({ ...target, kind: e.target.value })} style={{ width: 200 }}>
            <option value="template">Template reutilisable</option>
            <option value="by-name">By machine name</option>
            <option value="by-mac">By MAC address</option>
          </select>
          <input type="text" value={target.value} onChange={e => setTarget({ ...target, value: e.target.value })}
            placeholder={target.kind === "by-name" ? "PC-COMPTA-01" : target.kind === "by-mac" ? "AABBCCDDEEFF" : "Workstation-Standard"} style={{ flex: 1 }} />
        </div>
        {target.kind === "template" && (
          <p style={{ color: "var(--text-dim)", fontSize: 12.5, marginTop: 8, marginBottom: 0 }}>
            Un template est enregistre a la racine du dossier Sequences. Il est selectionnable directement en phase 2 sur le poste (choix 1 de l'assistant), sans etre lie a une machine.
          </p>
        )}
      </div>

      <div className="panel">
        <h2>Start from an existing sequence</h2>
        <p style={{ color: "var(--text-dim)", fontSize: 12.5, marginTop: -4 }}>
          Loads the steps of a template (or an existing sequence) as a starting point. You can then change the target above to derive it as by-name / by-mac. The source is not modified.
        </p>
        <div className="row wrap">
          <select value={loadFrom} onChange={e => setLoadFrom(e.target.value)} style={{ flex: 1, minWidth: 220 }}>
            <option value="">— choose a sequence —</option>
            {seqList.filter(s => s.Type === "template").length > 0 && (
              <optgroup label="Templates">
                {seqList.filter(s => s.Type === "template").map((s, i) => (
                  <option key={`t${i}`} value={`template::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
            {seqList.filter(s => s.Type === "by-name").length > 0 && (
              <optgroup label="By name">
                {seqList.filter(s => s.Type === "by-name").map((s, i) => (
                  <option key={`n${i}`} value={`by-name::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
            {seqList.filter(s => s.Type === "by-mac").length > 0 && (
              <optgroup label="By MAC">
                {seqList.filter(s => s.Type === "by-mac").map((s, i) => (
                  <option key={`m${i}`} value={`by-mac::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
          </select>
          <button className="btn" onClick={loadTemplate} disabled={!loadFrom}>Load steps</button>
        </div>
      </div>

      <div className="panel">
        <div className="row" style={{ marginBottom: 12 }}>
          <h2 style={{ margin: 0 }}>Etapes ({steps.length})</h2>
          <div className="spacer" />
          <select value={addType} onChange={e => setAddType(e.target.value)} style={{ width: 220 }}>
            {Object.entries(STEP_TYPES).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </select>
          <button className="btn" onClick={addStep}>Add step</button>
        </div>

        {steps.length === 0 ? (
          <div className="empty"><p>Sequence vide.</p><p>Add a first step to get started.</p></div>
        ) : steps.map((s, i) => (
          <StepCard key={s.Id} step={s} ord={i + 1}
            onChange={(ns) => updateStep(i, ns)} onRemove={() => removeStep(i)}
            onUp={() => move(i, -1)} onDown={() => move(i, 1)}
            catalogue={catalogue} scripts={scripts} drivers={drivers} />
        ))}
      </div>

      <div className="row">
        <div className="spacer" />
        <button className="btn primary" onClick={save} disabled={steps.length === 0}>Save sequence</button>
      </div>
    </div>
  )
}

function StepCard({ step, ord, onChange, onRemove, onUp, onDown, catalogue, scripts, drivers }) {
  const [open, setOpen] = useState(true)
  const def = STEP_TYPES[step.Type]
  const setParam = (k, v) => onChange({ ...step, Params: { ...step.Params, [k]: v } })

  return (
    <div className={`step ${step.Enabled ? "" : "disabled"}`}>
      <div className="step-head" onClick={() => setOpen(!open)}>
        <span className="ord">{String(ord).padStart(2, "0")}</span>
        <span className="ttl">{step.Name}</span>
        <span className="typ">{step.Type}</span>
        <div className="spacer" />
        <button className="btn sm ghost" onClick={e => { e.stopPropagation(); onUp() }}>↑</button>
        <button className="btn sm ghost" onClick={e => { e.stopPropagation(); onDown() }}>↓</button>
        <button className="btn sm danger" onClick={e => { e.stopPropagation(); onRemove() }}>Retirer</button>
      </div>
      {open && (
        <div className="step-body">
          <p style={{ color: "var(--text-dim)", fontSize: 12.5, marginTop: 8 }}>{def?.desc}</p>
          <label className="field"><span>Step name</span>
            <input type="text" value={step.Name} onChange={e => onChange({ ...step, Name: e.target.value })} /></label>

          {def?.fields.map(f => (
            <StepField key={f.key} field={f} value={step.Params[f.key]} onChange={v => setParam(f.key, v)}
              catalogue={catalogue} scripts={scripts} drivers={drivers} />
          ))}

          <div className="row" style={{ marginTop: 8 }}>
            <label className="row" style={{ gap: 6, fontSize: 13 }}>
              <input type="checkbox" style={{ width: "auto" }} checked={step.Enabled} onChange={e => onChange({ ...step, Enabled: e.target.checked })} />
              Etape active
            </label>
            <div className="spacer" />
            <span style={{ fontSize: 12, color: "var(--text-dim)" }}>Reboot apres :</span>
            <select value={step.RebootAfter} onChange={e => onChange({ ...step, RebootAfter: e.target.value })} style={{ width: 130 }}>
              <option value="Never">Jamais</option>
              <option value="IfRequired">Si requis</option>
              <option value="Always">Toujours</option>
            </select>
          </div>
        </div>
      )}
    </div>
  )
}

function StepField({ field, value, onChange, catalogue, scripts, drivers }) {
  if (field.type === "appList") {
    const selected = value || []
    const toggle = (name) => onChange(selected.includes(name) ? selected.filter(x => x !== name) : [...selected, name])
    return (
      <label className="field"><span>{field.label}</span>
        <div className="row wrap" style={{ gap: 6 }}>
          {catalogue.length === 0 ? <span style={{ color: "var(--text-dim)", fontSize: 12 }}>Catalogue vide.</span> :
            catalogue.map((a, i) => (
              <button key={i} type="button" className={`btn sm ${selected.includes(a.Name) ? "primary" : "ghost"}`}
                onClick={() => toggle(a.Name)}>{a.Name}</button>
            ))}
        </div>
      </label>
    )
  }
  if (field.type === "scriptPick") {
    return (
      <label className="field"><span>{field.label}</span>
        <input type="text" list="scripts-dl" value={value || ""} onChange={e => onChange(e.target.value)} placeholder={field.placeholder} />
        <datalist id="scripts-dl">{scripts.map((s, i) => <option key={i} value={s.RelativePath}>{s.Name}</option>)}</datalist>
      </label>
    )
  }
  if (field.type === "driverPick") {
    return (
      <label className="field"><span>{field.label}</span>
        <select value={value || ""} onChange={e => onChange(e.target.value)}>
          <option value="">— none —</option>
          {drivers.map((d, i) => <option key={i} value={d.Name}>{d.Name} ({d.InfCount} .inf)</option>)}
        </select>
      </label>
    )
  }
  if (field.type === "select") {
    return (
      <label className="field"><span>{field.label}</span>
        <select value={value || ""} onChange={e => onChange(e.target.value)}>
          {field.options.map(o => <option key={o} value={o}>{o}</option>)}
        </select>
      </label>
    )
  }
  if (field.type === "checkbox") {
    return (
      <label className="row" style={{ gap: 6, fontSize: 13, marginBottom: 12 }}>
        <input type="checkbox" style={{ width: "auto" }} checked={!!value} onChange={e => onChange(e.target.checked)} />
        {field.label}
      </label>
    )
  }
  if (field.type === "number") {
    return (
      <label className="field"><span>{field.label}</span>
        <input type="number" value={value ?? ""} onChange={e => onChange(Number(e.target.value))} /></label>
    )
  }
  return (
    <label className="field"><span>{field.label}</span>
      <input type="text" value={value || ""} onChange={e => onChange(e.target.value)} placeholder={field.placeholder} /></label>
  )
}

// ─── Visionneuse de code (modal lecture seule) ─────────────
function CodeViewer({ title, content, onClose }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <span className="mono">{title}</span>
          <button className="btn sm ghost" onClick={onClose}>Close</button>
        </div>
        <pre className="code-view">{content || "(vide)"}</pre>
      </div>
    </div>
  )
}

// ─── Page : Scripts ────────────────────────────────────────
function ScriptsPage({ toast }) {
  const [scripts, setScripts] = useState([])
  const [loading, setLoading] = useState(true)
  const [view, setView] = useState(null)   // { title, content }

  useEffect(() => {
    (async () => {
      const r = await api.scripts()
      setLoading(false)
      if (r && r.success) setScripts(asArray(r.data))
      else toast((r && r.error) || "Could not read the scripts.", "err")
    })()
  }, [toast])

  async function open(s) {
    const r = await api.scriptContent(s.RelativePath)
    if (r && r.success) setView({ title: s.RelativePath, content: r.content })
    else toast((r && r.error) || "Could not read the script.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Scripts</h1>
        <p>PowerShell scripts from the share, usable in RunScript steps. Click to view the content.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Loading...</div> :
          scripts.length === 0 ? (
            <div className="empty"><p>No script found.</p><p>Drop .ps1 files on the Scripts share.</p></div>
          ) : (
            <table>
              <thead><tr><th>Name</th><th>Chemin relatif</th><th></th></tr></thead>
              <tbody>
                {scripts.map((s, i) => (
                  <tr key={i}>
                    <td><b>{s.Name}</b></td>
                    <td className="mono" style={{ color: "var(--text-dim)", fontSize: 12 }}>{s.RelativePath}</td>
                    <td style={{ textAlign: "right" }}>
                      <button className="btn sm ghost" onClick={() => open(s)}>Voir</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
      </div>
      {view && <CodeViewer title={view.title} content={view.content} onClose={() => setView(null)} />}
    </div>
  )
}

// ─── Page : Sequences (liste + voir) ───────────────────────
function SequenceListPage({ toast }) {
  const [list, setList] = useState([])
  const [loading, setLoading] = useState(true)
  const [view, setView] = useState(null)
  const [filter, setFilter] = useState("")
  const [opening, setOpening] = useState("")   // nom en cours de chargement

  const load = useCallback(async () => {
    setLoading(true)
    const r = await api.sequences()
    setLoading(false)
    if (r && r.success) setList(asArray(r.data))
    else toast((r && r.error) || "Could not read the sequences.", "err")
  }, [toast])

  useEffect(() => { load() }, [load])

  async function open(s) {
    if (opening) return            // un chargement est deja en cours -> ignorer
    setOpening(s.Name)
    const r = await api.sequenceContent(s.Type, s.Name)
    setOpening("")
    if (r && r.success) setView({ title: `${s.Type} / ${s.Name}.psd1`, content: r.content })
    else toast((r && r.error) || "Could not read the sequence.", "err")
  }

  const typeBadge = (t) => {
    const m = { template: "cat", "by-name": "info", "by-mac": "warn" }
    const lbl = { template: "template", "by-name": "by name", "by-mac": "by MAC" }
    return <span className={`badge ${m[t] || ""}`}>{lbl[t] || t}</span>
  }
  const shown = list.filter(s => !filter || s.Type === filter)

  return (
    <div>
      <div className="page-head">
        <h1>Sequences</h1>
        <p>All available sequences: reusable templates, and sequences assigned by name or MAC. Click to view the content.</p>
      </div>
      <div className="panel">
        <div className="row" style={{ marginBottom: 14 }}>
          <select value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 200 }}>
            <option value="">All types</option>
            <option value="template">Templates</option>
            <option value="by-name">By name</option>
            <option value="by-mac">By MAC</option>
          </select>
          <div className="spacer" />
          <button className="btn ghost" onClick={load}>Rafraichir</button>
        </div>
        {loading ? <div className="empty">Loading...</div> :
          shown.length === 0 ? (
            <div className="empty"><p>Aucune sequence{filter ? " of this type" : ""}.</p><p>Cree un template depuis l'editeur de sequence.</p></div>
          ) : (
            <table>
              <thead><tr><th>Name</th><th>Type</th><th></th></tr></thead>
              <tbody>
                {shown.map((s, i) => (
                  <tr key={i}>
                    <td><b>{s.Name}</b></td>
                    <td>{typeBadge(s.Type)}</td>
                    <td style={{ textAlign: "right" }}>
                      <button className="btn sm ghost" onClick={() => open(s)} disabled={!!opening}>
                        {opening === s.Name ? "Lecture..." : "Voir"}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
      </div>
      {view && <CodeViewer title={view.title} content={view.content} onClose={() => setView(null)} />}
    </div>
  )
}

// ─── Page : Statistiques ───────────────────────────────────
function StatsPage({ toast, t }) {
  if (!t) t = (k) => k
  const [stats, setStats] = useState(null)
  const [completed, setCompleted] = useState([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(0)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState("")
  const PAGE_SIZE = 25

  const loadStats = useCallback(async () => {
    const s = await api.deployStats()
    if (s && s.success) setStats(s.data)
    else toast((s && s.error) || "Stats indisponibles.", "err")
  }, [toast])

  const loadPage = useCallback(async (p) => {
    setLoading(true)
    const c = await api.deployCompleted(PAGE_SIZE, p * PAGE_SIZE)
    setLoading(false)
    if (c && c.success) { setCompleted(asArray(c.data)); setTotal(c.total || 0) }
    else toast((c && c.error) || "Could not read.", "err")
  }, [toast])

  useEffect(() => { loadStats() }, [loadStats])
  useEffect(() => { loadPage(page) }, [loadPage, page])

  async function removeOne(id) {
    setBusy(id)
    const r = await api.deleteDeployment(id)
    setBusy("")
    if (r && r.success) { toast("Entry removed."); loadPage(page); loadStats() }
    else toast((r && r.error) || "Delete failed.", "err")
  }

  async function purge() {
    const months = parseInt(window.prompt("Delete completed deployments older than how many months?", "12"), 10)
    if (!months || months <= 0) return
    setBusy("purge")
    const r = await api.purgeDeployments(months)
    setBusy("")
    if (r && r.success) { toast(`${r.purged} suivi(s) purge(s) (> ${r.months} mois).`); setPage(0); loadPage(0); loadStats() }
    else toast((r && r.error) || "Purge failed.", "err")
  }

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))

  const fmtDur = (sec) => {
    if (sec == null) return "—"
    const m = Math.floor(sec / 60), s = sec % 60
    if (m === 0) return `${s}s`
    return `${m}min ${String(s).padStart(2, "0")}s`
  }
  const fmtDate = (iso) => {
    if (!iso) return "—"
    try { return new Date(iso).toLocaleString() } catch { return iso }
  }

  return (
    <div>
      <div className="page-head">
        <h1>{t("stats.title")}</h1>
        <p>Summary of completed deployments: volumes per period and durations.</p>
      </div>

      {loading ? <div className="panel"><div className="empty">Loading...</div></div> : (
        <>
          <div className="stat-grid">
            <div className="stat-card"><div className="stat-num">{stats?.Today ?? 0}</div><div className="stat-lbl">{t("stats.today")}</div></div>
            <div className="stat-card"><div className="stat-num">{stats?.Week ?? 0}</div><div className="stat-lbl">{t("stats.week")}</div></div>
            <div className="stat-card"><div className="stat-num">{stats?.Month ?? 0}</div><div className="stat-lbl">{t("stats.month")}</div></div>
            <div className="stat-card"><div className="stat-num">{stats?.Year ?? 0}</div><div className="stat-lbl">{t("stats.year")}</div></div>
            <div className="stat-card"><div className="stat-num">{stats?.Total ?? 0}</div><div className="stat-lbl">{t("stats.total")}</div></div>
          </div>

          <div className="panel">
            <h2>Durees</h2>
            <div className="row wrap" style={{ gap: 30 }}>
              <div><div style={{ color: "var(--text-dim)", fontSize: 12 }}>Moyenne</div><div style={{ fontSize: 20, fontWeight: 600 }}>{fmtDur(stats?.AvgDurationSec)}</div></div>
              <div><div style={{ color: "var(--text-dim)", fontSize: 12 }}>Minimum</div><div style={{ fontSize: 20, fontWeight: 600, color: "var(--ok)" }}>{fmtDur(stats?.MinDurationSec)}</div></div>
              <div><div style={{ color: "var(--text-dim)", fontSize: 12 }}>Maximum</div><div style={{ fontSize: 20, fontWeight: 600, color: "var(--warn)" }}>{fmtDur(stats?.MaxDurationSec)}</div></div>
            </div>
          </div>

          <div className="panel">
            <div className="row" style={{ marginBottom: 12 }}>
              <h2 style={{ margin: 0 }}>Completed deployments</h2>
              <div className="spacer" />
              <button className="btn ghost" onClick={purge} disabled={busy === "purge"}>{busy === "purge" ? "..." : t("stats.purge")}</button>
              <button className="btn ghost" onClick={() => { loadPage(page); loadStats() }}>Rafraichir</button>
            </div>
            {completed.length === 0 ? (
              <div className="empty"><p>Aucun deploiement termine{page > 0 ? " on this page" : ""}.</p></div>
            ) : (
              <>
              <table>
                <thead><tr><th>Machine</th><th>Debut</th><th>Fin</th><th>Duree</th><th>Etat</th><th></th></tr></thead>
                <tbody>
                  {completed.map((d, i) => (
                                    <tr key={d.Id || i}>
                      <td><b>{d.ComputerName || d.Mac || "?"}</b></td>
                      <td style={{ fontSize: 12.5 }}>{fmtDate(d.Start)}</td>
                      <td style={{ fontSize: 12.5 }}>{fmtDate(d.End)}</td>
                      <td className="mono">{fmtDur(d.DurationSec)}</td>
                      <td>{d.Completed ? <span className="badge ok">termine</span> : <span className="badge warn">{d.Status}</span>}</td>
                      <td style={{ textAlign: "right" }}>
                        <button className="btn sm ghost" onClick={() => removeOne(d.Id)} disabled={busy === d.Id} title="Delete this entry">
                          {busy === d.Id ? "..." : "Suppr."}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="row" style={{ marginTop: 14, alignItems: "center" }}>
                <span style={{ color: "var(--text-dim)", fontSize: 12.5 }}>
                  {total} deploiement(s) -- page {page + 1} / {totalPages}
                </span>
                <div className="spacer" />
                <button className="btn sm ghost" onClick={() => setPage(p => Math.max(0, p - 1))} disabled={page === 0 || loading}>Precedent</button>
                <button className="btn sm ghost" onClick={() => setPage(p => p + 1)} disabled={page + 1 >= totalPages || loading}>Suivant</button>
              </div>
              </>
            )}
          </div>
        </>
      )}
    </div>
  )
}

// ─── Shell ─────────────────────────────────────────────────
const PAGES = [
  { id: "editor", label: "Editeur", comp: SequencesPage },
  { id: "sequences", label: "Sequences", comp: SequenceListPage },
  { id: "catalogue", label: "Catalogue", comp: CataloguePage },
  { id: "scripts", label: "Scripts", comp: ScriptsPage },
  { id: "drivers", label: "Drivers", comp: DriversPage },
  { id: "monitor", label: "Suivi", comp: MonitorPage },
  { id: "stats", label: "Statistiques", comp: StatsPage },
]

// Petites icones (emoji, sans dependance) pour les liens de pied de page.
const FOOT_ICONS = {
  github: "\u{1F419}",  // poulpe (clin d'oeil GitHub)
  kofi:   "\u2615",     // tasse de cafe
  docs:   "\u{1F4D8}",  // livre
  site:   "\u{1F310}",  // globe
}

export default function App() {
  const { t } = useT()
  const [authed, setAuthed] = useState(false)
  const [checking, setChecking] = useState(true)
  const [page, setPage] = useState("editor")
  const [links, setLinks] = useState([])
  const [toast, toastNode] = useToast()

  // Au demarrage : verifier si une session valide existe deja (cookie).
  useEffect(() => {
    (async () => {
      const r = await api.me()
      setAuthed(!!(r && r.success))
      if (r && r.success && Array.isArray(r.links)) setLinks(r.links)
      setChecking(false)
    })()
  }, [])

  async function logout() {
    await api.logout()
    setAuthed(false)
  }

  if (checking) return <div className="login-wrap"><div style={{ color: "var(--text-dim)" }}>Loading...</div></div>
  if (!authed) return <Login onAuthed={() => setAuthed(true)} />

  const Page = PAGES.find(p => p.id === page)?.comp || SequencesPage

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <div className="logo">PSWin<b>Deploy</b></div>
          <div className="sub">console // phase 2</div>
        </div>
        <nav className="nav">
          {PAGES.map(p => (
            <button key={p.id} className={page === p.id ? "active" : ""} onClick={() => setPage(p.id)}>
              <span className="dot" />{t(`nav.${p.id}`)}
            </button>
          ))}
        </nav>
        <div className="sidebar-foot">
          {t("nav.connected")}
          <button onClick={logout}>{t("nav.logout")}</button>
          {links.length > 0 && (
            <div className="foot-links">
              {links.map((l) => (
                <a key={l.key} href={l.url} target="_blank" rel="noopener noreferrer" title={l.label}>
                  <span className="foot-ico">{FOOT_ICONS[l.key] || "\u2197"}</span>
                  <span>{l.label}</span>
                </a>
              ))}
            </div>
          )}
        </div>
      </aside>
      <main className="main">
        <Page toast={toast} t={t} />
      </main>
      {toastNode}
    </div>
  )
}
