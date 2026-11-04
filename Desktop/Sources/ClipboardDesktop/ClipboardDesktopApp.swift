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
    .defaultSize(width: 760, height: 520)
  }
}

struct HistoryView: View {
  @State var model = HistoryModel()
  @State var settingsSection = DesktopSettingsSection.general
  @State var showsCompactFilters = false
  @State var archiveDirectory: URL?
  @State var modelImportDirectory: URL?
  @Environment(\.openURL) var openURL
  @Environment(\.chooseFile) var chooseFile
  @Environment(\.chooseFileSaveDestination) var chooseSaveDestination

  var body: some View {
    GeometryReader { geometry in
      let viewportWidth = model.responsiveWidth(proposed: geometry.size.width)
      let language = DesktopUILanguage.resolve(override: model.uiLanguage)
      let extraCountDigits = ([model.allTypesCount] + Array(model.kindCounts.values))
        .reduce(0) { $0 + max(0, String($1).count - 1) }
      let filterRowWidth =
        (language == .simplifiedChinese || language == .traditionalChinese ? 740.0 : 1200.0)
        + Double(extraCountDigits) * 7 / 0.56
      let compactFilters = viewportWidth < filterRowWidth
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        if model.showsSettings {
          settings
        } else {
          history(
            width: geometry.size.width, compactFilters: compactFilters,
            imageHeight: model.previewImageHeight(proposed: geometry.size.height)
          )
          .disabled(model.historyActivationBusy)
        }
        Divider()
        HStack(spacing: 0) {
          HStack(spacing: 4) {
            Text(model.t("\(model.items.count) items")).font(.system(size: 12)).lineLimit(1)
              .fixedSize()
            Spacer()
            sessionActions
          }.padding(.horizontal, 12).frame(width: max(0, geometry.size.width * 0.56))
          Text(model.t(model.status)).font(.system(size: 12)).lineLimit(1)
            .help(model.t(model.status)).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 32)

      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
    .font(.system(size: 14))
    .environment(\.colorScheme, model.effectiveDark ? .dark : .light)
    .inspectWindow {
      DesktopChrome.apply(
        to: $0, dark: model.effectiveDark, language: .resolve(override: model.uiLanguage))
      model.attachWindow($0)
    }
    .task { @MainActor in
      await model.load()
      // Fixture input only: keep the real native chooser/default-name path,
      // while its initial directory and untouched default save stay private.
      if archiveDirectory == nil && CommandLine.arguments.contains("--smoke-root") {
        archiveDirectory = DesktopApplicationContext.dataRoot
      }
      if modelImportDirectory == nil, CommandLine.arguments.contains("--smoke-root"),
        DesktopApplicationContext.profile != "production"
      {
        modelImportDirectory = DesktopApplicationContext.dataRoot
      }
    }
    .onChange(of: model.selectedID) { Task { @MainActor in await model.loadPreview() } }
  }

  var header: some View {
    HStack(spacing: 10) {
      if model.showsSettings {
        Text(model.t("Preferences")).font(.system(size: 15))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        DesktopSymbol(name: "search", size: 16)
        TextField(model.t("Search history"), text: $model.query)
          .inspect {
            DesktopChrome.setClass("clipboard-search", on: $0)
            model.attachSearch($0)
            DesktopImeStateFixture.attach($0)
          }
          .onSubmit {
            Task { @MainActor in
              guard let id = model.selectedID else { return }
              await model.activateHistoryItem(id: id)
            }
          }
          .onChange(of: model.query) { Task { @MainActor in await model.refresh() } }
          .font(.system(size: 15)).frame(maxWidth: .infinity)
      }
      Divider().frame(height: 18)
      iconButton("Settings", symbol: "settings") { model.showPreferences() }
    }.padding(.horizontal, 14).frame(height: 44)
      .inspect { DesktopChrome.setClass("clipboard-search-surface", on: $0) }
      .padding(12)
  }

  var sessionActions: some View {
    HStack(spacing: 4) {
      iconButton(
        model.recording ? "Pause recording" : "Start recording",
        symbol: model.recording ? "pause" : "record"
      ) {
        Task { @MainActor in await model.toggleRecording() }
      }.disabled(!model.ready || model.recordingTransition)
      if model.canHide { iconButton("Hide", symbol: "hide") { model.hide() } }
      iconButton(showsCompactFilters ? "Hide filters" : "Filters", symbol: "filter") {
        showsCompactFilters.toggle()
      }
    }
  }

  func history(width: Double, compactFilters: Bool, imageHeight: Double) -> some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        historyFilters(compact: compactFilters)
        Divider()
        historyItems.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      }.frame(width: max(0, width * 0.56))
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        preview(imageHeight: imageHeight)
          .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        itemActions.padding(8)
      }.inspect { DesktopChrome.setClass("clipboard-preview", on: $0) }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }

  func historyFilters(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Spacer()
        HStack(spacing: 2) {
          filterButton(
            "All", count: model.allItemsCount, selected: !model.onlyPinned, segment: true
          ) {
            Task { @MainActor in await model.selectTab(onlyPinned: false) }
          }
          filterButton(
            "Pinned", count: model.pinnedItemsCount, selected: model.onlyPinned, segment: true
          ) {
            Task { @MainActor in await model.selectTab(onlyPinned: true) }
          }
        }.padding(2).inspect { DesktopChrome.setClass("clipboard-segments", on: $0) }
        Spacer()
      }
      if compact {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 3) {
            allTypesButton
            typeButton(.text)
            typeButton(.image)
          }
          HStack(spacing: 3) {
            typeButton(.file)
            typeButton(.rtf)
            typeButton(.mixed)
          }
        }
      } else {
        HStack(spacing: 3) {
          allTypesButton
          typeButton(.text)
          typeButton(.image)
          typeButton(.file)
          typeButton(.rtf)
          typeButton(.mixed)
        }
      }
      if showsCompactFilters {
        TextField(model.t("Source app ID (optional)"), text: $model.sourceFilter)
          .onChange(of: model.sourceFilter) { Task { @MainActor in await model.refresh() } }
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
      }
    }.padding(8)
  }

  func filterButton(
    _ label: String, count: Int, selected: Bool, segment: Bool = false, symbol: String? = nil,
    action: @escaping @MainActor @Sendable () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 3) {
        if let symbol { DesktopSymbol(name: symbol, size: 12) }
        Text(
          model.t(
            segment
              ? label
              : label == "All types"
                ? "All types compact" : label == "Mixed" ? "Mixed compact" : label)
        )
        .font(.system(size: 12)).lineLimit(1).fixedSize()
        Text("(\(count))").font(.system(size: 12)).lineLimit(1)
          .fixedSize()
      }.padding(.horizontal, segment ? 16 : 3).padding(.vertical, 4)
        .frame(minWidth: segment ? 110 : nil)
    }
    .inspect([.onCreate, .afterUpdate]) {
      DesktopChrome.label(model.t(label), on: $0)
      DesktopChrome.setClass(segment ? "clipboard-segment" : "clipboard-filter", on: $0)
      DesktopChrome.setClass("clipboard-selected", on: $0, enabled: selected)
    }
    .buttonStyle(.borderless)
  }
  var allTypesButton: some View {
    filterButton("All types", count: model.allTypesCount, selected: model.kindFilter == nil) {
      Task { @MainActor in await model.selectKind(nil) }
    }
  }
  func typeButton(_ kind: ClipKind) -> some View {
    filterButton(
      kind.rawValue.capitalized, count: model.kindCounts[kind, default: 0],
      selected: model.kindFilter == kind, symbol: kindSymbol(kind)
    ) {
      Task { @MainActor in await model.selectKind(kind) }
    }
  }

  var historyItems: some View {
    let items = model.items
    let itemIDs = items.map(\.id)
    return ScrollView {
      List(items, selection: $model.selectedID) { item in
        HStack(spacing: 10) {
          Group {
            if let image = model.previewThumbnail(for: item) {
              DesktopImagePreview(image: image, accessibilityLabel: model.t("Image thumbnail"))
            } else {
              DesktopSymbol(name: item.sensitive ? "lock" : kindSymbol(item.kind), size: 20)
            }
          }.frame(width: 40, height: 40)
            .inspect { DesktopChrome.setClass("clipboard-kind", on: $0) }
          VStack(alignment: .leading, spacing: 0) {
            Text(
              item.sensitive
                ? model.t("Sensitive content")
                : model.itemPresentations[item.id]?.rowText
                  ?? DesktopTextPreview(item.preview, maxUTF8Bytes: 512).text
            ).font(.system(size: 14)).lineLimit(1)
            Text(
              (item.pinned ? model.t("Pinned") + " · " : "")
                + (model.itemPresentations[item.id].map { $0.rowCreatedText } ?? "")
                + (model.itemPresentations[item.id]?.sourceName.map { " · " + $0 } ?? "")
            )
            .font(.system(size: 12)).lineLimit(1)
            .inspect { DesktopChrome.setClass("clipboard-secondary", on: $0) }
          }.frame(maxWidth: .infinity, alignment: .leading)
          // The pinned List adds 6px vertically and 8px horizontally itself.
          // Add only the remainder to reach the approved 7px / 10px row inset.
        }.padding(.vertical, 1).padding(.horizontal, 2)
      }.inspect([.onCreate, .afterUpdate]) { list in
        DesktopChrome.setClass("clipboard-history", on: list)
        model.attachHistoryList(list, itemIDs: itemIDs)
      }
    }.padding(.horizontal, 8).padding(.vertical, 6)
  }

  func kindSymbol(_ kind: ClipKind) -> String {
    switch kind {
    case .text: return "text"
    case .image: return "image"
    case .file: return "file"
    case .rtf: return "rich"
    case .mixed: return "copy"
    }
  }

  func preview(imageHeight: Double) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          HStack(spacing: 4) {
            DesktopSymbol(name: kindSymbol(model.selected?.kind ?? .text), size: 12)
            Text(model.t(model.selected.map { $0.kind.rawValue.capitalized } ?? "Preview"))
              .font(.system(size: 12)).lineLimit(1)
          }.padding(.horizontal, 7).padding(.vertical, 3)
            .inspect { DesktopChrome.setClass("clipboard-preview-badge", on: $0) }
          if let item = model.selected, let source = model.itemPresentations[item.id]?.sourceName {
            Text(source).font(.system(size: 12)).lineLimit(1)
              .help(DesktopTextPreview(item.sourceBundleID ?? "", maxUTF8Bytes: 4096).text)
              .inspect([.onCreate, .afterUpdate]) {
                DesktopChrome.label(model.t("Source: ") + source, on: $0, alwaysUpdate: true)
              }
          }
          Spacer()
          itemMenu
        }
        if let item = model.selected, let presentation = model.itemPresentations[item.id] {
          Text(
            presentation.createdText + " · " + String(max(0, item.sizeBytes)) + " "
              + model.t("bytes")
          )
          .font(.system(size: 12)).foregroundColor(.gray).lineLimit(1)
        }
      }.padding(12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if case .running(let remote, let imageSummary, let textEngine)? = model
            .selectedAnalysisProgress
          {
            Text(
              model.t(
                remote
                  ? "Generating summary…"
                  : imageSummary
                    ? "Analyzing image locally…"
                    : model.selected?.kind == .image
                      ? "Recognizing text…" : model.localTextProgressMessage(textEngine)
              ))
          }
          if case .failed(let remote, let imageSummary)? = model.selectedAnalysisProgress {
            Text(
              model.t(
                remote
                  ? "Could not generate a summary."
                  : imageSummary
                    ? "Could not analyze the image locally."
                    : model.selected?.kind == .image
                      ? "Could not recognize text."
                      : model.usesOptionalTextAnalysis
                        ? "Could not analyze text locally." : "Could not create a local excerpt.")
            )
            Button(
              model.t(
                remote
                  ? "Retry summary"
                  : imageSummary
                    ? "Retry image analysis"
                    : model.selected?.kind == .image
                      ? "Retry text recognition"
                      : model.usesOptionalTextAnalysis
                        ? "Retry local analysis" : "Retry local excerpt")
            ) {
              model.retryAnalysis()
            }.disabled(
              model.historyActivationBusy || model.analysisBusy || (remote && !model.canSummarize)
                || (!remote && model.selected?.kind != .image && !model.canSummarizeLocally))
          }
          if let summary = model.selected?.summary, model.selected?.sensitive != true {
            Text(
              model.t(model.summaryResultLabel)
            ).font(.system(size: 14))
            Text(summary).frame(maxWidth: .infinity, alignment: .leading)
            Button(model.t("Copy result")) {
              Task { @MainActor in await model.copyAnalysisResult() }
            }
          }
          if let image = model.previewImage {
            DesktopImagePreview(image: image, accessibilityLabel: model.t("Image preview")).frame(
              minWidth: 0, maxWidth: .infinity, maxHeight: imageHeight)
          }
          if let count = model.previewFileCount {
            Text(model.t("Files") + ": " + String(count)).font(.system(size: 12)).foregroundColor(
              .gray)
            ForEach(
              Array(model.previewText.components(separatedBy: "\n").enumerated()), id: \.offset
            ) { entry in
              Text(entry.element).frame(maxWidth: .infinity, alignment: .leading)
            }
          } else if model.previewImage != nil {
            Text(model.previewMessage.map { model.t($0) } ?? model.previewText)
              .font(.system(size: 12)).foregroundColor(.gray)
              .frame(maxWidth: .infinity, alignment: .center)
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

        }.frame(
          minHeight: model.previewImage == nil ? 0 : imageHeight + 32,
          alignment: model.previewImage == nil ? .topLeading : .center
        )
        .padding(16)
      }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
  }

  var itemMenu: some View {
    let enabled = !model.historyActivationBusy && model.selected != nil
    return DesktopActionMenu(
      label: "⋯", accessibilityLabel: model.t("Item actions"),
      entries: [
        .init(label: model.t("Copy"), enabled: enabled) {
          Task { @MainActor in await model.copySelected() }
        },
        .init(label: model.t("Pin / unpin"), enabled: enabled) {
          Task { @MainActor in await model.togglePin() }
        },
        .init(label: model.t("Delete"), enabled: enabled) {
          Task { @MainActor in await model.deleteSelected() }
        },
      ]
    ).frame(width: 28, height: 28)
  }

  var itemActions: some View {
    HStack(spacing: 8) {
      iconButton("Copy", symbol: "copy") {
        Task { @MainActor in await model.copySelected() }
      }.disabled(model.historyActivationBusy || model.selected == nil)
      if model.selected?.kind == .image || model.canSummarize || model.canSummarizeLocally {
        HStack(spacing: 8) {
          iconButton("Recognize text", symbol: "text") { model.analyze(remote: false) }
            .disabled(
              model.historyActivationBusy || model.selected?.kind != .image
                || model.selected?.sensitive == true
                || model.analysisBusy)
          if model.selected?.kind == .image {
            iconButton("Analyze image locally", symbol: "image") {
              model.analyze(remote: false, imageSummary: true)
            }.disabled(
              model.historyActivationBusy || model.selected?.sensitive == true || model.analysisBusy
            )
          }
          if model.canSummarizeLocally {
            iconButton("Summarize locally", symbol: "ai") { model.analyze(remote: false) }
              .disabled(model.historyActivationBusy || model.analysisBusy)
          }
          iconButton("Summarize", symbol: "ai") { model.analyze(remote: true) }
            .disabled(model.historyActivationBusy || !model.canSummarize || model.analysisBusy)
        }
      }
    }
  }

  var contentSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      preferenceRow("History capacity (1–5000)") {
        TextField(model.t("100"), text: $model.capacityDraft).frame(width: 76)
      }
      Button(model.t("Save content settings")) {
        Task { @MainActor in await model.applyContentSettings() }
      }
    }
  }

  var privacySettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("History stays on this device. Sensitive items stay in memory."))
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
    }
  }

  var archiveSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
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
      Toggle(
        model.t("Include local image labels in automatic recognition"),
        isOn: $model.automaticLocalImageSummariesDraft
      ).disabled(!model.automaticOCRDraft)
      Text(
        model.t(
          "Reads image text first, then uses local image labels when text is absent. Nothing is uploaded."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
      optionalTextAnalysisSettings
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
      Toggle(model.t("Allow local file analysis"), isOn: $model.localFileSummariesDraft)
      Text(
        model.t(
          "Reads the first copied UTF-8 text or PDF file on this device. File and extracted text: at most 1 MiB; PDF: at most 256 pages."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
      Text(
        model.t(
          "This file permission also gates local generation and language analysis. Automatic file analysis additionally requires that engine's automatic permission."
        )
      ).font(.system(size: 12)).foregroundColor(.gray)
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
  var startupSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(model.t(model.startupEnabled ? "Disable launch at login" : "Enable launch at login")) {
        Task { @MainActor in await model.toggleStartup() }
      }.disabled(!model.startupAvailable || model.startupBusy)
      Text(
        model.t(
          "System startup policy can override this registration. Check Startup apps or your desktop session settings."
        )
      )
      .font(.system(size: 12)).foregroundColor(.gray)
    }
  }

  var serviceSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
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
  func preferenceRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control)
    -> some View
  {
    VStack(spacing: 12) {
      HStack(spacing: 16) {
        Text(model.t(title)).font(.system(size: 14))
        Spacer()
        control().frame(width: 210)
      }
      Divider()
    }.padding(.vertical, 6)
  }

  var presentationSettings: some View {
    VStack(spacing: 12) {
      preferenceRow("Appearance") {
        DesktopActionMenu(
          label: model.t(
            model.appearance == "dark" ? "Dark" : model.appearance == "light" ? "Light" : "System"),
          accessibilityLabel: model.t("Appearance options"),
          entries: [("System", "system"), ("Light", "light"), ("Dark", "dark")].map {
            title, value in
            .init(label: model.t(title), enabled: true) {
              Task { @MainActor in await model.setAppearance(value) }
            }
          }, showsArrow: true)
      }
      preferenceRow("Language") {
        DesktopActionMenu(
          label: model.uiLanguage.flatMap { DesktopUILanguage(rawValue: $0)?.nativeName }
            ?? model.t("System language"),
          accessibilityLabel: model.t("Language options"),
          entries: [
            .init(label: model.t("System language"), enabled: true) {
              Task { @MainActor in await model.setLanguage(nil) }
            }
          ]
            + DesktopUILanguage.allCases.map { language in
              .init(label: language.nativeName, enabled: true) {
                Task { @MainActor in await model.setLanguage(language.rawValue) }
              }
            }, showsArrow: true)
      }
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

  var behaviorSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(model.t("Keep running when closing the window"), isOn: $model.closeToTrayDraft)
      Toggle(model.t("Show history when starting"), isOn: $model.showOnLaunchDraft)
      Toggle(model.t("Record when starting"), isOn: $model.recordOnLaunchDraft)
      Button(model.t("Save behavior")) { Task { @MainActor in await model.applyBehavior() } }
      if !model.shellStatus.isEmpty { Text(model.t(model.shellStatus)).lineLimit(3) }
    }
  }

  var shortcutSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(model.t("Enable global shortcut"), isOn: $model.shortcutEnabledDraft)
      TextField(model.t("Ctrl+Alt+V"), text: $model.shortcutDraft)
      Button(model.t("Apply shortcut")) { Task { @MainActor in await model.applyShortcut() } }
      if !model.shellStatus.isEmpty { Text(model.t(model.shellStatus)).lineLimit(3) }
    }
  }

  var settings: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        iconButton("Back to history", symbol: "back") {
          Task { @MainActor in await model.showHistory() }
        }
        Spacer()
        ForEach(DesktopSettingsSection.allCases, id: \.self) { section in
          Button {
            guard settingsSection != section else { return }
            settingsSection = section
          } label: {
            VStack(spacing: 4) {
              DesktopSymbol(name: section.symbol, size: 20)
              Text(model.t(section.rawValue)).font(.system(size: 12)).lineLimit(1)
            }.padding(8)
          }
          .inspect([.onCreate, .afterUpdate]) {
            DesktopChrome.label(model.t(section.rawValue), on: $0)
            DesktopChrome.setClass("clipboard-settings-tab", on: $0)
            DesktopChrome.setClass(
              "clipboard-selected", on: $0, enabled: settingsSection == section)
          }
          .buttonStyle(.borderless)
        }
        Spacer()
      }.padding(8)
      Divider()
      // All five native pages stay mounted. Hide whole page roots so off-page
      // editors cannot receive focus, while drafts/IME and scroll positions survive.
      ZStack(alignment: .topLeading) {
        settingsPage(.general) {
          presentationSettings
          contentSettings
          startupSettings
          behaviorSettings
          Button(model.t("Quit Clipboard")) { Task { @MainActor in await model.shutdown() } }
        }
        settingsPage(.privacy) { privacySettings }
        settingsPage(.ai) {
          serviceSettings
          desktopModelSettings
        }
        settingsPage(.shortcuts) { shortcutSettings }
        settingsPage(.data) {
          archiveSettings
          updateSettings
        }
      }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
