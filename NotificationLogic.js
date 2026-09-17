function isChromiumDerived(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 ||
         source.indexOf("vivaldi") >= 0 || source.indexOf("microsoft-edge") >= 0 ||
         source.indexOf("opera") >= 0
}

function sanitizeBody(body, app, appIcon) {
  var text = String(body || "").replace(/<img[^>]*>/gi, "")
  if (!isChromiumDerived(app, appIcon)) return text

  return text
    .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
    .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "")
}

// The notification server advertises bodyMarkupSupported, so a body may carry
// markup and has to be rendered as StyledText or the tags show up as text.
// Same shape as the shell's own card: sanitize, then make real newlines into
// breaks, since StyledText collapses them.
function styledBody(body, app, appIcon) {
  return sanitizeBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>")
}

function summaryStartsWithGlyph(summary) {
  var text = String(summary || "").replace(/^\s+/, "")
  if (!text) return false

  var offset = 1
  var first = text.charCodeAt(0)
  if (first >= 0xd800 && first <= 0xdbff && text.length > 1) offset = 2

  var spaces = 0
  while (offset < text.length && text.charAt(offset) === " ") {
    spaces++
    offset++
  }

  return spaces >= 2
}

function shouldBypassDnd(notification, criticalUrgency) {
  var appName = String((notification && notification.appName) || "")
  if (appName === "omarchy-action") return true
  return appName === "notify-send" && notification && notification.urgency === criticalUrgency
}

function isEphemeralApp(appName) {
  var name = String(appName || "")
  return name === "notify-send" || name === "omarchy-action"
}

function glyphFromHints(hints) {
  try {
    if (hints) {
      var glyph = hints["omarchy-glyph"]
      if (glyph !== undefined && glyph !== null) return String(glyph)
    }
  } catch (e) {
  }
  return ""
}

function shouldRenderCompactGlyph(glyph, iconSource, singleLineToast) {
  return String(glyph || "").length > 0 && String(iconSource || "").length === 0 && !!singleLineToast
}

function snapshotOf(notification, timestamp) {
  var n = notification || {}
  var id = n.id || 0
  var expireTimeout = Number(n.expireTimeout || 0)
  if (!isFinite(expireTimeout) || expireTimeout < 0) expireTimeout = 0
  return {
    id: id,
    originalId: id,
    app: n.appName || "",
    appIcon: n.appIcon || "",
    summary: String(n.summary || ""),
    body: n.body || "",
    image: n.image || "",
    glyph: glyphFromHints(n.hints),
    urgency: n.urgency,
    expireTimeout: expireTimeout,
    timestamp: timestamp === undefined ? Date.now() : timestamp
  }
}

// Validate a notification's click action into an argv vector, or null.
//
// Same checks the shell's own service makes before running one: valid JSON, a
// non-empty array of strings, and a program that argv would not read as an
// option. It does not judge intent -- a well-formed ["bash","-c",...] passes.
// Which senders may set the hint at all is the session bus's boundary, not
// this widget's: any same-uid process can, by the freedesktop protocol's
// design, and Omarchy's own toasts are what use it.
function parseExecArgv(value) {
  var text = String(value || "")
  if (!text) return null

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }

  if (!Array.isArray(parsed) || parsed.length === 0) return null
  for (var i = 0; i < parsed.length; i++) {
    if (typeof parsed[i] !== "string") return null
  }
  if (!parsed[0] || parsed[0].charAt(0) === "-") return null
  return parsed
}

function historyEntry(value, normalUrgency) {
  var e = value || {}
  return {
    id: e.id || 0,
    originalId: e.originalId || e.id || 0,
    app: e.app || "",
    appIcon: e.appIcon || "",
    summary: e.summary || "",
    body: e.body || "",
    image: e.image || "",
    glyph: e.glyph || "",
    execArgv: e.execArgv || "",
    urgency: typeof e.urgency === "number" ? e.urgency : normalUrgency,
    expireTimeout: 0,
    timestamp: e.timestamp || 0
  }
}

function dedupeByOriginalId(rows) {
  var values = Array.isArray(rows) ? rows : []
  var keep = {}
  for (var i = 0; i < values.length; i++) {
    var row = values[i]
    if (!row) continue
    var key = row.originalId
    if (key === undefined || key === null) key = "_" + i
    var prior = keep[key]
    if (!prior || (row.timestamp || 0) >= (prior.timestamp || 0)) keep[key] = row
  }

  var out = []
  for (var id in keep) out.push(keep[id])
  out.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return out
}

// Rows read straight out of the notification service's history directory.
//
// `raw` is one line per file: the file's path, a tab, then the JSON object the
// service wrote into it. Each file holds exactly one notification, so a line
// parses on its own and a half-written file costs one row rather than the
// whole list. The directory is already one file per notification -- no two
// entries describe the same one -- so these are only sorted, never deduped:
// ids restart at 1 with every shell generation, and collapsing by id would
// silently merge yesterday's notification 3 with today's.
function recentFromFiles(raw, normalUrgency) {
  var lines = String(raw || "").split("\n")
  var rows = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var tab = line.indexOf("\t")
    if (tab === -1) continue
    var entry
    try {
      entry = JSON.parse(line.substring(tab + 1))
    } catch (e) {
      continue
    }
    rows.push(historyEntry(entry, normalUrgency))
  }
  rows.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return rows
}

