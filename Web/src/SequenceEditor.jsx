import { useState, useRef, useCallback } from "react"

// ─── Types de steps disponibles ───────────────────────────────────────────────
const STEP_TYPES = [
  { type:"FormatDisk",      label:"Partition disque",   cat:"infra",    color:"#7c3aed", bg:"#ede9fe", icon:"💾", rebootAfter:"Never"      },
  { type:"ApplyWIM",        label:"Appliquer WIM",      cat:"infra",    color:"#7c3aed", bg:"#ede9fe", icon:"📀", rebootAfter:"Never"      },
  { type:"InjectDrivers",   label:"Injecter drivers",   cat:"infra",    color:"#7c3aed", bg:"#ede9fe", icon:"🔌", rebootAfter:"Never"      },
  { type:"WaitForNetwork",  label:"Attente réseau",     cat:"network",  color:"#0891b2", bg:"#e0f2fe", icon:"🌐", rebootAfter:"Never"      },
  { type:"JoinDomain",      label:"Jonction domaine",   cat:"network",  color:"#0891b2", bg:"#e0f2fe", icon:"🔗", rebootAfter:"Always"     },
  { type:"InstallUpdates",  label:"Mises à jour",       cat:"software", color:"#d97706", bg:"#fef3c7", icon:"🔄", rebootAfter:"IfRequired" },
  { type:"InstallSoftware", label:"Installer apps",     cat:"software", color:"#d97706", bg:"#fef3c7", icon:"📦", rebootAfter:"IfRequired" },
  { type:"RunScript",       label:"Exécuter script",    cat:"software", color:"#059669", bg:"#d1fae5", icon:"⚡", rebootAfter:"Never"      },
  { type:"CopyFiles",       label:"Copier fichiers",    cat:"software", color:"#059669", bg:"#d1fae5", icon:"📋", rebootAfter:"Never"      },
  { type:"SetRegistry",     label:"Registre",           cat:"system",   color:"#6b7280", bg:"#f3f4f6", icon:"🗂️", rebootAfter:"Never"      },
  { type:"SetLocale",       label:"Langue / timezone",  cat:"system",   color:"#6b7280", bg:"#f3f4f6", icon:"🌍", rebootAfter:"Never"      },
  { type:"Reboot",          label:"Redémarrage",        cat:"system",   color:"#ef4444", bg:"#fee2e2", icon:"♻️", rebootAfter:"Always"     },
]

const CATS = {
  infra:    { label:"Infrastructure",  color:"#7c3aed" },
  network:  { label:"Réseau",          color:"#0891b2" },
  software: { label:"Logiciels",       color:"#d97706" },
  system:   { label:"Système",         color:"#6b7280" },
}

const REBOOT_OPTIONS = ["Never","IfRequired","Always"]
const CRED_SOURCES   = ["vault","env","prompt"]

let _uid = 1
const uid = () => `step-${String(_uid++).padStart(2,'0')}`

const makeStep = (type) => {
  const def = STEP_TYPES.find(t => t.type === type)
  return {
    id:             uid(),
    type,
    name:           def?.label ?? type,
    enabled:        true,
    continueOnError:false,
    rebootAfter:    def?.rebootAfter ?? "IfRequired",
    condition:      "",
    params:         defaultParams(type),
  }
}

function defaultParams(type) {
  switch (type) {
    case "FormatDisk":      return { diskNumber:-1, firmwareType:"UEFI" }
    case "ApplyWIM":        return { wimPath:"\\\\SERVEUR\\Images\\Win11Pro.wim", index:1, targetDrive:"W:\\" }
    case "InjectDrivers":   return { path:"\\\\SERVEUR\\Drivers", recurse:true, targetDrive:"W:\\" }
    case "WaitForNetwork":  return { timeoutSec:60 }
    case "JoinDomain":      return { domain:"corp.local", ou:"OU=Postes,OU=IT,DC=corp,DC=local", credential:{ source:"vault", key:"domainJoin" } }
    case "InstallUpdates":  return { categories:["Security","Critical"], rebootIfNeeded:true }
    case "InstallSoftware": return { source:"\\\\SERVEUR\\Logiciels", packages:[] }
    case "RunScript":       return { path:"\\\\SERVEUR\\Scripts\\script.ps1", shell:"PowerShell", args:"" }
    case "CopyFiles":       return { source:"\\\\SERVEUR\\Files\\", dest:"C:\\Deploy\\Files\\" }
    case "SetRegistry":     return { key:"HKLM:\\SOFTWARE\\Corp\\Deploy", value:"1", type:"DWord" }
    case "SetLocale":       return { locale:"fr-FR", timezone:"Romance Standard Time" }
    case "Reboot":          return { continueAt:"" }
    default:                return {}
  }
}

