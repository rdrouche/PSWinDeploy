// i18n.js -- the project is English-only. This module is kept as a thin shim so
// existing t("...") calls keep working without a language mechanism: t() looks
// up a small English string table and, if the key is not found, returns the
// argument unchanged (so t("Some literal text") just yields that text).
//
// No language selector, no localStorage, no FR/EN toggle. English in, English out.

import { useCallback } from "react"

const STRINGS = {
  // Navigation
  "nav.editor": "Editor",
  "nav.sequences": "Sequences",
  "nav.catalogue": "Catalogue",
  "nav.scripts": "Scripts",
  "nav.drivers": "Drivers",
  "nav.monitor": "Monitoring",
  "nav.stats": "Statistics",
  "nav.logout": "Log out",
  "nav.connected": "connected",

  // Monitoring
  "monitor.waiting.title": "Waiting for configuration",
  "monitor.waiting.empty": "No machine waiting.",
  "monitor.waiting.hint": "A machine appears here if it chose \"Wait for a sequence\" in phase 2.",
  "monitor.waiting.push": "Push a sequence",
  "monitor.waiting.cancel": "Cancel",
  "monitor.push.title": "Push a sequence to {0}",
  "monitor.push.read_err": "Cannot read the sequence.",
  "monitor.push.err": "Push failed.",
  "monitor.push.ok": "Sequence pushed to {0}.",
  "monitor.cancel.ok": "Wait cancelled.",

  // Statistics
  "stats.title": "Statistics",
  "stats.today": "Today",
  "stats.week": "This week",
  "stats.month": "This month",
  "stats.year": "This year",
  "stats.total": "Total",
  "stats.purge": "Purge old ones",
}

// Translate a key with {0}, {1}... substitution. Unknown keys (i.e. literal
// text that was wrapped in t()) are returned as-is.
export function translate(key, ...args) {
  let s = STRINGS[key]
  if (s == null) s = key            // literal passthrough
  args.forEach((a, i) => { s = s.replace(`{${i}}`, a) })
  return s
}

// Hook kept for API compatibility. Returns a stable English t().
export function useT() {
  const t = useCallback((key, ...args) => translate(key, ...args), [])
  return { t, lang: "en", changeLang: () => {} }
}
