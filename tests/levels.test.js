#!/usr/bin/env node
// Tests for Levels.js. The file starts with ".pragma library" (QML only), so the
// first line is dropped and the rest runs in a vm context.
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "Levels.js"), "utf8").replace(/^\.pragma library[^\n]*\n/, "")
const context = vm.createContext({})
vm.runInContext(source, context)
const L = context

let passed = 0
let failed = 0
function test(name, fn) {
  try { fn(); passed++; console.log("  ok   " + name) }
  catch (error) { failed++; console.log("  FAIL " + name + "\n       " + String(error.message).split("\n").join("\n       ")) }
}
const eq = (actual, expected, message = "values differ") => assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected, message)

const T = { swapLimitPercent: 90, pressureLimitPercent: 50, pressureDurationSec: 20 }
const sample = (swap, pressure, nowMs, swapAvailable = true) => ({ swapPercent: swap, swapAvailable, pressure, nowMs })
const level = (swap, pressure, previous = null, nowMs = 0, thresholds = T, options = {}) =>
  L.evaluate(sample(swap, pressure, nowMs), thresholds, options, previous)

console.log("levels.test.js")

test("normal when both are low", () => eq(level(10, 0).level, "normal"))
test("normal just below both warn lines", () => eq(level(74.9, 24.9).level, "normal"))

test("warn at swap limit minus 15", () => eq(level(75, 0).level, "warn"))
test("warn at half the pressure limit", () => eq(level(0, 25).level, "warn"))
test("critical at swap limit minus 5", () => eq(level(85, 0).level, "critical"))
test("swap between warn and critical lines is warn", () => eq(level(84.9, 0).level, "warn"))
test("critical swap beats low pressure", () => eq(level(88, 1).level, "critical"))

test("pressure above the limit is only warn on the first sample", () => {
  const s = level(0, 60)
  eq([s.level, s.heldSec], ["warn", 0])
})
test("pressure above the limit goes critical once held half the duration", () => {
  let s = level(0, 60, null, 0)
  for (let t = 1; t <= 9; t++) { s = level(0, 60, s, t * 1000); eq(s.level, "warn", "t=" + t) }
  s = level(0, 60, s, 10000)
  eq([s.level, s.heldSec], ["critical", 10])
})
test("held counter resets when pressure drops below the limit", () => {
  let s = level(0, 60, null, 0)
  s = level(0, 60, s, 5000)
  eq(s.heldSec, 5)
  s = level(0, 40, s, 6000)
  eq(s.heldSec, 0)
  s = level(0, 60, s, 7000)
  eq(s.heldSec, 1, "counting restarts from zero, plus the one second since the last sample")
})
test("a long gap (suspend) counts at most maxSampleGapSec", () => {
  let s = level(0, 60, null, 0)
  s = level(0, 60, s, 3600 * 1000)
  eq(s.heldSec, 5)
})
test("held counter is not negative when the clock goes backwards", () => {
  let s = level(0, 60, null, 10000)
  s = level(0, 60, s, 5000)
  eq(s.heldSec, 0)
})
test("pressure exactly at the limit counts as above", () => eq(level(0, 50, level(0, 50, null, 0), 2000).heldSec, 2))

test("custom hold percent: 100 percent needs the full duration", () => {
  let s = level(0, 60, null, 0, T, { criticalHoldPercent: 100 })
  for (let t = 1; t <= 19; t++) s = level(0, 60, s, t * 1000, T, { criticalHoldPercent: 100 })
  eq(s.level, "warn")
  s = level(0, 60, s, 20000, T, { criticalHoldPercent: 100 })
  eq(s.level, "critical")
})
test("custom hold percent 0 is critical straight away", () => eq(level(0, 60, null, 0, T, { criticalHoldPercent: 0 }).level, "critical"))
test("custom swap margins", () => {
  const options = { swapWarnMargin: 30, swapCriticalMargin: 10 }
  eq(level(59, 0, null, 0, T, options).level, "normal")
  eq(level(60, 0, null, 0, T, options).level, "warn")
  eq(level(79, 0, null, 0, T, options).level, "warn")
  eq(level(80, 0, null, 0, T, options).level, "critical")
})
test("custom pressure warn percent", () => {
  eq(level(0, 19, null, 0, T, { pressureWarnPercent: 40 }).level, "normal")
  eq(level(0, 20, null, 0, T, { pressureWarnPercent: 40 }).level, "warn")
})
test("critical margin larger than warn margin is clamped to it", () => {
  const s = level(75, 0, null, 0, T, { swapWarnMargin: 15, swapCriticalMargin: 40 })
  eq([s.swapWarnAt, s.swapCriticalAt], [75, 75])
})
test("negative or non-numeric options fall back to defaults", () => {
  const o = L.normalizeOptions({ swapWarnMargin: -1, swapCriticalMargin: "x", criticalHoldPercent: null })
  eq([o.swapWarnMargin, o.swapCriticalMargin, o.criticalHoldPercent], [15, 5, 50])
})

