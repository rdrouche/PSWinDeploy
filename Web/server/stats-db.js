// stats-db.js -- stockage SQLite des deploiements et calcul des statistiques.
//
// Le conteneur garde une copie PERSISTANTE des deploiements termines sur un
// volume Docker. Les donnees sont synchronisees depuis l'API PowerShell : le
// BFF pull /api/deploy/completed et UPSERT ici.
//
// MODELE (v2) : chaque DEPLOIEMENT est une ligne (PK technique auto-incrementee
// row_id). La MAC n'est plus la cle : c'est un attribut (identite machine). Un
// redeploiement de la meme VM cree donc une NOUVELLE ligne.
//   -> Pour que la sync ne cree pas de doublons, on deduplique sur une cle
//      METIER stable : dedup_key = "<mac>|<end_ts>". Meme machine + meme fin de
//      cycle = meme deploiement (mise a jour) ; fin differente = nouvelle ligne.
//   -> Suppression = hidden par row_id (reversible ; la sync ne reaffiche pas).

import Database from "better-sqlite3"
import path from "node:path"
import fs from "node:fs"

let db = null

export function initDb(sqlitePath) {
  fs.mkdirSync(path.dirname(sqlitePath), { recursive: true })
  db = new Database(sqlitePath)
  db.pragma("journal_mode = WAL")
  db.exec(`
    CREATE TABLE IF NOT EXISTS deployments (
      row_id        INTEGER PRIMARY KEY AUTOINCREMENT,  -- PK technique
      dedup_key     TEXT UNIQUE,          -- cle metier "<mac>|<end_ts>" (anti-doublon sync)
      computer_name TEXT,
      mac           TEXT,                 -- identite machine (attribut, plus la cle)
      status        TEXT,                 -- done / running / ...
      completed     INTEGER NOT NULL DEFAULT 0,
      start_ts      TEXT,
      end_ts        TEXT,
      duration_sec  INTEGER,
      events        INTEGER,
      hidden        INTEGER NOT NULL DEFAULT 0,  -- 1 = masque (supprime cote GUI)
      updated_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_dep_end ON deployments(end_ts);
    CREATE INDEX IF NOT EXISTS idx_dep_completed ON deployments(completed);
    CREATE INDEX IF NOT EXISTS idx_dep_hidden ON deployments(hidden);
  `)
  migrateIfNeeded()
  return db
}

// Migration depuis l'ancien schema (PK = id [MAC]). On bascule vers le nouveau
// modele auto-incremente sans perdre les donnees existantes.
function migrateIfNeeded() {
  try {
    const cols = db.prepare("PRAGMA table_info(deployments)").all()
    const hasRowId = cols.some(c => c.name === "row_id")
    const hasOldId = cols.some(c => c.name === "id")
    if (hasRowId) return  // deja au nouveau schema

    if (hasOldId) {
      // Ancienne table : la renommer, recreer la nouvelle, recopier les donnees
      // en fabriquant dedup_key = mac|end_ts (ou id|end_ts en repli).
      db.exec("ALTER TABLE deployments RENAME TO deployments_old")
      db.exec(`
        CREATE TABLE deployments (
          row_id        INTEGER PRIMARY KEY AUTOINCREMENT,
          dedup_key     TEXT UNIQUE,
          computer_name TEXT,
          mac           TEXT,
          status        TEXT,
          completed     INTEGER NOT NULL DEFAULT 0,
          start_ts      TEXT,
          end_ts        TEXT,
          duration_sec  INTEGER,
          events        INTEGER,
          hidden        INTEGER NOT NULL DEFAULT 0,
          updated_at    INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_dep_end ON deployments(end_ts);
        CREATE INDEX IF NOT EXISTS idx_dep_completed ON deployments(completed);
        CREATE INDEX IF NOT EXISTS idx_dep_hidden ON deployments(hidden);
      `)
      const oldRows = db.prepare("SELECT * FROM deployments_old").all()
      const ins = db.prepare(`
        INSERT OR IGNORE INTO deployments
          (dedup_key, computer_name, mac, status, completed, start_ts, end_ts, duration_sec, events, hidden, updated_at)
        VALUES
          (@dedup_key, @computer_name, @mac, @status, @completed, @start_ts, @end_ts, @duration_sec, @events, @hidden, @updated_at)
      `)
      const now = Date.now()
      const tx = db.transaction((rows) => {
        for (const r of rows) {
          const mac = r.mac || r.id || ""
          const end = r.end_ts || ""
          ins.run({
            dedup_key: `${mac}|${end}`,
            computer_name: r.computer_name ?? null,
            mac: mac || null,
            status: r.status ?? null,
            completed: r.completed ?? 0,
            start_ts: r.start_ts ?? null,
            end_ts: r.end_ts ?? null,
            duration_sec: r.duration_sec ?? null,
            events: r.events ?? null,
            hidden: r.hidden ?? 0,
            updated_at: r.updated_at ?? now,
          })
        }
      })
      tx(oldRows)
      db.exec("DROP TABLE deployments_old")
      console.log(`[stats-db] migration v2 : ${oldRows.length} ligne(s) migree(s).`)
    }
  } catch (e) {
    console.error(`[stats-db] migration KO : ${e?.message || e}`)
  }
}

