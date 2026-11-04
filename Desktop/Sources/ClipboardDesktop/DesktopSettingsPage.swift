import CGtk
import GtkBackend
import SwiftCrossUI

enum DesktopSettingsSection: String, CaseIterable, Hashable {
  case general = "General"
  case shortcuts = "Shortcuts"
  case ai = "AI"
  case privacy = "Privacy"
  case data = "Data"

  var symbol: String {
    switch self {
    case .general: return "settings"
    case .shortcuts: return "keyboard"
    case .ai: return "ai"
    case .privacy: return "lock"
    case .data: return "data"
    }
  }
}

extension HistoryView {
  func settingsPage<Content: View>(
    _ section: DesktopSettingsSection,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) { content() }
        .frame(maxWidth: 560, alignment: .leading).padding(24)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .inspect(.afterUpdate) { widget in
      DesktopChrome.label(model.t(section.rawValue), on: widget)
      // InspectView adds one native TupleView container around the inspected
      // frame. Hide that container too, otherwise its empty allocation blocks
      // pointer/scroll input to the active page below it in the ZStack.
      let root = gtk_widget_get_parent(widget.widgetPointer) ?? widget.widgetPointer
      let visible = settingsSection == section
      if (gtk_widget_get_visible(root) != 0) != visible {
        gtk_widget_set_visible(root, visible ? 1 : 0)
      }
    }
  }
}
