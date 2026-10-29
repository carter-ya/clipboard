import AppKit
import ClipboardCore
import SwiftUI

/// Explicit segment widths avoid Form-dependent first-layout sizing.
struct AppearancePicker: NSViewRepresentable {
  @Binding var selection: AppAppearance

  private var labels: [String] {
    [String(localized: "Follow System"), String(localized: "Light"), String(localized: "Dark")]
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  func makeNSView(context: Context) -> Container {
    let control = NSSegmentedControl(
      labels: labels, trackingMode: .selectOne,
      target: context.coordinator, action: #selector(Coordinator.selectAppearance(_:)))
    control.segmentStyle = .automatic
    control.segmentDistribution = .fillEqually
    control.setAccessibilityLabel(String(localized: "Appearance"))
    let container = Container(control: control)
    updateNSView(container, context: context)
    return container
  }

  func updateNSView(_ container: Container, context: Context) {
    let control = container.control
    context.coordinator.selection = $selection
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    control.font = font
    let widest =
      labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    let width = ceil(widest + 16)
    for index in labels.indices {
      if control.label(forSegment: index) != labels[index] {
        control.setLabel(labels[index], forSegment: index)
      }
      if control.width(forSegment: index) != width {
        control.setWidth(width, forSegment: index)
      }
    }
    let selected = AppAppearance.allCases.firstIndex(of: selection) ?? 0
    if control.selectedSegment != selected { control.selectedSegment = selected }
    container.updateWidth(width * CGFloat(labels.count))
  }

  @MainActor
  final class Container: NSView {
    let control: NSSegmentedControl
    private var preferredWidth: CGFloat = 0

    init(control: NSSegmentedControl) {
      self.control = control
      super.init(frame: .zero)
      addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unavailable") }

    override var intrinsicContentSize: NSSize {
      NSSize(width: preferredWidth, height: control.intrinsicContentSize.height)
    }

    func updateWidth(_ width: CGFloat) {
      if preferredWidth != width {
        preferredWidth = width
        invalidateIntrinsicContentSize()
      }
      // The Form sizes this container, not the native control. This
      // avoids adding native alignment insets again on theme/layout updates.
      control.frame = NSRect(origin: .zero, size: intrinsicContentSize)
    }

    override func layout() {
      super.layout()
      control.frame = NSRect(origin: .zero, size: intrinsicContentSize)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<AppAppearance>

    init(selection: Binding<AppAppearance>) { self.selection = selection }

    @objc func selectAppearance(_ sender: NSSegmentedControl) {
      guard AppAppearance.allCases.indices.contains(sender.selectedSegment) else { return }
      selection.wrappedValue = AppAppearance.allCases[sender.selectedSegment]
    }
  }
}
