import CGtk
import Gtk
import GtkBackend
import SwiftCrossUI

/// A history row always reserves two single lines. Let GTK shape the visible
/// labels once instead of probing both Text views and a nested stack repeatedly
/// for every record, even when only the selection or preview changed.
struct DesktopRowLabels: GtkWidgetRepresentable {
  let title: String
  let subtitle: String

  @MainActor final class Coordinator {
    let title = Gtk.Label(string: "")
    let subtitle = Gtk.Label(string: "")
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeGtkWidget(context: Context) -> Gtk.Box {
    let box = Gtk.Box(orientation: .vertical, spacing: 3)
    for label in [context.coordinator.title, context.coordinator.subtitle] {
      label.ellipsize = .end
      label.xalign = 0
      gtk_widget_set_hexpand(label.widgetPointer, 1)
      box.add(label)
    }
    DesktopChrome.setClass("clipboard-row-title", on: context.coordinator.title)
    DesktopChrome.setClass("clipboard-row-subtitle", on: context.coordinator.subtitle)
    DesktopChrome.setClass("clipboard-secondary", on: context.coordinator.subtitle)
    return box
  }

  func updateGtkWidget(_ widget: Gtk.Box, context: Context) {
    if context.coordinator.title.label != title { context.coordinator.title.label = title }
    if context.coordinator.subtitle.label != subtitle {
      context.coordinator.subtitle.label = subtitle
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Box, context: Context) -> ViewSize
  {
    // CJK fallback fonts can be taller than the nominal font size. GTK caches
    // these native single-line measurements and invalidates on font/DPI/text
    // changes; retain enough height for both lines at every system scale.
    var height: Int32 = 3
    for label in [context.coordinator.title, context.coordinator.subtitle] {
      var natural: Int32 = 0
      gtk_widget_measure(label.widgetPointer, GTK_ORIENTATION_VERTICAL, -1, nil, &natural, nil, nil)
      height += natural
    }
    return ViewSize(max(0, proposal.width ?? 220), Double(max(40, height)))
  }
}
