import ClipboardCore
import SwiftUI

struct KindChip: View {
  let label: LocalizedStringKey
  let icon: String?
  let count: Int
  let shortcut: String
  let showsShortcutHint: Bool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 3) {
        if let icon {
          Image(systemName: icon)
        }
        Text(label)
        // Both labels participate in layout so holding Command doesn't
        // move the chips, including when a count grows beyond two digits.
        ZStack(alignment: .trailing) {
          Text("\(count)")
            .monospacedDigit()
            .opacity(showsShortcutHint ? 0 : 1)
          Text(verbatim: shortcut)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .opacity(showsShortcutHint ? 1 : 0)
        }
        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
        .accessibilityHidden(true)
      }
      .font(.caption)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .background(
        isSelected
          ? AnyShapeStyle(Color.accentColor)
          : AnyShapeStyle(Color.clear)
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help(Text(label) + Text(verbatim: " · \(shortcut)"))
    .accessibilityLabel(label)
    .accessibilityHint(Text(verbatim: shortcut))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct KindChipBar: View {
  @Binding var selection: ClipKind?
  let count: (ClipKind?) -> Int
  var showsShortcutHints = false

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        chip(label: "All", icon: nil, value: nil, shortcut: "⌘1")
        chip(label: "Text", icon: "text.alignleft", value: .text, shortcut: "⌘2")
        chip(label: "Image", icon: "photo", value: .image, shortcut: "⌘3")
        chip(label: "File", icon: "doc", value: .file, shortcut: "⌘4")
        chip(label: "Rich", icon: "doc.richtext", value: .rtf, shortcut: "⌘5")
        chip(label: "Mixed", icon: "square.stack", value: .mixed, shortcut: "⌘6")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func chip(label: LocalizedStringKey, icon: String?, value: ClipKind?, shortcut: String)
    -> some View
  {
    KindChip(
      label: label,
      icon: icon,
      count: count(value),
      shortcut: shortcut,
      showsShortcutHint: showsShortcutHints,
      isSelected: selection == value
    ) {
      // Re-clicking a selected kind clears it; otherwise pick it.
      if selection == value {
        selection = nil
      } else {
        selection = value
      }
    }
  }
}
