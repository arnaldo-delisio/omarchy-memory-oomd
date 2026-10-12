import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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
  readonly property string constraintText: levelState.binding ? String(levelState.binding.text || "") : ""
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
  readonly property var worstPressure: appSnapshot.maxPressure ? appSnapshot.maxPressure : null
  readonly property int processRosterSize: {
    var value = Number(setting("processCount", 5))
    return isFinite(value) ? Math.max(1, Math.min(10, Math.round(value))) : 5
  }
  readonly property string processScript: localPath(Qt.resolvedUrl("scripts/process-memory"))

  readonly property real totalBytes: Number(snapshot.totalBytes || 0)
  readonly property real usedBytes: Number(snapshot.usedBytes || 0)
  readonly property real appBytes: Number(snapshot.appBytes || 0)
  readonly property real kernelBytes: Number(snapshot.kernelBytes || 0)
  readonly property real cacheBytes: Number(snapshot.cacheBytes || 0)
  readonly property real freeBytes: Number(snapshot.freeBytes || 0)
  readonly property real swapTotalBytes: Number(snapshot.swapTotalBytes || 0)
  readonly property real swapUsedBytes: Number(snapshot.swapUsedBytes || 0)
  readonly property real swapInBytesPerSecond: Number(snapshot.swapInBytesPerSecond || 0)
  readonly property real swapOutBytesPerSecond: Number(snapshot.swapOutBytesPerSecond || 0)
  readonly property real pressurePercent: Math.max(0, Math.min(100, Number(snapshot.pressurePercent || 0)))
  readonly property real usedPercent: totalBytes > 0
    ? Math.max(0, Math.min(100, usedBytes * 100 / totalBytes))
    : 0

  readonly property color appColor: "#168cfa"
  readonly property color kernelColor: "#f05a9d"
  readonly property color cacheColor: "#ffc11a"
  readonly property color freeColor: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.22)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(barForeground, 1.5)
  // The pressure ring keeps its accent color while memory is fine, then follows
  // the level: urgent when critical, halfway there when warn.
  readonly property color pressureColor: levelRank >= 2
    ? urgentColor
    : (levelRank === 1 ? mixColor(Color.accent, urgentColor, 0.55) : Color.accent)
  readonly property color levelAccent: levelRank >= 2
    ? urgentColor
    : (levelRank === 1 ? mixColor(barForeground, urgentColor, 0.55) : barForeground)

  readonly property var memorySegments: [
    { value: appBytes, color: appColor },
    { value: kernelBytes, color: kernelColor },
    { value: cacheBytes, color: cacheColor },
    { value: freeBytes, color: freeColor }
  ]
  readonly property var breakdownRows: [
    { label: "Applications", value: appBytes, color: appColor },
    { label: "Kernel", value: kernelBytes, color: kernelColor },
    { label: "Cache", value: cacheBytes, color: cacheColor },
    { label: "Free", value: freeBytes, color: freeColor }
  ]

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function mixColor(from, to, amount) {
    return Qt.rgba(
      from.r + (to.r - from.r) * amount,
      from.g + (to.g - from.g) * amount,
      from.b + (to.b - from.b) * amount,
      from.a + (to.a - from.a) * amount)
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

  function appIconSource(name) {
    if (String(name || "").indexOf("terminal") === 0) {
      var terminalIcon = Quickshell.iconPath("utilities-terminal", true)
      if (terminalIcon) return terminalIcon
    }
    return processIconSource(name)
  }

  // "63% cap" for the tighter of the RAM cap and the swap cap, "" if uncapped.
  // Kept short so the app name keeps the row's width.
  function capLabel(app) {
    var ram = app.capPercent === null || app.capPercent === undefined ? -1 : Number(app.capPercent)
    var swap = app.swapCapPercent === null || app.swapCapPercent === undefined ? -1 : Number(app.swapCapPercent)
    if (ram < 0 && swap < 0) return ""
    return Math.round(Math.max(ram, swap)) + "% cap"
  }

  function capFraction(app) {
    return Math.max(Number(app.capPercent || 0), Number(app.swapCapPercent || 0))
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

  function formatRate(bytesPerSecond) {
    return formatBytes(bytesPerSecond) + "/s"
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

  function processIconSource(processName) {
    var entry = desktopEntryForProcess(processName)
    var appLibrary = root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
    if (entry && appLibrary && typeof appLibrary.iconSource === "function")
      return appLibrary.iconSource(entry.icon)

    if (entry && entry.icon) {
      var entryIcon = Quickshell.iconPath(String(entry.icon), true)
      if (entryIcon) return entryIcon
    }

    var processIcon = Quickshell.iconPath(String(processName || ""), true)
    if (processIcon) return processIcon
    return Quickshell.iconPath("application-x-executable", true)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshAll()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(8)

        Row {
          width: parent.width
          height: Style.space(142)

          Item {
            width: parent.width / 2
            height: parent.height

            Canvas {
              id: pressureRing
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              width: Style.space(104)
              height: width
              property real progress: root.pressurePercent / 100
              property color trackColor: root.freeColor
              property color ringColor: root.pressureColor

              onProgressChanged: requestPaint()
              onTrackColorChanged: requestPaint()
              onRingColorChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var context = getContext("2d")
                context.clearRect(0, 0, width, height)
                var ringWidth = Style.spaceReal(8)
                var radius = Math.max(0, Math.min(width, height) / 2 - ringWidth / 2)
                var start = -Math.PI / 2
                context.lineWidth = ringWidth
                context.lineCap = "butt"

                context.beginPath()
                context.strokeStyle = trackColor
                context.arc(width / 2, height / 2, radius, start, start + Math.PI * 2)
                context.stroke()

                if (progress > 0) {
                  context.beginPath()
                  context.strokeStyle = ringColor
                  context.arc(width / 2, height / 2, radius, start, start + Math.PI * 2 * Math.min(1, progress))
                  context.stroke()
                }
              }
            }

            Text {
              anchors.horizontalCenter: pressureRing.horizontalCenter
              anchors.verticalCenter: pressureRing.verticalCenter
              anchors.verticalCenterOffset: -Style.space(4)
              text: root.totalBytes > 0 ? Math.round(root.pressurePercent) + "%" : "--"
              color: root.levelAccent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.space(25)
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              anchors.horizontalCenter: pressureRing.horizontalCenter
              anchors.verticalCenter: pressureRing.verticalCenter
              anchors.verticalCenterOffset: Style.space(20)
              text: "PRESSURE"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              text: "PSI · 10 second average"
              color: Qt.darker(root.barForeground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width / 2
            height: parent.height

            Canvas {
              id: memoryRing
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              width: Style.space(104)
              height: width
              property real total: root.totalBytes
              property var segments: root.memorySegments
              property color trackColor: root.freeColor

              onTotalChanged: requestPaint()
              onSegmentsChanged: requestPaint()
              onTrackColorChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var context = getContext("2d")
                context.clearRect(0, 0, width, height)
                var ringWidth = Style.spaceReal(8)
                var radius = Math.max(0, Math.min(width, height) / 2 - ringWidth / 2)
                var start = -Math.PI / 2
                var fullCircle = Math.PI * 2
                var gap = 0.02
                context.lineWidth = ringWidth
                context.lineCap = "butt"

                context.beginPath()
                context.strokeStyle = trackColor
                context.arc(width / 2, height / 2, radius, start, start + fullCircle)
                context.stroke()

                if (total <= 0) return
                for (var index = 0; index < segments.length; index++) {
                  var segment = segments[index]
                  var sweep = Math.max(0, Number(segment.value || 0)) / total * fullCircle
                  if (sweep > gap) {
                    context.beginPath()
                    context.strokeStyle = segment.color
                    context.arc(width / 2, height / 2, radius, start + gap / 2, start + sweep - gap / 2)
                    context.stroke()
                  }
                  start += sweep
                }
              }
            }

            Text {
              anchors.horizontalCenter: memoryRing.horizontalCenter
              anchors.verticalCenter: memoryRing.verticalCenter
              anchors.verticalCenterOffset: -Style.space(4)
              text: root.totalBytes > 0 ? Math.round(root.usedPercent) + "%" : "--"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.space(25)
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              anchors.horizontalCenter: memoryRing.horizontalCenter
              anchors.verticalCenter: memoryRing.verticalCenter
              anchors.verticalCenterOffset: Style.space(20)
              text: "MEMORY"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              text: root.totalBytes > 0
                ? root.formatBytes(root.usedBytes) + " of " + root.formatBytes(root.totalBytes)
                : (root.memoryError !== "" ? root.memoryError : "Reading memory…")
              color: Qt.darker(root.barForeground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.barForeground
          opacity: 0.12
        }

        Item {
          id: constraintRow
          width: parent.width
          height: Style.space(22)

          Rectangle {
            id: levelDot
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(9)
            height: width
            radius: width / 2
            color: root.levelAccent
          }

          Text {
            anchors.left: levelDot.right
            anchors.leftMargin: Style.space(7)
            anchors.right: levelLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.constraintText !== "" ? root.constraintText : "Waiting for oomd thresholds…"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            id: levelLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.levelName.toUpperCase()
            color: root.levelAccent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          width: parent.width
          text: {
            var t = levelState.thresholds
            if (!t) return ""
            var line = "oomd kills at swap > " + Math.round(t.swapLimitPercent) + "% or app pressure >= "
              + Math.round(t.pressureLimitPercent) + "% for " + Math.round(t.pressureDurationSec) + "s"
            if (root.worstPressure && Number(root.worstPressure.fullAvg10) >= 1)
              line += "\nMost stalled app: " + root.worstPressure.name + " "
                + Number(root.worstPressure.fullAvg10).toFixed(1) + "%"
            return line
          }
          visible: text !== ""
          color: root.dimColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.barForeground
          opacity: 0.12
        }

        Repeater {
          model: root.breakdownRows

          delegate: Item {
            required property var modelData
            width: contentColumn.width
            height: Style.space(22)

            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(9)
              height: width
              radius: width / 2
              color: modelData.color
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.formatBytes(modelData.value)
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignRight
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.barForeground
          opacity: 0.12
        }

        Item {
          visible: root.showsApps
          width: parent.width
          height: visible ? Style.space(22) : 0

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "APPS (OOMD CANDIDATES)"
            color: root.appColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          visible: root.showsApps && root.appRows.length === 0
          width: parent.width
          height: visible ? Style.space(46) : 0
          text: root.appsError !== ""
            ? root.appsError
            : (root.appsLoaded ? "No app cgroups found" : "Reading app memory…")
          color: Qt.darker(root.barForeground, 1.35)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Repeater {
          model: root.showsApps ? root.appRows.slice(0, root.appRosterSize) : []

          delegate: Item {
            required property var modelData
            width: contentColumn.width
            height: Style.space(27)
            opacity: modelData.oomdOmit ? 0.55 : 1

            Item {
              id: appIconSlot
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: parent.height

              Image {
                id: appIcon
                anchors.centerIn: parent
                width: Style.space(18)
                height: width
                fillMode: Image.PreserveAspectFit
                source: root.appIconSource(modelData.name)
                asynchronous: true
              }

              Text {
                anchors.centerIn: parent
                visible: appIcon.status !== Image.Ready
                text: "󰣆"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Text {
              anchors.left: appIconSlot.right
              anchors.leftMargin: Style.space(7)
              anchors.right: appCapLabel.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.name)
                + (Number(modelData.unitCount || 0) > 1 ? "  ·  " + modelData.unitCount : "")
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: appCapLabel
              anchors.right: appSwapLabel.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(52)
              text: root.capLabel(modelData)
              color: root.capFraction(modelData) >= 80 ? root.urgentColor : root.dimColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }

            Text {
              id: appSwapLabel
              anchors.right: appRamLabel.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(70)
              text: Number(modelData.swapBytes || 0) > 0 ? "+" + root.formatBytes(modelData.swapBytes) : ""
              color: Qt.darker(root.barForeground, 1.25)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }

            Text {
              id: appRamLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(66)
              text: root.formatBytes(modelData.ramBytes)
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignRight
            }
          }
        }

        Text {
          visible: root.showsApps && root.appRows.length > 0
          width: parent.width
          height: visible ? implicitHeight : 0
          text: "RAM, +swap, fuller of RAM or swap cap · dimmed = protected"
          color: root.dimColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }

        Rectangle {
          visible: root.showsApps && root.showsProcesses
          width: parent.width
          height: visible ? Math.max(1, Style.space(1)) : 0
          color: root.barForeground
          opacity: 0.12
        }

        Item {
          visible: root.showsProcesses
          width: parent.width
          height: visible ? Style.space(22) : 0

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "TOP PROCESSES"
            color: root.appColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(7)
            height: width
            radius: width / 2
            color: root.appColor
            opacity: root.processLoading ? 0.45 : 0.9

            SequentialAnimation on opacity {
              running: root.opened && root.processLoading
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 450 }
              NumberAnimation { to: 0.9; duration: 450 }
            }
          }
        }

        Text {
          visible: root.showsProcesses && root.processRows.length === 0
          width: parent.width
          height: visible ? Style.space(46) : 0
          text: root.processError !== ""
            ? root.processError
            : (root.processLoading ? "Reading process memory…" : "No process memory data")
          color: Qt.darker(root.barForeground, 1.35)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Repeater {
          model: root.showsProcesses ? root.processRows.slice(0, root.processRosterSize) : []

          delegate: Item {
            required property var modelData
            width: contentColumn.width
            height: Style.space(27)

            Item {
              id: processIconSlot
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: parent.height

              Image {
                id: processIcon
                anchors.centerIn: parent
                width: Style.space(18)
                height: width
                fillMode: Image.PreserveAspectFit
                source: root.processIconSource(modelData.name)
                asynchronous: true
              }

              Text {
                anchors.centerIn: parent
                visible: processIcon.status !== Image.Ready
                text: "󰣆"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Text {
              anchors.left: processIconSlot.right
              anchors.leftMargin: Style.space(7)
              anchors.right: processPercentLabel.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.processDisplayName(modelData.name)
                + (Number(modelData.processCount || 0) > 1 ? "  ·  " + modelData.processCount : "")
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: processPercentLabel
              anchors.right: processMemoryLabel.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(56)
              text: Number(modelData.percent || 0).toFixed(1) + "%"
              color: Qt.darker(root.barForeground, 1.25)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignRight
            }

            Text {
              id: processMemoryLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(82)
              text: root.formatBytes(modelData.rssBytes)
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignRight
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.barForeground
          opacity: 0.12
        }

        Item {
          width: parent.width
          height: Style.space(22)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Swap in"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatRate(root.swapInBytesPerSecond)
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Item {
          width: parent.width
          height: Style.space(22)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Swap out"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatRate(root.swapOutBytesPerSecond)
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.barForeground
          opacity: 0.12
        }

        Item {
          width: parent.width
          height: Style.space(22)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "SWAP"
            color: root.appColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.swapTotalBytes > 0
              ? root.formatBytes(root.swapUsedBytes) + " of " + root.formatBytes(root.swapTotalBytes)
              : "Not configured"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          width: parent.width
          text: root.showsProcesses ? "Processes are grouped RSS · R to refresh" : "R to refresh"
          color: Qt.darker(root.barForeground, 1.5)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
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
