import AppKit
import KeyboardShortcuts
import SwiftUI

/// SwiftUI shortcut recorder that uses KeyboardShortcuts storage but
/// renders a container matching the rest of the glass Preferences:
/// rounded-6 rect with primary/0.06 fill and primary/0.10 stroke, or
/// accent-stroked while recording. Bypasses the library's own
/// NSSearchField-style recorder, which can't be restyled from SwiftUI.
struct HotkeyRecorder: View {
  let name: KeyboardShortcuts.Name

  @State private var isRecording = false
  @State private var shortcutText: String = ""
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 4) {
      Text(displayText)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(foreground)
      if !shortcutText.isEmpty, !isRecording {
        Button(action: clear) {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear shortcut")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(minWidth: 110)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.primary.opacity(isRecording ? 0.10 : 0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(
          isRecording ? Color.accentColor : Color.primary.opacity(0.10),
          lineWidth: isRecording ? 1 : 0.5
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onTapGesture { toggle() }
    .onAppear { refresh() }
    .onDisappear { stop() }
    .accessibilityAddTraits(.isButton)
  }

  private var displayText: String {
    if isRecording { return "Recording…" }
    if shortcutText.isEmpty { return "None" }
    return shortcutText
  }

  private var foreground: Color {
    if isRecording || shortcutText.isEmpty { return .secondary }
    return .primary
  }

  private func refresh() {
    shortcutText = KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
  }

  private func toggle() {
    if isRecording { stop() } else { start() }
  }

  private func start() {
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Esc cancels without mutating the stored shortcut.
      if event.keyCode == 53 {
        stop()
        return nil
      }
      let mods = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .function, .numericPad, .help])
      // Require at least one modifier so bare letters can't be bound.
      if mods.isEmpty {
        NSSound.beep()
        return nil
      }
      if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        refresh()
      }
      stop()
      return nil
    }
  }

  private func stop() {
    if let m = monitor {
      NSEvent.removeMonitor(m)
      monitor = nil
    }
    isRecording = false
  }

  private func clear() {
    KeyboardShortcuts.setShortcut(nil, for: name)
    refresh()
  }
}