const INITIAL_STEPS = [
  makeStep("FormatDisk"),
  makeStep("ApplyWIM"),
  makeStep("InjectDrivers"),
  makeStep("SetLocale"),
  makeStep("WaitForNetwork"),
  makeStep("JoinDomain"),
  makeStep("InstallUpdates"),
  makeStep("InstallSoftware"),
  makeStep("RunScript"),
]

// ─── Composant champ de formulaire ────────────────────────────────────────────
const Field = ({ label, children }) => (
  <div style={{ marginBottom:10 }}>
    <label style={{ display:"block", fontSize:11, color:"#6b7280", marginBottom:3, fontWeight:500 }}>{label}</label>
    {children}
  </div>
)

const Input = ({ value, onChange, placeholder, mono }) => (
  <input value={value ?? ""} onChange={e => onChange(e.target.value)} placeholder={placeholder}
    style={{ width:"100%", padding:"5px 8px", border:"1.5px solid #e5e7eb", borderRadius:6,
      fontSize: mono ? 12 : 13, fontFamily: mono ? "monospace" : "inherit",
      background:"#fff", color:"#1e293b", outline:"none" }} />
)

const Select = ({ value, onChange, options }) => (
  <select value={value ?? ""} onChange={e => onChange(e.target.value)}
    style={{ width:"100%", padding:"5px 8px", border:"1.5px solid #e5e7eb", borderRadius:6,
      fontSize:13, background:"#fff", color:"#1e293b", outline:"none" }}>
    {options.map(o => <option key={o} value={o}>{o}</option>)}
  </select>
)

const Toggle = ({ on, onChange }) => (
  <div onClick={onChange} style={{ width:32, height:18, borderRadius:9,
    background: on ? "#3b82f6" : "#d1d5db", position:"relative", cursor:"pointer",
    transition:"background .2s", flexShrink:0, display:"inline-block" }}>
    <div style={{ position:"absolute", top:2, left: on ? 16 : 2, width:14, height:14,
      borderRadius:7, background:"#fff", transition:"left .18s" }} />
  </div>
)

