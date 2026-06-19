import { useState, useEffect, useRef } from "react"

const API = import.meta.env?.VITE_API_URL || "http://localhost:8080"

// ─── Mock data (fallback si API offline) ────────────────────────────────────
const MOCK_PROFILES = [
  { id: "profil-poste-rh", name: "Poste RH", description: "Office 365, SAP GUI, domaine RH", icon: "💼", color: "#0ea5e9", requiredApps: ["app-7zip","app-office365"], defaultApps: ["app-chrome","app-sap-gui"], requiredScripts: ["script-bitlocker"], defaultScripts: ["script-post-config"] },
  { id: "profil-laptop-commercial", name: "Laptop commercial", description: "CRM Salesforce, VPN, Teams", icon: "💻", color: "#8b5cf6", requiredApps: ["app-7zip","app-office365","app-vpn"], defaultApps: ["app-chrome","app-teams"], requiredScripts: ["script-bitlocker","script-post-config"], defaultScripts: [] },
  { id: "profil-kiosque", name: "Kiosque / Borne", description: "Standalone, mode kiosque verrouillé", icon: "🖥️", color: "#f59e0b", requiredApps: ["app-7zip","app-chrome"], defaultApps: [], requiredScripts: ["script-kiosque-lock"], defaultScripts: [] },
]
const MOCK_CATALOGUE = [
  { id:"app-7zip", type:"app", name:"7-Zip 23", description:"Archivage universel", category:"outils", requiredByDefault:true },
  { id:"app-office365", type:"app", name:"Office 365", description:"Suite Microsoft complète", category:"bureautique", requiredByDefault:true },
  { id:"app-chrome", type:"app", name:"Chrome Enterprise", description:"Navigateur GPO-ready", category:"outils" },
  { id:"app-sap-gui", type:"app", name:"SAP GUI 8.0", description:"Client ERP SAP", category:"bureautique" },
  { id:"app-vpn", type:"app", name:"GlobalProtect VPN", description:"Client VPN Palo Alto", category:"securite" },
  { id:"app-teams", type:"app", name:"Microsoft Teams", description:"Messagerie & visio", category:"bureautique" },
  { id:"app-salesforce", type:"app", name:"Salesforce Anywhere", description:"Client CRM", category:"bureautique" },
  { id:"script-post-config", type:"script", name:"Post-Config.ps1", description:"Réseau, imprimantes, lecteurs", category:"scripts" },
  { id:"script-bitlocker", type:"script", name:"Bitlocker-Enable.ps1", description:"Chiffrement disque", category:"securite" },
  { id:"script-wallpaper", type:"script", name:"Set-WallpaperGPO.ps1", description:"Fond d'écran entreprise", category:"scripts" },
  { id:"script-kiosque-lock", type:"script", name:"Set-KioskMode.ps1", description:"Verrouillage kiosque", category:"scripts" },
]
const MOCK_LOG = [
  "2025-05-21 14:30:01 [>>] [-] PSWINDEX — Task Sequence Engine",
  "2025-05-21 14:30:02 [~]  [-] Séquence 'Poste RH' v1.0.0 — 9 step(s)",
  "2025-05-21 14:30:03 [>>] [step-01] FormatDisk — Partitionner le disque",
  "2025-05-21 14:31:14 [OK] [step-01] Disque 0 initialisé (UEFI/GPT)",
  "2025-05-21 14:31:15 [>>] [step-02] ApplyWIM — Appliquer Windows 11 Pro",
  "2025-05-21 14:44:20 [OK] [step-02] Image appliquée en 13.1 min",
  "2025-05-21 14:44:21 [>>] [step-03] InjectDrivers — Drivers matériel",
  "2025-05-21 14:44:55 [OK] [step-03] Drivers injectés depuis \\\\SERVEUR\\Drivers",
  "2025-05-21 14:44:56 [>>] [step-04] JoinDomain — Jonction domaine corp.local",
  "2025-05-21 14:45:12 [~]  [step-04] Résolution DNS corp.local → 10.0.0.10...",
]

// ─── API helper ───────────────────────────────────────────────────────────────
async function apiFetch(path, opts = {}) {
  try {
    const r = await fetch(`${API}${path}`, { headers: { "Content-Type": "application/json" }, ...opts })
    return await r.json()
  } catch { return null }
}

