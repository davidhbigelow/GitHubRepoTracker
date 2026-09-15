import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One tracked repo: name, sparkline of the selected observed/cohort timeline
// (trend-colored with a downward gradient fade), bold right-aligned total.
// Tappable when `checkable` so the panel can arm comparison selections.
Item {
  id: root

  property var entry: null
  property bool checkable: false
  property bool checked: false
  property bool pinned: false
  property bool refreshing: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color muted: Color.muted

  signal clicked()

  readonly property bool hasData: root.entry && root.entry.hasData === true
  readonly property color trendColor: {
    if (!root.entry) return root.muted
    if (root.entry.trend === "up") return root.accent
    if (root.entry.trend === "down") return root.urgent
    return root.muted
  }

  // Sparkline shows observed totals or per-period release cohort volumes.
  readonly property var sparkValues: {
    if (!root.entry) return []
    var t = root.entry.totals
    if (t && t.length) return t
    return root.entry.values || []
  }

  implicitHeight: Style.space(40)

  Rectangle {
    id: hoverFill
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.pinned
      ? Util.alpha(root.accent, 0.15)
      : (hoverArea.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
  }

  // Selection checkbox (compare arming mode).
  Rectangle {
    id: checkBox
    visible: root.checkable
    width: Style.space(15)
    height: Style.space(15)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    radius: Style.space(2)
    color: root.checked ? root.accent : "transparent"
    border.width: 1
    border.color: root.checked ? root.accent : Style.normalBorderFor(root.foreground, root.accent)
  }

  Text {
    id: nameText
    width: root.checkable ? Style.space(136) : Style.space(150)
    anchors.left: root.checkable ? checkBox.right : parent.left
    anchors.leftMargin: root.checkable ? Style.space(8) : Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.entry ? root.entry.name : "—"
    color: root.hasData ? root.foreground : root.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Item {
    id: sparkArea
    anchors.left: nameText.right
    anchors.leftMargin: Style.space(10)
    anchors.right: totalText.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: Style.space(24)

    Sparkline {
      id: spark
      anchors.fill: parent
      visible: !root.refreshing
      values: root.sparkValues
      lineColor: root.trendColor
    }

    // This repo is queued/in-flight in the current refresh cycle.
    ControlIcon {
      anchors.centerIn: parent
      visible: root.refreshing
      kind: "refresh"
      spinning: true
      size: Style.space(14)
      color: root.muted
    }
  }

  Text {
    id: totalText
    width: Style.space(64)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.entry ? Model.formatNumber(root.entry.total) : "—"
    color: root.hasData ? root.foreground : root.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.bold: true
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
