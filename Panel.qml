import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Levels.js" as Levels

Panel {
  id: root
  moduleName: "io.github.arnaldo-delisio.memory-oomd"
  ipcTarget: "io.github.arnaldo-delisio.memory-oomd"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool processLoading: false
  property bool processHasSnapshot: false
  property string processError: ""
  property var processRows: []

  readonly property var barIdentity: hostWidget || root
  readonly property var snapshot: hostWidget && hostWidget.memorySnapshot
    ? hostWidget.memorySnapshot
    : ({})
  readonly property string memoryError: hostWidget ? String(hostWidget.memoryError || "") : ""
  readonly property var levelState: hostWidget && hostWidget.levelState ? hostWidget.levelState : ({})
  readonly property int levelRank: Number(levelState.rank || 0)
  readonly property string levelName: String(levelState.level || "normal")
  readonly property var appSnapshot: hostWidget && hostWidget.appSnapshot ? hostWidget.appSnapshot : ({})
  readonly property var appRows: appSnapshot.apps && Array.isArray(appSnapshot.apps) ? appSnapshot.apps : []
  readonly property bool appsLoaded: hostWidget ? hostWidget.appsLoaded === true : false
  readonly property string appsError: hostWidget ? String(hostWidget.appsError || "") : ""
  readonly property string listMode: hostWidget ? String(hostWidget.listMode || "apps") : "apps"
  readonly property bool showsApps: listMode !== "processes"
  readonly property bool showsProcesses: listMode !== "apps"
  readonly property int appRosterSize: {
    var value = Number(setting("appCount", 6))
    return isFinite(value) ? Math.max(1, Math.min(12, Math.round(value))) : 6
  }
  readonly property int processRosterSize: {
    var value = Number(setting("processCount", 5))
    return isFinite(value) ? Math.max(1, Math.min(10, Math.round(value))) : 5
  }
  readonly property string processScript: localPath(Qt.resolvedUrl("scripts/process-memory"))

  // Styling follows the built-in Agents popup: one foreground color on a track,
  // dim for secondary text, and a level color only where oomd is getting close.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The theme's orange comes from the bar widget (it reads colors.toml).
  readonly property color warnColor: hostWidget && hostWidget.warnColor !== undefined
    ? hostWidget.warnColor
    : urgent

  readonly property real totalBytes: Number(snapshot.totalBytes || 0)
  readonly property real usedBytes: Number(snapshot.usedBytes || 0)
  readonly property real swapTotalBytes: Number(snapshot.swapTotalBytes || 0)
  readonly property real usedPercent: totalBytes > 0
    ? Math.max(0, Math.min(100, usedBytes * 100 / totalBytes))
    : 0
  readonly property real swapPercent: swapTotalBytes > 0
    ? Math.max(0, Math.min(100, Number(snapshot.swapUsedPercent || 0)))
    : 0
  // The pressure oomd judges (app.slice, else system-wide), the same figure the
  // level is computed from.
  readonly property real pressurePercent: Math.max(0, Math.min(100, Number(levelState.pressure || 0)))
  readonly property var thresholds: levelState.thresholds ? levelState.thresholds : Levels.normalizeThresholds(null)

  // Level of each constraint on its own, so a bar or ring turns orange or red
  // only when it is the one oomd is closing in on. The memory ring follows swap,
  // the memory-side constraint oomd acts on (RAM itself has no level rule). Never above the overall level.
  readonly property int swapRank: {
    if (levelRank === 0 || swapTotalBytes <= 0) return 0
    var raw = swapPercent >= Number(levelState.swapCriticalAt) ? 2
      : (swapPercent >= Number(levelState.swapWarnAt) ? 1 : 0)
    return Math.min(raw, levelRank)
  }
  readonly property int pressureRank: {
    if (levelRank === 0) return 0
    var raw = pressurePercent >= thresholds.pressureLimitPercent
        && Number(levelState.heldSec || 0) >= Number(levelState.holdNeededSec || 0) ? 2
      : (pressurePercent >= Number(levelState.pressureWarnAt) ? 1 : 0)
    return Math.min(raw, levelRank)
  }
  readonly property color levelColor: rankColor(levelRank)

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function rankColor(rank) {
    if (rank >= 2) return urgent
    if (rank === 1) return warnColor
    return foreground
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function open() {
    processError = ""
    processLoading = !processHasSnapshot
    root.controller.show()
    if (hostWidget) {
      hostWidget.refreshConfig()
      if (showsApps) hostWidget.refreshApps()
    }
    Qt.callLater(root.refreshProcesses)
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refreshProcesses() {
    if (showsProcesses && !processMemory.running) processMemory.running = true
  }

  function refreshAll() {
    refreshProcesses()
    if (hostWidget && showsApps) hostWidget.refreshApps()
  }

  // The tighter of an app's RAM cap and swap cap, in percent; 0 if uncapped.
  function capFraction(app) {
    return Math.max(Number(app.capPercent || 0), Number(app.swapCapPercent || 0))
  }

  function hasCap(app) {
    return (app.capPercent !== null && app.capPercent !== undefined)
      || (app.swapCapPercent !== null && app.swapCapPercent !== undefined)
  }

  function updateProcesses(raw) {
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      processRows = Array.isArray(parsed) ? parsed : []
      processError = ""
      processHasSnapshot = true
      processLoading = false
    } catch (error) {
      if (!processHasSnapshot) {
        processRows = []
        processError = "Could not read process memory"
        processHasSnapshot = true
      }
      processLoading = false
    }
  }

  function formatBytes(bytes) {
    var value = Number(bytes)
    if (!isFinite(value) || value < 0) value = 0
    if (value < 1024) return Math.round(value) + " B"
    if (value < 1024 * 1024)
      return (value / 1024).toFixed(value < 10 * 1024 ? 1 : 0) + " KB"
    if (value < 1024 * 1024 * 1024)
      return (value / (1024 * 1024)).toFixed(value < 100 * 1024 * 1024 ? 1 : 0) + " MB"
    return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  // "10.6 / 13.3 GB": two sizes sharing one unit.
  function formatUsedOf(used, total) {
    var gib = 1024 * 1024 * 1024
    if (Number(total) >= gib)
      return (Number(used) / gib).toFixed(1) + " / " + (Number(total) / gib).toFixed(1) + " GB"
    return formatBytes(used) + " / " + formatBytes(total)
  }

  // "4.0 + 4.2 GB": RAM plus swap in one unit; just the RAM when there is no swap.
  function formatRamSwap(ram, swap) {
    var mib = 1024 * 1024
    var gib = 1024 * mib
    var r = Math.max(0, Number(ram) || 0)
    var w = Math.max(0, Number(swap) || 0)
    if (Math.max(r, w) >= 100 * mib) {
      var gb = (r / gib).toFixed(1)
      return (w > 0 ? gb + " + " + (w / gib).toFixed(1) : gb) + " GB"
    }
    var mb = Math.round(r / mib).toString()
    return (w > 0 ? mb + " + " + Math.round(w / mib) : mb) + " MB"
  }

  function normalizedAppName(value) {
    return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  }

  function desktopEntryForProcess(processName) {
    var needle = normalizedAppName(processName)
    if (needle.length < 2) return null

    var entries = DesktopEntries.applications.values || []
    var bestEntry = null
    var bestScore = 0

    for (var index = 0; index < entries.length; index++) {
      var entry = entries[index]
      if (!entry) continue

      var id = normalizedAppName(entry.id).replace(/desktop$/, "")
      var name = normalizedAppName(entry.name)
      var icon = normalizedAppName(entry.icon)
      var score = 0

      if (needle === id || needle === name || needle === icon) score = 100
      else if (needle.length >= 4 && (id.indexOf(needle) >= 0 || name.indexOf(needle) >= 0 || icon.indexOf(needle) >= 0)) score = 80
      else if (id.length >= 4 && needle.indexOf(id) >= 0) score = 70

      if (score > bestScore) {
        bestScore = score
        bestEntry = entry
      }
    }

    return bestEntry
  }

  function processDisplayName(processName) {
    var entry = desktopEntryForProcess(processName)
    return entry && entry.name ? String(entry.name) : String(processName || "Unknown")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshAll()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Rings: pressure and memory ----------
          Row {
            width: parent.width
            height: pressureRing.height

            Item {
              width: parent.width / 2
              height: parent.height

              Ring {
                id: pressureRing
                anchors.horizontalCenter: parent.horizontalCenter
                value: root.pressurePercent / 100
                valueText: root.totalBytes > 0 ? Math.round(root.pressurePercent) + "%" : "--"
                caption: "PRESSURE"
                ringColor: root.rankColor(root.pressureRank)
              }
            }

            Item {
              width: parent.width / 2
              height: parent.height

              Ring {
                anchors.horizontalCenter: parent.horizontalCenter
                value: root.usedPercent / 100
                valueText: root.totalBytes > 0 ? Math.round(root.usedPercent) + "%" : "--"
                caption: "MEMORY"
                ringColor: root.rankColor(root.swapRank)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.totalBytes > 0 ? root.levelName.toUpperCase()
              : (root.memoryError !== "" ? root.memoryError : "Reading memory…")
            color: root.levelRank > 0 ? root.levelColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- RAM, swap and pressure against the oomd kill lines ----------
          Column {
            id: limitsSection
            width: parent.width
            spacing: Style.space(10)

            LimitRow {
              width: parent.width
              label: "RAM"
              valueText: root.totalBytes > 0
                ? root.formatUsedOf(root.usedBytes, root.totalBytes) + "  " + Math.round(root.usedPercent) + "%"
                : "--"
              ratio: root.usedPercent / 100
              rank: 0
            }

            LimitRow {
              width: parent.width
              label: "Swap"
              valueText: root.swapTotalBytes > 0
                ? Math.round(root.swapPercent) + "% · kill at " + Math.round(root.thresholds.swapLimitPercent) + "%"
                : "not configured"
              // The bar ends at the kill line, so a full bar means oomd acts.
              ratio: root.swapTotalBytes > 0 ? root.swapPercent / root.thresholds.swapLimitPercent : -1
              rank: root.swapRank
            }

            LimitRow {
              width: parent.width
              label: "Pressure"
              valueText: Math.round(root.pressurePercent) + "% · kill at "
                + Math.round(root.thresholds.pressureLimitPercent) + "% for "
                + Math.round(root.thresholds.pressureDurationSec) + "s"
              ratio: root.pressurePercent / root.thresholds.pressureLimitPercent
              rank: root.pressureRank
            }
          }

          // ---------- Apps ----------
          PanelSeparator {
            visible: root.showsApps
            foreground: root.foreground
          }

          Column {
            id: appsSection
            visible: root.showsApps
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "APPS OOMD COULD KILL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.appRows.length === 0
              width: parent.width
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
              text: root.appsError !== ""
                ? root.appsError
                : (root.appsLoaded ? "No app cgroups found" : "Reading app memory…")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.showsApps ? root.appRows.slice(0, root.appRosterSize) : []

              ListRow {
                required property var modelData
                width: appsSection.width
                name: String(modelData.name)
                valueText: root.formatRamSwap(modelData.ramBytes, modelData.swapBytes)
                detailText: root.hasCap(modelData) ? Math.round(root.capFraction(modelData)) + "% of cap" : ""
                detailAlarming: root.capFraction(modelData) >= 90
                // Apps protected from oomd are shown dimmed.
                opacity: modelData.oomdOmit ? 0.5 : 1
              }
            }
          }

          // ---------- Processes ----------
          PanelSeparator {
            visible: root.showsProcesses
            foreground: root.foreground
          }

          Column {
            id: processSection
            visible: root.showsProcesses
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "TOP PROCESSES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.processRows.length === 0
              width: parent.width
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
              text: root.processError !== ""
                ? root.processError
                : (root.processLoading ? "Reading process memory…" : "No process memory data")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.showsProcesses ? root.processRows.slice(0, root.processRosterSize) : []

              ListRow {
                required property var modelData
                width: processSection.width
                name: root.processDisplayName(modelData.name)
                valueText: root.formatBytes(modelData.rssBytes)
                detailText: (Number(modelData.processCount || 0) > 1 ? modelData.processCount + " processes · " : "")
                  + Number(modelData.percent || 0).toFixed(1) + "% of RAM"
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.showsApps
            width: parent.width
            topPadding: Style.space(2)
            text: "dimmed apps are protected from oomd"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A ring: a track circle with one arc of the value on top and the figure and
  // its name in the middle.
  component Ring: Item {
    id: ring
    property real value: 0
    property string valueText: ""
    property string caption: ""
    property color ringColor: root.foreground

    width: Style.space(104)
    height: width

    Canvas {
      id: ringCanvas
      anchors.fill: parent
      property real progress: root.clamp(ring.value, 0, 1)
      property color trackColor: root.track
      property color arcColor: ring.ringColor

      onProgressChanged: requestPaint()
      onTrackColorChanged: requestPaint()
      onArcColorChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var context = getContext("2d")
        context.clearRect(0, 0, width, height)
        var ringWidth = Style.spaceReal(6)
        var radius = Math.max(0, Math.min(width, height) / 2 - ringWidth / 2)
        var start = -Math.PI / 2
        context.lineWidth = ringWidth
        context.lineCap = "butt"

        context.beginPath()
        context.strokeStyle = trackColor
        context.arc(width / 2, height / 2, radius, start, start + Math.PI * 2)
        context.stroke()

        if (progress > 0.004) {
          context.beginPath()
          context.strokeStyle = arcColor
          context.arc(width / 2, height / 2, radius, start, start + Math.PI * 2 * progress)
          context.stroke()
        }
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: ring.valueText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: ring.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // The Agents popup's thin usage bar: a track with the value on it.
  component Meter: Item {
    id: meter
    property real value: -1
    property color fillColor: root.foreground
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.fillColor

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // A label and figure over a thin bar. `rank` colors the bar when this
  // constraint is the one in warn (1) or critical (2).
  component LimitRow: Column {
    id: limitRow
    property string label: ""
    property string valueText: ""
    property real ratio: -1
    property int rank: 0

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        text: limitRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.valueText
        color: limitRow.rank > 0 ? root.rankColor(limitRow.rank) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideLeft
        anchors.left: limitLabel.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: parent.right
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      visible: limitRow.ratio >= 0
      width: parent.width
      value: limitRow.ratio
      fillColor: root.rankColor(limitRow.rank)
    }
  }

  // Plain list row: name on the left, figure on the right, and an optional dim
  // second line under the name.
  component ListRow: Column {
    id: listRow
    property string name: ""
    property string valueText: ""
    property string detailText: ""
    property bool detailAlarming: false

    spacing: Style.spacing.xxs

    Item {
      width: parent.width
      implicitHeight: Math.max(rowName.implicitHeight, rowValue.implicitHeight)

      Text {
        id: rowName
        textFormat: Text.PlainText
        text: listRow.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: rowValue.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: rowValue
        textFormat: Text.PlainText
        text: listRow.valueText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: listRow.detailText !== ""
      width: parent.width
      text: listRow.detailText
      color: listRow.detailAlarming ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Process {
    id: processMemory
    command: [root.processScript]

    onRunningChanged: {
      if (running) root.processLoading = !root.processHasSnapshot
      else root.processLoading = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.processHasSnapshot) {
        root.processRows = []
        root.processError = "Could not read process memory"
        root.processHasSnapshot = true
      }
      root.processLoading = false
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateProcesses(text)
    }
  }

  Timer {
    interval: 2000
    running: root.opened && root.showsProcesses
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshProcesses()
  }
}
