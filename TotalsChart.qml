import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Model.js" as Model

// Timeline chart for observed totals or release cohort volumes by period bucket,
// scaled against the true time range (so gaps are gaps) and the value range.
// Rendered with QtQuick.Shapes (Canvas does not paint in this shell).
// The line, gradient, and data-point dots take their color from cumulative
// start-to-end growth (up = success, down = warning, flat/1-point = neutral).
// Hovering draws a vertical cursor line and shows a tooltip (date +
// period-worded value delta) when the line intersects a data point.
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
  // Active timeline period ("daily" | "weekly" | "monthly" | "annual");
  // drives the tooltip's date format and delta wording.
  property string period: "daily"
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
  // cursorX is the mouse's horizontal position for the vertical guide line.
  property int hoverIdx: -1
  property point hoverPos: Qt.point(0, 0)
  property real cursorX: NaN

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
    return Model.formatDateShort(p.t, root.period) + " · " + Model.formatNumber(p.v)
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
  readonly property string tipDeltaArrow: isNaN(root.tipDeltaValue) ? ""
    : (root.tipDeltaValue > 0 ? "▲" : (root.tipDeltaValue < 0 ? "▼" : "—"))
  readonly property string tipDeltaText: root.deltaLabel(root.tipDeltaValue, root.tipDeltaDays)

  function elapsedDaysBetween(i) {
    var pts = root.points || []
    if (i === null || i === undefined || i <= 0 || i >= pts.length) return NaN
    return Math.max(1, (pts[i].t - pts[i - 1].t) / 86400000)
  }

  function deltaLabel(d, days) {
    if (isNaN(d)) return ""
    if (d > 0 || d < 0) {
      var body = Model.formatDelta(d)
      // Daily buckets span a single day, so a per-day rate is meaningful.
      // Longer periods bucket one point per week/month/year: the delta is
      // that whole period's change, so label it in period terms instead.
      if (root.period === "daily")
        return body + (!isNaN(days) ? " · " + Model.formatRate(d / days) + "/day" : "")
      if (root.period === "weekly") return body + " this week"
      if (root.period === "monthly") return body + " this month"
      return body + " this year"
    }
    return "—"
  }

  function deltaColor(d) {
    if (d > 0) return root.successColor
    if (d < 0) return root.warningColor
    return Color.foreground
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

  // Horizontal catch radius around a data point: half the closest gap
  // between adjacent points (so dense charts always claim the nearest one),
  // clamped so sparse charts only pop the tooltip when the cursor line
  // actually reaches the point.
  readonly property real hoverRadius: {
    var pts = root.allPts
    if (!pts || pts.length < 2) return Style.space(12)
    var gap = Infinity
    for (var i = 1; i < pts.length; i++) gap = Math.min(gap, pts[i].x - pts[i - 1].x)
    return Math.max(Style.space(8), Math.min(gap / 2, Style.space(28)))
  }

  // Track the cursor's x for the guide line and claim the data point it
  // horizontally intersects (nearest by x within the catch radius).
  function hoverAt(mx) {
    root.cursorX = mx
    var pts = root.allPts
    if (!pts || !pts.length) { root.hoverIdx = -1; return }
    var best = -1
    var bestD = Infinity
    for (var i = 0; i < pts.length; i++) {
      var d = Math.abs(pts[i].x - mx)
      if (d < bestD) { bestD = d; best = i }
    }
    root.hoverIdx = bestD <= root.hoverRadius ? best : -1
    if (root.hoverIdx >= 0) root.hoverPos = Qt.point(pts[root.hoverIdx].x, pts[root.hoverIdx].y)
  }

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
      property bool hovered: index === root.hoverIdx
      width: hovered ? 7 : (isLast ? (root.hasLine ? 5 : 9) : 3)
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

  // Hover handling for the guide line + data-point tooltip.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    visible: root.hasPoint
    onPositionChanged: (mouse) => root.hoverAt(mouse.x)
    onExited: {
      root.hoverIdx = -1
      root.cursorX = NaN
    }
  }

  // Vertical guide line at the cursor; snaps onto the hovered data point so
  // the line, dot, and tooltip read as one crosshair.
  Rectangle {
    visible: root.hasPoint && !isNaN(root.cursorX)
    width: 1
    x: (root.hoverIdx >= 0 ? root.hoverPos.x : root.cursorX) - 0.5
    y: root.topPad
    height: root.height - root.topPad - root.bottomPad
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
  }

  // Tooltip chip showing the hovered point's date + formatted value, with a
  // delta line for the change versus the previous period. Sized up and kept
  // to full-contrast foreground/success/warning colors for readability.
  Item {
    id: tip
    visible: root.hoverIdx >= 0 && root.tooltipText !== ""
    width: Math.max(tipText.implicitWidth, tipDelta.implicitWidth) + Style.space(16)
    height: tipText.implicitHeight + (root.hasTipDelta ? tipDelta.implicitHeight + Style.space(2) : 0) + Style.space(10)
    x: Math.max(0, Math.min(root.width - width, root.hoverPos.x + Style.space(12)))
    y: Math.max(0, Math.min(root.height - height, root.hoverPos.y - height - Style.space(6)))
    z: 20

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: Color.background
      border.color: Qt.rgba(root.trendColor.r, root.trendColor.g, root.trendColor.b, 0.7)
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
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      // Delta line: trend-colored arrow + full-foreground number so the
      // value itself stays high-contrast even when the theme's green/red
      // are dim. Same size as the date/value line.
      Row {
        id: tipDelta
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(3)
        visible: root.hasTipDelta

        Text {
          textFormat: Text.PlainText
          text: root.tipDeltaArrow
          color: root.deltaColor(root.tipDeltaValue)
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: root.tipDeltaText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
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
