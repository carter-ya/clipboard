import AppKit
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
  var onCheckForUpdates: () -> Void = {}
  var canCheckForUpdates: Bool = false
  var hotkeyMissing: Bool = false

  @State private var selectedTab: PreferencesTab = .general

  private enum PreferencesTab: Hashable {
    case general, shortcuts, ai, privacy, data
  }

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

  /// Read-only mirror of the panel-internal shortcuts wired in
  /// HistoryPanelView.keyboardShortcutButtons. Kept hand-curated
  /// because those bindings are SwiftUI literals; if you add or
  /// rebind one there, mirror it here.
  private let inPanelShortcuts: [(keys: String, label: LocalizedStringKey)] = [
    ("↵", "Copy"),
    ("↑↓", "Select"),
    ("Esc", "Close"),
    ("⌘P", "Pin"),
    ("⌘⌫", "Delete"),
    ("⌘,", "Preferences"),
    ("⌘⇧[", "Previous tab"),
    ("⌘⇧]", "Next tab"),
    ("⌘1", "All"),
    ("⌘2", "Text"),
    ("⌘3", "Image"),
    ("⌘4", "File"),
    ("⌘5", "Rich Text"),
    ("⌘6", "Mixed"),
  ]

  var body: some View {
    TabView(selection: $selectedTab) {
      general
        .tabItem { Label("General", systemImage: "gear") }
        .tag(PreferencesTab.general)
      shortcuts
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        .tag(PreferencesTab.shortcuts)
      ai
        .tabItem { Label("AI", systemImage: "sparkles") }
        .tag(PreferencesTab.ai)
      privacy
        .tabItem { Label("Privacy", systemImage: "lock") }
        .tag(PreferencesTab.privacy)
      data
        .tabItem { Label("Data", systemImage: "tray.and.arrow.up") }
        .tag(PreferencesTab.data)
    }
    // Reserve the 28pt title bar area with padding so interactive
    // content stays below it. A Color.clear spacer (used previously)
    // was suspected of interfering with the NSPopUpButton hit-test
    // under SwiftUI Picker, which is why we use padding instead.
    .padding(.top, 28)
    .frame(width: 520, height: 408)
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      Divider().padding(.top, 28)
    }
    .onAppear {
      // Land users on Shortcuts tab when no global hotkey is bound,
      // so the recorder + warning are visible without an extra click.
      if hotkeyMissing { selectedTab = .shortcuts }
    }
  }

  private var general: some View {
    Form {
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
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
              if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
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
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
              if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
            Text("MiB")
              .foregroundStyle(.secondary)
          }
          Text("Set to 0 to disable the size cap.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section("Updates") {
        HStack {
          Button(action: onCheckForUpdates) {
            Label("Check for Updates…", systemImage: "arrow.down.circle")
          }
          .disabled(!canCheckForUpdates)
          Spacer()
          Text("v\(appVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !canCheckForUpdates {
          Text("Automatic updates are not configured in this build.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var ai: some View {
    Form {
      Section("AI Summaries") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "Enable AI summaries",
            isOn: Binding(
              get: { prefs.summariesEnabled },
              set: {
                prefs.summariesEnabled = $0
                onSave(prefs)
              }
            )
          )
          Toggle(
            "Summarize images",
            isOn: Binding(
              get: { prefs.allowImageSummaries },
              set: {
                prefs.allowImageSummaries = $0
                onSave(prefs)
              }
            )
          )
          .disabled(!prefs.summariesEnabled || !AICapability.isVisionAvailable)
          Toggle(
            "Summarize text",
            isOn: Binding(
              get: { prefs.allowTextSummaries },
              set: {
                prefs.allowTextSummaries = $0
                onSave(prefs)
              }
            )
          )
          .disabled(
            !prefs.summariesEnabled
              || !(AICapability.isNaturalLanguageAvailable
                || AICapability.isFoundationModelsAvailable)
          )
          Toggle(
            "Summarize files",
            isOn: Binding(
              get: { prefs.allowFileSummaries },
              set: {
                prefs.allowFileSummaries = $0
                onSave(prefs)
              }
            )
          )
          .disabled(!prefs.summariesEnabled || !AICapability.isFoundationModelsAvailable)
          aiCapabilityCaption
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var appVersion: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? "?"
  }

  @ViewBuilder
  private var aiCapabilityCaption: some View {
    // When FM is unavailable show two lines: the user-visible impact
    // (which toggles will or won't produce output) on the first line,
    // and the technical reason on the second line for support / dev
    // diagnosis. Image summaries always work via Vision and need no
    // mention here.
    VStack(alignment: .leading, spacing: 4) {
      if let reason = AICapability.foundationModelsUnavailableReason {
        Text("File summaries are disabled; text summaries fall back to a keyword list.")
        (Text("Foundation Models unavailable — ") + Text(reason))
      } else {
        Text("Text and file summaries run on the on-device LLM.")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var shortcuts: some View {
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
      Section("Global") {
        HStack {
          Text("Toggle panel")
          Spacer()
          HotkeyRecorder(name: .toggleHistoryPanel)
        }
      }
      Section("In panel") {
        ForEach(inPanelShortcuts, id: \.keys) { row in
          HStack {
            Text(row.label)
            Spacer()
            ReadOnlyShortcutChip(keys: row.keys)
          }
        }
      }
      Section {
        Text("In-panel shortcuts only work while the history panel is focused.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var privacy: some View {
    Form {
      Section("Sensitive content") {
        Toggle(
          "Mask sensitive items",
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
        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "Enable blocklist",
            isOn: Binding(
              get: { prefs.blocklistEnabled },
              set: {
                prefs.blocklistEnabled = $0
                onSave(prefs)
              }
            )
          )
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
          .disabled(!prefs.blocklistEnabled)
          .opacity(prefs.blocklistEnabled ? 1.0 : 0.55)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  /// Read-only key combo chip used by the Shortcuts tab. Visually
  /// matches HotkeyRecorder's idle (non-recording) state so the
  /// editable global recorder and the static in-panel rows read as
  /// one family.
  private struct ReadOnlyShortcutChip: View {
    let keys: String

    var body: some View {
      Text(keys)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 110)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.06))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
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
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

}
