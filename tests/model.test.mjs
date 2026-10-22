// node --test tests/model.test.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
const Model = new Function(source + "\nreturn { parseStatus, parseLineup, parseFavorites, genres, filter, heroTitle, heroSubtitle, heroCaption, tooltip, cleanError }")()

const lineup = JSON.stringify({ channels: [
  { id: "a", name: "SiriusXM Hits 1", number: 2, category: "Pop", description: "Pop hits", logo: "" },
  { id: "b", name: "Howard 100", number: 100, category: "Comedy", description: "Howard", logo: "" },
  { id: "c", name: "Octane", number: 37, category: "Hard Rock & Metal", description: "", logo: "" },
  { id: "d", name: "Channel 20", number: 20, category: "Pop", description: "", logo: "" },
] })

test("status parsing is defensive", () => {
  const s = Model.parseStatus("garbage")
  assert.equal(s.state, "stopped")
  assert.equal(s.loggedIn, false)
  const p = Model.parseStatus(JSON.stringify({ running: true, state: "playing", loggedIn: true, volume: 250,
    channel: { id: "a", name: "Hits 1", number: 2 }, track: { artist: "X", title: "Y" } }))
  assert.equal(p.volume, 100)
  assert.equal(Model.heroTitle(p), "Y")
  assert.equal(Model.heroSubtitle(p), "X")
  assert.equal(Model.heroCaption(p), "Ch 2 · Hits 1")
  assert.equal(Model.tooltip(p), "Ch 2 · Hits 1\nX — Y")
})

test("filtering by text, number, genre and favorites", () => {
  const channels = Model.parseLineup(lineup)
  assert.deepEqual(Model.filter(channels, "howard", "all", "", []).map(c => c.id), ["b"])
  assert.deepEqual(Model.filter(channels, "2", "all", "", []).map(c => c.id), ["a", "d"])
  assert.deepEqual(Model.filter(channels, "20", "all", "", []).map(c => c.id), ["d"])
  assert.deepEqual(Model.filter(channels, "", "all", "Pop", []).map(c => c.id), ["a", "d"])
  assert.deepEqual(Model.filter(channels, "", "favorites", "", ["c"]).map(c => c.id), ["c"])
  assert.deepEqual(Model.genres(channels), ["Comedy", "Hard Rock & Metal", "Pop"])
})

test("favorites and errors", () => {
  assert.deepEqual(Model.parseFavorites('{"favorites":["a",3,"b"]}'), ["a", "b"])
  assert.equal(Model.cleanError("Traceback\nsxm: SiriusXM rejected that email or password\n"), "SiriusXM rejected that email or password")
})