// ─── Panneau de propriétés selon le type ─────────────────────────────────────
function StepParamsEditor({ step, onChange }) {
  const p = step.params
  const setP = (key, val) => onChange({ ...step, params: { ...p, [key]: val } })
  const setCredField = (field, val) => setP("credential", { ...p.credential, [field]: val })

  switch (step.type) {
    case "FormatDisk": return (
      <>
        <Field label="Numéro de disque (-1 = assistant interactif)">
          <Input value={p.diskNumber} onChange={v => setP("diskNumber", parseInt(v)||0)} />
        </Field>
        <Field label="Firmware">
          <Select value={p.firmwareType} onChange={v => setP("firmwareType",v)} options={["UEFI","BIOS"]} />
        </Field>
      </>
    )
    case "ApplyWIM": return (
      <>
        <Field label="Chemin WIM"><Input value={p.wimPath} onChange={v => setP("wimPath",v)} mono /></Field>
        <Field label="Index image (0 = assistant)">
          <Input value={p.index} onChange={v => setP("index", parseInt(v)||1)} />
        </Field>
        <Field label="Lecteur cible">
          <Input value={p.targetDrive} onChange={v => setP("targetDrive",v)} />
        </Field>
      </>
    )
    case "InjectDrivers": return (
      <>
        <Field label="Chemin drivers"><Input value={p.path} onChange={v => setP("path",v)} mono /></Field>
        <Field label="Lecteur cible"><Input value={p.targetDrive} onChange={v => setP("targetDrive",v)} /></Field>
        <Field label="Récursif">
          <div style={{ display:"flex", alignItems:"center", gap:8 }}>
            <Toggle on={p.recurse} onChange={() => setP("recurse",!p.recurse)} />
            <span style={{ fontSize:12, color:"#6b7280" }}>Inclure sous-dossiers</span>
          </div>
        </Field>
      </>
    )
    case "WaitForNetwork": return (
      <Field label="Timeout (secondes)">
        <Input value={p.timeoutSec} onChange={v => setP("timeoutSec", parseInt(v)||60)} />
      </Field>
    )
    case "JoinDomain": return (
      <>
        <Field label="Domaine"><Input value={p.domain} onChange={v => setP("domain",v)} /></Field>
        <Field label="Unité d'organisation"><Input value={p.ou} onChange={v => setP("ou",v)} mono /></Field>
        <Field label="Source credential">
          <Select value={p.credential?.source} onChange={v => setCredField("source",v)} options={CRED_SOURCES} />
        </Field>
        <Field label="Clé vault / variable">
          <Input value={p.credential?.key} onChange={v => setCredField("key",v)} />
        </Field>
      </>
    )
    case "InstallUpdates": return (
      <>
        <Field label="Catégories">
          <Input value={(p.categories||[]).join(",")} onChange={v => setP("categories", v.split(",").map(s=>s.trim()).filter(Boolean))} />
        </Field>
        <Field label="Reboot si nécessaire">
          <Toggle on={p.rebootIfNeeded} onChange={() => setP("rebootIfNeeded",!p.rebootIfNeeded)} />
        </Field>
      </>
    )
    case "InstallSoftware": return (
      <>
        <Field label="Dossier source"><Input value={p.source} onChange={v => setP("source",v)} mono /></Field>
        <Field label="Packages (JSON)">
          <textarea value={JSON.stringify(p.packages||[], null, 2)}
            onChange={e => { try { setP("packages", JSON.parse(e.target.value)) } catch {} }}
            style={{ width:"100%", padding:"5px 8px", border:"1.5px solid #e5e7eb", borderRadius:6,
              fontSize:11, fontFamily:"monospace", minHeight:100, resize:"vertical",
              background:"#fafafa", color:"#1e293b", outline:"none" }} />
        </Field>
      </>
    )
    case "RunScript": return (
      <>
        <Field label="Chemin script"><Input value={p.path} onChange={v => setP("path",v)} mono /></Field>
        <Field label="Shell"><Select value={p.shell} onChange={v => setP("shell",v)} options={["PowerShell","CMD"]} /></Field>
        <Field label="Arguments"><Input value={p.args} onChange={v => setP("args",v)} mono /></Field>
      </>
    )
    case "CopyFiles": return (
      <>
        <Field label="Source"><Input value={p.source} onChange={v => setP("source",v)} mono /></Field>
        <Field label="Destination"><Input value={p.dest} onChange={v => setP("dest",v)} mono /></Field>
      </>
    )
    case "SetRegistry": return (
      <>
        <Field label="Clé"><Input value={p.key} onChange={v => setP("key",v)} mono /></Field>
        <Field label="Nom valeur"><Input value={p.name} onChange={v => setP("name",v)} /></Field>
        <Field label="Valeur"><Input value={p.value} onChange={v => setP("value",v)} /></Field>
        <Field label="Type"><Select value={p.type} onChange={v => setP("type",v)} options={["String","DWord","QWord","Binary","MultiString"]} /></Field>
      </>
    )
    case "SetLocale": return (
      <>
        <Field label="Locale"><Input value={p.locale} onChange={v => setP("locale",v)} /></Field>
        <Field label="Timezone"><Input value={p.timezone} onChange={v => setP("timezone",v)} /></Field>
      </>
    )
    case "Reboot": return (
      <Field label="Reprendre au step (id)">
        <Input value={p.continueAt} onChange={v => setP("continueAt",v)} placeholder="step-07" />
      </Field>
    )
    default: return <p style={{ fontSize:12, color:"#9ca3af" }}>Pas de paramètres pour ce type.</p>
  }
}

