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

  // Remote AI tab — API key local UI state. The key itself never
  // leaves the SecureField; on Save we hand it to Keychain and clear
  // the field. `keyPresent` mirrors `RemoteAICredentials.hasKey(...)`
  // and is refreshed `.onAppear` and after every save / remove so the
  // UI stays in sync without polling.
  @State private var apiKeyDraft: String = ""
  @State private var keyPresent: Bool = false
  @State private var isReplacingKey: Bool = false

  // Remote AI tab — Test connection state. Cancelled on disappear.
  @State private var testTask: Task<Void, Never>?
  @State private var testState: TestConnectionState = .idle

  enum TestConnectionState: Equatable {
    case idle
    case testing
    case ok
    case authFailed(detail: String?)
    case notFound
    case serverError(code: Int, detail: String?)
    case network
    case badResponse
  }

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
      remoteAISection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear { refreshKeyPresent() }
    .onDisappear {
      testTask?.cancel()
      testTask = nil
    }
  }

  // MARK: - Remote AI section

  /// "Remote AI (OpenAI-compatible)" Section under the AI tab.
  /// All controls (incl. Save / Replace / Remove / Test) are gated
  /// behind `summariesEnabled && remoteAIEnabled`, except the master
  /// toggle itself (which is gated only on `summariesEnabled`) and the
  /// privacy caption (always visible so users can read the policy
  /// before opting in).
  @ViewBuilder
  private var remoteAISection: some View {
    let remoteEnabled = prefs.summariesEnabled && prefs.remoteAIEnabled
    let validatedURL = validateRemoteAIBaseURL(prefs.remoteAIBaseURL ?? "")
    let baseURLText = prefs.remoteAIBaseURL ?? ""
    let baseURLInvalid = !baseURLText.isEmpty && validatedURL == nil

    Section("remoteAI.section.title") {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "remoteAI.toggle.title",
            isOn: Binding(
              get: { prefs.remoteAIEnabled },
              set: {
                prefs.remoteAIEnabled = $0
                onSave(prefs)
              }
            )
          )
          .disabled(!prefs.summariesEnabled)
          Text("remoteAI.toggle.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("remoteAI.baseURL.label")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "",
            text: Binding(
              get: { prefs.remoteAIBaseURL ?? "" },
              set: { newValue in
                let trimmed = newValue
                prefs.remoteAIBaseURL = trimmed.isEmpty ? nil : trimmed
                onSave(prefs)
                refreshKeyPresent()
              }
            ),
            prompt: Text("remoteAI.baseURL.placeholder")
          )
          .textFieldStyle(.roundedBorder)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Color.red, lineWidth: baseURLInvalid ? 1 : 0)
          )
          if baseURLInvalid {
            Text("remoteAI.baseURL.invalid")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        .disabled(!remoteEnabled)

        VStack(alignment: .leading, spacing: 4) {
          Text("remoteAI.model.label")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "",
            text: Binding(
              get: { prefs.remoteAIModel ?? "" },
              set: { newValue in
                prefs.remoteAIModel = newValue.isEmpty ? nil : newValue
                onSave(prefs)
              }
            ),
            prompt: Text("remoteAI.model.placeholder")
          )
          .textFieldStyle(.roundedBorder)
        }
        .disabled(!remoteEnabled)

        apiKeyRow(remoteEnabled: remoteEnabled, validatedURL: validatedURL)

        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "remoteAI.allowImages.title",
            isOn: Binding(
              get: { prefs.remoteAIAllowImages },
              set: {
                prefs.remoteAIAllowImages = $0
                onSave(prefs)
              }
            )
          )
          .disabled(!remoteEnabled)
          if prefs.remoteAIAllowImages {
            Text("remoteAI.allowImages.caption")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        testConnectionRow(validatedURL: validatedURL)

        Text("remoteAI.privacy.caption")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// API Key row. Two presentations:
  /// - No key in Keychain: SecureField + "Save" button. Save is
  ///   disabled until the base URL validates, since the Keychain
  ///   account is the canonicalised URL — saving against an invalid
  ///   URL would orphan the entry.
  /// - Key already saved: masked label + "Replace…" + "Remove".
  ///   "Replace…" flips local UI state to show the SecureField again
  ///   without touching Keychain (so the user can cancel by entering
  ///   nothing and never pressing Save).
  @ViewBuilder
  private func apiKeyRow(remoteEnabled: Bool, validatedURL: URL?) -> some View {
    let canSaveKey = remoteEnabled && validatedURL != nil
    let showSecure = !keyPresent || isReplacingKey
    VStack(alignment: .leading, spacing: 4) {
      Text("remoteAI.apiKey.label")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("remoteAI.apiKey.optional")
        .font(.caption)
        .foregroundStyle(.secondary)
      if showSecure {
        HStack(spacing: 8) {
          SecureField(
            "",
            text: $apiKeyDraft,
            prompt: Text("remoteAI.apiKey.label")
          )
          .textFieldStyle(.roundedBorder)
          Button("Save") {
            saveAPIKey(validatedURL: validatedURL)
          }
          .disabled(!canSaveKey)
        }
      } else {
        HStack(spacing: 8) {
          Text("remoteAI.apiKey.masked")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
          Spacer()
          Button("remoteAI.apiKey.replace") {
            isReplacingKey = true
            apiKeyDraft = ""
          }
          Button("remoteAI.apiKey.remove") {
            removeAPIKey(validatedURL: validatedURL)
          }
        }
      }
    }
    .disabled(!remoteEnabled)
  }

  /// Test-connection button + result text.
  /// Enable rule (`canTest`) is computed locally without a Keychain
  /// hit per plan v4 S1: missing key just falls through to a 401 in
  /// the request which surfaces as `.authFailed`.
  @ViewBuilder
  private func testConnectionRow(validatedURL: URL?) -> some View {
    let canTest =
      prefs.remoteAIEnabled
      && prefs.summariesEnabled
      && validatedURL != nil
      && !(prefs.remoteAIModel ?? "").isEmpty
    HStack(spacing: 8) {
      Button("remoteAI.test.button") {
        startTestConnection(validatedURL: validatedURL)
      }
      .disabled(!canTest || testState == .testing)
      testStateLabel
    }
  }

  @ViewBuilder
  private var testStateLabel: some View {
    switch testState {
    case .idle:
      EmptyView()
    case .testing:
      Text("remoteAI.test.testing")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .ok:
      Text("remoteAI.test.ok")
        .font(.caption)
        .foregroundStyle(.green)
    case .authFailed(let detail):
      if let d = detail, !d.isEmpty {
        Text(
          String(
            format: NSLocalizedString("remoteAI.test.authFailedWithDetail", comment: ""),
            d
          )
        )
        .font(.caption)
        .foregroundStyle(.red)
      } else {
        Text("remoteAI.test.authFailed")
          .font(.caption)
          .foregroundStyle(.red)
      }
    case .notFound:
      Text("remoteAI.test.notFound")
        .font(.caption)
        .foregroundStyle(.red)
    case .serverError(let code, let detail):
      if let d = detail, !d.isEmpty {
        Text(
          String(
            format: NSLocalizedString("remoteAI.test.serverErrorWithDetail", comment: ""),
            code,
            d
          )
        )
        .font(.caption)
        .foregroundStyle(.red)
      } else {
        Text(
          String(
            format: NSLocalizedString("remoteAI.test.serverError", comment: ""),
            code
          )
        )
        .font(.caption)
        .foregroundStyle(.red)
      }
    case .network, .badResponse:
      // .badResponse folds into the network message: from the user's
      // perspective the endpoint is reachable but unusable, which is
      // indistinguishable from a network failure for diagnosis.
      Text("remoteAI.test.network")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  // MARK: - Remote AI helpers

  /// Recompute `keyPresent` from Keychain. Cheap (microseconds);
  /// fine to run on the main thread per plan note.
  private func refreshKeyPresent() {
    if let url = validateRemoteAIBaseURL(prefs.remoteAIBaseURL ?? "") {
      keyPresent = RemoteAICredentials.hasKey(baseURL: url.absoluteString)
    } else {
      keyPresent = false
    }
  }

  private func saveAPIKey(validatedURL: URL?) {
    guard let url = validatedURL else { return }
    let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      // Treat trimmed-empty (or blank-only) input as a no-op: don't
      // write a `Bearer    ` 401 to Keychain, and don't delete an
      // existing key. Removing requires the explicit Remove button.
      apiKeyDraft = ""
      isReplacingKey = false
      refreshKeyPresent()
      return
    }
    try? RemoteAICredentials.save(trimmed, baseURL: url.absoluteString)
    apiKeyDraft = ""
    isReplacingKey = false
    refreshKeyPresent()
  }

  private func removeAPIKey(validatedURL: URL?) {
    guard let url = validatedURL else { return }
    try? RemoteAICredentials.delete(baseURL: url.absoluteString)
    apiKeyDraft = ""
    isReplacingKey = false
    refreshKeyPresent()
  }

  /// Build a one-shot ephemeral session and POST a tiny chat
  /// completion (`max_tokens=4`) to surface auth / network / model
  /// errors quickly. State writes happen via `MainActor.run` because
  /// the Task body is `nonisolated`.
  private func startTestConnection(validatedURL: URL?) {
    guard let url = validatedURL else { return }
    let model = prefs.remoteAIModel ?? ""
    guard !model.isEmpty else { return }
    testTask?.cancel()
    testState = .testing
    testTask = Task {
      let cfg = URLSessionConfiguration.ephemeral
      cfg.httpAdditionalHeaders = [:]
      cfg.httpCookieAcceptPolicy = .never
      cfg.httpShouldSetCookies = false
      cfg.urlCache = nil
      cfg.waitsForConnectivity = true
      cfg.timeoutIntervalForRequest = 5
      cfg.timeoutIntervalForResource = 5
      let session = URLSession(configuration: cfg)
      let endpoint = url.appendingPathComponent("chat/completions")

      // Key is now optional — local OpenAI-compatible servers (Ollama,
      // vLLM default) accept unauthenticated requests. If present, we
      // attach Authorization; if absent, we let the server respond and
      // surface its actual status (200, 401, 404, ...).
      let key = RemoteAICredentials.read(baseURL: url.absoluteString)

      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let k = key, !k.isEmpty {
        request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
      }
      let body = RemoteOpenAIRequest(
        model: model,
        messages: buildRemoteOpenAITextMessages("reply OK"),
        maxTokens: 4,
        temperature: 0
      )
      do {
        request.httpBody = try JSONEncoder().encode(body)
      } catch {
        await MainActor.run { testState = .badResponse }
        return
      }

      let result: TestConnectionState
      do {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          result = .badResponse
          await MainActor.run { testState = result }
          return
        }
        switch http.statusCode {
        case 200:
          result = .ok
        case 404:
          result = .notFound
        case 401, 403:
          // Detail is shown only here in the UI — never logged
          // (must_not exception in harness.json).
          result = .authFailed(detail: parseRemoteOpenAIErrorBody(data))
        case let code where (400..<600).contains(code):
          result = .serverError(code: code, detail: parseRemoteOpenAIErrorBody(data))
        default:
          result = .badResponse
        }
      } catch is CancellationError {
        return
      } catch _ as URLError {
        // Covers timeout / DNS / connection refused / TLS — folded
        // into a single "network" state per plan v4 N3.
        await MainActor.run { testState = .network }
        return
      } catch {
        await MainActor.run { testState = .badResponse }
        return
      }
      await MainActor.run { testState = result }
    }
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
