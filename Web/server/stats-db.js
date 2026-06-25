// stats-db.js -- stockage SQLite des deploiements et calcul des statistiques.
//
// Le conteneur garde une copie PERSISTANTE des deploiements termines (table
// deployments) sur un volume Docker. Les donnees sont synchronisees depuis
// l'API PowerShell (source des heartbeats) : le BFF pull /api/deploy/completed
// et UPSERT ici. Avantage : les stats survivent meme si l'API purge son
// historique, et les agregations se font en SQL (rapide, flexible).

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
      id            TEXT PRIMARY KEY,     -- identifiant du poste (nom ou MAC)
      computer_name TEXT,
      mac           TEXT,
      status        TEXT,                 -- done / running / ...
      completed     INTEGER NOT NULL DEFAULT 0,  -- 1 si termine
      start_ts      TEXT,                 -- ISO 8601
      end_ts        TEXT,                 -- ISO 8601
      duration_sec  INTEGER,
      events        INTEGER,
      updated_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_dep_end ON deployments(end_ts);
    CREATE INDEX IF NOT EXISTS idx_dep_completed ON deployments(completed);
  `)
  return db
}

// UPSERT d'un lot de deploiements (issus de /api/deploy/completed).
// Chaque element : { Id, ComputerName, Mac, Status, Completed, Start, End,
// DurationSec, Events }.
export function upsertDeployments(list) {
  if (!db || !Array.isArray(list) || list.length === 0) return 0
  const stmt = db.prepare(`
    INSERT INTO deployments
      (id, computer_name, mac, status, completed, start_ts, end_ts, duration_sec, events, updated_at)
    VALUES
      (@id, @computer_name, @mac, @status, @completed, @start_ts, @end_ts, @duration_sec, @events, @updated_at)
    ON CONFLICT(id) DO UPDATE SET
      computer_name = excluded.computer_name,
      mac           = excluded.mac,
      status        = excluded.status,
      completed     = excluded.completed,
      start_ts      = excluded.start_ts,
      end_ts        = excluded.end_ts,
      duration_sec  = excluded.duration_sec,
      events        = excluded.events,
      updated_at    = excluded.updated_at
  `)
  const now = Date.now()
  const tx = db.transaction((rows) => {
    for (const r of rows) {
      stmt.run({
        id: String(r.Id ?? r.id ?? ""),
        computer_name: r.ComputerName ?? null,
        mac: r.Mac ?? null,
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
  tx(list.filter(r => (r.Id ?? r.id)))
  return list.length
}

// Calcule les statistiques (J/S/M/A + durees) par requetes SQL.
export function computeStats() {
  if (!db) return null
  const now = new Date()
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  // Lundi comme debut de semaine.
  const dow = (now.getDay() + 6) % 7
  const startOfWeek = new Date(startOfDay); startOfWeek.setDate(startOfDay.getDate() - dow)
  const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1)
  const startOfYear = new Date(now.getFullYear(), 0, 1)
  const iso = (d) => d.toISOString()

  const countSince = db.prepare(
    "SELECT COUNT(*) AS n FROM deployments WHERE completed = 1 AND end_ts >= ?"
  )
  const total = db.prepare("SELECT COUNT(*) AS n FROM deployments WHERE completed = 1").get().n
  const dur = db.prepare(`
    SELECT AVG(duration_sec) AS avg, MIN(duration_sec) AS min, MAX(duration_sec) AS max
    FROM deployments WHERE completed = 1 AND duration_sec IS NOT NULL
  `).get()

  return {
    Today: countSince.get(iso(startOfDay)).n,
    Week: countSince.get(iso(startOfWeek)).n,
    Month: countSince.get(iso(startOfMonth)).n,
    Year: countSince.get(iso(startOfYear)).n,
    Total: total,
    AvgDurationSec: dur.avg != null ? Math.round(dur.avg) : 0,
    MinDurationSec: dur.min != null ? Math.round(dur.min) : 0,
    MaxDurationSec: dur.max != null ? Math.round(dur.max) : 0,
  }
}

// Liste paginee des deploiements termines. Retourne { rows, total }.
export function listCompleted({ limit = 25, offset = 0 } = {}) {
  if (!db) return { rows: [], total: 0 }
  const total = db.prepare("SELECT COUNT(*) AS n FROM deployments").get().n
  const rows = db.prepare(`
    SELECT id, computer_name, mac, status, completed, start_ts, end_ts, duration_sec, events
    FROM deployments
    ORDER BY end_ts DESC
    LIMIT ? OFFSET ?
  `).all(limit, offset)
  return {
    total,
    rows: rows.map(r => ({
      Id: r.id,
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

// Supprime un deploiement par id (suppression manuelle). Retourne le nb de
// lignes supprimees (0 ou 1).
export function deleteDeployment(id) {
  if (!db || !id) return 0
  const info = db.prepare("DELETE FROM deployments WHERE id = ?").run(String(id))
  return info.changes
}

// Purge les deploiements termines dont la fin est anterieure a X mois.
// Retourne le nombre de lignes supprimees.
export function purgeOlderThan(months) {
  if (!db || !months || months <= 0) return 0
  const cutoff = new Date()
  cutoff.setMonth(cutoff.getMonth() - months)
  const info = db.prepare(
    "DELETE FROM deployments WHERE end_ts IS NOT NULL AND end_ts < ?"
  ).run(cutoff.toISOString())
  return info.changes
}
