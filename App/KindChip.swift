import ClipboardCore
import SwiftUI

struct KindChip: View {
  let label: String
  let icon: String?
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let icon {
          Image(systemName: icon)
        }
        Text(label)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        isSelected
          ? AnyShapeStyle(Color.accentColor)
          : AnyShapeStyle(Color.secondary.opacity(0.18))
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct KindChipBar: View {
  @Binding var selection: ClipKind?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(label: "All", icon: nil, value: nil)
        chip(label: "Text", icon: "text.alignleft", value: .text)
        chip(label: "Image", icon: "photo", value: .image)
        chip(label: "File", icon: "doc", value: .file)
        chip(label: "Rich", icon: "doc.richtext", value: .rtf)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func chip(label: String, icon: String?, value: ClipKind?) -> some View {
    KindChip(
      label: label,
      icon: icon,
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