// ─── Icons (SVG inline) ───────────────────────────────────────────────────────
const Icon = ({ name, size = 16 }) => {
  const icons = {
    rocket:    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 14H9V8h2v8zm4 0h-2V8h2v8z"/>,
    grid:      <path d="M4 5h6v6H4zm0 8h6v6H4zm8-8h6v6h-6zm0 8h6v6h-6z" opacity=".8"/>,
    apps:      <path d="M4 8h4V4H4v4zm6 12h4v-4h-4v4zm-6 0h4v-4H4v4zm0-6h4v-4H4v4zm6 0h4v-4h-4v4zm6-10v4h4V4h-4zm-6 4h4V4h-4v4zm6 6h4v-4h-4v4zm0 6h4v-4h-4v4z"/>,
    list:      <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>,
    image:     <path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-1.1 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/>,
    chart:     <path d="M5 9.2h3V19H5V9.2zM10.6 5h2.8v14h-2.8V5zm5.6 8H19v6h-2.8v-6z"/>,
    cog:       <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>,
    play:      <path d="M8 5v14l11-7z"/>,
    check:     <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>,
    x:         <path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/>,
    plus:      <path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/>,
    filter:    <path d="M10 18h4v-2h-4v2zM3 6v2h18V6H3zm3 7h12v-2H6v2z"/>,
    terminal:  <path d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 14H4V8h16v10zm-9-1h2v-2h-2v2zm0-4h2v-2h-2v2zm4 4h2v-2h-2v2zm-8 0h2v-2H7v2z"/>,
    shield:    <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>,
    briefcase: <path d="M20 6h-2.18c.07-.44.18-.88.18-1.36C18 3.15 16.85 2 15.36 2H8.64C7.15 2 6 3.15 6 4.64c0 .48.11.92.18 1.36H4c-1.1 0-2 .9-2 2v11c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zM8.64 4h6.72c.36 0 .64.29.64.64 0 .72-.18 1.36-.18 1.36H8.18S8 5.36 8 4.64C8 4.29 8.28 4 8.64 4zM12 17c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3z"/>,
  }
  return <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor">{icons[name]}</svg>
}

// ─── Category config ──────────────────────────────────────────────────────────
const CAT = {
  bureautique: { label:"Bureautique", color:"#3b82f6", bg:"#eff6ff" },
  outils:      { label:"Outils",      color:"#f59e0b", bg:"#fffbeb" },
  securite:    { label:"Sécurité",    color:"#ef4444", bg:"#fef2f2" },
  scripts:     { label:"Scripts PS",  color:"#10b981", bg:"#ecfdf5" },
}

// ─── Small components ─────────────────────────────────────────────────────────
const Badge = ({ children, color = "#6b7280", bg = "#f3f4f6" }) => (
  <span style={{ background: bg, color, fontSize: 11, padding: "2px 8px", borderRadius: 20, fontWeight: 600, whiteSpace:"nowrap" }}>{children}</span>
)

const Toggle = ({ on, onChange, disabled }) => (
  <div onClick={disabled ? undefined : onChange}
    style={{ width:36, height:20, borderRadius:10, background: on ? "#3b82f6" : "#d1d5db",
      position:"relative", cursor: disabled ? "default" : "pointer", transition:"background .2s", flexShrink:0, opacity: disabled ? .5 : 1 }}>
    <div style={{ position:"absolute", top:2, left: on ? 18 : 2, width:16, height:16,
      borderRadius:8, background:"#fff", transition:"left .2s", boxShadow:"0 1px 3px rgba(0,0,0,.2)" }} />
  </div>
)

const StepDot = ({ status }) => {
  const colors = { done:"#10b981", active:"#3b82f6", pending:"#d1d5db", error:"#ef4444" }
  return (
    <div style={{ width:10, height:10, borderRadius:"50%", background: colors[status], flexShrink:0,
      boxShadow: status === "active" ? "0 0 0 3px #bfdbfe" : "none",
      animation: status === "active" ? "pulse 1.5s infinite" : "none" }} />
  )
}

// ─── Pages ────────────────────────────────────────────────────────────────────

