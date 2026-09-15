import QtQuick
import QtQuick.Shapes
import qs.Commons

// Sparkline for a repo/aggregate series. Drawn with the QtQuick.Shapes scene
// graph (plain QtQuick.Canvas does not paint in this shell), as a smoothed-fit
// polyline in `lineColor` with a soft same-hue gradient fill beneath.
Item {
  id: root

  // Array of numbers: cumulative totals (or any raw series).
  property var values: []
  property color lineColor: Color.foreground
  property real lineWidth: 1.5
  property real fillAlpha: 0.30
  property real topPad: 2
  property real bottomPad: 2
  property real sidePad: 1.5

  implicitWidth: 120
  implicitHeight: 26

  // Derived path data (in item coordinates), recomputed reactively.
  readonly property var line: root.build()
  readonly property var startPt: root.line.start
  readonly property var restPts: root.line.rest
  readonly property var fillPts: root.line.fill
  readonly property bool hasLine: root.line.count >= 2
  readonly property bool hasPoint: root.line.count >= 1

  function build() {
    var out = { start: Qt.point(0, 0), rest: [], fill: [], count: 0 }
    var vals = root.values || []
    var w = root.width
    var h = root.height
    if (!vals.length || w <= 0 || h <= 0) return out

    var padL = root.sidePad, padR = root.sidePad
    var padT = root.topPad, padB = root.bottomPad
    var plotW = Math.max(1, w - padL - padR)
    var plotH = Math.max(1, h - padT - padB)

    var min = Infinity, max = -Infinity, i
    for (i = 0; i < vals.length; i++) {
      if (vals[i] < min) min = vals[i]
      if (vals[i] > max) max = vals[i]
    }
    if (max === min) max = min + Math.max(1, Math.abs(min) * 0.1 || 1)
    var range = max - min
    var n = vals.length

    var line = []
    for (i = 0; i < n; i++) {
      // A lone observation is current data, so place it at the right edge
      // rather than making it look like a historical midpoint.
      var x = n === 1 ? padL + plotW : padL + (i / (n - 1)) * plotW
      var y = n === 1 ? padT + plotH / 2 : padT + plotH - ((vals[i] - min) / range) * plotH
      line.push(Qt.point(x, y))
    }
    out.count = line.length
    out.start = line[0]
    // Include line[0] in the painted polyline: PathPolyline starts its own
    // subpath at its first point, so the connecting Move-to-start segment is
    // otherwise lost for short series (a 2-value sparkline vanished entirely).
    for (i = 0; i < line.length; i++) out.rest.push(line[i])
    var baseY = h - root.bottomPad
    for (i = 0; i < line.length; i++) out.fill.push(line[i])
    if (out.rest.length) {
      out.fill.push(Qt.point(line[line.length - 1].x, baseY))
      out.fill.push(Qt.point(line[0].x, baseY))
    }
    return out
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    visible: root.hasLine

    // Gradient area fill underneath the line.
    ShapePath {
      strokeColor: "transparent"
      fillGradient: LinearGradient {
        x1: 0
        y1: root.topPad
        x2: 0
        y2: root.height - root.bottomPad
        GradientStop { position: 0; color: Qt.rgba(root.lineColor.r, root.lineColor.g, root.lineColor.b, root.fillAlpha) }
        GradientStop { position: 1; color: Qt.rgba(root.lineColor.r, root.lineColor.g, root.lineColor.b, 0) }
      }
      PathMove { x: root.startPt.x; y: root.startPt.y }
      PathPolyline { path: root.fillPts }
    }

    // The line itself.
    ShapePath {
      strokeColor: root.lineColor
      strokeWidth: root.lineWidth
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      fillColor: "transparent"
      PathMove { x: root.startPt.x; y: root.startPt.y }
      PathPolyline { path: root.restPts }
    }
  }

  // Empty series (no data for the selected period): show a muted hint instead
  // of a blank void.
  Text {
    anchors.centerIn: parent
    visible: (root.values || []).length === 0
    width: root.width - Style.space(8)
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideMiddle
    textFormat: Text.PlainText
    text: "No Data Available"
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.space(9)
  }

  // A single real observation cannot define a slope, but it should remain
  // visible while history accumulates.
  Rectangle {
    visible: root.hasPoint && !root.hasLine
    width: Math.min(root.width, Style.space(18))
    height: 2
    x: root.startPt.x - width
    y: root.startPt.y - height / 2
    radius: 1
    color: Qt.rgba(root.lineColor.r, root.lineColor.g, root.lineColor.b, 0.45)
  }

  Rectangle {
    visible: root.hasPoint && !root.hasLine
    width: Style.space(7)
    height: width
    radius: width / 2
    color: root.lineColor
    x: Math.min(root.width - width, root.startPt.x - width / 2)
    y: root.startPt.y - height / 2
  }
}
