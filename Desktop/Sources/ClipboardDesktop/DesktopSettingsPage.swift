import CGtk
import Gtk
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
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    DesktopRetainedPage(active: settingsSection == section) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) { content() }
          .frame(maxWidth: 560, alignment: .leading).padding(24)
          .frame(maxWidth: .infinity, alignment: .top)
      }
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .inspect(.afterUpdate) { widget in
        DesktopChrome.label(model.t(section.rawValue), on: widget)
      }
    }
  }
}

/// Preserve native editors/IME/scroll positions, but do no layout or updates
/// for off-page controls. Hiding a widget after layout still measured all five
/// pages (including every AI setting) on each tab click and keystroke.
private struct DesktopRetainedPage<Content: View>: View {
  let active: Bool
  @ViewBuilder let content: () -> Content
  var body: some View { content() }

  func computeLayout<Backend: BaseAppBackend>(
    _ widget: Backend.Widget, children: any ViewGraphNodeChildren,
    proposedSize: ProposedViewSize, environment: EnvironmentValues, backend: Backend
  ) -> ViewLayoutResult {
    guard active else { return .leafView(size: .zero) }
    return defaultComputeLayout(
      widget, children: children, proposedSize: proposedSize,
      environment: environment, backend: backend)
  }

  func commit<Backend: BaseAppBackend>(
    _ widget: Backend.Widget, children: any ViewGraphNodeChildren,
    layout: ViewLayoutResult, environment: EnvironmentValues, backend: Backend
  ) {
    if active {
      defaultCommit(
        widget, children: children, layout: layout, environment: environment, backend: backend)
    }
    if let widget = widget as? Gtk.Widget,
      (gtk_widget_get_visible(widget.widgetPointer) != 0) != active
    {
      gtk_widget_set_visible(widget.widgetPointer, active ? 1 : 0)
    }
  }
}