function PageDeploy({ profiles, catalogue, onLaunch }) {
  const [selectedProfile, setSelectedProfile] = useState(profiles[0])
  const [appState, setAppState] = useState({})   // id -> bool
  const [tab, setTab] = useState("apps")

  useEffect(() => {
    if (!selectedProfile) return
    const init = {}
    catalogue.forEach(item => {
      const req  = selectedProfile.requiredApps?.includes(item.id) || selectedProfile.requiredScripts?.includes(item.id)
      const def  = selectedProfile.defaultApps?.includes(item.id)  || selectedProfile.defaultScripts?.includes(item.id)
      init[item.id] = req || def
    })
    setAppState(init)
  }, [selectedProfile])

  const requiredIds = [...(selectedProfile?.requiredApps||[]), ...(selectedProfile?.requiredScripts||[])]
  const selected = catalogue.filter(i => appState[i.id])
  const appCount = selected.filter(i => i.type === "app").length
  const scriptCount = selected.filter(i => i.type === "script").length

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:20 }}>
      {/* Profils */}
      <section>
        <div style={{ fontSize:12, fontWeight:600, color:"#6b7280", letterSpacing:".06em", textTransform:"uppercase", marginBottom:12 }}>
          Profil de déploiement
        </div>
        <div style={{ display:"grid", gridTemplateColumns:"repeat(3,1fr)", gap:10 }}>
          {profiles.map(p => (
            <div key={p.id} onClick={() => setSelectedProfile(p)}
              style={{ border: selectedProfile?.id === p.id ? `2px solid ${p.color}` : "1.5px solid #e5e7eb",
                borderRadius:12, padding:"14px 16px", cursor:"pointer",
                background: selectedProfile?.id === p.id ? p.color + "08" : "#fff",
                transition:"all .15s" }}>
              <div style={{ fontSize:24, marginBottom:8 }}>{p.icon}</div>
              <div style={{ fontWeight:600, fontSize:14, marginBottom:4 }}>{p.name}</div>
              <div style={{ fontSize:12, color:"#6b7280", lineHeight:1.4, marginBottom:10 }}>{p.description}</div>
              <div style={{ display:"flex", gap:6, flexWrap:"wrap" }}>
                <Badge color={p.color} bg={p.color+"15"}>{(p.requiredApps?.length||0)+(p.requiredScripts?.length||0)} obligatoires</Badge>
                {(p.defaultApps?.length||0) > 0 && <Badge>{p.defaultApps.length} optionnelles</Badge>}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Tabs apps / scripts */}
      <section>
        <div style={{ display:"flex", gap:0, marginBottom:14, borderBottom:"1.5px solid #f3f4f6" }}>
          {[["apps","Applications",appCount], ["scripts","Scripts PS",scriptCount]].map(([id,label,count]) => (
            <button key={id} onClick={() => setTab(id)}
              style={{ padding:"8px 18px", background:"none", border:"none", cursor:"pointer", fontSize:13, fontWeight: tab===id ? 600 : 400,
                color: tab===id ? "#1e293b" : "#9ca3af",
                borderBottom: tab===id ? "2px solid #3b82f6" : "2px solid transparent",
                marginBottom:-1.5, transition:"all .15s" }}>
              {label} <span style={{ background: tab===id ? "#eff6ff" : "#f3f4f6", color: tab===id ? "#3b82f6" : "#9ca3af",
                fontSize:10, padding:"1px 6px", borderRadius:10, marginLeft:4, fontWeight:600 }}>{count}</span>
            </button>
          ))}
        </div>

        <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:8 }}>
          {catalogue.filter(i => tab === "apps" ? i.type === "app" : i.type === "script").map(item => {
            const isReq = requiredIds.includes(item.id)
            const isOn  = !!appState[item.id]
            const cat   = CAT[item.category] || CAT.outils
            return (
              <div key={item.id}
                style={{ display:"flex", alignItems:"center", gap:12, padding:"10px 14px",
                  border: isOn ? `1.5px solid ${isReq ? "#fca5a5" : "#93c5fd"}` : "1.5px solid #f3f4f6",
                  borderRadius:10, background: isOn ? (isReq ? "#fef2f2" : "#eff6ff") : "#fafafa",
                  cursor: isReq ? "default" : "pointer", transition:"all .15s" }}
                onClick={isReq ? undefined : () => setAppState(s => ({ ...s, [item.id]: !s[item.id] }))}>
                <div style={{ width:34, height:34, borderRadius:8, background: cat.bg,
                  display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0 }}>
                  <span style={{ fontSize:16 }}>{item.type === "script" ? "⚡" : "📦"}</span>
                </div>
                <div style={{ flex:1, minWidth:0 }}>
                  <div style={{ fontSize:13, fontWeight:600, marginBottom:2 }}>{item.name}</div>
                  <div style={{ fontSize:11, color:"#9ca3af", whiteSpace:"nowrap", overflow:"hidden", textOverflow:"ellipsis" }}>{item.description}</div>
                </div>
                {isReq
                  ? <Badge color="#dc2626" bg="#fee2e2">Obligatoire</Badge>
                  : <Toggle on={isOn} onChange={() => setAppState(s => ({ ...s, [item.id]: !s[item.id] }))} />}
              </div>
            )
          })}
        </div>
      </section>

      {/* Action */}
      <div style={{ display:"flex", justifyContent:"flex-end", gap:10, paddingTop:4 }}>
        <div style={{ fontSize:13, color:"#6b7280", display:"flex", alignItems:"center", gap:6 }}>
          <span>{appCount} app(s)</span><span style={{ color:"#e5e7eb" }}>·</span>
          <span>{scriptCount} script(s)</span>
        </div>
        <button onClick={() => onLaunch(selectedProfile, Object.keys(appState).filter(id => appState[id]))}
          style={{ display:"flex", alignItems:"center", gap:8, padding:"9px 22px", background:"#3b82f6",
            color:"#fff", border:"none", borderRadius:8, fontWeight:600, fontSize:14, cursor:"pointer" }}>
          <Icon name="play" size={16} /> Lancer le déploiement
        </button>
      </div>
    </div>
  )
}

