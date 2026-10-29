import AppKit
import SwiftUI

/// Native segment widths stay stable while counts and key hints swap.
struct HistoryTabPicker: NSViewRepresentable {
  @Binding var selection: HistoryPanelTab
  let allCount: Int
  let pinnedCount: Int
  let showsShortcutHints: Bool

  private var countLabels: [String] {
    [
      "\(String(localized: "All")) (\(allCount))",
      "\(String(localized: "Pinned")) (\(pinnedCount))",
    ]
  }

  private var shortcutLabels: [String] {
    ["\(String(localized: "All")) ⌘⇧[", "\(String(localized: "Pinned")) ⌘⇧]"]
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: countLabels, trackingMode: .selectOne,
      target: context.coordinator, action: #selector(Coordinator.selectTab(_:)))
    control.segmentStyle = .automatic
    control.segmentDistribution = .fillEqually
    control.setAccessibilityLabel(String(localized: "Tab"))
    control.setToolTip("⌘⇧[", forSegment: 0)
    control.setToolTip("⌘⇧]", forSegment: 1)
    updateNSView(control, context: context)
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.selection = $selection
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    control.font = font
    let widest =
      (countLabels + shortcutLabels)
      .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    let width = min((HistoryPanelLayout.listWidth - 24) / 2, ceil(widest + 24))
    let labels = showsShortcutHints ? shortcutLabels : countLabels
    for index in labels.indices {
      if control.label(forSegment: index) != labels[index] {
        control.setLabel(labels[index], forSegment: index)
      }
      if control.width(forSegment: index) != width {
        control.setWidth(width, forSegment: index)
      }
    }
    let selected = selection == .all ? 0 : 1
    if control.selectedSegment != selected { control.selectedSegment = selected }
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<HistoryPanelTab>

    init(selection: Binding<HistoryPanelTab>) { self.selection = selection }

    @objc func selectTab(_ sender: NSSegmentedControl) {
      guard (0..<2).contains(sender.selectedSegment) else { return }
      selection.wrappedValue = sender.selectedSegment == 0 ? .all : .pinned
    }
  }
}
