import SwiftUI

/// A compact "⌘P Pin" style hint used in the panel footer bar.
/// Keys render as a tiny monospaced chip with a rounded gray
/// background; the label is plain secondary text next to it.
struct ShortcutHint: View {
  let keys: String
  let label: LocalizedStringKey

  var body: some View {
    HStack(spacing: 4) {
      Text(keys)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(keys) ") + Text(label))
  }
}
