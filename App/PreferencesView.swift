import ClipboardCore
import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
  @State var prefs: Preferences
  var onSave: (Preferences) -> Void
  var onClearHistory: () -> Void
  var onExportHistory: () -> Void

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
      Section("Hotkey") {
        KeyboardShortcuts.Recorder("Toggle panel", name: .toggleHistoryPanel)
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