// Fabrique la cle de deduplication d'un deploiement (issu de l'API).
function dedupKey(r) {
  const mac = r.Mac ?? r.mac ?? r.Id ?? r.id ?? ""
  const end = r.End ?? r.end_ts ?? ""
  return `${mac}|${end}`
}

// UPSERT d'un lot de deploiements (issus de /api/deploy/completed).
// Deduplication sur dedup_key (mac|end). Un deploiement deja vu est mis a jour ;
// un nouveau cycle (fin differente) cree une nouvelle ligne.
export function upsertDeployments(list) {
  if (!db || !Array.isArray(list) || list.length === 0) return 0
  const stmt = db.prepare(`
    INSERT INTO deployments
      (dedup_key, computer_name, mac, status, completed, start_ts, end_ts, duration_sec, events, hidden, updated_at)
    VALUES
      (@dedup_key, @computer_name, @mac, @status, @completed, @start_ts, @end_ts, @duration_sec, @events, 0, @updated_at)
    ON CONFLICT(dedup_key) DO UPDATE SET
      computer_name = excluded.computer_name,
      mac           = excluded.mac,
      status        = excluded.status,
      completed     = excluded.completed,
      start_ts      = excluded.start_ts,
      end_ts        = excluded.end_ts,
      duration_sec  = excluded.duration_sec,
      events        = excluded.events,
      updated_at    = excluded.updated_at
    -- 'hidden' n'est PAS reinitialise : une ligne masquee le reste meme si la
    -- sync la retrouve dans l'API.
  `)
  const now = Date.now()
  const tx = db.transaction((rows) => {
    for (const r of rows) {
      const mac = r.Mac ?? r.mac ?? r.Id ?? r.id ?? null
      stmt.run({
        dedup_key: dedupKey(r),
        computer_name: r.ComputerName ?? null,
        mac: mac,
        status: r.Status ?? null,
        completed: (r.Completed === true || r.Completed === 1) ? 1 : 0,
        start_ts: r.Start ?? null,
        end_ts: r.End ?? null,
        duration_sec: (r.DurationSec ?? null),
        events: (r.Events ?? null),
        updated_at: now,
      })
    }
  })
  // On n'insere que les deploiements ayant une fin (cycle termine) : la cle de
  // dedup repose sur end_ts.
  tx(list.filter(r => (r.End ?? r.end_ts)))
  return list.length
}

