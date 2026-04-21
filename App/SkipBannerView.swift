import ClipboardCore
import SwiftUI

struct SkipBannerView: View {
  let skip: SkipEvent
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(primaryMessage)
          .font(.caption)
          .foregroundStyle(.primary)
        Text("Raise the limit in Preferences if you need larger items.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.15))
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundStyle(Color.orange.opacity(0.35)),
      alignment: .bottom
    )
  }

  private var primaryMessage: String {
    let size = formatBytes(skip.bytes)
    if let source = skip.bundleID, !source.isEmpty {
      return "Skipped a \(size) item from \(source)"
    }
    return "Skipped a \(size) item"
  }

  private func formatBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useKB]
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
  }
}
