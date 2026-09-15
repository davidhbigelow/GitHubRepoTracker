import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Model.js" as Model

// Timeline chart for observed totals or release cohort volumes by period bucket,
// scaled against the true time range (so gaps are gaps) and the value range.
// Rendered with QtQuick.Shapes (Canvas does not paint in this shell).
// The line, gradient, and data-point dots take their color from cumulative
// start-to-end growth (up = success, down = warning, flat/1-point = neutral).
// Hovering a data point shows a tooltip with its date and formatted value.
Item {
  id: root

  // Array of { t: epochMs, v: value }, oldest first.
  property var points: []
  property real domainStart: NaN
  property real domainEnd: NaN
  property int slotCount: 0
  property color lineColor: Color.accent
  property color successColor: root.lineColor
  property color warningColor: root.lineColor
  property bool forceSuccess: false
  property bool cohortVolumes: false
  property real lineWidth: 1.8
  property real fillAlpha: 0.22
  property real topPad: 4
  property real bottomPad: 24
  property real sidePad: 4

  // A refresh cycle is running: hide the empty-state hint so it cannot
  // collide with the caller's "Refreshing Data" overlay.
  property bool busy: false

  // Labels rendered below/above the plot (start date, end date, current peak).
  property string startLabel: ""
  property string endLabel: ""
  property string peakLabel: ""

  // Hover state (index into root.allPts, -1 = none) and the point's position.
  property int hoverIdx: -1
  property point hoverPos: Qt.point(0, 0)

  implicitHeight: Style.space(110)
  implicitWidth: Style.space(300)

  readonly property var built: root.build()
  readonly property var startPt: root.built.start
  readonly property var restPts: root.built.rest
  readonly property var fillPts: root.built.fill
  readonly property var allPts: root.built.pts
  readonly property bool hasLine: root.built.count >= 2
  readonly property bool hasPoint: root.built.count >= 1
  readonly property point lastPt: root.built.last

  // Up = success, down = warning, otherwise neutral. Stars/releases are
  // cumulative and never decline, so callers force them to always-success.
  readonly property color trendColor: {
    if (root.forceSuccess) return root.successColor
    var pts = root.points || []
    if (pts.length < 2) return root.lineColor
    var last = pts[pts.length - 1].v
    var first = pts[0].v
    if (last > first) return root.successColor
    if (last < first) return root.warningColor
    return root.lineColor
  }

  readonly property string tooltipText: {
    var pts = root.points || []
    if (!pts.length || root.hoverIdx < 0 || root.hoverIdx >= pts.length) return ""
    var p = pts[root.hoverIdx]
    return Model.formatDateShort(p.t, "daily") + " · " + Model.formatNumber(p.v)
  }

  // Delta between consecutive points: points[i].v - points[i-1].v (NaN when
  // unavailable). Tooltips use it; the peak label was removed (see Panel total).
  function deltaBetween(i) {
    var pts = root.points || []
    if (i === null || i === undefined || i <= 0 || !pts || i >= pts.length) return NaN
    return pts[i].v - pts[i - 1].v
  }

  readonly property real tipDeltaValue: root.deltaBetween(root.hoverIdx)
  readonly property real tipDeltaDays: root.elapsedDaysBetween(root.hoverIdx)
  readonly property bool hasTipDelta: !root.cohortVolumes && !isNaN(root.tipDeltaValue)
  readonly property string tipDeltaText: root.deltaLabel(root.tipDeltaValue, root.tipDeltaDays)

  function elapsedDaysBetween(i) {
    var pts = root.points || []
    if (i === null || i === undefined || i <= 0 || i >= pts.length) return NaN
    return Math.max(1, (pts[i].t - pts[i - 1].t) / 86400000)
  }

  function deltaLabel(d, days) {
    if (isNaN(d)) return ""
    var rate = !isNaN(days) ? " · " + Model.formatRate(d / days) + "/day" : ""
    if (d > 0) return "▲ " + Model.formatDelta(d) + rate
    if (d < 0) return "▼ " + Model.formatDelta(d) + rate
    return "—"
  }

  function deltaColor(d) {
    if (d > 0) return root.successColor
    if (d < 0) return root.warningColor
    return root.lineColor
  }

  function build() {
    var out = { start: Qt.point(0, 0), rest: [], fill: [], pts: [], last: Qt.point(0, 0), count: 0 }
    var pts = root.points || []
    var w = root.width
    var h = root.height
    if (!pts.length || w <= 0 || h <= 0) return out

    var padL = root.sidePad, padR = root.sidePad
    var padT = root.topPad, padB = root.bottomPad
    var plotW = Math.max(1, w - padL - padR)
    var plotH = Math.max(1, h - padT - padB)

    if (pts.length === 1) {
      // One sample is a current observation, not a midpoint in history.
      var only = Qt.point(padL + plotW, padT + plotH / 2)
      out.start = only
      out.last = only
      out.pts.push(only)
      out.count = 1
      return out
    }

    var minT = isFinite(root.domainStart) ? root.domainStart : Infinity
    var maxT = isFinite(root.domainEnd) ? root.domainEnd : -Infinity
    var minV = Infinity, maxV = -Infinity, i
    for (i = 0; i < pts.length; i++) {
      if (pts[i].t < minT) minT = pts[i].t
      if (pts[i].t > maxT) maxT = pts[i].t
      if (pts[i].v < minV) minV = pts[i].v
      if (pts[i].v > maxV) maxV = pts[i].v
    }
    if (maxV === minV) maxV = minV + Math.max(1, Math.abs(minV) * 0.05 || 1)
    var tRange = maxT - minT || 1
    var vRange = maxV - minV

    var line = []
    for (i = 0; i < pts.length; i++) {
      var x = padL + ((pts[i].t - minT) / tRange) * plotW
      var y = padT + plotH - ((pts[i].v - minV) / vRange) * plotH
      var p = Qt.point(x, y)
      line.push(p)
      out.pts.push(p)
    }
    out.count = line.length
    out.start = line[0]
    out.last = line[line.length - 1]
    // Include line[0] in the painted polyline: PathPolyline starts its own
    // subpath at its first point, so the connecting Move-to-start segment is
    // otherwise lost for short series (a 2-point line vanished entirely).
    for (i = 0; i < line.length; i++) out.rest.push(line[i])
    var baseY = h - padB
    for (i = 0; i < line.length; i++) out.fill.push(line[i])
    if (out.rest.length) {
      out.fill.push(Qt.point(line[line.length - 1].x, baseY))
      out.fill.push(Qt.point(line[0].x, baseY))
    }
    return out
  }

  function hoverAt(mx, my) {
    var pts = root.allPts
    if (!pts || !pts.length) { root.hoverIdx = -1; return }
    var best = -1
    var bestD = root.dotRadius * 4
    for (var i = 0; i < pts.length; i++) {
      var dx = pts[i].x - mx, dy = pts[i].y - my
      var d = Math.sqrt(dx * dx + dy * dy)
      if (d < bestD) { bestD = d; best = i }
    }
    root.hoverIdx = best
    if (best >= 0) root.hoverPos = Qt.point(pts[best].x, pts[best].y)
  }

  readonly property real dotRadius: 2

  Text {
    id: emptyHint
    anchors.centerIn: parent
    anchors.verticalCenterOffset: root.points.length === 1 ? Style.space(18) : Style.space(-6)
    visible: root.points.length < 2 && !root.busy
    text: root.points.length ? "1 observation · trend begins with the next bucket" : "No Data Available"
    color: Color.muted
    font.pixelSize: Style.space(11)
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    visible: root.hasPoint

    // Faint baseline + midpoint gridline.
    ShapePath {
      strokeColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
      strokeWidth: 1
      fillColor: "transparent"
      PathMove { x: root.sidePad; y: root.height - root.bottomPad }
      PathLine { x: root.width - root.sidePad; y: root.height - root.bottomPad }
      PathMove { x: root.sidePad; y: (root.topPad + (root.height - root.bottomPad)) / 2 }
      PathLine { x: root.width - root.sidePad; y: (root.topPad + (root.height - root.bottomPad)) / 2 }
    }

    // Gradient area fill under the line (same hue as the trend color).
    ShapePath {
      strokeColor: "transparent"
      fillGradient: LinearGradient {
        x1: 0
        y1: root.topPad
        x2: 0
        y2: root.height - root.bottomPad
        GradientStop { position: 0; color: Qt.rgba(root.trendColor.r, root.trendColor.g, root.trendColor.b, root.fillAlpha) }
        GradientStop { position: 1; color: Qt.rgba(root.trendColor.r, root.trendColor.g, root.trendColor.b, 0) }
      }
      PathMove { x: root.startPt.x; y: root.startPt.y }
      PathPolyline { path: root.fillPts }
    }
  }

  // One subtle baseline tick per retained bucket, including unknown null gaps.
  Repeater {
    model: root.slotCount

    Rectangle {
      required property int index
      width: 1
      height: index % 5 === 0 ? Style.space(5) : Style.space(3)
      x: root.slotCount <= 1
        ? root.width - root.sidePad
        : root.sidePad + (index / (root.slotCount - 1)) * (root.width - root.sidePad * 2)
      y: root.height - root.bottomPad - height
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
    }
  }

  // The line itself (separate Shape so it stays crisp on top of the fill).
  Shape {
    anchors.fill: parent
    antialiasing: true
    visible: root.hasLine

    ShapePath {
      strokeColor: root.trendColor
      strokeWidth: root.lineWidth
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      fillColor: "transparent"
      PathMove { x: root.startPt.x; y: root.startPt.y }
      PathPolyline { path: root.restPts }
    }
  }

  // Data-point markers (last point slightly larger).
  Repeater {
    model: root.allPts

    Rectangle {
      required property var modelData
      required property int index
      property bool isLast: index === root.allPts.length - 1
      width: (isLast ? (root.hasLine ? 5 : 9) : 3)
      height: width
      radius: width / 2
      color: root.trendColor
      visible: root.hasPoint
      x: Math.min(root.width - width, modelData.x - width / 2)
      y: modelData.y - height / 2
    }
  }

  Text {
    visible: root.points.length === 1
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    y: root.startPt.y - height - Style.space(7)
    textFormat: Text.PlainText
    text: root.points.length ? "CURRENT  " + Model.formatNumber(root.points[0].v) : ""
    color: root.trendColor
    font.family: Style.font.family
    font.pixelSize: Style.space(10)
    font.bold: true
  }

  // Hover handling for the data-point tooltip.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    visible: root.hasPoint
    onPositionChanged: (mouse) => root.hoverAt(mouse.x, mouse.y)
    onExited: root.hoverIdx = -1
  }

  // Tooltip chip showing the hovered point's date + formatted value, with a
  // delta line for the change versus the previous period.
  Item {
    id: tip
    visible: root.hoverIdx >= 0 && root.tooltipText !== ""
    width: Math.max(tipText.implicitWidth, tipDelta.implicitWidth) + Style.space(12)
    height: tipText.implicitHeight + (root.hasTipDelta ? tipDelta.implicitHeight + Style.space(2) : 0) + Style.space(6)
    x: Math.max(0, Math.min(root.width - width, root.hoverPos.x + Style.space(12)))
    y: Math.max(0, Math.min(root.height - height, root.hoverPos.y - height - Style.space(6)))
    z: 20

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: Color.background
      border.color: Qt.rgba(root.trendColor.r, root.trendColor.g, root.trendColor.b, 0.5)
      border.width: 1
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        id: tipText
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.tooltipText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.space(10)
      }

      Text {
        id: tipDelta
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.hasTipDelta
        textFormat: Text.PlainText
        text: root.tipDeltaText
        color: root.deltaColor(root.tipDeltaValue)
        font.family: Style.font.family
        font.pixelSize: Style.space(9)
      }
    }
  }

  Text {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(2)
    anchors.bottom: parent.bottom
    text: root.startLabel
    color: Color.foreground
    font.pixelSize: Style.space(10)
    visible: root.startLabel !== ""
  }

  Text {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(2)
    anchors.bottom: parent.bottom
    text: root.endLabel
    color: Color.foreground
font.pixelSize: Style.space(10)
    visible: root.endLabel !== ""
  }
}