function PageRunning({ profile, logs }) {
  const logRef = useRef()
  const steps = [
    { id:"s1", label:"Partition disque", status:"done" },
    { id:"s2", label:"Application WIM", status:"done" },
    { id:"s3", label:"Injection drivers", status:"done" },
    { id:"s4", label:"Jonction domaine", status:"active" },
    { id:"s5", label:"Mises à jour", status:"pending" },
    { id:"s6", label:"Installation apps", status:"pending" },
    { id:"s7", label:"Scripts PS", status:"pending" },
    { id:"s8", label:"Mot de passe admin", status:"pending" },
    { id:"s9", label:"Nettoyage sécurité", status:"pending" },
  ]
  useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight }, [logs])

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:16 }}>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(3,1fr)", gap:10 }}>
        {[["3 / 9","Steps complétés","#3b82f6"],["14 min","Temps écoulé","#10b981"],["~22 min","Estimé restant","#f59e0b"]].map(([v,l,c]) => (
          <div key={l} style={{ background:"#f8fafc", borderRadius:10, padding:"14px 16px", textAlign:"center" }}>
            <div style={{ fontSize:24, fontWeight:700, color:c, fontVariantNumeric:"tabular-nums" }}>{v}</div>
            <div style={{ fontSize:12, color:"#9ca3af", marginTop:4 }}>{l}</div>
          </div>
        ))}
      </div>

      <div style={{ display:"grid", gridTemplateColumns:"1fr 1.5fr", gap:12 }}>
        {/* Steps */}
        <div style={{ background:"#f8fafc", borderRadius:10, padding:14 }}>
          <div style={{ fontSize:12, fontWeight:600, color:"#6b7280", marginBottom:12, textTransform:"uppercase", letterSpacing:".05em" }}>Progression</div>
          <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
            {steps.map(s => (
              <div key={s.id} style={{ display:"flex", alignItems:"center", gap:10,
                opacity: s.status === "pending" ? .45 : 1, transition:"opacity .3s" }}>
                <StepDot status={s.status} />
                <span style={{ fontSize:13, fontWeight: s.status === "active" ? 600 : 400, flex:1 }}>{s.label}</span>
                {s.status === "done" && <Icon name="check" size={14} style={{ color:"#10b981" }} />}
                {s.status === "active" && <span style={{ fontSize:11, color:"#3b82f6", fontWeight:600 }}>En cours…</span>}
              </div>
            ))}
          </div>
        </div>

        {/* Logs */}
        <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
          <div style={{ fontSize:12, fontWeight:600, color:"#6b7280", textTransform:"uppercase", letterSpacing:".05em" }}>Journal</div>
          <div ref={logRef} style={{ background:"#0f172a", borderRadius:10, padding:14,
            fontFamily:"'Cascadia Code','Fira Code',monospace", fontSize:11.5, lineHeight:1.8,
            color:"#94a3b8", overflowY:"auto", maxHeight:260, flex:1 }}>
            {logs.map((line, i) => {
              const color = line.includes("[OK]") ? "#34d399" : line.includes("[>>]") ? "#a78bfa" :
                            line.includes("[!]") ? "#fbbf24" : line.includes("[X]") ? "#f87171" : "#94a3b8"
              return <div key={i} style={{ color }}>{line}</div>
            })}
            <div style={{ display:"inline-block", width:8, height:14, background:"#3b82f6",
              animation:"blink 1s infinite", verticalAlign:"middle" }} />
          </div>
        </div>
      </div>
    </div>
  )
}