// ─── App principale ────────────────────────────────────────────────────────────
export default function SequenceEditor({ onSave }) {
  const [steps, setSteps]         = useState(INITIAL_STEPS)
  const [selected, setSelected]   = useState(INITIAL_STEPS[0].id)
  const [seqName, setSeqName]     = useState("Win11-Domaine-Standard")
  const [seqVersion, setVersion]  = useState("1.0.0")
  const [showPalette, setShowPal] = useState(false)
  const [showJson, setShowJson]   = useState(false)
  const [saved, setSaved]         = useState(false)

  // Drag state
  const dragIdx   = useRef(null)
  const dragOver  = useRef(null)

  const selectedStep = steps.find(s => s.id === selected)

  // ── Drag & drop ──────────────────────────────────────────────────────────
  const onDragStart = (i) => { dragIdx.current = i }
  const onDragEnter = (i) => { dragOver.current = i }
  const onDragEnd   = () => {
    if (dragIdx.current === null || dragOver.current === null) return
    if (dragIdx.current === dragOver.current) return
    const next = [...steps]
    const [moved] = next.splice(dragIdx.current, 1)
    next.splice(dragOver.current, 0, moved)
    setSteps(next)
    dragIdx.current  = null
    dragOver.current = null
  }

  // ── Mutations ─────────────────────────────────────────────────────────────
  const updateStep = useCallback((updated) => {
    setSteps(s => s.map(x => x.id === updated.id ? updated : x))
  }, [])

  const removeStep = (id) => {
    const idx = steps.findIndex(s => s.id === id)
    setSteps(s => s.filter(x => x.id !== id))
    if (selected === id) {
      const next = steps[idx + 1] ?? steps[idx - 1]
      setSelected(next?.id ?? null)
    }
  }

  const addStep = (type) => {
    const step = makeStep(type)
    setSteps(s => [...s, step])
    setSelected(step.id)
    setShowPal(false)
  }

  const duplicateStep = (id) => {
    const src  = steps.find(s => s.id === id)
    const copy = { ...src, id: uid(), name: src.name + " (copie)" }
    const idx  = steps.findIndex(s => s.id === id)
    const next = [...steps]
    next.splice(idx + 1, 0, copy)
    setSteps(next)
    setSelected(copy.id)
  }

  // ── Export JSON ───────────────────────────────────────────────────────────
  const exportJson = () => {
    const seq = {
      id:          seqName.toLowerCase().replace(/[^a-z0-9]+/g,'-'),
      name:        seqName,
      version:     seqVersion,
      description: "",
      metadata:    { locale:"fr-FR", timezone:"Romance Standard Time" },
      options:     { continueOnError:false, logLevel:"Info" },
      steps,
    }
    return JSON.stringify(seq, null, 2)
  }

  const handleSave = () => {
    const json = exportJson()
    onSave?.(json)
    setSaved(true)
    setTimeout(() => setSaved(false), 2000)
  }

  const handleDownload = () => {
    const blob = new Blob([exportJson()], { type:"application/json" })
    const url  = URL.createObjectURL(blob)
    const a    = Object.assign(document.createElement("a"), { href:url, download:`${seqName}.json` })
    a.click(); URL.revokeObjectURL(url)
  }

  // ─── Render ───────────────────────────────────────────────────────────────
  return (
    <div style={{ display:"flex", flexDirection:"column", gap:0, height:"100%" }}>
      {/* Topbar */}
      <div style={{ display:"flex", alignItems:"center", gap:10, padding:"10px 16px",
        borderBottom:"1.5px solid #f1f5f9", background:"#fff", flexShrink:0, flexWrap:"wrap" }}>
        <div style={{ display:"flex", alignItems:"center", gap:8, flex:1, minWidth:200 }}>
          <input value={seqName} onChange={e => setSeqName(e.target.value)}
            style={{ fontWeight:600, fontSize:14, border:"none", outline:"none",
              background:"transparent", color:"#1e293b", minWidth:160 }} />
          <input value={seqVersion} onChange={e => setVersion(e.target.value)}
            style={{ fontSize:12, border:"1.5px solid #e5e7eb", borderRadius:5, padding:"2px 7px",
              color:"#6b7280", background:"#f8fafc", outline:"none", width:60 }} />
          <span style={{ fontSize:12, color:"#9ca3af" }}>{steps.length} step(s)</span>
        </div>
        <div style={{ display:"flex", gap:6 }}>
          <button onClick={() => setShowJson(v => !v)}
            style={{ padding:"5px 12px", border:"1.5px solid #e5e7eb", borderRadius:7,
              background:"#fff", fontSize:12, cursor:"pointer", color:"#6b7280" }}>
            {showJson ? "← Éditer" : "JSON"}
          </button>
          <button onClick={handleDownload}
            style={{ padding:"5px 12px", border:"1.5px solid #e5e7eb", borderRadius:7,
              background:"#fff", fontSize:12, cursor:"pointer", color:"#6b7280" }}>
            ⬇ Export
          </button>
          <button onClick={handleSave}
            style={{ padding:"5px 14px", border:"none", borderRadius:7, fontSize:12,
              background: saved ? "#059669" : "#3b82f6", color:"#fff", cursor:"pointer",
              transition:"background .2s" }}>
            {saved ? "✓ Sauvegardé" : "Sauvegarder"}
          </button>
        </div>
      </div>

      {showJson ? (
        /* ── Vue JSON ── */
        <div style={{ flex:1, overflow:"auto", padding:16 }}>
          <pre style={{ fontFamily:"monospace", fontSize:12, color:"#1e293b",
            background:"#f8fafc", padding:16, borderRadius:10, border:"1.5px solid #f1f5f9",
            lineHeight:1.6, whiteSpace:"pre-wrap", wordBreak:"break-word" }}>
            {exportJson()}
          </pre>
        </div>
      ) : (
        /* ── Vue éditeur ── */
        <div style={{ display:"flex", flex:1, overflow:"hidden" }}>

          {/* ─ Colonne gauche : liste steps ─ */}
          <div style={{ width:260, minWidth:260, borderRight:"1.5px solid #f1f5f9",
            display:"flex", flexDirection:"column", background:"#fafafa" }}>

            {/* Liste draggable */}
            <div style={{ flex:1, overflowY:"auto", padding:"8px 8px 0" }}>
              {steps.map((step, i) => {
                const def  = STEP_TYPES.find(t => t.type === step.type)
                const isSel = step.id === selected
                return (
                  <div key={step.id}
                    draggable
                    onDragStart={() => onDragStart(i)}
                    onDragEnter={() => onDragEnter(i)}
                    onDragEnd={onDragEnd}
                    onDragOver={e => e.preventDefault()}
                    onClick={() => setSelected(step.id)}
                    style={{ display:"flex", alignItems:"center", gap:8, padding:"7px 10px",
                      borderRadius:8, marginBottom:4, cursor:"grab",
                      border: isSel ? `1.5px solid ${def?.color??'#3b82f6'}` : "1.5px solid transparent",
                      background: isSel ? (def?.bg ?? "#eff6ff") : "#fff",
                      opacity: step.enabled ? 1 : .45, transition:"all .12s",
                      userSelect:"none" }}>
                    {/* Grip handle */}
                    <span style={{ color:"#d1d5db", fontSize:14, cursor:"grab", flexShrink:0 }}>⠿</span>
                    {/* Numéro */}
                    <span style={{ fontSize:11, color:"#9ca3af", minWidth:18, textAlign:"right" }}>
                      {i + 1}
                    </span>
                    {/* Icône type */}
                    <span style={{ fontSize:14, flexShrink:0 }}>{def?.icon ?? "⚙️"}</span>
                    {/* Nom */}
                    <span style={{ fontSize:12, fontWeight: isSel ? 600 : 400, flex:1,
                      overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap",
                      color: step.enabled ? "#1e293b" : "#9ca3af" }}>
                      {step.name}
                    </span>
                    {/* Indicateurs */}
                    <div style={{ display:"flex", gap:3, flexShrink:0 }}>
                      {step.rebootAfter === "Always" &&
                        <span style={{ fontSize:9, background:"#fee2e2", color:"#dc2626", padding:"1px 4px", borderRadius:3, fontWeight:600 }}>R</span>}
                      {step.rebootAfter === "IfRequired" &&
                        <span style={{ fontSize:9, background:"#fef3c7", color:"#b45309", padding:"1px 4px", borderRadius:3, fontWeight:600 }}>?R</span>}
                      {step.continueOnError &&
                        <span style={{ fontSize:9, background:"#f3f4f6", color:"#6b7280", padding:"1px 4px", borderRadius:3, fontWeight:600 }}>CE</span>}
                    </div>
                  </div>
                )
              })}
            </div>

            {/* Bouton ajouter */}
            <div style={{ padding:8, borderTop:"1.5px solid #f1f5f9" }}>
              <button onClick={() => setShowPal(v => !v)}
                style={{ width:"100%", padding:"7px 0", border:"1.5px dashed #d1d5db",
                  borderRadius:8, background:"transparent", fontSize:13, color:"#6b7280",
                  cursor:"pointer", display:"flex", alignItems:"center", justifyContent:"center", gap:6 }}>
                + Ajouter un step
              </button>
            </div>
          </div>

          {/* ─ Colonne droite : propriétés ─ */}
          <div style={{ flex:1, overflowY:"auto", padding:16 }}>
            {selectedStep ? (
              <div>
                {/* En-tête step */}
                <div style={{ display:"flex", alignItems:"center", gap:10, marginBottom:16 }}>
                  <div style={{ width:36, height:36, borderRadius:9,
                    background: STEP_TYPES.find(t => t.type === selectedStep.type)?.bg ?? "#f3f4f6",
                    display:"flex", alignItems:"center", justifyContent:"center", fontSize:18 }}>
                    {STEP_TYPES.find(t => t.type === selectedStep.type)?.icon ?? "⚙️"}
                  </div>
                  <div style={{ flex:1 }}>
                    <input value={selectedStep.name}
                      onChange={e => updateStep({ ...selectedStep, name: e.target.value })}
                      style={{ fontWeight:600, fontSize:14, border:"none", outline:"none",
                        background:"transparent", width:"100%", color:"#1e293b" }} />
                    <div style={{ fontSize:11, color:"#9ca3af" }}>{selectedStep.type} · {selectedStep.id}</div>
                  </div>
                  <button onClick={() => duplicateStep(selectedStep.id)}
                    title="Dupliquer"
                    style={{ padding:"4px 8px", border:"1.5px solid #e5e7eb", borderRadius:6,
                      background:"#fff", fontSize:12, cursor:"pointer", color:"#6b7280" }}>⧉</button>
                  <button onClick={() => removeStep(selectedStep.id)}
                    title="Supprimer"
                    style={{ padding:"4px 8px", border:"1.5px solid #fca5a5", borderRadius:6,
                      background:"#fff", fontSize:12, cursor:"pointer", color:"#dc2626" }}>✕</button>
                </div>

                {/* Options communes */}
                <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:8, marginBottom:14,
                  padding:"10px 12px", background:"#f8fafc", borderRadius:8, border:"1.5px solid #f1f5f9" }}>
                  <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                    <Toggle on={selectedStep.enabled}
                      onChange={() => updateStep({ ...selectedStep, enabled:!selectedStep.enabled })} />
                    <span style={{ fontSize:12, color:"#374151" }}>Activé</span>
                  </div>
                  <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                    <Toggle on={selectedStep.continueOnError}
                      onChange={() => updateStep({ ...selectedStep, continueOnError:!selectedStep.continueOnError })} />
                    <span style={{ fontSize:12, color:"#374151" }}>Continue on error</span>
                  </div>
                  <div>
                    <label style={{ fontSize:11, color:"#6b7280", display:"block", marginBottom:3 }}>Reboot après</label>
                    <Select value={selectedStep.rebootAfter}
                      onChange={v => updateStep({ ...selectedStep, rebootAfter:v })}
                      options={REBOOT_OPTIONS} />
                  </div>
                  <div>
                    <label style={{ fontSize:11, color:"#6b7280", display:"block", marginBottom:3 }}>Condition</label>
                    <Input value={selectedStep.condition}
                      onChange={v => updateStep({ ...selectedStep, condition:v })}
                      placeholder="{{ metadata.domain != null }}" mono />
                  </div>
                </div>

                {/* Params spécifiques au type */}
                <div style={{ marginBottom:8, fontSize:12, fontWeight:600, color:"#374151" }}>
                  Paramètres — {selectedStep.type}
                </div>
                <div style={{ background:"#fff", border:"1.5px solid #f1f5f9", borderRadius:8, padding:12 }}>
                  <StepParamsEditor step={selectedStep} onChange={updateStep} />
                </div>
              </div>
            ) : (
              <div style={{ textAlign:"center", paddingTop:60, color:"#9ca3af", fontSize:13 }}>
                Sélectionnez un step pour éditer ses propriétés
              </div>
            )}
          </div>
        </div>
      )}

      {/* ─ Palette flottante ─ */}
      {showPalette && (
        <div style={{ position:"absolute", zIndex:100 }}>
          <div onClick={() => setShowPal(false)}
            style={{ position:"fixed", inset:0 }} />
        </div>
      )}
      {showPalette === false && showPalette !== true ? null : null}

      {/* Palette inline sous le bouton + */}
      {showPalette !== false && (
        <div style={{ position:"fixed", bottom:60, left:8, width:248, zIndex:200,
          background:"#fff", border:"1.5px solid #e5e7eb", borderRadius:10,
          boxShadow:"0 4px 20px rgba(0,0,0,.12)", overflow:"hidden" }}>
          <div onClick={() => setShowPal(false)}
            style={{ position:"fixed", inset:0, zIndex:-1 }} />
          {Object.entries(CATS).map(([cat, catDef]) => (
            <div key={cat}>
              <div style={{ padding:"6px 12px", fontSize:10, fontWeight:700, color:catDef.color,
                textTransform:"uppercase", letterSpacing:".07em", background:"#fafafa",
                borderTop:"1.5px solid #f1f5f9" }}>
                {catDef.label}
              </div>
              {STEP_TYPES.filter(t => t.cat === cat).map(t => (
                <div key={t.type} onClick={() => addStep(t.type)}
                  style={{ display:"flex", alignItems:"center", gap:10, padding:"7px 14px",
                    cursor:"pointer", fontSize:13 }}
                  onMouseEnter={e => e.currentTarget.style.background="#f8fafc"}
                  onMouseLeave={e => e.currentTarget.style.background=""}>
                  <span style={{ fontSize:16 }}>{t.icon}</span>
                  <span>{t.label}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}

      {/* Override showPalette logic */}
      {showPal && (
        <>
          <div onClick={() => setShowPal(false)}
            style={{ position:"fixed", inset:0, zIndex:199 }} />
          <div style={{ position:"fixed", bottom:56, left:8, width:248, zIndex:200,
            background:"#fff", border:"1.5px solid #e5e7eb", borderRadius:10,
            boxShadow:"0 4px 20px rgba(0,0,0,.12)", overflow:"hidden" }}>
            {Object.entries(CATS).map(([cat, catDef]) => (
              <div key={cat}>
                <div style={{ padding:"6px 12px", fontSize:10, fontWeight:700, color:catDef.color,
                  textTransform:"uppercase", letterSpacing:".07em", background:"#fafafa",
                  borderTop:"1px solid #f1f5f9" }}>
                  {catDef.label}
                </div>
                {STEP_TYPES.filter(t => t.cat === cat).map(t => (
                  <div key={t.type} onClick={() => addStep(t.type)}
                    style={{ display:"flex", alignItems:"center", gap:10, padding:"7px 14px",
                      cursor:"pointer", fontSize:13, transition:"background .1s" }}
                    onMouseEnter={e => e.currentTarget.style.background="#f8fafc"}
                    onMouseLeave={e => e.currentTarget.style.background=""}>
                    <span style={{ fontSize:15 }}>{t.icon}</span>
                    <span style={{ color:"#374151" }}>{t.label}</span>
                  </div>
                ))}
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}
