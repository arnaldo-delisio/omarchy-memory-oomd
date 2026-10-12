import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Levels.js" as Levels

BarWidget {
  id: root
  moduleName: "io.github.arnaldo-delisio.memory-oomd"

  property var memorySnapshot: ({})
  property string memoryError: ""

  // systemd-oomd thresholds (scripts/oomd-config) and the level judged from them.
  property var oomdThresholds: Levels.normalizeThresholds(null)
  property var levelState: Levels.evaluate({ swapAvailable: false, swapPercent: 0, pressure: 0, nowMs: 0 },
    Levels.normalizeThresholds(null), null, null)
  // Per-app cgroup snapshot (scripts/app-memory), refreshed while it is needed.
  property var appSnapshot: ({})
  property bool appsLoaded: false
  property string appsError: ""
  property var lastNotifiedMs: ({})
  property var pendingNotification: null

  readonly property real configuredWidth: {
    var value = Number(setting("width", Style.bar.iconSlot))
    return isFinite(value) && value > 0
      ? Math.max(Style.bar.iconSlot, Math.min(100, value))
      : Style.bar.iconSlot
  }
  readonly property string memoryScript: localPath(Qt.resolvedUrl("scripts/memory-stats"))
  readonly property string oomdConfigScript: localPath(Qt.resolvedUrl("scripts/oomd-config"))
  readonly property string appScript: localPath(Qt.resolvedUrl("scripts/app-memory"))
  readonly property real totalBytes: Number(memorySnapshot.totalBytes || 0)
  readonly property real usedBytes: Number(memorySnapshot.usedBytes || 0)
  readonly property real usedFraction: totalBytes > 0
    ? Math.max(0, Math.min(1, usedBytes / totalBytes))
    : 0
  readonly property string level: String(levelState.level || "normal")
  readonly property int levelRank: Number(levelState.rank || 0)
  readonly property string listMode: {
    var mode = String(setting("listMode", "apps"))
    return mode === "processes" || mode === "both" ? mode : "apps"
  }
  readonly property bool showsApps: listMode !== "processes"
  readonly property bool notifyEnabled: {
    var value = setting("notify", true)
    return value !== false && value !== "false" && value !== 0
  }
  readonly property real notifyCooldownSec: numberSetting("notifyCooldownSec", 300, 0, 86400)
  // Rows requested from the scan: enough that the notification can still find a
  // killable app when the biggest ones are protected from oomd.
  readonly property int appFetchCount: 16
  readonly property color foregroundColor: bar ? bar.barForeground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color levelColor: levelColorFor(levelRank, foregroundColor, urgentColor)
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function numberSetting(name, fallback, low, high) {
    var value = Number(setting(name, fallback))
    return isFinite(value) ? Math.max(low, Math.min(high, value)) : fallback
  }

  function levelOptions() {
    return {
      swapWarnMargin: numberSetting("swapWarnMargin", 15, 0, 100),
      swapCriticalMargin: numberSetting("swapCriticalMargin", 5, 0, 100),
      pressureWarnPercent: numberSetting("pressureWarnPercent", 50, 1, 100),
      criticalHoldPercent: numberSetting("criticalHoldPercent", 50, 0, 100)
    }
  }

  function mixColor(from, to, amount) {
    return Qt.rgba(
      from.r + (to.r - from.r) * amount,
      from.g + (to.g - from.g) * amount,
      from.b + (to.b - from.b) * amount,
      from.a + (to.a - from.a) * amount)
  }

  // normal keeps the bar's own foreground, critical is the theme's urgent
  // color, warn sits between them.
  function levelColorFor(rank, normal, urgent) {
    if (rank >= 2) return urgent
    if (rank === 1) return mixColor(normal, urgent, 0.55)
    return normal
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function formatBytes(bytes) {
    var value = Number(bytes)
    if (!isFinite(value) || value < 0) value = 0
    if (value < 1024 * 1024 * 1024)
      return (value / (1024 * 1024)).toFixed(value < 100 * 1024 * 1024 ? 1 : 0) + " MB"
    return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  function refresh() {
    if (!memoryProcess.running) memoryProcess.running = true
  }

  function refreshConfig() {
    if (!configProcess.running) configProcess.running = true
  }

  function refreshApps() {
    if (!appProcess.running) appProcess.running = true
  }

  function updateConfig(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      oomdThresholds = Levels.normalizeThresholds(parsed)
    } catch (error) {
      oomdThresholds = Levels.normalizeThresholds(null)
    }
  }

  function updateApps(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (!parsed || !Array.isArray(parsed.apps)) throw new Error("Missing apps")
      appSnapshot = parsed
      appsLoaded = true
      appsError = ""
    } catch (error) {
      if (!appsLoaded) appsError = "Could not read app memory"
    }
    flushNotification()
  }

  // The pressure oomd acts on is the app.slice cgroup's "full" avg10. Without
  // that cgroup (fixture, unusual setup) fall back to the system-wide figure.
  function judgedPressure(sample) {
    return sample.appSlicePressureAvailable === true
      ? Number(sample.appSlicePressureFullAvg10 || 0)
      : Number(sample.pressureFullPercent || 0)
  }

  function applyLevel(sample) {
    var previous = levelState
    var next = Levels.evaluate({
      swapAvailable: Number(sample.swapTotalBytes || 0) > 0,
      swapPercent: Number(sample.swapUsedPercent || 0),
      pressure: judgedPressure(sample),
      nowMs: Number(sample.sampledMs || Date.now())
    }, oomdThresholds, levelOptions(), previous)
    levelState = next

    var decision = Levels.notifyDecision(previous.level, next.level, Date.now(),
      lastNotifiedMs, notifyCooldownSec, notifyEnabled)
    if (decision.notify) {
      lastNotifiedMs = decision.lastNotifiedMs
      pendingNotification = next
      // Name the top app from fresh data; flushNotification runs when it lands.
      refreshApps()
      notifyFallback.restart()
    }
  }

  function flushNotification() {
    if (!pendingNotification) return
    var note = Levels.buildNotification(pendingNotification, appsLoaded ? appSnapshot.apps : [])
    pendingNotification = null
    notifyFallback.stop()
    notifyProcess.command = [
      "notify-send",
      "--app-name=Memory (oomd)",
      "--urgency=" + note.urgency,
      "--icon=" + (note.urgency === "critical" ? "dialog-warning" : "dialog-information"),
      "--hint=string:x-canonical-private-synchronous:memory-oomd",
      note.summary,
      note.body
    ]
    if (!notifyProcess.running) notifyProcess.running = true
  }

  function updateMemory(raw) {
    try {
      var next = JSON.parse(String(raw || "{}"))
      if (!next || Number(next.totalBytes || 0) <= 0)
        throw new Error("Missing memory total")

      var previous = memorySnapshot || ({})
      var elapsedMs = Number(next.sampledMs || 0) - Number(previous.sampledMs || 0)
      var pageSize = Number(next.pageSize || 4096)

      function counterRate(current, old) {
        var delta = Number(current || 0) - Number(old || 0)
        if (elapsedMs <= 0 || delta < 0) return 0
        return delta * pageSize * 1000 / elapsedMs
      }

      next.swapInBytesPerSecond = counterRate(next.swapInPages, previous.swapInPages)
      next.swapOutBytesPerSecond = counterRate(next.swapOutPages, previous.swapOutPages)
      memorySnapshot = next
      memoryError = ""
      applyLevel(next)
    } catch (error) {
      memoryError = "Could not read memory statistics"
    }
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: {
    refreshConfig()
    refresh()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: root.vertical ? -1 : root.configuredWidth
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 0
    verticalPadding: 0
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.totalBytes > 0
      ? "Memory: " + root.formatBytes(root.usedBytes) + " used of " + root.formatBytes(root.totalBytes)
        + (root.levelRank > 0 ? "\n" + root.level.toUpperCase() + ": " + root.levelState.binding.text : "")
      : (root.memoryError !== "" ? root.memoryError : "Reading memory usage…")

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }

    Row {
      id: memoryIndicator
      anchors.centerIn: parent
      height: Style.bar.iconCanvas
      spacing: Style.spaceReal(3)

      Item {
        width: Style.spaceReal(8)
        height: parent.height

        Text {
          anchors.centerIn: parent
          text: "M\nE\nM"
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: 7
          font.bold: true
          lineHeight: 0.72
          lineHeightMode: Text.ProportionalHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering

          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 160 }
          }
        }
      }

      Item {
        id: memoryMeter
        width: Style.spaceReal(7)
        height: parent.height

        Rectangle {
          id: memoryTrack
          anchors.fill: parent
          radius: width / 2
          color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.12)
        }

        Rectangle {
          anchors.left: memoryTrack.left
          anchors.right: memoryTrack.right
          anchors.bottom: memoryTrack.bottom
          height: root.totalBytes > 0
            ? memoryTrack.height * root.usedFraction
            : 0
          radius: Math.min(width / 2, height / 2)
          color: root.levelColor

          Behavior on height {
            NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
          }

          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 160 }
          }
        }
      }
    }
  }

  Process {
    id: memoryProcess
    command: [root.memoryScript]

    onExited: function(exitCode) {
      if (exitCode !== 0 && root.totalBytes <= 0)
        root.memoryError = "Could not read memory statistics"
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateMemory(text)
    }
  }

  Process {
    id: configProcess
    command: [root.oomdConfigScript]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateConfig(text)
    }
  }

  Process {
    id: appProcess
    command: [root.appScript, "--top", String(root.appFetchCount)]

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (!root.appsLoaded) root.appsError = "Could not read app memory"
        root.flushNotification()
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateApps(text)
    }
  }

  Process {
    id: notifyProcess
  }

  // Sample every second while the panel is open or memory is tight. PSI averages
  // only move every two seconds, so a calm bar polls at half the rate.
  Timer {
    interval: root.opened || root.levelRank > 0 ? 1000 : 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // The cgroup scan costs more than the memory sample, so it runs only while
  // the panel shows apps or the level is warn or worse.
  Timer {
    interval: 2000
    running: (root.opened && root.showsApps) || root.levelRank > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshApps()
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: root.refreshConfig()
  }

  // If the scan behind a pending notification never answers, notify without it.
  Timer {
    id: notifyFallback
    interval: 4000
    onTriggered: root.flushNotification()
  }
}
