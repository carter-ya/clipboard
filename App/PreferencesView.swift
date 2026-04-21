import ClipboardCore
import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
  @State var prefs: Preferences
  var onSave: (Preferences) -> Void
  var onClearHistory: () -> Void
  var onExportHistory: () -> Void
  var onImportHistory: () -> Void = {}
  /// Returns true on success. Failure path tells the view to roll
  /// back the local `prefs.launchAtLogin` value.
  var onApplyLaunchAtLogin: (Bool) -> Bool = { _ in true }
  var hotkeyMissing: Bool = false

  private let capRange: ClosedRange<Double> = 20...2000
  private let sizeRange: ClosedRange<Double> = 0...(100 * 1024 * 1024)

  var body: some View {
    TabView {
      general
        .tabItem { Label("General", systemImage: "gear") }
      privacy
        .tabItem { Label("Privacy", systemImage: "lock") }
      data
        .tabItem { Label("Data", systemImage: "tray.and.arrow.up") }
    }
    .frame(width: 520, height: 380)
    .padding()
  }

  private var general: some View {
    Form {
      if hotkeyMissing {
        Section {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
              Text("No shortcut is set")
                .font(.caption)
              Text("Record a shortcut below — the panel can't be summoned without one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("Hotkey") {
        KeyboardShortcuts.Recorder("Toggle panel", name: .toggleHistoryPanel)
      }
      Section("Startup") {
        Toggle(
          "Start at Login",
          isOn: Binding(
            get: { prefs.launchAtLogin },
            set: { newValue in
              let old = prefs.launchAtLogin
              prefs.launchAtLogin = newValue
              if !onApplyLaunchAtLogin(newValue) {
                // Roll back the UI if the system rejected the change.
                prefs.launchAtLogin = old
                return
              }
              onSave(prefs)
            }
          )
        )
        Text("Clipboard launches in the background when you log in.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Retention") {
        HStack {
          Text("Cap")
          Slider(
            value: Binding(
              get: { Double(prefs.cap) },
              set: {
                prefs.cap = Int($0)
                onSave(prefs)
              }
            ),
            in: capRange,
            step: 10
          )
          Text("\(prefs.cap)")
            .monospacedDigit()
            .frame(width: 50, alignment: .trailing)
        }
        HStack {
          Text("Skip items larger than")
          Slider(
            value: Binding(
              get: { Double(prefs.maxClipSizeBytes) },
              set: {
                prefs.maxClipSizeBytes = Int($0)
                onSave(prefs)
              }
            ),
            in: sizeRange,
            step: 1024 * 1024
          )
          Text(sizeLabel)
            .monospacedDigit()
            .frame(width: 80, alignment: .trailing)
        }
        Text("Set to 0 to disable the size cap.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var privacy: some View {
    Form {
      Section("Sensitive content") {
        Toggle(
          "Skip items marked as concealed (password managers)",
          isOn: Binding(
            get: { prefs.skipSensitive },
            set: {
              prefs.skipSensitive = $0
              onSave(prefs)
            }
          )
        )
      }
      Section("Blocked source apps (bundle IDs, one per line)") {
        TextEditor(
          text: Binding(
            get: { prefs.blockedBundleIDs.joined(separator: "\n") },
            set: { text in
              prefs.blockedBundleIDs =
                text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
              onSave(prefs)
            }
          )
        )
        .frame(height: 140)
        .font(.system(.body, design: .monospaced))
      }
    }
  }

  private var data: some View {
    Form {
      Section("History data") {
        Button(action: onExportHistory) {
          Label("Export history…", systemImage: "square.and.arrow.up")
        }
        Button(action: onImportHistory) {
          Label("Import history…", systemImage: "square.and.arrow.down")
        }
        Button(role: .destructive, action: onClearHistory) {
          Label("Clear history…", systemImage: "trash")
        }
      }
      Text("Sensitive items are never exported or written to disk.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var sizeLabel: String {
    if prefs.maxClipSizeBytes == 0 { return "off" }
    let mb = Double(prefs.maxClipSizeBytes) / (1024 * 1024)
    return String(format: "%.0f MiB", mb)
  }
}
