import SwiftUI

struct OnboardingView: View {
  var onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "doc.on.clipboard")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
      Text("Welcome to Clipboard")
        .font(.title2)
        .bold()
      VStack(alignment: .leading, spacing: 8) {
        bullet("⌥⌘V", "open the history panel from anywhere")
        bullet("↵", "copy the selected item back to the clipboard")
        bullet("⌘V", "paste it manually into any app")
        bullet("🎯", "sensitive content (password managers) stays in memory only")
      }
      .padding(.horizontal)
      Button("Got it", action: onDismiss)
        .keyboardShortcut(.defaultAction)
    }
    .padding(24)
    .frame(width: 420)
  }

  private func bullet(_ symbol: String, _ description: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(symbol)
        .frame(width: 52, alignment: .leading)
        .font(.system(.body, design: .monospaced))
      Text(description)
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }
}
