.pragma library

// Pure helpers for Panel.qml. Kept free of QML types so they can be tested
// with plain node (tests/model.test.mjs).

function emptyTrack() {
  return { artist: "", title: "", album: "", art: "", interstitial: false }
}

function parseJson(text) {
  if (typeof text !== "string" || text === "" || text.length > 8 * 1024 * 1024) return null
  try { return JSON.parse(text) } catch (e) { return null }
}

function str(value, limit) {
  return String(value === undefined || value === null ? "" : value).replace(/[\r\n\t]+/g, " ").slice(0, limit || 200)
}

function parseStatus(text) {
  var raw = parseJson(text) || {}
  var track = raw.track && typeof raw.track === "object" ? raw.track : {}
  var channel = raw.channel && typeof raw.channel === "object" && raw.channel.id ? raw.channel : null
  var volume = Number(raw.volume)
  return {
    running: raw.running === true,
    state: ["playing", "paused", "loading", "stopped", "error"].indexOf(raw.state) >= 0 ? raw.state : "stopped",
    channel: channel ? normalizeChannel(channel) : null,
    track: {
      artist: str(track.artist), title: str(track.title), album: str(track.album),
      art: str(track.art, 2000), interstitial: track.interstitial === true
    },
    volume: isFinite(volume) ? Math.max(0, Math.min(100, Math.round(volume))) : 100,
    muted: raw.muted === true,
    error: str(raw.error, 300),
    loggedIn: raw.loggedIn === true,
    last: str(raw.last)
  }
}

function normalizeChannel(c) {
  var number = Number(c.number)
  return {
    id: str(c.id),
    name: str(c.name),
    description: str(c.description, 300),
    number: c.number === null || c.number === undefined || !isFinite(number) ? null : number,
    category: str(c.category),
    logo: str(c.logo, 2000),
    locked: c.locked === true
  }
}

function parseLineup(text) {
  var raw = parseJson(text)
  var list = raw && Array.isArray(raw.channels) ? raw.channels : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id) out.push(normalizeChannel(list[i]))
  }
  return out
}

function parseFavorites(text) {
  var raw = parseJson(text)
  var list = raw && Array.isArray(raw.favorites) ? raw.favorites : []
  return list.filter(function(id) { return typeof id === "string" && id !== "" })
}

function genres(channels) {
  var seen = {}
  var out = []
  for (var i = 0; i < channels.length; i++) {
    var g = channels[i].category
    if (g && !seen[g]) { seen[g] = true; out.push(g) }
  }
  out.sort(function(a, b) { return a.localeCompare(b) })
  return out
}

function filter(channels, query, mode, genre, favorites) {
  var q = String(query || "").trim().toLowerCase()
  var favSet = {}
  for (var f = 0; f < favorites.length; f++) favSet[favorites[f]] = true
  var numeric = /^\d+$/.test(q)
  var out = []
  for (var i = 0; i < channels.length; i++) {
    var c = channels[i]
    if (mode === "favorites" && !favSet[c.id]) continue
    if (genre && c.category !== genre) continue
    if (q) {
      var hit = numeric
        ? String(c.number) === q || String(c.number).indexOf(q) === 0
        : (c.name.toLowerCase().indexOf(q) >= 0
          || c.category.toLowerCase().indexOf(q) >= 0
          || c.description.toLowerCase().indexOf(q) >= 0)
      if (!hit) continue
    }
    out.push(c)
  }
  if (numeric) {
    // Exact channel number first.
    out.sort(function(a, b) { return (String(b.number) === q) - (String(a.number) === q) })
  }
  return out
}

function nowPlayingLine(status) {
  var t = status.track
  if (!t || !t.title || t.interstitial) return ""
  return t.artist ? t.artist + " — " + t.title : t.title
}

function channelLabel(channel) {
  if (!channel) return ""
  return channel.number !== null ? "Ch " + channel.number + " · " + channel.name : channel.name
}

function heroTitle(status) {
  if (!status.loggedIn) return "SiriusXM"
  if (!status.running || !status.channel) return "SiriusXM"
  var t = status.track
  return t && t.title && !t.interstitial ? t.title : status.channel.name
}

function heroSubtitle(status) {
  if (!status.loggedIn) return "Sign in to start listening"
  if (!status.running || !status.channel) return "Pick a channel below"
  var t = status.track
  if (t && t.title && !t.interstitial) return t.artist
  return status.channel.description
}

function heroCaption(status) {
  if (!status.loggedIn) return "Not signed in"
  var stateLabel = { playing: "", paused: "Paused · ", loading: "Tuning · ", error: "Error · ", stopped: "" }[status.state] || ""
  if (!status.running || !status.channel) return status.state === "error" ? "Error" : "Stopped"
  return stateLabel + channelLabel(status.channel)
}

function tooltip(status) {
  if (!status.loggedIn) return "SiriusXM: sign in"
  if (!status.running || !status.channel) return "SiriusXM"
  var line = nowPlayingLine(status)
  var prefix = status.state === "paused" ? "Paused: " : (status.state === "loading" ? "Tuning: " : "")
  var text = prefix + channelLabel(status.channel) + (line ? "\n" + line : "")
  if (status.error) text += "\n" + status.error
  return text.replace(/</g, "‹").replace(/>/g, "›")
}

function cleanError(text) {
  var lines = String(text || "").split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l !== "" })
  if (lines.length === 0) return ""
  var last = lines[lines.length - 1]
  return last.replace(/^sxm:\s*/, "").slice(0, 300)
}