test("thresholds from the oomd config are used", () => {
  const custom = { swapLimitPercent: 60, pressureLimitPercent: 30, pressureDurationSec: 30 }
  eq(level(44, 0, null, 0, custom).level, "normal")
  eq(level(45, 0, null, 0, custom).level, "warn")
  eq(level(55, 0, null, 0, custom).level, "critical")
  eq(level(0, 15, null, 0, custom).level, "warn")
  const s = level(0, 40, null, 0, custom)
  eq(s.holdNeededSec, 15)
})
test("missing or invalid thresholds fall back to 90 / 50 / 20", () => {
  eq(L.normalizeThresholds(null), T)
  eq(L.normalizeThresholds({}), T)
  eq(L.normalizeThresholds({ swapLimitPercent: 0, pressureLimitPercent: -4, pressureDurationSec: "abc" }), T)
  eq(L.normalizeThresholds({ swapLimitPercent: "60" }).swapLimitPercent, 60)
})

test("swap is ignored when the machine has no swap", () => {
  const s = L.evaluate(sample(100, 0, 0, false), T, {}, null)
  eq([s.level, s.swapPercent], ["normal", 0])
})
test("pressure still works without swap", () => eq(L.evaluate(sample(0, 30, 0, false), T, {}, null).level, "warn"))
test("garbage values do not throw and read as zero or clamp", () => {
  const s = L.evaluate({ swapPercent: NaN, swapAvailable: true, pressure: undefined, nowMs: "x" }, T, {}, null)
  eq(s.level, "normal")
  eq(L.evaluate(sample(500, 900, 0), T, {}, null).level, "critical")
})

test("hysteresis: critical swap holds until 3 points below the line", () => {
  let s = level(86, 0)
  eq(s.level, "critical")
  s = level(83, 0, s); eq(s.level, "critical")
  s = level(81.9, 0, s); eq(s.level, "warn")
})
test("hysteresis: warn holds until 3 points below the line", () => {
  let s = level(76, 0)
  s = level(73, 0, s); eq(s.level, "warn")
  s = level(71.9, 0, s); eq(s.level, "normal")
})
test("hysteresis: warn from pressure holds down to 80 percent of the line", () => {
  let s = level(0, 26)
  eq(s.level, "warn")
  s = level(0, 20, s); eq(s.level, "warn")
  s = level(0, 19.9, s); eq(s.level, "normal")
})
test("hysteresis never raises a level by itself", () => {
  eq(level(73, 0, { level: "normal", heldSec: 0, nowMs: 0 }).level, "normal")
})
test("a value hovering at the line does not flap", () => {
  let s = level(0, 0), changes = 0, last = s.level
  for (const swap of [74, 75, 74, 75, 73.5, 75.2, 74.1]) {
    s = level(swap, 0, s)
    if (s.level !== last) { changes++; last = s.level }
  }
  eq(changes, 1)
})

test("binding constraint: swap when it is closest", () => {
  const b = level(80, 5).binding
  eq([b.kind, b.value, b.limit], ["swap", 80, 90])
  eq(b.text, "swap 80% of 90% kill line")
})
test("binding constraint: pressure when it is closest", () => {
  const b = level(10, 30).binding
  eq([b.kind, b.value, b.limit], ["pressure", 30, 50])
  eq(b.text, "pressure 30% of 50% kill line")
})
test("binding constraint: held seconds shown while above the limit", () => {
  let s = level(0, 60, null, 0)
  s = level(0, 60, s, 3000)
  eq(s.binding.text, "pressure 60% of 50% kill line, held 3s of 20s")
})
test("binding constraint: no data without swap and with unusable pressure", () => {
  const b = L.evaluate({ swapAvailable: false, pressure: NaN, nowMs: 0 }, T, {}, null).binding
  // NaN pressure is clamped to 0, so pressure is the constraint at 0 percent.
  eq(b.kind, "pressure")
})
test("binding constraint: small decimals", () => eq(level(0, 7.25).binding.text, "pressure 7.3% of 50% kill line"))

