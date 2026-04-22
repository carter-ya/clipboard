import ClipboardCore
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
  var onApplyLanguage: (String?) -> Void = { _ in }
  var hotkeyMissing: Bool = false

  private let languageOptions: [(tag: String, label: String)] = [
    ("system", "System"),
    ("en", "English"),
    ("zh-Hans", "简体中文"),
    ("zh-Hant", "繁體中文"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("de", "Deutsch"),
    ("es", "Español"),
  ]

  private let capRange: ClosedRange<Int> = 20...2000

  var body: some View {
    TabView {
      general
        .tabItem { Label("General", systemImage: "gear") }
      privacy
        .tabItem { Label("Privacy", systemImage: "lock") }
      data
        .tabItem { Label("Data", systemImage: "tray.and.arrow.up") }
    }
    .frame(width: 520, height: 408)
    .background(.regularMaterial, ignoresSafeAreaEdges: .all)
    .safeAreaInset(edge: .top, spacing: 0) { Divider() }
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
        HStack {
          Text("Toggle panel")
          Spacer()
          HotkeyRecorder(name: .toggleHistoryPanel)
        }
      }
      Section("Language") {
        Picker(
          "Language",
          selection: Binding(
            get: { prefs.languageOverride ?? "system" },
            set: { code in
              let newValue = code == "system" ? nil : code
              prefs.languageOverride = newValue
              // Defer side effects until the Picker has fully dismissed.
              // Running them synchronously inside the set closure blocks
              // SwiftUI's response chain and cascades UserDefaults +
              // Monitor rebuilds mid-animation, which can leave the
              // Preferences window unresponsive and briefly starve the
              // global hotkey's event tap.
              let snapshot = prefs
              DispatchQueue.main.async {
                onSave(snapshot)
                onApplyLanguage(newValue)
              }
            }
          )
        ) {
          ForEach(languageOptions, id: \.tag) { option in
            Text(option.label).tag(option.tag)
          }
        }
        .labelsHidden()
        Text("Language changes apply after the next launch.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Cap")
            Spacer()
            TextField(
              "",
              value: Binding(
                get: { prefs.cap },
                set: { newValue in
                  prefs.cap = min(capRange.upperBound, max(capRange.lowerBound, newValue))
                  onSave(prefs)
                }
              ),
              format: .number
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 80)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
          }
          HStack {
            Text("Skip items larger than")
            Spacer()
            TextField(
              "",
              value: Binding(
                get: { Double(prefs.maxClipSizeBytes) / (1024 * 1024) },
                set: { newMiB in
                  let bounded = max(0, newMiB)
                  prefs.maxClipSizeBytes = Int(bounded * 1024 * 1024)
                  onSave(prefs)
                }
              ),
              format: .number.precision(.fractionLength(0...1))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 80)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            Text("MiB")
              .foregroundStyle(.secondary)
          }
          Text("Set to 0 to disable the size cap.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(6)
        .frame(height: 140)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.06))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

}
