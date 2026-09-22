import QtQuick
import qs.Commons
import "Model.js" as Model

// Hover chip revealing the exact value behind a compactly formatted display
// number ("16.3k" -> "16,308"). Drop it over the number it explains (fill the
// number's bounds); the chip floats above it, or below when `below` is set so
// numbers at the top edge of a clipped scroller stay visible. Bind `active`
// to the owning item's hover state — this component does not trap mouse
// events itself, so surrounding click targets keep working.
//
// The chip never spills past this item's right edge: when narrower than its
// bounds it centers, when wider it hangs left over the preceding content.
// `before` places it immediately left of the bounds, flush with the number
// (in `[16,308] 16.3k` style); `overlayLeft` pins it to the left edge inside
// the bounds; `inline` centers it vertically instead of floating above/below
// — useful for rows in a scroller where an above/below chip would be clipped.
Item {
  id: root

  property real value: NaN
  property bool active: false
  property bool below: false
  property bool before: false
  property bool overlayLeft: false
  property bool inline: false
  property string label: ""
  property color accentColor: Color.accent

  readonly property string exactText: isFinite(root.value) ? Model.grouped(root.value) : ""
  readonly property bool shown: root.active && root.exactText !== ""

  x: 0
  y: 0

  Item {
    id: chip
    visible: root.shown
    z: 60
    x: root.before
      ? -width - Style.space(6)
      : root.overlayLeft
        ? Math.max(0, Math.min(Style.space(8), root.width - width))
        : (function() {
            var span = root.width - width
            return span >= 0 ? span / 2 : span
          })()
    y: root.inline
      ? Math.max(0, (root.height - height) / 2)
      : (root.below ? root.height + Style.space(6) : -height - Style.space(6))
    width: chipText.implicitWidth + Style.space(16)
    height: chipText.implicitHeight + Style.space(9)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: Color.background
      border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.7)
      border.width: 1
    }

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: (root.label !== "" ? root.label + " · " : "") + root.exactText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
  }
}