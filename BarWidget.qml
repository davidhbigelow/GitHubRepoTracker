import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

  // Toolbar widget. Shows a compact text sparkline of recent weekly totals
// plus the aggregate total, colored by cumulative direction (accent =
// up, urgent = down). Click to open the details panel. Reads only
// store.json written by Service.qml, so it stays live without any IPC.
//
// The widget is `allowMultiple` and optionally pinned to a single repo via a
// layout entry:  "settings": { "repo": "owner/repo" }.
BarWidget {
  id: root
  moduleName: "ghrepo.tracker"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property var storePath: Model.pathsFor(home).storePath

  property var store: null
  readonly property string pinnedRepo: root.setting("repo", "")

  readonly property var aggregate: Model.aggregateFor(root.store, root.pinnedRepo)
  readonly property color trendColor: {
    if (root.aggregate.trend === "up") return Color.accent
    if (root.aggregate.trend === "down") return Color.urgent
    return root.bar ? root.bar.barForeground : Color.foreground
  }
  readonly property string btnText: Model.formatNumber(root.aggregate.total)
  readonly property string btnTooltip: {
    var whom = root.pinnedRepo !== ""
      ? root.pinnedRepo + " downloads"
      : "Repo Tracker · " + root.aggregate.count + " repos"
    if (!root.aggregate.totals || root.aggregate.totals.length < 2)
      return whom + " · collecting weekly history"
    var dir = root.aggregate.trend === "up" ? "↑ rising"
      : (root.aggregate.trend === "down" ? "↓ falling" : "· flat")
    return whom + " · " + dir
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (!panelLoader.active) {
      openPending = true
      panelLoader.active = true
      return
    }
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (!panelLoader.active) {
      openPending = true
      panelLoader.active = true
      return
    }
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: widgetRow.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  FileView {
    id: storeFile
    path: root.storePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.store = Model.parseStore(text())
    onLoadFailed: root.store = null
  }

  // Live theme switches rewrite this file (and push `shell applyTheme` IPC).
  // The panel's cross-file color bindings — kit Button fills, selected-state
  // tints — resolve once at creation and never re-evaluate, so content created
  // under the previous palette keeps stale colors after a switch. Rebuild the
  // panel a beat later so everything re-resolves against the new theme.
  FileView {
    id: themeFile
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      if (panelLoader.active) rethemeTimer.restart()
    }
  }

  Timer {
    id: rethemeTimer
    interval: 300
    onTriggered: {
      if (!panelLoader.active) return
      var wasOpen = panelLoader.item ? panelLoader.item.opened === true : false
      panelLoader.active = false
      root.openPending = wasOpen
      Qt.callLater(function() { panelLoader.active = true })
    }
  }

  property bool openPending: false

  Loader {
    id: panelLoader
    active: false
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(function() {
        root.injectPanel()
        if (root.openPending) {
          root.openPending = false
          openDelayTimer.restart()
        }
      })
    }
  }

  Timer {
    id: openDelayTimer
    interval: 50
    onTriggered: {
      if (panelLoader.item) {
        root.injectPanel()
        panelLoader.item.open()
      }
    }
  }

  Row {
    id: widgetRow
    anchors.centerIn: parent
    spacing: Style.space(3)

    // Trend chart glyph; the slot forwards clicks and the tooltip so the
    // whole widget behaves like one button alongside the number.
    Item {
      id: iconSlot
      width: trendIcon.width
      height: trendIcon.height
      anchors.verticalCenter: parent.verticalCenter

      ControlIcon {
        id: trendIcon
        kind: "chart"
        size: Style.space(14)
        color: root.trendColor
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggle()
        onEntered: if (root.bar) root.bar.showTooltip(button, root.btnTooltip)
        onExited: if (root.bar) root.bar.hideTooltip(button)
      }
    }

    WidgetButton {
      id: button
      anchors.verticalCenter: parent.verticalCenter
      horizontalMargin: 2
      bar: root.bar
      text: root.btnText
      tooltipText: root.btnTooltip
      foreground: root.trendColor
      fontSize: Style.font.bodySmall
      fixedWidth: -1
      fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton) root.toggle()
      }
    }
  }
}
