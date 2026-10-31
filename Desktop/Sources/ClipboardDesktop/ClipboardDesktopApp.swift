import ClipboardCore
import Foundation
import GtkBackend
import SwiftCrossUI

struct ClipboardDesktopApp: App {
  var backend: GtkBackend {
    let profile = DesktopApplicationContext.profile
    return GtkBackend(
      appIdentifier: profile == "production"
        ? "com.clipboard.desktop" : "com.clipboard.desktop.p" + String(profile.prefix(24)))
  }
  var body: some Scene {
    WindowGroup("Clipboard") {
      if DesktopApplicationContext.startupFailed {
        VStack(spacing: 16) {
          Text(
            DesktopLocalization.text("Clipboard could not safely open this profile.", language: nil)
          )
          Text(
            DesktopLocalization.text(
              "Close another instance or check the desktop session, then try again.", language: nil)
          )
          Button(DesktopLocalization.text("Quit", language: nil)) { exit(1) }
        }.padding(24)
      } else if CommandLine.arguments.contains("--ui-baseline") {
        BaselineView()
      } else {
        HistoryView()
      }
    }
    .defaultSize(width: 960, height: 640)
  }
}

struct HistoryView: View {
  @State var model = HistoryModel()
  @State var showsCompactFilters = false
  @State var archiveDirectory: URL?
  @Environment(\.openURL) var openURL
  @Environment(\.chooseFile) var chooseFile
  @Environment(\.chooseFileSaveDestination) var chooseSaveDestination

