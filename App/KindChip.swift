import ClipboardCore
import SwiftUI

struct KindChip: View {
  let label: LocalizedStringKey
  let icon: String?
  let count: Int
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let icon {
          Image(systemName: icon)
        }
        Text(label)
        Text("\(count)")
          .monospacedDigit()
          .foregroundStyle(
            isSelected ? Color.white.opacity(0.7) : Color.secondary
          )
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        isSelected
          ? AnyShapeStyle(Color.accentColor)
          : AnyShapeStyle(Color.primary.opacity(0.06))
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .strokeBorder(
            isSelected ? Color.clear : Color.primary.opacity(0.10),
            lineWidth: 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct KindChipBar: View {
  @Binding var selection: ClipKind?
  let count: (ClipKind?) -> Int

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(label: "All", icon: nil, value: nil)
        chip(label: "Text", icon: "text.alignleft", value: .text)
        chip(label: "Image", icon: "photo", value: .image)
        chip(label: "File", icon: "doc", value: .file)
        chip(label: "Rich", icon: "doc.richtext", value: .rtf)
        chip(label: "Mixed", icon: "square.stack", value: .mixed)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func chip(label: LocalizedStringKey, icon: String?, value: ClipKind?)
    -> some View
  {
    KindChip(
      label: label,
      icon: icon,
      count: count(value),
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
