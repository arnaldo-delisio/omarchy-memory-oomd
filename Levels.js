.pragma library

// Memory level logic for the systemd-oomd aware widget. Everything here is a
// pure function of its arguments so it can run under node (tests/levels.test.js)
// as well as inside Quickshell. The QML side keeps the state between samples.
//
// A level is "normal", "warn" or "critical", judged by how close the machine is
// to the two things that make systemd-oomd kill an app:
//   - system swap used above SwapUsedLimit, or
//   - the monitored app.slice cgroup's memory pressure (PSI "full", avg10)
//     staying at or above the pressure limit for the configured duration.

var LEVELS = ["normal", "warn", "critical"]

var DEFAULT_OPTIONS = {
  // Percentage points below the swap kill line where warn / critical start.
  swapWarnMargin: 15,
  swapCriticalMargin: 5,
  // Warn starts at this percent of the pressure limit.
  pressureWarnPercent: 50,
  // Critical needs pressure at or above the limit for this percent of the duration.
  criticalHoldPercent: 50,
  // A level is left only once the value falls this far below where it began:
  // swap in percentage points, pressure as a percent of the starting value.
  swapHysteresis: 3,
  pressureHysteresis: 20,
  // A gap between samples longer than this (suspend, stalled shell) is counted
  // as this many seconds toward the held-above counter.
  maxSampleGapSec: 5
}

var DEFAULT_THRESHOLDS = { swapLimitPercent: 90, pressureLimitPercent: 50, pressureDurationSec: 20 }