  var body: some View {
    GeometryReader { geometry in
      let viewportWidth = model.responsiveWidth(proposed: geometry.size.width)
      let compact = viewportWidth < 820
      let imageHeight = model.previewImageHeight(proposed: geometry.size.height)
      VStack(alignment: .leading, spacing: 12) {
        header(compact: compact)
        ScrollView {
          if model.showsSettings {
            settings
          } else {
            history(
              compact: compact, compactFilters: viewportWidth < 1100, imageHeight: imageHeight
            )
            .disabled(model.historyActivationBusy)
          }
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        if !model.showsSettings { itemActions }
        Divider()
        HStack {
          Text(model.t(model.status)).foregroundColor(.gray)
          Spacer()
          if !compact { Text(model.t("Local history")).foregroundColor(.gray) }
        }
      }.padding(compact ? 12 : 24)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
    .environment(\.colorScheme, model.effectiveDark ? .dark : .light)
    .inspectWindow { model.attachWindow($0) }
    .task { @MainActor in
      await model.load()
      // Fixture input only: keep the real native chooser/default-name path,
      // while its initial directory and untouched default save stay private.
      if archiveDirectory == nil && CommandLine.arguments.contains("--smoke-root") {
        archiveDirectory = DesktopApplicationContext.dataRoot
      }
    }
    .onChange(of: model.selectedID) { Task { @MainActor in await model.loadPreview() } }
  }

  func header(compact: Bool) -> some View {
    HStack {
      if compact {
        Text(model.t("Clipboard")).font(.system(size: 22))
      } else {
        title
      }
      Spacer()
      headerActions
    }
  }
  var title: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.t("Clipboard")).font(.system(size: 26))
      Text(model.t("Your clipboard history, on this device.")).foregroundColor(.gray)
    }
  }
  var headerActions: some View {
    HStack {
      Button(model.t(model.recording ? "Pause recording" : "Start recording")) {
        Task { @MainActor in await model.toggleRecording() }
      }.disabled(!model.ready || model.recordingTransition)
      if model.canHide { Button(model.t("Hide")) { model.hide() } }
      Button(model.t("Settings")) { model.showPreferences() }
    }
  }

  func history(compact: Bool, compactFilters: Bool, imageHeight: Double) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField(model.t("Search history"), text: $model.query)
        .inspect { model.attachSearch($0) }
        .onChange(of: model.query) { Task { @MainActor in await model.refresh() } }
      HStack(spacing: 10) {
        HStack(spacing: 4) {
          Button(model.t("All")) {
            Task { @MainActor in await model.selectTab(onlyPinned: false) }
          }
          countBadge(model.allItemsCount)
        }
        HStack(spacing: 4) {
          Button(model.t("Pinned")) {
            Task { @MainActor in await model.selectTab(onlyPinned: true) }
          }
          countBadge(model.pinnedItemsCount)
        }
        if compact {
          Button(model.t(showsCompactFilters ? "Hide filters" : "Filters")) {
            showsCompactFilters.toggle()
          }
        }
        Spacer()
        Text(model.t("\(model.items.count) items")).foregroundColor(.gray)
      }
      if !compact || showsCompactFilters {
        if compactFilters {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              allTypesButton
              typeButton(.text)
              typeButton(.rtf)
            }
            HStack(spacing: 8) {
              typeButton(.image)
              typeButton(.file)
              typeButton(.mixed)
              Spacer()
            }
          }
        } else {
          HStack(spacing: 8) {
            allTypesButton
            ForEach(ClipKind.allCases, id: \.self) { kind in
              typeButton(kind)
            }
          }
        }
        #if os(Linux)
          if ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] != nil {
            Text(
              model.t(
                "Wayland does not identify clipboard source apps. App exclusions cannot match unknown sources; sensitive hints still apply."
              )
            )
            .font(.system(size: 12)).foregroundColor(.gray)
          }
        #endif
        TextField(model.t("Source app ID (optional)"), text: $model.sourceFilter)
          .onChange(of: model.sourceFilter) { Task { @MainActor in await model.refresh() } }
      }
      Divider()
      if compact {
        VStack(alignment: .leading, spacing: 16) {
          historyItems.frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220)
          Divider()
          preview(imageHeight: imageHeight).frame(
            maxWidth: .infinity, minHeight: 200, maxHeight: 300)
        }
      } else {
        HStack(alignment: .top, spacing: 20) {
          historyItems.frame(minWidth: 300, maxWidth: 340, minHeight: 280, maxHeight: 360)
          Divider()
          preview(imageHeight: imageHeight).frame(
            minWidth: 340, maxWidth: .infinity, minHeight: 280, maxHeight: 360)
        }
      }
    }
  }
  func countBadge(_ count: Int) -> some View {
    Text("(\(count))").font(.system(size: 12)).foregroundColor(.gray)
      .lineLimit(1).frame(width: 44)
  }
  var allTypesButton: some View {
    HStack(spacing: 4) {
      Button(model.t("All types")) {
        Task { @MainActor in await model.selectKind(nil) }
      }.frame(minWidth: 104)
      countBadge(model.allTypesCount)
    }
  }
  func typeButton(_ kind: ClipKind) -> some View {
    HStack(spacing: 4) {
      Button(model.t(kind.rawValue.capitalized)) {
        Task { @MainActor in await model.selectKind(kind) }
      }.frame(minWidth: 96)
      countBadge(model.kindCounts[kind, default: 0])
    }
  }
  var historyItems: some View {
    let items = model.items
    let itemIDs = items.map(\.id)
    return ScrollView {
      List(items, selection: $model.selectedID) { item in
        VStack(alignment: .leading, spacing: 7) {
          Text(
            item.sensitive
              ? model.t("Sensitive content")
              : model.itemPresentations[item.id]?.rowText
                ?? DesktopTextPreview(item.preview, maxUTF8Bytes: 512).text
          ).lineLimit(2)
          Text(
            (item.pinned ? model.t("Pinned") + " · " : "") + model.t(item.kind.rawValue.capitalized)
              + (model.itemPresentations[item.id].map { " · " + $0.createdText } ?? "")
              + (model.itemPresentations[item.id]?.sourceName.map { " · " + $0 } ?? "")
          )
          .font(.system(size: 12)).foregroundColor(.gray).lineLimit(1)
        }.padding(10)
      }.inspect([.onCreate, .afterUpdate]) { list in
        model.attachHistoryList(list, itemIDs: itemIDs)
      }
    }
  }

  func preview(imageHeight: Double) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("Preview")).font(.system(size: 18))
      if let item = model.selected, let presentation = model.itemPresentations[item.id] {
        if let source = presentation.sourceName {
          Text(model.t("Source: ") + source).font(.system(size: 12)).foregroundColor(.gray)
            .lineLimit(1).help(
              DesktopTextPreview(item.sourceBundleID ?? "", maxUTF8Bytes: 4096).text)
        }
        Text(
          presentation.createdText + " · " + String(max(0, item.sizeBytes)) + " " + model.t("bytes")
        )
        .font(.system(size: 12)).foregroundColor(.gray).lineLimit(1)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if case .running(let remote)? = model.selectedAnalysisProgress {
            Text(
              model.t(
                remote
                  ? "Generating summary…"
                  : model.selected?.kind == .image ? "Recognizing text…" : "Creating local excerpt…"
              ))
          }
          if case .failed(let remote)? = model.selectedAnalysisProgress {
            Text(
              model.t(
                remote
                  ? "Could not generate a summary."
                  : model.selected?.kind == .image
                    ? "Could not recognize text." : "Could not create a local excerpt."))
            Button(
              model.t(
                remote
                  ? "Retry summary"
                  : model.selected?.kind == .image
                    ? "Retry text recognition" : "Retry local excerpt")
            ) {
              model.retryAnalysis()
            }.disabled(
              model.historyActivationBusy || model.analysisBusy || (remote && !model.canSummarize)
                || (!remote && model.selected?.kind != .image && !model.canSummarizeLocally))
          }
          if let summary = model.selected?.summary, model.selected?.sensitive != true {
            Text(
              model.t(
                model.selected?.summarySource == .localExtractive
                  ? "Local excerpt" : "OCR / AI result")
            ).font(.system(size: 14))
            Text(summary).frame(maxWidth: .infinity, alignment: .leading)
            Button(model.t("Copy result")) {
              Task { @MainActor in await model.copyAnalysisResult() }
            }
          }
          if let image = model.previewImage {
            DesktopImagePreview(image: image, accessibilityLabel: model.t("Image preview")).frame(
              minWidth: 250, maxWidth: .infinity, maxHeight: imageHeight)
          }
          if let count = model.previewFileCount {
            Text(model.t("Files") + ": " + String(count)).font(.system(size: 12)).foregroundColor(
              .gray)
            ForEach(
              Array(model.previewText.components(separatedBy: "\n").enumerated()), id: \.offset
            ) { entry in
              Text(entry.element).frame(maxWidth: .infinity, alignment: .leading)
            }
          } else {
            DesktopTextPreviewView(
              text: model.canRevealSensitivePreview
                ? model.t("Sensitive content is hidden.")
                : (model.previewMessage.map { model.t($0) } ?? model.previewText)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if model.canRevealSensitivePreview {
            Button(model.t("Reveal for this session")) {
              Task { @MainActor in await model.revealSensitivePreview() }
            }
          }
          if model.previewTruncated {
            Text(
              model.t(
                model.previewFileCount == nil
                  ? "Preview truncated. Copy keeps the full text."
                  : "File list truncated. Copy keeps every original file reference.")
            )
            .font(.system(size: 12)).foregroundColor(.gray)
          }

        }
      }.frame(minHeight: 100, maxHeight: 180)
      Text(model.t("Copy here, then paste in your app."))
        .font(.system(size: 12)).foregroundColor(.gray)
    }
  }

  var itemActions: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Button(model.t("Copy")) { Task { @MainActor in await model.copySelected() } }.disabled(
          model.historyActivationBusy || model.selected == nil)
        Button(model.t("Pin / unpin")) { Task { @MainActor in await model.togglePin() } }
          .disabled(model.historyActivationBusy || model.selected == nil)
        Button(model.t("Delete")) { Task { @MainActor in await model.deleteSelected() } }
          .disabled(model.historyActivationBusy || model.selected == nil)
      }
      if model.selected?.kind == .image || model.canSummarize || model.canSummarizeLocally {
        HStack(spacing: 10) {
          Button(model.t("Recognize text")) { model.analyze(remote: false) }
            .disabled(
              model.historyActivationBusy || model.selected?.kind != .image
                || model.selected?.sensitive == true
                || model.analysisBusy)
          if model.canSummarizeLocally {
            Button(model.t("Summarize locally")) { model.analyze(remote: false) }
              .disabled(model.historyActivationBusy || model.analysisBusy)
          }
          Button(model.t("Summarize")) { model.analyze(remote: true) }
            .disabled(model.historyActivationBusy || !model.canSummarize || model.analysisBusy)
        }
      }
    }
  }

  var contentSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("History capacity (1–5000)"))
      TextField(model.t("100"), text: $model.capacityDraft)
      Text(model.t("Maximum clipboard item (MiB)"))
      TextField(model.t("10"), text: $model.maxSizeDraft)
      Text(
        model.t(
          "0 disables size filtering. Use a dot for decimals. Clipboard transfers remain limited to 16 MiB."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
      Toggle(model.t("Mark blocked source apps as sensitive"), isOn: $model.blocklistEnabledDraft)
      TextField(model.t("Blocked app IDs, separated by commas"), text: $model.blockedAppsDraft)
      Button(model.t("Save content settings")) {
        Task { @MainActor in await model.applyContentSettings() }
      }
      Text(model.t("ZIP archives work with Mac. Use .json for the legacy export format."))
      Button(model.t("Export history")) {
        Task { @MainActor in
          if let destination = await chooseSaveDestination(
            title: model.t("Export history"), initialDirectory: archiveDirectory,
            defaultFileName: "clipboard-history.zip")
          {
            archiveDirectory = destination.deletingLastPathComponent()
            await model.exportHistory(to: destination)
          }
        }
      }
      if model.confirmsClearHistory {
        Text(model.t("Delete all history, including pinned items?"))
        HStack {
          Button(model.t("Delete all history")) {
            Task { @MainActor in await model.clearHistory() }
          }
          Button(model.t("Cancel")) { model.confirmsClearHistory = false }
        }
      } else {
        Button(model.t("Clear history")) { model.confirmsClearHistory = true }
      }
      Button(model.t("Import history")) {
        Task { @MainActor in
          if let source = await chooseFile(
            title: model.t("Import history"), initialDirectory: archiveDirectory)
          {
            archiveDirectory = source.deletingLastPathComponent()
            await model.importHistory(from: source)
          }
        }
      }
    }
  }

  var localAnalysisSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        model.t(
          "Local OCR uses installed system language packs. Apple-only models are unavailable here.")
      )
      Toggle(model.t("Automatically recognize images"), isOn: $model.automaticOCRDraft)
      Toggle(model.t("Enable local text summaries"), isOn: $model.localTextSummariesDraft)
      Text(model.t("Creates a short excerpt on this device. Nothing is uploaded."))
        .font(.system(size: 12)).foregroundColor(.gray)
      Toggle(
        model.t("Automatically summarize text locally"), isOn: $model.automaticLocalSummariesDraft
      )
      .disabled(!model.localTextSummariesDraft)

    }
  }

  var localFileSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(model.t("Enable local file excerpts"), isOn: $model.localFileSummariesDraft)
      Text(
        model.t(
          "Reads the first copied UTF-8 text or PDF file on this device. File and extracted text: at most 1 MiB; PDF: at most 256 pages."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
      Toggle(
        model.t("Automatically summarize files locally"),
        isOn: $model.automaticLocalFileSummariesDraft
      )
      .disabled(!model.localFileSummariesDraft)
    }
  }
  var remoteFileSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(model.t("Allow file text uploads"), isOn: $model.aiFilesDraft)
      Text(
        model.t(
          "Uploads text from the first copied UTF-8 or PDF file only. File and extracted text: at most 1 MiB; PDF: at most 256 pages. Encrypted or image-only PDFs are unavailable."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
    }
  }
  var serviceSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("System services")).font(.system(size: 18))
      Button(model.t(model.startupEnabled ? "Disable launch at login" : "Enable launch at login")) {
        Task { @MainActor in await model.toggleStartup() }
      }.disabled(!model.startupAvailable || model.startupBusy)
      Text(
        model.t(
          "System startup policy can override this registration. Check Startup apps or your desktop session settings."
        ))
      localAnalysisSettings
      localFileSettings
      Text(
        model.t(
          "Remote AI is off by default. Enabling it sends eligible content to your chosen endpoint."
        ))
      Toggle(model.t("Enable remote AI"), isOn: connectionBinding($model.aiEnabledDraft))
      Toggle(model.t("Allow text summaries"), isOn: $model.aiTextDraft)
      Toggle(model.t("Allow image uploads"), isOn: $model.aiImagesDraft)
      remoteFileSettings
      Toggle(model.t("Automatically summarize new items"), isOn: $model.automaticSummariesDraft)
      TextField(model.t("API endpoint"), text: connectionBinding($model.aiEndpointDraft))
      TextField(model.t("Model name"), text: connectionBinding($model.aiModelDraft))
      SecureField(model.t("API key"), text: $model.aiKeyDraft)
      HStack {
        Button(model.t("Save API key")) { Task { @MainActor in await model.saveAPIKey() } }
        Button(model.t("Delete API key")) { Task { @MainActor in await model.deleteAPIKey() } }
      }
      Toggle(model.t("Use saved API key"), isOn: connectionBinding($model.aiCredentialDraft))
      Button(model.t("Save AI settings")) { Task { @MainActor in await model.saveAISettings() } }
      Text(
        model.t(
          "Tests these fields with the saved key when selected. Only a test message is sent; clipboard history is not included."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
      HStack {
        Button(model.t("Test AI connection")) { model.testAIConnection() }
          .disabled(!model.canTestAIConnection || model.connectionBusy)
        if model.connectionBusy {
          Button(model.t("Cancel connection test")) { model.cancelAIConnection() }
        }
      }
      if let message = model.connectionMessage { Text(model.t(message)) }
    }
  }
  private func connectionBinding<Value: Equatable>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(
      get: { binding.wrappedValue },
      set: { value in
        guard binding.wrappedValue != value else { return }
        binding.wrappedValue = value
        model.invalidateAIConnection()
      })
  }
  var presentationSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("Appearance")).font(.system(size: 18))
      HStack {
        Button(model.t("System")) { Task { @MainActor in await model.setAppearance("system") } }
        Button(model.t("Light")) { Task { @MainActor in await model.setAppearance("light") } }
        Button(model.t("Dark")) { Task { @MainActor in await model.setAppearance("dark") } }
      }
      Text(model.t("Language")).font(.system(size: 18))
      HStack {
        Button(model.t("System language")) { Task { @MainActor in await model.setLanguage(nil) } }
        languageButton(.english)
        languageButton(.simplifiedChinese)
        languageButton(.traditionalChinese)
      }
      HStack {
        languageButton(.japanese)
        languageButton(.korean)
        languageButton(.german)
        languageButton(.spanish)
      }
    }
  }

  func languageButton(_ language: DesktopUILanguage) -> some View {
    Button(language.nativeName) {
      Task { @MainActor in await model.setLanguage(language.rawValue) }
    }
  }

  var updateSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.t("Desktop updates")).font(.system(size: 18))
      Text(
        model.t("Installed version") + ": "
          + (model.desktopVersion.isEmpty ? "—" : model.desktopVersion)
      )
      .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      Text(model.t(model.updateMessage)).lineLimit(3)
      HStack {
        Button(model.t("Check for updates")) { model.checkUpdates() }
          .disabled(model.updateBusy || model.desktopVersion.isEmpty)
        if model.updateBusy {
          Button(model.t("Cancel update check")) { model.cancelUpdateCheck() }
        }
      }
      if case .available(let update) = model.updateResult {
        Text(model.t("Available version") + ": " + update.version)
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        Button(model.t("Open official release page")) { openURL(update.page) }
      }
      Text(
        model.t(
          "Updates are installed manually. Quit Clipboard, verify SHA-256, then use the official package instructions."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray).lineLimit(4)
    }
  }

  var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.t("Preferences")).font(.system(size: 22))
        Spacer()
        Button(model.t("Back to history")) { Task { @MainActor in await model.showHistory() } }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(model.t("History stays on this device. Sensitive items stay in memory."))
          contentSettings
          serviceSettings
          presentationSettings
          Text(model.t("Recording: \(model.recording ? "On" : "Paused")"))
          Toggle(model.t("Enable global shortcut"), isOn: $model.shortcutEnabledDraft)
          TextField(model.t("Ctrl+Alt+V"), text: $model.shortcutDraft)
          Button(model.t("Apply shortcut")) { Task { @MainActor in await model.applyShortcut() } }
          Toggle(model.t("Keep running when closing the window"), isOn: $model.closeToTrayDraft)
          Toggle(model.t("Show history when starting"), isOn: $model.showOnLaunchDraft)
          Toggle(model.t("Record when starting"), isOn: $model.recordOnLaunchDraft)
          Button(model.t("Save behavior")) { Task { @MainActor in await model.applyBehavior() } }
          if !model.shellStatus.isEmpty { Text(model.t(model.shellStatus)).lineLimit(3) }
          updateSettings
          Button(model.t("Quit Clipboard")) { Task { @MainActor in await model.shutdown() } }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
      }.frame(minHeight: 320, maxHeight: 360)
    }.frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

/// Isolates backend/window/control startup from asynchronous Core history updates.
struct BaselineView: View {
  @State var count = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("SwiftCrossUI baseline").font(.system(size: 24))
      Text("Counter: \(count)")
      Button("Increment") { count += 1 }
    }.padding(24)
  }
}
