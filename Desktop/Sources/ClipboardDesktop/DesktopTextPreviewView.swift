import CGtk
import Gtk
import GtkBackend
import SwiftCrossUI

// Match the pinned backend's multi-line label behavior. Ellipsizing prevents
// GTK's own minimum-width query from laying out every unbroken character on
// a separate line; the allocated height still exposes the complete preview.
final class DesktopPreviewLabel: Gtk.Label {
  override func setSizeRequest(width: Int, height: Int) {
    super.setSizeRequest(width: width, height: height)
    let layout = gtk_label_get_layout(opaquePointer)
    let scaledHeight = Int64(max(0, height)) * Int64(PANGO_SCALE)
    pango_layout_set_height(layout, Int32(clamping: scaledHeight))
  }
}

final class DesktopTextLayoutCache {
  var text = ""
  var heights: [Int: Int] = [:]
  private var contextSerial: UInt32 = 0
  private var fontMapSerial: UInt32 = 0
  private var scale: Int32 = 0

  @MainActor func refreshMetrics(for widget: Gtk.Label) {
    guard let context = gtk_widget_get_pango_context(widget.widgetPointer) else { return }
    let serial = pango_context_get_serial(context)
    let mapSerial = pango_context_get_font_map(context).map { pango_font_map_get_serial($0) } ?? 0
    let currentScale = gtk_widget_get_scale_factor(widget.widgetPointer)
    if contextSerial != serial || fontMapSerial != mapSerial || scale != currentScale {
      heights.removeAll()
      contextSerial = serial
      fontMapSerial = mapSerial
      scale = currentScale
    }
  }
}

/// Native plain text with one bounded layout cache per current preview. The
/// generic Text view shapes the whole string during zero-width measurement,
/// which is prohibitively slow for a long unbroken paragraph.
struct DesktopTextPreviewView: GtkWidgetRepresentable {
  let text: String

  func makeCoordinator() -> DesktopTextLayoutCache { DesktopTextLayoutCache() }

  func makeGtkWidget(context: Context) -> DesktopPreviewLabel {
    let label = DesktopPreviewLabel(string: "")
    label.ellipsize = .end
    label.wrap = true
    label.lineWrapMode = .wordCharacter
    label.xalign = 0
    label.yalign = 0
    return label
  }

  func updateGtkWidget(_ widget: DesktopPreviewLabel, context: Context) {
    guard context.coordinator.text != text else { return }
    context.coordinator.text = text
    context.coordinator.heights.removeAll()
    widget.label = text
  }

  func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: DesktopPreviewLabel, context: Context)
    -> ViewSize
  {
    context.coordinator.refreshMetrics(for: gtkWidget)
    // A minimum-size query needs no full-content shaping. Actual readable
    // widths are measured normally; hidden/zero geometry never enters Pango.
    if let width = proposal.width, width <= 0 { return ViewSize(0, 20) }
    let width = Int(min(16384, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 340))
    let height: Int
    if let cached = context.coordinator.heights[width] {
      height = cached
    } else {
      height =
        Pango(for: gtkWidget).getTextSize(
          text, ellipsize: .none, proposedWidth: Double(max(1, width))
        ).height
      if context.coordinator.heights.count >= 8 { context.coordinator.heights.removeAll() }
      context.coordinator.heights[width] = height
    }
    return ViewSize(Double(width), Double(height))
  }
}