// Calcule les statistiques (J/S/M/A + durees) par requetes SQL.
export function computeStats() {
  if (!db) return null
  const now = new Date()
  const iso = (d) => d.toISOString()
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const startOfWeek = new Date(startOfDay)
  const dow = (startOfDay.getDay() + 6) % 7   // lundi = 0
  startOfWeek.setDate(startOfDay.getDate() - dow)
  const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1)
  const startOfYear = new Date(now.getFullYear(), 0, 1)

  const countSince = (d) => db.prepare(
    "SELECT COUNT(*) AS n FROM deployments WHERE completed = 1 AND hidden = 0 AND end_ts >= ?"
  ).get(iso(d)).n
  const total = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE completed = 1 AND hidden = 0").get().n
  const dur = db.prepare(`
    SELECT AVG(duration_sec) AS avg, MIN(duration_sec) AS min, MAX(duration_sec) AS max
    FROM deployments WHERE completed = 1 AND hidden = 0 AND duration_sec IS NOT NULL
  `).get()

  return {
    Today: countSince(startOfDay),
    Week:  countSince(startOfWeek),
    Month: countSince(startOfMonth),
    Year:  countSince(startOfYear),
    Total: total,
    DurationAvgSec: dur.avg ? Math.round(dur.avg) : null,
    DurationMinSec: dur.min ?? null,
    DurationMaxSec: dur.max ?? null,
  }
}

// Liste paginee des deploiements termines visibles (pour le tableau Stats).
export function listCompleted({ limit = 25, offset = 0 } = {}) {
  if (!db) return { rows: [], total: 0 }
  const total = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE hidden = 0").get().n
  const rows = db.prepare(`
    SELECT row_id, dedup_key, computer_name, mac, status, completed, start_ts, end_ts, duration_sec, events
    FROM deployments
    WHERE hidden = 0
    ORDER BY end_ts DESC
    LIMIT ? OFFSET ?
  `).all(limit, offset)
  return {
    total,
    rows: rows.map(r => ({
      // RowId = identifiant unique de CE deploiement (pour la suppression).
      RowId: r.row_id,
      Id: r.row_id,            // compat front (cle de ligne)
      ComputerName: r.computer_name,
      Mac: r.mac,
      Status: r.status,
      Completed: !!r.completed,
      Start: r.start_ts,
      End: r.end_ts,
      DurationSec: r.duration_sec,
      Events: r.events,
    })),
  }
}

// "Supprime" un deploiement = le masque (hidden=1), PAR LIGNE (row_id). La ligne
// reste en base mais disparait des stats, et la sync ne la reaffiche pas.
export function deleteDeployment(rowId) {
  if (!db || rowId == null) return 0
  return db.prepare("UPDATE deployments SET hidden = 1 WHERE row_id = ?").run(Number(rowId)).changes
}

// Re-affiche un deploiement masque (hidden=0). Sans rowId -> tous les masques.
export function unhideDeployment(rowId) {
  if (!db) return 0
  if (rowId != null && rowId !== "") {
    return db.prepare("UPDATE deployments SET hidden = 0 WHERE row_id = ?").run(Number(rowId)).changes
  }
  return db.prepare("UPDATE deployments SET hidden = 0 WHERE hidden = 1").run().changes
}

// Purge les deploiements termines dont la fin est anterieure a X mois (DELETE reel).
export function purgeOlderThan(months) {
  if (!db || !months || months <= 0) return 0
  const cutoff = new Date()
  cutoff.setMonth(cutoff.getMonth() - months)
  return db.prepare(
    "DELETE FROM deployments WHERE end_ts IS NOT NULL AND end_ts < ?"
  ).run(cutoff.toISOString()).changes
}

// Diagnostic : etat brut de la table (y compris les lignes masquees).
export function debugDump() {
  if (!db) return { dbReady: false }
  const total = db.prepare("SELECT COUNT(*) AS n FROM deployments").get().n
  const hidden = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE hidden = 1").get().n
  const completed = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE completed = 1").get().n
  const visibleCompleted = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE completed = 1 AND hidden = 0").get().n
  const rows = db.prepare("SELECT row_id, dedup_key, computer_name, mac, completed, hidden, end_ts, duration_sec FROM deployments ORDER BY end_ts DESC LIMIT 50").all()
  return { dbReady: true, total, hidden, completed, visibleCompleted, rows }
}