function finite(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

function rank(level) {
  var index = LEVELS.indexOf(level)
  return index < 0 ? 0 : index
}

function normalizeOptions(raw) {
  var source = raw || {}
  var options = {}
  for (var key in DEFAULT_OPTIONS) {
    var value = finite(source[key], DEFAULT_OPTIONS[key])
    options[key] = value < 0 ? DEFAULT_OPTIONS[key] : value
  }
  options.pressureWarnPercent = clamp(options.pressureWarnPercent, 1, 100)
  options.criticalHoldPercent = clamp(options.criticalHoldPercent, 0, 100)
  options.pressureHysteresis = clamp(options.pressureHysteresis, 0, 90)
  // Critical never starts before warn.
  if (options.swapCriticalMargin > options.swapWarnMargin)
    options.swapCriticalMargin = options.swapWarnMargin
  return options
}

function normalizeThresholds(raw) {
  var source = raw || {}
  var swap = finite(source.swapLimitPercent, DEFAULT_THRESHOLDS.swapLimitPercent)
  var pressure = finite(source.pressureLimitPercent, DEFAULT_THRESHOLDS.pressureLimitPercent)
  var duration = finite(source.pressureDurationSec, DEFAULT_THRESHOLDS.pressureDurationSec)
  return {
    swapLimitPercent: swap > 0 ? swap : DEFAULT_THRESHOLDS.swapLimitPercent,
    pressureLimitPercent: pressure > 0 ? pressure : DEFAULT_THRESHOLDS.pressureLimitPercent,
    pressureDurationSec: duration > 0 ? duration : DEFAULT_THRESHOLDS.pressureDurationSec
  }
}

function formatPercent(value) {
  var n = finite(value, 0)
  if (n >= 10 || n === Math.round(n)) return String(Math.round(n))
  return n.toFixed(1)
}

function formatSeconds(value) {
  return String(Math.round(finite(value, 0)))
}

// The trigger closest to firing: the larger of swap/limit and pressure/limit.
function bindingConstraint(sample, thresholds, heldSec) {
  var swapFraction = sample.swapAvailable ? sample.swapPercent / thresholds.swapLimitPercent : -1
  var pressureFraction = sample.pressure / thresholds.pressureLimitPercent
  if (swapFraction < 0 && !(pressureFraction >= 0)) {
    return { kind: "none", fraction: 0, value: 0, limit: 0, text: "no data" }
  }
  if (swapFraction > pressureFraction) {
    return {
      kind: "swap",
      fraction: swapFraction,
      value: sample.swapPercent,
      limit: thresholds.swapLimitPercent,
      text: "swap " + formatPercent(sample.swapPercent) + "% of "
        + formatPercent(thresholds.swapLimitPercent) + "% kill line"
    }
  }
  var text = "pressure " + formatPercent(sample.pressure) + "% of "
    + formatPercent(thresholds.pressureLimitPercent) + "% kill line"
  if (sample.pressure >= thresholds.pressureLimitPercent && heldSec > 0)
    text += ", held " + formatSeconds(heldSec) + "s of " + formatSeconds(thresholds.pressureDurationSec) + "s"
  return {
    kind: "pressure",
    fraction: pressureFraction,
    value: sample.pressure,
    limit: thresholds.pressureLimitPercent,
    text: text
  }
}

// evaluate(sample, thresholds, options, previous) -> state
//   sample:     { swapPercent, swapAvailable, pressure, nowMs }
//               pressure is the app.slice PSI "full" avg10, in percent
//   thresholds: { swapLimitPercent, pressureLimitPercent, pressureDurationSec }
//   previous:   the state returned by the last call (or null): its level gives
//               hysteresis, its heldSec and nowMs feed the held-above counter
//   state:      { level, heldSec, nowMs, binding, swapPercent, pressure, ... }
function evaluate(sample, thresholdsRaw, optionsRaw, previous) {
  var thresholds = normalizeThresholds(thresholdsRaw)
  var options = normalizeOptions(optionsRaw)
  var swapAvailable = !!sample.swapAvailable
  var swapPercent = swapAvailable ? clamp(finite(sample.swapPercent, 0), 0, 100) : 0
  var pressure = clamp(finite(sample.pressure, 0), 0, 100)
  var nowMs = finite(sample.nowMs, 0)
  var prevLevel = previous && previous.level ? previous.level : "normal"
  var prevRank = rank(prevLevel)

  var heldSec = 0
  var aboveLimit = pressure >= thresholds.pressureLimitPercent
  if (aboveLimit) {
    var previousHeld = previous ? finite(previous.heldSec, 0) : 0
    var gapSec = previous ? (nowMs - finite(previous.nowMs, nowMs)) / 1000 : 0
    heldSec = previousHeld + clamp(gapSec, 0, options.maxSampleGapSec)
  }

  var swapWarnAt = Math.max(0, thresholds.swapLimitPercent - options.swapWarnMargin)
  var swapCriticalAt = Math.max(swapWarnAt, thresholds.swapLimitPercent - options.swapCriticalMargin)
  var pressureWarnAt = thresholds.pressureLimitPercent * options.pressureWarnPercent / 100
  var holdNeededSec = thresholds.pressureDurationSec * options.criticalHoldPercent / 100
  var pressureKeep = 1 - options.pressureHysteresis / 100

  var criticalEnter = (swapAvailable && swapPercent >= swapCriticalAt)
    || (aboveLimit && heldSec >= holdNeededSec)
  var criticalStay = prevRank >= 2
    && ((swapAvailable && swapPercent >= swapCriticalAt - options.swapHysteresis)
      || pressure >= thresholds.pressureLimitPercent * pressureKeep)
  var warnEnter = (swapAvailable && swapPercent >= swapWarnAt) || pressure >= pressureWarnAt
  var warnStay = prevRank >= 1
    && ((swapAvailable && swapPercent >= swapWarnAt - options.swapHysteresis)
      || pressure >= pressureWarnAt * pressureKeep)

  var level = "normal"
  if (criticalEnter || criticalStay) level = "critical"
  else if (warnEnter || warnStay) level = "warn"

  var swapSample = { swapPercent: swapPercent, swapAvailable: swapAvailable, pressure: pressure }
  return {
    level: level,
    rank: rank(level),
    heldSec: heldSec,
    nowMs: nowMs,
    swapPercent: swapPercent,
    swapAvailable: swapAvailable,
    pressure: pressure,
    thresholds: thresholds,
    swapWarnAt: swapWarnAt,
    swapCriticalAt: swapCriticalAt,
    pressureWarnAt: pressureWarnAt,
    holdNeededSec: holdNeededSec,
    binding: bindingConstraint(swapSample, thresholds, heldSec)
  }
}

// Decide whether a level change should raise a notification. Only escalations
// notify (normal to warn, warn to critical, normal to critical), each level has
// its own cooldown, and the caller keeps the returned lastNotifiedMs.
//   lastNotifiedMs: { warn: ms, critical: ms } (missing key means never)
function notifyDecision(previousLevel, level, nowMs, lastNotifiedMs, cooldownSec, enabled) {
  var last = lastNotifiedMs || {}
  var result = { notify: false, level: level, lastNotifiedMs: { warn: last.warn, critical: last.critical } }
  if (!enabled) return result
  if (level !== "warn" && level !== "critical") return result
  if (rank(level) <= rank(previousLevel)) return result
  var cooldownMs = Math.max(0, finite(cooldownSec, 300)) * 1000
  var sinceMs = last[level] === undefined || last[level] === null ? Infinity : nowMs - last[level]
  if (sinceMs < cooldownMs) return result
  result.notify = true
  result.lastNotifiedMs[level] = nowMs
  return result
}

function formatBytes(bytes) {
  var value = finite(bytes, 0)
  if (value < 0) value = 0
  if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(value < 100 * 1024 * 1024 ? 1 : 0) + " MB"
  return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
}

// The app oomd could kill that holds the most memory: apps marked
// user.oomd_omit are skipped, the list is expected sorted largest first.
function topCandidate(apps) {
  var list = apps || []
  for (var i = 0; i < list.length; i++)
    if (!list[i].oomdOmit) return list[i]
  return null
}

// buildNotification(state, apps) -> { summary, body, urgency }
function buildNotification(state, apps) {
  var critical = state.level === "critical"
  var body = state.binding.text
  var top = topCandidate(apps)
  if (top) {
    body += "\nLargest app oomd could kill: " + top.name + ", "
      + formatBytes(top.ramBytes) + " RAM"
      + (top.swapBytes > 0 ? " + " + formatBytes(top.swapBytes) + " swap" : "")
  }
  return {
    summary: critical ? "Memory critical: oomd may kill an app" : "Memory is getting tight",
    body: body,
    urgency: critical ? "critical" : "normal"
  }
}