function parseHistory(raw, normalUrgency, historyCap) {
  var text = String(raw || "").trim()
  var cap = historyCap === undefined || historyCap === null ? 100 : Number(historyCap)
  if (isNaN(cap)) cap = 100
  cap = Math.max(0, cap)
  if (!text) return { empty: true, error: false, dnd: null, pending: [], past: [], hadDuplicates: false }

  try {
    var parsed = JSON.parse(text)
    var pendingRaw = (parsed && Array.isArray(parsed.pending)) ? parsed.pending : []
    var pastRaw = (parsed && Array.isArray(parsed.past)) ? parsed.past : []
    if (parsed && Array.isArray(parsed.entries)) pastRaw = pastRaw.concat(parsed.entries)

    var pendingDeduped = dedupeByOriginalId(pendingRaw)
    var pastDeduped = dedupeByOriginalId(pastRaw)

    return {
      empty: false,
      error: false,
      dnd: parsed && typeof parsed.dnd === "boolean" ? parsed.dnd : null,
      pending: pendingDeduped.slice(0, cap).map(function(entry) { return historyEntry(entry, normalUrgency) }),
      past: pastDeduped.slice(0, cap).map(function(entry) { return historyEntry(entry, normalUrgency) }),
      hadDuplicates: pendingDeduped.length !== pendingRaw.length || pastDeduped.length !== pastRaw.length
    }
  } catch (e) {
    return { empty: false, error: true, errorMessage: String(e), dnd: null, pending: [], past: [], hadDuplicates: false }
  }
}

function recentHistoryRows(pending, past, limit, normalUrgency) {
  var max = limit === undefined || limit === null ? 5 : Number(limit)
  if (isNaN(max)) max = 5
  max = Math.max(0, max)

  var values = []
  function collect(rows) {
    var source = Array.isArray(rows) ? rows : []
    for (var i = 0; i < source.length; i++) {
      if (source[i]) values.push(source[i])
    }
  }
  collect(pending)
  collect(past)

  var keep = {}
  for (var j = 0; j < values.length; j++) {
    var row = values[j]
    var key = row.originalId
    if (key === undefined || key === null) key = row.id
    if (key === undefined || key === null) key = "_" + j
    var prior = keep[key]
    if (!prior || (row.timestamp || 0) >= (prior.timestamp || 0)) keep[key] = row
  }

  var out = []
  for (var id in keep) out.push(historyEntry(keep[id], normalUrgency))
  out.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return out.slice(0, max)
}

function dumpRows(rows) {
  var values = Array.isArray(rows) ? rows : []
  var out = []
  for (var i = 0; i < values.length; i++) {
    var r = values[i]
    if (!r) continue
    out.push({
      id: r.id,
      originalId: r.originalId,
      app: r.app,
      appIcon: r.appIcon,
      summary: r.summary,
      body: r.body,
      image: r.image,
      glyph: r.glyph || "",
      urgency: r.urgency,
      timestamp: r.timestamp
    })
  }
  return out
}

function popupPlacement(barPosition, barClearance, gapsOut) {
  var position = String(barPosition || "top")
  var clearance = Number(barClearance)
  var gap = Number(gapsOut)
  if (!isFinite(clearance)) clearance = 0
  if (!isFinite(gap)) gap = 0

  return {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: {
      top: position === "top" ? clearance : gap,
      bottom: gap,
      left: gap,
      right: position === "right" ? clearance : gap
    }
  }
}

function imageExtension(srcPath) {
  var lower = String(srcPath || "").toLowerCase()
  var dot = lower.lastIndexOf(".")
  if (dot < 0) return "png"
  var ext = lower.substring(dot + 1)
  if (ext.length === 0 || ext.length > 5) return "png"
  return ext
}

if (typeof module !== "undefined") {
  module.exports = {
    isChromiumDerived: isChromiumDerived,
    sanitizeBody: sanitizeBody,
    styledBody: styledBody,
    summaryStartsWithGlyph: summaryStartsWithGlyph,
    shouldBypassDnd: shouldBypassDnd,
    isEphemeralApp: isEphemeralApp,
    glyphFromHints: glyphFromHints,
    shouldRenderCompactGlyph: shouldRenderCompactGlyph,
    snapshotOf: snapshotOf,
    historyEntry: historyEntry,
    parseExecArgv: parseExecArgv,
    recentFromFiles: recentFromFiles,
    dedupeByOriginalId: dedupeByOriginalId,
    parseHistory: parseHistory,
    recentHistoryRows: recentHistoryRows,
    dumpRows: dumpRows,
    popupPlacement: popupPlacement,
    imageExtension: imageExtension
  }
}