test("notify: first warn notifies", () => {
  const d = L.notifyDecision("normal", "warn", 1000, {}, 300, true)
  eq([d.notify, d.lastNotifiedMs.warn], [true, 1000])
})
test("notify: disabled never notifies", () => eq(L.notifyDecision("normal", "critical", 1000, {}, 300, false).notify, false))
test("notify: normal never notifies", () => eq(L.notifyDecision("warn", "normal", 1000, {}, 300, true).notify, false))
test("notify: staying at the same level does not notify", () => eq(L.notifyDecision("warn", "warn", 999999, {}, 300, true).notify, false))
test("notify: leaving critical for warn does not notify", () => eq(L.notifyDecision("critical", "warn", 999999, {}, 300, true).notify, false))
test("notify: cooldown blocks a repeat warn", () => {
  const first = L.notifyDecision("normal", "warn", 0, {}, 300, true)
  eq(L.notifyDecision("normal", "warn", 299999, first.lastNotifiedMs, 300, true).notify, false)
  eq(L.notifyDecision("normal", "warn", 300000, first.lastNotifiedMs, 300, true).notify, true)
})
test("notify: warn cooldown does not block critical", () => {
  const first = L.notifyDecision("normal", "warn", 0, {}, 300, true)
  const second = L.notifyDecision("warn", "critical", 5000, first.lastNotifiedMs, 300, true)
  eq([second.notify, second.lastNotifiedMs.warn, second.lastNotifiedMs.critical], [true, 0, 5000])
})
test("notify: normal straight to critical notifies", () => eq(L.notifyDecision("normal", "critical", 10, {}, 300, true).notify, true))
test("notify: cooldown 0 always allows", () => {
  const first = L.notifyDecision("normal", "warn", 0, {}, 0, true)
  eq(L.notifyDecision("normal", "warn", 0, first.lastNotifiedMs, 0, true).notify, true)
})
test("notify: does not mutate the input", () => {
  const input = { warn: 5 }
  L.notifyDecision("normal", "warn", 100000, input, 1, true)
  eq(input, { warn: 5 })
})

const apps = [
  { name: "Chromium", ramBytes: 3 * 1024 ** 3, swapBytes: 0, oomdOmit: true },
  { name: "terminal (claude)", ramBytes: 2.5 * 1024 ** 3, swapBytes: 700 * 1024 ** 2, oomdOmit: false },
  { name: "Brave", ramBytes: 1024 ** 3, swapBytes: 0, oomdOmit: false }
]
test("topCandidate skips protected apps", () => eq(L.topCandidate(apps).name, "terminal (claude)"))
test("topCandidate is null when everything is protected or empty", () => {
  eq(L.topCandidate([apps[0]]), null)
  eq(L.topCandidate([]), null)
  eq(L.topCandidate(null), null)
})
test("critical notification names the top app and uses critical urgency", () => {
  const s = level(88, 0)
  const n = L.buildNotification(s, apps)
  eq(n.urgency, "critical")
  assert.ok(n.summary.includes("critical"), n.summary)
  assert.ok(n.body.includes("swap 88% of 90% kill line"), n.body)
  assert.ok(n.body.includes("terminal (claude)"), n.body)
  assert.ok(n.body.includes("2.5 GB RAM + 700 MB swap"), n.body)
})
test("warn notification uses normal urgency", () => {
  const n = L.buildNotification(level(76, 0), apps)
  eq(n.urgency, "normal")
  assert.ok(!n.summary.includes("critical"))
})
test("notification without app data still has a body", () => {
  const n = L.buildNotification(level(88, 0), [])
  eq(n.body, "swap 88% of 90% kill line")
})
test("formatBytes", () => {
  eq(L.formatBytes(50 * 1024 ** 2), "50.0 MB")
  eq(L.formatBytes(512 * 1024 ** 2), "512 MB")
  eq(L.formatBytes(1.5 * 1024 ** 3), "1.5 GB")
  eq(L.formatBytes(-5), "0.0 MB")
})

console.log("levels.test.js: " + passed + " passed, " + failed + " failed")
process.exit(failed === 0 ? 0 : 1)
