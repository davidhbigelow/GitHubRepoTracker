import QtQuick
import QtQuick.Shapes
import qs.Commons

// Normalized overlay for the compare view. Each repo's change/rate series
// is scaled to its own max (so a 68k and a 15.9M repo are directly
// comparable), drawn as a colored line with a soft downward gradient fill.
// Rendered with QtQuick.Shapes (Canvas does not paint in this shell). Colors
// come from the palette, so the chart re-themes live.
Item {
  id: root

  // Array of { name, color, values } where all arrays share observed dates.
  property var series: []
  property real lineWidth: 1.8
  property real fillAlpha: 0.16
  property real topPad: 4
  property real bottomPad: 10
  property real sidePad: 4

  implicitHeight: Style.space(110)
  implicitWidth: Style.space(300)

  function layerFor(entry) {
    var out = { start: Qt.point(0, 0), rest: [], fill: [], count: 0 }
    var vals = entry && entry.values ? entry.values : []
    var w = root.width
    var h = root.height
    if (!vals.length || w <= 0 || h <= 0) return out

    var padL = root.sidePad, padR = root.sidePad
    var padT = root.topPad, padB = root.bottomPad
    var plotW = Math.max(1, w - padL - padR)
    var plotH = Math.max(1, h - padT - padB)

    var max = 0, i
    for (i = 0; i < vals.length; i++) if (vals[i] > max) max = vals[i]
    if (max <= 0) max = 1
    var lRange = max

    var line = []
    for (i = 0; i < vals.length; i++) {
      var x = padL + (i / (vals.length - 1)) * plotW
      var y = padT + plotH - (Math.max(0, vals[i]) / lRange) * plotH
      line.push(Qt.point(x, y))
    }
    out.count = line.length
    if (line.length < 2) return out
    out.start = line[0]
    // Include line[0] in the painted polyline: PathPolyline starts its own
    // subpath at its first point, so the connecting Move-to-start segment is
    // otherwise lost for short series (a 2-point line vanished entirely).
    for (i = 0; i < line.length; i++) out.rest.push(line[i])
    var baseY = h - padB
    for (i = 0; i < line.length; i++) out.fill.push(line[i])
    out.fill.push(Qt.point(line[line.length - 1].x, baseY))
    out.fill.push(Qt.point(line[0].x, baseY))
    return out
  }

  // Faint baseline.
  Shape {
    anchors.fill: parent
    antialiasing: true

    ShapePath {
      strokeColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
      strokeWidth: 1
      fillColor: "transparent"
      PathMove { x: root.sidePad; y: root.height - root.bottomPad }
      PathLine { x: root.width - root.sidePad; y: root.height - root.bottomPad }
    }
  }

  Repeater {
    model: root.series

    Shape {
      required property var modelData
      anchors.fill: parent
      antialiasing: true

      readonly property var built: root.layerFor(modelData)
      readonly property var startPt: built.start
      readonly property var restPts: built.rest
      readonly property var fillPts: built.fill
      readonly property bool hasLine: built.count >= 2

      visible: hasLine

      // Gradient fill under this series (low opacity so overlays stay legible).
      ShapePath {
        strokeColor: "transparent"
        fillGradient: LinearGradient {
          x1: 0
          y1: root.topPad
          x2: 0
          y2: root.height - root.bottomPad
          GradientStop { position: 0; color: Qt.rgba(modelData.color.r, modelData.color.g, modelData.color.b, root.fillAlpha) }
          GradientStop { position: 1; color: Qt.rgba(modelData.color.r, modelData.color.g, modelData.color.b, 0) }
        }
        PathMove { x: startPt.x; y: startPt.y }
        PathPolyline { path: fillPts }
      }

      // The line.
      ShapePath {
        strokeColor: modelData.color
        strokeWidth: root.lineWidth
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        fillColor: "transparent"
        PathMove { x: startPt.x; y: startPt.y }
        PathPolyline { path: restPts }
      }
    }
  }
}
