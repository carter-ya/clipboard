import CGtk
import Gtk
import GtkBackend
import SwiftCrossUI

/// GTK owns the popover as a MenuButton child, including outside-click dismissal
/// and teardown. End alignment keeps actions inside the right edge of the panel.
struct DesktopActionMenu: GtkWidgetRepresentable {
  struct Entry {
    let label: String
    let enabled: Bool
    let action: @MainActor () -> Void
  }
  let label: String
  let accessibilityLabel: String
  let entries: [Entry]
  var showsArrow = false

  final class Coordinator {
    let popover = Gtk.Popover()
    var buttons: [Gtk.Button] = []
    var box: Gtk.Box?
    var entries: [Entry] = []
    var enabled = true
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeGtkWidget(context: Context) -> Gtk.Widget {
    let widget = Gtk.Widget(gtk_menu_button_new())
    let coordinator = context.coordinator
    let pointer = OpaquePointer(widget.widgetPointer)
    gtk_menu_button_set_direction(pointer, showsArrow ? GTK_ARROW_DOWN : GTK_ARROW_NONE)
    gtk_menu_button_set_popover(pointer, coordinator.popover.widgetPointer)
    gtk_popover_set_has_arrow(
      UnsafeMutablePointer<GtkPopover>(coordinator.popover.opaquePointer), 0)
    gtk_popover_set_position(
      UnsafeMutablePointer<GtkPopover>(coordinator.popover.opaquePointer), GTK_POS_BOTTOM)
    gtk_widget_set_halign(coordinator.popover.widgetPointer, GTK_ALIGN_END)
    DesktopChrome.setClass("clipboard-more", on: widget)
    return widget
  }
  func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context)
    -> ViewSize
  {
    ViewSize(proposal.width ?? 28, 28)
  }
  func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
    let coordinator = context.coordinator
    coordinator.entries = entries
    coordinator.enabled = context.environment.isEnabled
    widget.sensitive = context.environment.isEnabled
    gtk_menu_button_set_label(OpaquePointer(widget.widgetPointer), label)
    if let child = gtk_widget_get_first_child(widget.widgetPointer) {
      DesktopChrome.label(accessibilityLabel, on: Gtk.Widget(child), alwaysUpdate: true)
    }
    if coordinator.buttons.count != entries.count {
      let box = Gtk.Box(orientation: .vertical, spacing: 0)
      coordinator.box = box
      coordinator.buttons = entries.indices.map { index in
        let button = Gtk.Button()
        button.clicked = { [weak coordinator] _ in
          guard let coordinator, coordinator.enabled, coordinator.entries.indices.contains(index),
            coordinator.entries[index].enabled
          else { return }
          gtk_popover_popdown(UnsafeMutablePointer<GtkPopover>(coordinator.popover.opaquePointer))
          coordinator.entries[index].action()
        }
        box.add(button)
        return button
      }
      gtk_popover_set_child(
        UnsafeMutablePointer<GtkPopover>(coordinator.popover.opaquePointer), box.widgetPointer)
    }
    for (button, entry) in zip(coordinator.buttons, entries) {
      button.label = entry.label
      button.sensitive = entry.enabled && context.environment.isEnabled
    }
  }
}
