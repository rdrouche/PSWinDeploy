// App.jsx -- PSWinDeploy console (P2). Login admin + pages de gestion.
import { useState, useEffect, useCallback } from "react"
import { api } from "./api.js"
import { STEP_TYPES, newStep } from "./stepTypes.js"
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
    else setErr((r && r.error) || "Connexion impossible.")
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <div className="logo">PSWin<b>Deploy</b></div>
        <div className="sub">console de deploiement // phase 2</div>
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
    else toast((r && r.error) || "Lecture du catalogue impossible.", "err")
  }, [toast])

  useEffect(() => { load() }, [load])

  const categories = [...new Set(apps.map(a => a.Category).filter(Boolean))].sort()
  const shown = apps.filter(a => !filter || a.Category === filter)

  async function save(app) {
    const r = await api.saveApp(app)
    if (r && r.success) { toast(r.updated ? "Application mise a jour." : "Application ajoutee."); setEditing(null); load() }
    else toast((r && r.error) || "Echec de l'enregistrement.", "err")
  }
  async function remove(name) {
    if (!confirm(`Retirer "${name}" du catalogue ?`)) return
    const r = await api.deleteApp(name)
    if (r && r.success) { toast("Application retiree."); load() }
    else toast((r && r.error) || "Echec de la suppression.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Catalogue d'applications</h1>
        <p>Les applications proposees au deploiement. Chaque app declare sa methode (winget, choco, exe ou script).</p>
      </div>

      <div className="panel">
        <div className="row" style={{ marginBottom: 14 }}>
          <select value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 200 }}>
            <option value="">Toutes les categories</option>
            {categories.map(c => <option key={c} value={c}>{c}</option>)}
          </select>
          <div className="spacer" />
          <button className="btn primary" onClick={() => setEditing(newApp())}>Ajouter une application</button>
        </div>

        {loading ? <div className="empty">Chargement...</div> :
          shown.length === 0 ? (
            <div className="empty">
              <p>Aucune application{filter ? " dans cette categorie" : ""}.</p>
              <p>Ajoute ta premiere application pour la rendre deployable.</p>
            </div>
          ) : (
            <table>
              <thead><tr><th>Nom</th><th>Categorie</th><th>Methode</th><th></th></tr></thead>
              <tbody>
                {shown.map((a, i) => (
                  <tr key={i}>
                    <td><b>{a.Name}</b></td>
                    <td>{a.Category ? <span className="badge cat">{a.Category}</span> : <span className="text-dim">—</span>}</td>
                    <td className="mono" style={{ color: "var(--text-dim)", fontSize: 12 }}>{methodOf(a)}</td>
                    <td style={{ textAlign: "right" }}>
                      <button className="btn sm ghost" onClick={() => setEditing({ ...a })}>Modifier</button>
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
      <h2>{app.Name ? `Modifier : ${app.Name}` : "Nouvelle application"}</h2>
      <div className="row wrap" style={{ alignItems: "flex-start", gap: 16 }}>
        <div style={{ flex: 1, minWidth: 220 }}>
          <label className="field"><span>Nom (affiche)</span>
            <input type="text" value={a.Name} onChange={e => set("Name", e.target.value)} /></label>
          <label className="field"><span>Categorie</span>
            <input type="text" list="cats" value={a.Category || ""} onChange={e => set("Category", e.target.value)} placeholder="Navigateurs, Bureautique..." />
            <datalist id="cats">{categories.map(c => <option key={c} value={c} />)}</datalist></label>
        </div>
        <div style={{ flex: 1, minWidth: 220 }}>
          <label className="field"><span>Script d'installation dedie (.ps1) — methode unique</span>
            <input type="text" value={a.Script || ""} onChange={e => set("Script", e.target.value)} placeholder="\\IP\Logiciels\x.ps1 ou installs\x.ps1" /></label>
          {useScript && <p style={{ color: "var(--text-dim)", fontSize: 12, marginTop: -6 }}>Script renseigne : les autres methodes sont ignorees.</p>}
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
            <label className="field"><span>Installeur (exe/msi du partage Logiciels)</span>
              <input type="text" value={a.Installer || ""} onChange={e => set("Installer", e.target.value)} /></label>
            <label className="field"><span>Arguments silencieux</span>
              <input type="text" value={a.Args || ""} onChange={e => set("Args", e.target.value)} placeholder="/S" /></label>
          </div>
        </div>
      )}

      <div className="row" style={{ marginTop: 8 }}>
        <div className="spacer" />
        <button className="btn ghost" onClick={onCancel}>Annuler</button>
        <button className="btn primary" onClick={() => onSave(a)} disabled={!a.Name}>Enregistrer</button>
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
      else toast((r && r.error) || "Lecture des drivers impossible.", "err")
    })()
  }, [toast])

  return (
    <div>
      <div className="page-head">
        <h1>Drivers</h1>
        <p>Les modeles de drivers disponibles sur le partage. Depose les dossiers sur le serveur ; ils apparaissent ici.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Chargement...</div> :
          drivers.length === 0 ? (
            <div className="empty"><p>Aucun modele de drivers trouve.</p><p>Cree un dossier par modele sous le partage Drivers (ex : Dell-Latitude-5540).</p></div>
          ) : (
            <table>
              <thead><tr><th>Modele</th><th>Fichiers .inf</th><th>Chemin</th></tr></thead>
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
function MonitorPage({ toast }) {
  const [list, setList] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let stop = false
    let timer = null

    // Boucle de rafraichissement QUI N'EMPILE PAS : on attend la fin de chaque
    // appel avant de reprogrammer le suivant (5s apres la reponse). Si l'API est
    // lente, les requetes ne s'accumulent pas.
    async function tick() {
      const r = await api.deployCurrent()
      if (stop) return
      setLoading(false)
      if (r && r.success) setList(asArray(r.data))
      timer = setTimeout(tick, 5000)
    }
    tick()

    return () => { stop = true; if (timer) clearTimeout(timer) }
  }, [])

  const statusBadge = (s) => {
    const m = { running: "info", rebooting: "warn", done: "ok", error: "err" }
    return <span className={`badge ${m[s] || ""}`}>{s || "?"}</span>
  }

  return (
    <div>
      <div className="page-head">
        <h1>Suivi des deploiements</h1>
        <p>Les postes en cours de deploiement. Mise a jour automatique toutes les 5 secondes.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Chargement...</div> :
          list.length === 0 ? (
            <div className="empty"><p>Aucun deploiement en cours.</p><p>Les postes apparaissent ici des qu'ils demarrent la phase 2.</p></div>
          ) : (
            <table>
              <thead><tr><th>Machine</th><th>MAC</th><th>Etat</th><th>Etape</th><th style={{ width: 160 }}>Avancement</th></tr></thead>
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
  const [loadFrom, setLoadFrom] = useState("")   // "type::name" du template a charger
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
    if (!(r && r.success && r.data)) { toast((r && r.error) || "Chargement impossible.", "err"); return }
    const seq = r.data
    const loadedSteps = asArray(seq.Steps).map(s => ({
      Id: s.Id || `step-${Math.random().toString(36).slice(2, 8)}`,
      Name: s.Name || s.Type || "Etape",
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
      if (!target.value) { toast("Donne un nom au template.", "err"); return }
      const seq = { Name: target.value, Steps: steps }
      const r = await api.saveSequenceTemplate(target.value, seq)
      if (r && r.success) { toast(`Template enregistre : ${r.path}`); loadSeqList() }
      else toast((r && r.error) || "Echec de l'enregistrement.", "err")
      return
    }
    if (!target.value) { toast("Renseigne le nom de machine ou la MAC cible.", "err"); return }
    const seq = { Name: `Sequence ${target.value}`, Steps: steps }
    const r = target.kind === "by-name"
      ? await api.saveSequenceByName(target.value, seq)
      : await api.saveSequenceByMac(target.value, seq)
    if (r && r.success) toast(`Sequence enregistree : ${r.path}`)
    else toast((r && r.error) || "Echec de l'enregistrement.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Editeur de sequence</h1>
        <p>Compose la sequence de post-installation, etape par etape, puis enregistre-la pour une machine (par nom ou par MAC).</p>
      </div>

      <div className="panel">
        <h2>Cible</h2>
        <div className="row wrap">
          <select value={target.kind} onChange={e => setTarget({ ...target, kind: e.target.value })} style={{ width: 200 }}>
            <option value="template">Template reutilisable</option>
            <option value="by-name">Par nom de machine</option>
            <option value="by-mac">Par adresse MAC</option>
          </select>
          <input type="text" value={target.value} onChange={e => setTarget({ ...target, value: e.target.value })}
            placeholder={target.kind === "by-name" ? "PC-COMPTA-01" : target.kind === "by-mac" ? "AABBCCDDEEFF" : "Poste-Standard"} style={{ flex: 1 }} />
        </div>
        {target.kind === "template" && (
          <p style={{ color: "var(--text-dim)", fontSize: 12.5, marginTop: 8, marginBottom: 0 }}>
            Un template est enregistre a la racine du dossier Sequences. Il est selectionnable directement en phase 2 sur le poste (choix 1 de l'assistant), sans etre lie a une machine.
          </p>
        )}
      </div>

      <div className="panel">
        <h2>Partir d'une sequence existante</h2>
        <p style={{ color: "var(--text-dim)", fontSize: 12.5, marginTop: -4 }}>
          Charge les etapes d'un template (ou d'une sequence existante) comme point de depart. Tu peux ensuite changer la cible ci-dessus pour la decliner en by-name / by-mac. La source n'est pas modifiee.
        </p>
        <div className="row wrap">
          <select value={loadFrom} onChange={e => setLoadFrom(e.target.value)} style={{ flex: 1, minWidth: 220 }}>
            <option value="">— choisir une sequence —</option>
            {seqList.filter(s => s.Type === "template").length > 0 && (
              <optgroup label="Templates">
                {seqList.filter(s => s.Type === "template").map((s, i) => (
                  <option key={`t${i}`} value={`template::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
            {seqList.filter(s => s.Type === "by-name").length > 0 && (
              <optgroup label="Par nom">
                {seqList.filter(s => s.Type === "by-name").map((s, i) => (
                  <option key={`n${i}`} value={`by-name::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
            {seqList.filter(s => s.Type === "by-mac").length > 0 && (
              <optgroup label="Par MAC">
                {seqList.filter(s => s.Type === "by-mac").map((s, i) => (
                  <option key={`m${i}`} value={`by-mac::${s.Name}`}>{s.Name}</option>
                ))}
              </optgroup>
            )}
          </select>
          <button className="btn" onClick={loadTemplate} disabled={!loadFrom}>Charger les etapes</button>
        </div>
      </div>

      <div className="panel">
        <div className="row" style={{ marginBottom: 12 }}>
          <h2 style={{ margin: 0 }}>Etapes ({steps.length})</h2>
          <div className="spacer" />
          <select value={addType} onChange={e => setAddType(e.target.value)} style={{ width: 220 }}>
            {Object.entries(STEP_TYPES).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </select>
          <button className="btn" onClick={addStep}>Ajouter l'etape</button>
        </div>

        {steps.length === 0 ? (
          <div className="empty"><p>Sequence vide.</p><p>Ajoute une premiere etape pour commencer.</p></div>
        ) : steps.map((s, i) => (
          <StepCard key={s.Id} step={s} ord={i + 1}
            onChange={(ns) => updateStep(i, ns)} onRemove={() => removeStep(i)}
            onUp={() => move(i, -1)} onDown={() => move(i, 1)}
            catalogue={catalogue} scripts={scripts} drivers={drivers} />
        ))}
      </div>

      <div className="row">
        <div className="spacer" />
        <button className="btn primary" onClick={save} disabled={steps.length === 0}>Enregistrer la sequence</button>
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
          <label className="field"><span>Nom de l'etape</span>
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
          <option value="">— aucun —</option>
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
          <button className="btn sm ghost" onClick={onClose}>Fermer</button>
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
      else toast((r && r.error) || "Lecture des scripts impossible.", "err")
    })()
  }, [toast])

  async function open(s) {
    const r = await api.scriptContent(s.RelativePath)
    if (r && r.success) setView({ title: s.RelativePath, content: r.content })
    else toast((r && r.error) || "Lecture du script impossible.", "err")
  }

  return (
    <div>
      <div className="page-head">
        <h1>Scripts</h1>
        <p>Les scripts PowerShell du partage, utilisables dans les etapes RunScript. Clique pour voir le contenu.</p>
      </div>
      <div className="panel">
        {loading ? <div className="empty">Chargement...</div> :
          scripts.length === 0 ? (
            <div className="empty"><p>Aucun script trouve.</p><p>Depose des fichiers .ps1 sur le partage Scripts.</p></div>
          ) : (
            <table>
              <thead><tr><th>Nom</th><th>Chemin relatif</th><th></th></tr></thead>
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
    else toast((r && r.error) || "Lecture des sequences impossible.", "err")
  }, [toast])

  useEffect(() => { load() }, [load])

  async function open(s) {
    if (opening) return            // un chargement est deja en cours -> ignorer
    setOpening(s.Name)
    const r = await api.sequenceContent(s.Type, s.Name)
    setOpening("")
    if (r && r.success) setView({ title: `${s.Type} / ${s.Name}.psd1`, content: r.content })
    else toast((r && r.error) || "Lecture de la sequence impossible.", "err")
  }

  const typeBadge = (t) => {
    const m = { template: "cat", "by-name": "info", "by-mac": "warn" }
    const lbl = { template: "template", "by-name": "par nom", "by-mac": "par MAC" }
    return <span className={`badge ${m[t] || ""}`}>{lbl[t] || t}</span>
  }
  const shown = list.filter(s => !filter || s.Type === filter)

  return (
    <div>
      <div className="page-head">
        <h1>Sequences</h1>
        <p>Toutes les sequences disponibles : templates reutilisables, et sequences assignees par nom ou par MAC. Clique pour voir le contenu.</p>
      </div>
      <div className="panel">
        <div className="row" style={{ marginBottom: 14 }}>
          <select value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 200 }}>
            <option value="">Tous les types</option>
            <option value="template">Templates</option>
            <option value="by-name">Par nom</option>
            <option value="by-mac">Par MAC</option>
          </select>
          <div className="spacer" />
          <button className="btn ghost" onClick={load}>Rafraichir</button>
        </div>
        {loading ? <div className="empty">Chargement...</div> :
          shown.length === 0 ? (
            <div className="empty"><p>Aucune sequence{filter ? " de ce type" : ""}.</p><p>Cree un template depuis l'editeur de sequence.</p></div>
          ) : (
            <table>
              <thead><tr><th>Nom</th><th>Type</th><th></th></tr></thead>
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

// ─── Shell ─────────────────────────────────────────────────
const PAGES = [
  { id: "editor", label: "Editeur", comp: SequencesPage },
  { id: "sequences", label: "Sequences", comp: SequenceListPage },
  { id: "catalogue", label: "Catalogue", comp: CataloguePage },
  { id: "scripts", label: "Scripts", comp: ScriptsPage },
  { id: "drivers", label: "Drivers", comp: DriversPage },
  { id: "monitor", label: "Suivi", comp: MonitorPage },
]

export default function App() {
  const [authed, setAuthed] = useState(false)
  const [checking, setChecking] = useState(true)
  const [page, setPage] = useState("editor")
  const [toast, toastNode] = useToast()

  // Au demarrage : verifier si une session valide existe deja (cookie).
  useEffect(() => {
    (async () => {
      const r = await api.me()
      setAuthed(!!(r && r.success))
      setChecking(false)
    })()
  }, [])

  async function logout() {
    await api.logout()
    setAuthed(false)
  }

  if (checking) return <div className="login-wrap"><div style={{ color: "var(--text-dim)" }}>Chargement...</div></div>
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
              <span className="dot" />{p.label}
            </button>
          ))}
        </nav>
        <div className="sidebar-foot">
          connecte
          <button onClick={logout}>Se deconnecter</button>
        </div>
      </aside>
      <main className="main">
        <Page toast={toast} />
      </main>
      {toastNode}
    </div>
  )
}