function PageCatalogue({ catalogue }) {
  const [filter, setFilter] = useState("all")
  const [search, setSearch] = useState("")

  const items = catalogue.filter(i =>
    (filter === "all" || i.category === filter) &&
    (!search || i.name.toLowerCase().includes(search.toLowerCase()) || i.description.toLowerCase().includes(search.toLowerCase()))
  )

  return (
    <div>
      <div style={{ display:"flex", gap:10, marginBottom:16, flexWrap:"wrap" }}>
        <div style={{ position:"relative", flex:1, minWidth:180 }}>
          <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Rechercher…"
            style={{ width:"100%", padding:"7px 12px 7px 32px", border:"1.5px solid #e5e7eb",
              borderRadius:8, fontSize:13, outline:"none", background:"#fff" }} />
          <span style={{ position:"absolute", left:10, top:"50%", transform:"translateY(-50%)", color:"#9ca3af" }}>
            <Icon name="filter" size={15} />
          </span>
        </div>
        {[["all","Tout"], ...Object.entries(CAT).map(([k,v]) => [k, v.label])].map(([id,label]) => (
          <button key={id} onClick={() => setFilter(id)}
            style={{ padding:"7px 14px", border: filter===id ? `1.5px solid ${CAT[id]?.color || "#3b82f6"}` : "1.5px solid #e5e7eb",
              borderRadius:8, background: filter===id ? (CAT[id]?.bg || "#eff6ff") : "#fff",
              color: filter===id ? (CAT[id]?.color || "#3b82f6") : "#6b7280",
              fontSize:12, fontWeight: filter===id ? 600 : 400, cursor:"pointer", transition:"all .15s" }}>
            {label}
          </button>
        ))}
      </div>

      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
        {items.map(item => {
          const cat = CAT[item.category] || CAT.outils
          return (
            <div key={item.id} style={{ display:"flex", gap:12, padding:"12px 14px",
              border:"1.5px solid #f3f4f6", borderRadius:10, background:"#fff" }}>
              <div style={{ width:38, height:38, borderRadius:9, background: cat.bg,
                display:"flex", alignItems:"center", justifyContent:"center", fontSize:18, flexShrink:0 }}>
                {item.type === "script" ? "⚡" : "📦"}
              </div>
              <div style={{ flex:1 }}>
                <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:3 }}>
                  <span style={{ fontWeight:600, fontSize:13 }}>{item.name}</span>
                  {item.requiredByDefault && <Badge color="#dc2626" bg="#fee2e2">Obligatoire défaut</Badge>}
                </div>
                <div style={{ fontSize:12, color:"#9ca3af", marginBottom:6 }}>{item.description}</div>
                <Badge color={cat.color} bg={cat.bg}>{cat.label}</Badge>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function PageProfiles({ profiles }) {
  return (
    <div style={{ display:"grid", gridTemplateColumns:"repeat(2,1fr)", gap:14 }}>
      {profiles.map(p => (
        <div key={p.id} style={{ border:`1.5px solid ${p.color}25`, borderRadius:12, padding:"18px 20px", background:"#fff" }}>
          <div style={{ display:"flex", alignItems:"flex-start", gap:14, marginBottom:14 }}>
            <div style={{ width:44, height:44, borderRadius:10, background: p.color+"15",
              display:"flex", alignItems:"center", justifyContent:"center", fontSize:22 }}>{p.icon}</div>
            <div>
              <div style={{ fontWeight:700, fontSize:15, marginBottom:4 }}>{p.name}</div>
              <div style={{ fontSize:12, color:"#6b7280" }}>{p.description}</div>
            </div>
          </div>
          <div style={{ display:"flex", gap:6, flexWrap:"wrap", marginBottom:14 }}>
            <Badge color={p.color} bg={p.color+"15"}>{(p.requiredApps?.length||0)} apps obligatoires</Badge>
            <Badge>{(p.defaultApps?.length||0)} apps optionnelles</Badge>
            <Badge color="#10b981" bg="#ecfdf5">{(p.requiredScripts?.length||0)} scripts</Badge>
          </div>
          <div style={{ display:"flex", gap:8 }}>
            <button style={{ flex:1, padding:"7px 0", border:"1.5px solid #e5e7eb", borderRadius:7, background:"#fff",
              fontSize:12, fontWeight:600, color:"#374151", cursor:"pointer" }}>Éditer</button>
            <button style={{ flex:1, padding:"7px 0", border:`1.5px solid ${p.color}`, borderRadius:7,
              background: p.color+"10", fontSize:12, fontWeight:600, color: p.color, cursor:"pointer",
              display:"flex", alignItems:"center", justifyContent:"center", gap:6 }}>
              <Icon name="play" size:14 /> Déployer
            </button>
          </div>
        </div>
      ))}
      <div style={{ border:"1.5px dashed #e5e7eb", borderRadius:12, padding:"18px 20px",
        display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center",
        gap:10, cursor:"pointer", color:"#9ca3af", minHeight:160 }}>
        <Icon name="plus" size={28} />
        <span style={{ fontSize:13 }}>Nouveau profil</span>
      </div>
    </div>
  )
}

function PageLogs() {
  const entries = [
    { machine:"RH-PC-042",  profil:"Poste RH",           status:"ok",    dur:"31 min", date:"21/05 14:18", steps:"9/9" },
    { machine:"COM-NB-017", profil:"Laptop commercial",  status:"error", dur:"12 min", date:"20/05 09:42", steps:"5/9", err:"step-06: JoinDomain timeout" },
    { machine:"RH-PC-041",  profil:"Poste RH",           status:"ok",    dur:"28 min", date:"19/05 16:05", steps:"9/9" },
    { machine:"KIOSK-003",  profil:"Kiosque",             status:"ok",    dur:"18 min", date:"18/05 11:20", steps:"6/6" },
  ]
  return (
    <div style={{ display:"flex", flexDirection:"column", gap:16 }}>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(3,1fr)", gap:10 }}>
        {[["47","Réussis","#10b981"],["3","Erreurs","#ef4444"],["28 min","Durée moy.","#3b82f6"]].map(([v,l,c]) => (
          <div key={l} style={{ background:"#f8fafc", borderRadius:10, padding:"14px 16px", textAlign:"center" }}>
            <div style={{ fontSize:26, fontWeight:700, color:c }}>{v}</div>
            <div style={{ fontSize:12, color:"#9ca3af", marginTop:4 }}>{l}</div>
          </div>
        ))}
      </div>
      <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
        {entries.map(e => (
          <div key={e.machine} style={{ display:"flex", alignItems:"center", gap:14, padding:"12px 16px",
            border:"1.5px solid #f3f4f6", borderRadius:10, background:"#fff" }}>
            <div style={{ width:10, height:10, borderRadius:"50%", flexShrink:0,
              background: e.status === "ok" ? "#10b981" : "#ef4444" }} />
            <div style={{ flex:1 }}>
              <div style={{ fontWeight:600, fontSize:13 }}>{e.machine} · {e.profil}</div>
              <div style={{ fontSize:12, color:"#9ca3af" }}>{e.date} · {e.dur} · {e.steps} steps
                {e.err && <span style={{ color:"#ef4444", marginLeft:6 }}>— {e.err}</span>}
              </div>
            </div>
            <Badge color={e.status==="ok"?"#059669":"#dc2626"} bg={e.status==="ok"?"#ecfdf5":"#fee2e2"}>
              {e.status==="ok"?"Succès":"Erreur"}
            </Badge>
          </div>
        ))}
      </div>
    </div>
  )
}

// ─── App shell ────────────────────────────────────────────────────────────────
export default function App() {
  const [page, setPage]           = useState("deploy")
  const [profiles, setProfiles]   = useState(MOCK_PROFILES)
  const [catalogue, setCatalogue] = useState(MOCK_CATALOGUE)
  const [running, setRunning]     = useState(false)
  const [runProfile, setRunProfile] = useState(null)
  const [logs, setLogs]           = useState(MOCK_LOG)
  const [apiOk, setApiOk]         = useState(null)

  // Vérification santé API
  useEffect(() => {
    apiFetch("/api/health").then(r => setApiOk(!!r?.status))
    apiFetch("/api/profiles").then(r => { if (r?.data?.length) setProfiles(r.data) })
    apiFetch("/api/catalogue").then(r => { if (r?.data?.length) setCatalogue(r.data) })
  }, [])

  // Simulation ajout de logs en mode démo
  useEffect(() => {
    if (!running) return
    const extraLines = [
      "2025-05-21 14:45:18 [OK] [step-04] Jonction domaine réussie !",
      "2025-05-21 14:45:19 [!]  [step-04] Reboot requis — sauvegarde état...",
      "2025-05-21 14:45:22 [~]  [-] RunOnce configuré → reprise step-05",
      "2025-05-21 14:45:27 [>>] [-] Reboot dans 5s",
    ]
    let i = 0
    const t = setInterval(() => {
      if (i < extraLines.length) {
        setLogs(l => [...l, extraLines[i]])
        i++
      } else clearInterval(t)
    }, 2000)
    return () => clearInterval(t)
  }, [running])

  const handleLaunch = (profile, apps) => {
    setRunProfile(profile)
    setRunning(true)
    setPage("running")
    setLogs(MOCK_LOG)
  }

  const NAV = [
    { id:"deploy",    icon:"rocket",    label:"Déployer" },
    { id:"profiles",  icon:"grid",      label:"Profils" },
    { id:"catalogue", icon:"apps",      label:"Catalogue" },
    { id:"sequences", icon:"list",      label:"Séquences" },
    { id:"logs",      icon:"chart",     label:"Déploiements" },
    { id:"settings",  icon:"cog",       label:"Paramètres" },
  ]

  const pageTitle = {
    deploy:"Nouveau déploiement", running:"Déploiement en cours",
    profiles:"Profils", catalogue:"Catalogue", sequences:"Séquences",
    logs:"Historique", settings:"Paramètres"
  }

  return (
    <>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=DM+Mono:wght@400;500&display=swap');
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:'DM Sans',sans-serif;background:#f1f5f9;color:#1e293b}
        button{font-family:inherit}
        input{font-family:inherit}
        @keyframes pulse{0%,100%{box-shadow:0 0 0 3px #bfdbfe}50%{box-shadow:0 0 0 6px #bfdbfe44}}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:0}}
        ::-webkit-scrollbar{width:6px;height:6px}
        ::-webkit-scrollbar-track{background:transparent}
        ::-webkit-scrollbar-thumb{background:#cbd5e1;border-radius:3px}
      `}</style>

      <div style={{ display:"flex", height:"100vh", minHeight:600 }}>
        {/* Sidebar */}
        <aside style={{ width:210, background:"#fff", borderRight:"1.5px solid #f1f5f9",
          display:"flex", flexDirection:"column", flexShrink:0 }}>
          <div style={{ padding:"18px 16px 14px", borderBottom:"1.5px solid #f1f5f9" }}>
            <div style={{ fontSize:16, fontWeight:700, letterSpacing:"-.02em" }}>PSWinDeploy</div>
            <div style={{ fontSize:11, color:"#94a3b8", marginTop:2 }}>Déploiement Windows</div>
          </div>

          {/* API status */}
          <div style={{ padding:"8px 16px", borderBottom:"1.5px solid #f1f5f9", display:"flex", alignItems:"center", gap:6 }}>
            <div style={{ width:7, height:7, borderRadius:"50%",
              background: apiOk === null ? "#f59e0b" : apiOk ? "#10b981" : "#ef4444" }} />
            <span style={{ fontSize:11, color:"#9ca3af" }}>
              {apiOk === null ? "Connexion…" : apiOk ? "API connectée" : "Mode démo (offline)"}
            </span>
          </div>

          <nav style={{ flex:1, padding:"8px 0" }}>
            {NAV.map(n => (
              <div key={n.id} onClick={() => setPage(n.id)}
                style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 16px",
                  cursor:"pointer", fontSize:13, color: page===n.id ? "#1e293b" : "#64748b",
                  fontWeight: page===n.id ? 600 : 400,
                  background: page===n.id ? "#f8fafc" : "transparent",
                  borderRight: page===n.id ? "2.5px solid #3b82f6" : "2.5px solid transparent",
                  transition:"all .12s" }}>
                <span style={{ color: page===n.id ? "#3b82f6" : "#94a3b8" }}>
                  <Icon name={n.icon} size={17} />
                </span>
                {n.label}
              </div>
            ))}
          </nav>

          <div style={{ padding:"12px 16px", borderTop:"1.5px solid #f1f5f9", fontSize:11, color:"#cbd5e1" }}>
            v0.4.0 · ADK amd64/arm64
          </div>
        </aside>

        {/* Main */}
        <div style={{ flex:1, display:"flex", flexDirection:"column", overflow:"hidden" }}>
          {/* Topbar */}
          <header style={{ padding:"14px 24px", borderBottom:"1.5px solid #f1f5f9", background:"#fff",
            display:"flex", alignItems:"center", justifyContent:"space-between", flexShrink:0 }}>
            <div>
              <div style={{ fontSize:16, fontWeight:700 }}>{pageTitle[page]}</div>
              {page==="running" && runProfile && (
                <div style={{ fontSize:12, color:"#9ca3af", marginTop:1 }}>
                  Profil : {runProfile.name} {runProfile.icon}
                </div>
              )}
            </div>
            {page==="running" && (
              <button onClick={() => { setRunning(false); setPage("deploy") }}
                style={{ display:"flex", alignItems:"center", gap:6, padding:"7px 16px",
                  border:"1.5px solid #fca5a5", borderRadius:8, background:"#fff",
                  color:"#dc2626", fontWeight:600, fontSize:13, cursor:"pointer" }}>
                <Icon name="x" size={15} /> Arrêter
              </button>
            )}
            {page==="catalogue" && (
              <button style={{ display:"flex", alignItems:"center", gap:6, padding:"7px 16px",
                border:"none", borderRadius:8, background:"#3b82f6",
                color:"#fff", fontWeight:600, fontSize:13, cursor:"pointer" }}>
                <Icon name="plus" size={15} /> Ajouter
              </button>
            )}
            {page==="profiles" && (
              <button style={{ display:"flex", alignItems:"center", gap:6, padding:"7px 16px",
                border:"none", borderRadius:8, background:"#3b82f6",
                color:"#fff", fontWeight:600, fontSize:13, cursor:"pointer" }}>
                <Icon name="plus" size={15} /> Nouveau profil
              </button>
            )}
          </header>

          {/* Content */}
          <main style={{ flex:1, overflowY:"auto", padding:24 }}>
            {page==="deploy"    && <PageDeploy profiles={profiles} catalogue={catalogue} onLaunch={handleLaunch} />}
            {page==="running"   && <PageRunning profile={runProfile} logs={logs} />}
            {page==="catalogue" && <PageCatalogue catalogue={catalogue} />}
            {page==="profiles"  && <PageProfiles profiles={profiles} />}
            {page==="logs"      && <PageLogs />}
            {page==="sequences" && (
              <div style={{ color:"#94a3b8", fontSize:14, textAlign:"center", paddingTop:60 }}>
                Éditeur de séquences — à venir dans la prochaine version
              </div>
            )}
            {page==="settings" && (
              <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:16 }}>
                {[["Réseau & partages",[["Partage images","\\\\SERVEUR\\Images"],["Partage logiciels","\\\\SERVEUR\\Logiciels"],["Partage logs","\\\\SERVEUR\\Logs"]]],
                  ["ADK & WinPE",[["Architecture","amd64 (arm64 supporté)"],["Chemin ADK","C:\\Program Files (x86)\\Windows Kits\\10\\..."],["Packages WinPE","PowerShell, WMI, NetFx, Scripting"]]],
                  ["Domaine & sécurité",[["Domaine par défaut","corp.local"],["Méthode secrets","Vault chiffré (DPAPI)"],["Compte deploy","deploy-temp"]]],
                  ["API Pode",[["Port","8080"],["CORS","*"],["Version","0.6.9"]]]
                ].map(([title, fields]) => (
                  <div key={title} style={{ background:"#fff", border:"1.5px solid #f3f4f6", borderRadius:12, padding:18 }}>
                    <div style={{ fontWeight:600, fontSize:14, marginBottom:14, color:"#1e293b" }}>{title}</div>
                    {fields.map(([label, val]) => (
                      <div key={label} style={{ marginBottom:10 }}>
                        <div style={{ fontSize:11, color:"#9ca3af", marginBottom:3 }}>{label}</div>
                        <input defaultValue={val} style={{ width:"100%", padding:"6px 10px",
                          border:"1.5px solid #f1f5f9", borderRadius:6, fontSize:12,
                          background:"#f8fafc", color:"#374151", outline:"none" }} />
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            )}
          </main>
        </div>
      </div>
    </>
  )
}
