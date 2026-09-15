import QtQuick
import qs.Commons

// Category section header ("MINE" / "OTHERS"), modelled on the stocks-style
// upper band: a colored trend dot + category label + this-week summary on the
// left, and the category's cumulative total with a start-to-end direction arrow
// on the right.
Item {
  id: root

  property string label: ""
  property int count: 0
  property string subText: ""
  property string totalText: ""
  property string trend: "flat"
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color muted: Color.muted

  readonly property color trendColor: root.trend === "up" ? root.accent : (root.trend === "down" ? root.urgent : root.muted)
  readonly property string arrow: root.trend === "up" ? "▲" : (root.trend === "down" ? "▼" : "—")

  implicitHeight: Math.max(leftBlock.implicitHeight, rightBlock.implicitHeight)

  Row {
    id: leftBlock
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Rectangle {
      id: dot
      width: Style.space(8)
      height: Style.space(8)
      radius: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      color: root.trendColor
    }

    Column {
      spacing: Style.space(1)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: root.label
        color: Qt.darker(root.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }

      Text {
        visible: root.subText !== ""
        textFormat: Text.PlainText
        text: root.subText
        color: root.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Row {
    id: rightBlock
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.arrow
      color: root.trendColor
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      id: totalText
      textFormat: Text.PlainText
      text: root.totalText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }
}
