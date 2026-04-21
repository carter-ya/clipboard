import SwiftUI

/// A compact "⌘P Pin" style hint used in the panel footer bar.
/// Keys render as a tiny monospaced chip with a rounded gray
/// background; the label is plain secondary text next to it.
struct ShortcutHint: View {
  let keys: String
  let label: String

  var body: some View {
    HStack(spacing: 4) {
      Text(keys)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.18))
        )
      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(keys) \(label)")
  }
}
