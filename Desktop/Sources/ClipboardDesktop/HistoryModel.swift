import ClipboardCore
import DesktopClipboard
import DesktopServices
import DesktopShell
import Foundation
import Gtk
import SwiftCrossUI

/// Presentation state; persistence, filters and native ownership stay in Core/adapters.
final class HistoryModel: ObservableObject {
  @Published var analysisBusy = false
  @Published var itemAnalysisProgress: [UUID: DesktopItemAnalysisProgress] = [:]
  @Published var connectionBusy = false
  @Published var connectionResult: DesktopAIConnectionResult?
  @Published var startupEnabled = false
  @Published var startupAvailable = false
  @Published var startupBusy = false
  @Published var aiEnabledDraft = false
  @Published var aiTextDraft = true
  @Published var aiImagesDraft = false
  @Published var aiFilesDraft = false
  @Published var aiCredentialDraft = false
  @Published var aiEndpointDraft = "https://api.openai.com/v1"
  @Published var aiModelDraft = ""
  @Published var aiKeyDraft = ""
  @Published var automaticSummariesDraft = false
  @Published var automaticOCRDraft = false
  @Published var localTextSummariesDraft = false
  @Published var automaticLocalSummariesDraft = false
  @Published var localFileSummariesDraft = false
  @Published var automaticLocalFileSummariesDraft = false
  @Published var appearance = "system"
  @Published var effectiveDark = false
  @Published var uiLanguage: String?
  private var credentials = NativeDesktopCredentials()
  private let ocr = NativeDesktopOCR()
  private let transport = BoundedDesktopAITransport()
  @MainActor private lazy var aiConnection: DesktopAIConnectionState = {
    let probe = DesktopAIConnectionProbe(credentials: credentials, transport: transport)
    return DesktopAIConnectionState(
      run: { await probe.test(settings: $0) },
      changed: { [weak self] busy, result in
        self?.connectionBusy = busy
        self?.connectionResult = result
      })
  }()
  @MainActor private var startup: DesktopStartupState?
  @MainActor private lazy var analysisProgress = DesktopAnalysisProgressState {
    [weak self] in self?.itemAnalysisProgress = $0
  }
  @MainActor private lazy var analysisScheduler = DesktopAnalysisScheduler(
    busyChanged: { [weak self] in self?.analysisBusy = $0 },
    perform: { [weak self] in await self?.performAnalysis($0) })
  @Published var items: [ClipItem] = []
  @Published var allItemsCount = 0
  @Published var pinnedItemsCount = 0
  @Published var allTypesCount = 0
  @Published var kindCounts: [ClipKind: Int] = [:]
  @Published var query = ""
  @Published var onlyPinned = false
  @Published var selectedID: UUID? {
    didSet { if oldValue != selectedID { resetSensitivePreview() } }
  }
  @Published var showsSettings = false
  @Published var status = "Loading history"
  @Published var recording = false
  @Published var recordingTransition = false
  @Published var ready = false
  @Published var previewText = "Choose an item to preview its content."
  @Published var previewMessage: String? = "Choose an item to preview its content."
  @Published var previewImage: DesktopPreviewImage?
  @Published var previewTruncated = false
  @Published var kindFilter: ClipKind?
  @Published var sourceFilter = ""
  @Published var confirmsClearHistory = false
  @Published var capacityDraft = "100"
  @Published var maxSizeDraft = "10"
  @Published var blockedAppsDraft = ""
  @Published var blocklistEnabledDraft = true
  @Published var skipSensitiveDraft = true
  @Published var shellStatus = ""
  @Published var canHide = false
  @Published var shortcutDraft = "Ctrl+Alt+V"
  @Published var shortcutEnabledDraft = true
  @Published var closeToTrayDraft = true
  @Published var showOnLaunchDraft = true
  @Published var recordOnLaunchDraft = false

  private var store: JSONSnapshotClipStore?
  private var settingsStore: (any DesktopSettingsPersisting)?
  private var settings = DesktopSettings()
  private var root: URL?
  private var clipboard: (any RichClipboardAccess)?
  private var clipboardTask: Task<any RichClipboardAccess, Error>?
  private var monitor: RichClipboardMonitor?
  private var shell: NativeDesktopShell?
  private var captureTask: Task<Void, Never>?
  private var captureSkipsTask: Task<Void, Never>?
  private var eventsTask: Task<Void, Never>?
  private var shellTask: Task<Void, Never>?
  private var activationTask: Task<Void, Never>?
  private var loadedPreviewID: UUID?
  private var previewGeneration: UInt64 = 0
  @Published private var revealedSensitiveID: UUID?
  @MainActor private var nativeWindow: GtkDesktopWindow?
  @MainActor private weak var searchEntry: Gtk.Entry?
  @MainActor private var windowCoordinator: DesktopWindowCoordinator?
  @MainActor private var startupActivationRequested = false
  @MainActor private var shuttingDown = false
  @MainActor private lazy var settingsSaveGate = DesktopSettingsSaveGate()

  static let fixtures = [
    "Welcome to Clipboard Preview",
    "中文笔记 · 设计评审与输入测试",
    "Release checklist · build, test, publish",
  ]
  var selected: ClipItem? { items.first { $0.id == selectedID } }

  @MainActor var canSummarize: Bool {
    guard let item = selected, !item.sensitive, settings.ai.allowsSummary(of: item.kind) else {
      return false
    }
    if item.kind == .file {
      return item.payloads.contains { $0.pasteboardType == "public.file-url" }
    }
    if item.kind == .image {
      return settings.ai.allowImages
        && item.payloads.contains(where: {
          ["public.png", "public.jpeg"].contains($0.pasteboardType)
        })
    }
    return true
  }

  @MainActor var canSummarizeLocally: Bool {
    guard let item = selected, !item.sensitive else { return false }
    if item.kind == .file { return settings.localFileSummariesEnabled }
    return settings.localTextSummariesEnabled && [.text, .rtf, .mixed].contains(item.kind)
  }
  var canRevealSensitivePreview: Bool {
    selected?.sensitive == true && revealedSensitiveID != selectedID
  }
  private func resetSensitivePreview() {
    previewGeneration &+= 1
    // Invalidate both completed and in-flight loads when their generation changes.
    loadedPreviewID = nil
    let wasRevealed = revealedSensitiveID != nil
    if wasRevealed { revealedSensitiveID = nil }
    if wasRevealed || selected?.sensitive == true {
      previewImage = nil
      previewTruncated = false
      previewText =
        selected?.sensitive == true
        ? "Sensitive content is hidden." : "Choose an item to preview its content."
      previewMessage = previewText
    }
  }
  @MainActor func revealSensitivePreview() async {
    guard !shuttingDown, !showsSettings, nativeWindow?.isVisible == true,
      let selected, selected.sensitive
    else { return }
    revealedSensitiveID = selected.id
    previewGeneration &+= 1
    loadedPreviewID = nil
    await loadPreview()
  }

  @MainActor func responsiveWidth(proposed: Double) -> Double {
    nativeWindow?.responsiveWidth(fallback: proposed) ?? proposed
  }
  @MainActor func previewImageHeight(proposed: Double) -> Double {
    let height = nativeWindow?.responsiveHeight(fallback: proposed) ?? proposed
    // Reserve the search, filter, action and status rows. The mapped window
    // supplies logical pixels even during hidden/zero-size layout proposals.
    return min(240, max(64, height - 560))
  }

  @MainActor func attachWindow(_ window: Gtk.Window) {
    if nativeWindow == nil {
      let presenter = GtkDesktopWindow()
      nativeWindow = presenter
      presenter.hidden = { [weak self] in
        self?.resetSensitivePreview()
        self?.invalidateAIConnection()
      }
      presenter.presentationChanged = { [weak self] in
        Task { @MainActor in
          guard let self, self.showsSettings, !self.shuttingDown else { return }
          await self.refreshStartup()
        }
      }
      presenter.observeAppearance { [weak self] property in
        guard let self else { return }
        DesktopAppearance.recordSystem(property: property)
        if self.appearance != "system" { DesktopAppearance.apply(self.appearance) }
        self.effectiveDark = DesktopAppearance.currentIsDark
      }
      windowCoordinator = DesktopWindowCoordinator(window: presenter)
      presenter.closeRequested = { [weak self] in
        guard let self else { return }
        if self.settings.closeToTray && self.canHide {
          self.windowCoordinator?.hide()
        } else {
          Task { @MainActor in await self.shutdown() }
        }
      }
      presenter.reopenRequested = { [weak self] in
        Task { @MainActor in await self?.showHistory() }
      }
    }
    nativeWindow?.attach(window)
    if let searchEntry { nativeWindow?.attachSearch(searchEntry) }
  }
  @MainActor func attachSearch(_ entry: Gtk.Entry) {
    searchEntry = entry
    entry.activate = { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        await self.copySelected()
        if self.status == "Copied to clipboard" { self.hide() }
      }
    }
    nativeWindow?.attachSearch(entry)
  }

  @MainActor func loadPreview() async {
    guard let selected else {
      loadedPreviewID = nil
      previewImage = nil
      previewTruncated = false
      previewText = "Choose an item to preview its content."
      previewMessage = previewText
      return
    }
    guard loadedPreviewID != selected.id else { return }
    loadedPreviewID = selected.id
    previewImage = nil
    previewTruncated = false
    if selected.sensitive && revealedSensitiveID != selected.id {
      previewText = "Sensitive content is hidden."
      previewMessage = previewText
      return
    }
    previewText = "Loading preview…"
    previewMessage = previewText
    let generation = previewGeneration
    let resolver = PayloadResolver(
      blobRoot: selected.sensitive ? nil : root?.appendingPathComponent("blobs"))
    let result = await Task.detached(priority: .userInitiated) {
      () -> (String, DesktopPreviewImage?, Bool, String?) in
      if selected.kind == .image,
        let payload = selected.payloads.first(where: {
          ClipKind.imagePayloadTypes.contains($0.pasteboardType)
        }),
        let bytes = try? resolver.data(for: payload)
      {
        let message = "Image · \(selected.sizeBytes) bytes"
        return (message, DesktopPreviewImage.decode(bytes), false, message)
      }
      if selected.kind == .file,
        let payload = selected.payloads.first(where: { $0.pasteboardType == "public.file-url" }),
        let bytes = try? resolver.data(for: payload),
        let urls = try? ClipboardFormats.fileURLs(from: bytes)
      {
        return (urls.map(\.path).joined(separator: "\n"), nil, false, nil)
      }
      if let payload = selected.payloads.first(where: {
        ["public.utf8-plain-text", "public.plain-text", "public.string"].contains($0.pasteboardType)
      }),
        let bytes = try? resolver.data(for: payload),
        let text = String(data: bytes, encoding: .utf8)
      {
        let preview = DesktopTextPreview(text)
        return (preview.text, nil, preview.isTruncated, nil)
      }
      let rich = selected.payloads.compactMap { payload -> RawPayload? in
        guard ["public.html", "public.rtf"].contains(payload.pasteboardType),
          let bytes = try? resolver.data(for: payload)
        else { return nil }
        return .init(pasteboardType: payload.pasteboardType, data: bytes)
      }
      let preview = RichTextPreview.preview(from: rich)
      let text = preview.text
      let fallback = "Rich content · copy to use its original formatting."
      let message = text.isEmpty && selected.preview.isEmpty ? fallback : nil
      return (
        text.isEmpty ? (selected.preview.isEmpty ? fallback : selected.preview) : text,
        nil, preview.isTruncated, message
      )
    }.value
    guard selectedID == selected.id, generation == previewGeneration,
      !selected.sensitive || revealedSensitiveID == selected.id
    else { return }
    previewText = result.0
    previewImage = result.1
    previewTruncated = result.2
    previewMessage = result.3
  }

  @MainActor func load() async {
    guard store == nil else { return }
    do {
      let args = CommandLine.arguments
      let directory: URL
      if let prepared = DesktopApplicationContext.dataRoot {
        directory = prepared
      } else if let position = args.firstIndex(of: "--smoke-root")
        ?? args.firstIndex(of: "--data-root"),
        position + 1 < args.count
      {
        directory = URL(fileURLWithPath: args[position + 1], isDirectory: true)
      } else {
        directory = try await Task.detached {
          try AppPaths.defaultStoreRoot(directoryName: "Clipboard")
        }.value
      }
      root = directory
      credentials = NativeDesktopCredentials(namespace: DesktopApplicationContext.profile)
      let settingsStore = JSONDesktopSettingsStore(root: directory)
      self.settingsStore = settingsStore
      do { settings = try await settingsStore.load() } catch {
        shellStatus = "Saved settings could not be read. Recording starts paused."
      }
      uiLanguage = settings.languageOverride
      appearance = settings.appearance
      DesktopAppearance.apply(appearance)
      effectiveDark = DesktopAppearance.currentIsDark
      aiEnabledDraft = settings.ai.enabled
      aiTextDraft = settings.ai.allowText
      aiImagesDraft = settings.ai.allowImages
      aiFilesDraft = settings.ai.allowFiles
      aiCredentialDraft = settings.ai.usesCredential
      aiEndpointDraft = settings.ai.endpoint
      aiModelDraft = settings.ai.model
      automaticSummariesDraft = settings.automaticSummaries
      automaticOCRDraft = settings.automaticOCR
      localTextSummariesDraft = settings.localTextSummariesEnabled
      automaticLocalSummariesDraft = settings.automaticLocalSummaries
      localFileSummariesDraft = settings.localFileSummariesEnabled
      automaticLocalFileSummariesDraft = settings.automaticLocalFileSummaries
      var startupBackend: NativeDesktopStartup?
      if DesktopApplicationContext.profile == "production" {
        startupBackend = try? NativeDesktopStartup(
          executable: DesktopApplicationContext.executableURL)
      } else if args.contains("--smoke-root"), args.contains("--smoke-startup") {
        // Private native-state fixture: never register an application that can
        // launch a production profile, and never use the normal startup name.
        startupBackend = try? NativeDesktopStartup(
          executable: directory.appendingPathComponent(".startup-no-launch"),
          name: "com.clipboard.test." + DesktopApplicationContext.profile,
          configRoot: directory.appendingPathComponent(".startup-config"))
      }
      if let startupBackend {
        startup = DesktopStartupState(backend: startupBackend) { [weak self] enabled, busy in
          guard let self, !self.shuttingDown else { return }
          if self.startupEnabled != enabled { self.startupEnabled = enabled }
          if self.startupBusy != busy { self.startupBusy = busy }
        }
        startupAvailable = true
      }
      capacityDraft = String(settings.historyCapacity)
      maxSizeDraft = DesktopSizeLimit.mibString(forBytes: settings.maxClipSizeBytes)
      blockedAppsDraft = settings.blockedAppIDs.joined(separator: ", ")
      blocklistEnabledDraft = settings.blocklistEnabled
      skipSensitiveDraft = settings.skipSensitive
      shortcutDraft = settings.shortcut
      shortcutEnabledDraft = settings.shortcutEnabled
      closeToTrayDraft = settings.closeToTray
      showOnLaunchDraft = settings.showOnLaunch
      recordOnLaunchDraft = settings.recordingEnabled
      let store = try await JSONSnapshotClipStore(root: directory, cap: settings.historyCapacity)
      self.store = store
      if args.contains("--smoke-root"), await store.all().isEmpty {
        for text in Self.fixtures {
          let data = Data(text.utf8)
          await store.insert(
            RawClipItem(
              payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
              totalBytes: data.count))
        }
        await store.flush()
      }
      if args.contains("--smoke-root"), args.contains("--smoke-sensitive") {
        let text = Data("Sensitive synthetic preview fixture · 中文".utf8)
        let image = Data(
          base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGPQyLvznxLMMGrAqAGjBgwXAwBc3HEfVZuzFAAAAABJRU5ErkJggg=="
        )!
        for payload in [
          RawPayload(pasteboardType: "public.utf8-plain-text", data: text),
          RawPayload(pasteboardType: "public.png", data: image),
        ] {
          await store.insert(
            RawClipItem(
              payloads: [payload], totalBytes: payload.data.count,
              isSensitive: true, sensitivityReason: "synthetic-preview-fixture"))
        }
        await store.flush()
      }
      let events = store.events
      eventsTask = Task { @MainActor [weak self] in
        for await event in events {
          guard !Task.isCancelled, let self else { break }
          switch event {
          case .deleted(let id), .evicted(let id, _, _):
            self.analysisScheduler.cancel(id: id)
            self.analysisProgress.remove(id: id)
          case .cleared:
            self.analysisScheduler.cancelAll()
            self.analysisProgress.clear()
          default: break
          }
          // Keep native editors/drafts while hidden, without rerendering history
          // for every captured item. Refresh once before the next presentation.
          if self.nativeWindow?.isVisible != false && !self.showsSettings { await self.refresh() }
          if case .inserted(let item) = event, !item.sensitive {
            if self.settings.automaticSummaries && self.settings.ai.allowsSummary(of: item.kind) {
              self.enqueueAutomaticAnalysis(remote: true, item: item)
            } else if self.settings.localFileSummariesEnabled
              && self.settings.automaticLocalFileSummaries
              && item.kind == .file
            {
              self.enqueueAutomaticAnalysis(remote: false, item: item)
            } else if self.settings.localTextSummariesEnabled
              && self.settings.automaticLocalSummaries
              && [.text, .rtf, .mixed].contains(item.kind)
            {
              self.enqueueAutomaticAnalysis(remote: false, item: item)
            } else if self.settings.automaticOCR && item.kind == .image {
              self.enqueueAutomaticAnalysis(remote: false, item: item)
            }
          }
        }
      }
      await refresh()
      await configureShell()
      ready = true
      status = "Ready"
      if showsSettings { await refreshStartup() }
      if !showsSettings { nativeWindow?.focusSearch() }
      if settings.recordingEnabled { await setRecording(true) }
      if (!settings.showOnLaunch || CommandLine.arguments.contains("--background")) && canHide
        && !startupActivationRequested
      {
        windowCoordinator?.hide()
      }
    } catch { status = "History could not be opened." }
  }

  @MainActor private func configureShell() async {
    let shell = NativeDesktopShell()
    self.shell = shell
    let shortcut = settings.shortcutEnabled ? try? DesktopShortcut(parsing: settings.shortcut) : nil
    do {
      try await Task.detached { try shell.start(shortcut: shortcut, recording: false) }.value
    } catch DesktopShellError.shortcutConflict {
      shellStatus = "The global shortcut is already in use. Choose another in Settings."
    } catch { shellStatus = "The global shortcut is unavailable in this desktop session." }
    shell.updateLanguage(DesktopUILanguage.resolve(override: settings.languageOverride).rawValue)
    reconcileShellCapabilities()
    let actions = shell.actions
    if let instance = DesktopApplicationContext.instance {
      let activations = instance.activations
      activationTask = Task { @MainActor [weak self] in
        for await _ in activations {
          guard !Task.isCancelled, let self else { break }
          self.nativeWindow?.activationTimestamp = 0
          await self.showHistory()
        }
      }
    }
    shellTask = Task { @MainActor [weak self] in
      for await event in actions {
        guard !Task.isCancelled, let self else { break }
        self.nativeWindow?.activationTimestamp = shell.activationTimestamp
        let action = event.action
        switch action {
        case .toggleHistory:
          if self.nativeWindow?.isVisible == true && !self.showsSettings {
            self.hide()
          } else {
            await self.showHistory()
          }
        case .showHistory:
          self.nativeWindow?.activationToken = event.activationToken
          await self.showHistory()
        case .showPreferences: self.showPreferences()
        case .toggleRecording: await self.toggleRecording()
        case .quit: await self.shutdown()
        case .capabilitiesChanged: self.reconcileShellCapabilities()
        }
      }
    }
  }
  @MainActor private func reconcileShellCapabilities() {
    guard let shell else { return }
    let capabilities = shell.capabilities
    switch capabilities.shortcutPortal {
    case .pending: shellStatus = "Waiting for the desktop shortcut portal."
    case .permissionRequired:
      shellStatus = "Apply the shortcut to request permission from your desktop."
    case .denied: shellStatus = "Shortcut permission was declined. Apply again to retry."
    case .unavailable:
      shellStatus = "The global shortcut portal is unavailable on this Wayland desktop."
    case .active:
      shellStatus =
        "The desktop manages this shortcut. Its assigned keys may differ from the preference."
    case .notApplicable: break
    }
    canHide = capabilities.tray || capabilities.globalShortcut
    if !capabilities.tray && shellStatus.isEmpty {
      shellStatus =
        capabilities.globalShortcut
        ? "System tray unavailable in this desktop session. Use the global shortcut to reopen."
        : "System tray unavailable in this desktop session. Closing this window quits Clipboard."
    }
    if !canHide && nativeWindow?.isVisible == false { nativeWindow?.present() }
  }

  @MainActor func showHistory() async {
    invalidateAIConnection()
    if !ready { startupActivationRequested = true }
    if showsSettings { showsSettings = false }
    // Each presentation starts at the first matching row, retaining query/tab/source.
    kindFilter = nil
    selectedID = nil
    await refresh()
    await Task.yield()
    windowCoordinator?.showHistory()
  }
  @MainActor func showPreferences() {
    resetSensitivePreview()
    if !ready { startupActivationRequested = true }
    if !showsSettings { showsSettings = true }
    windowCoordinator?.showPreferences()
    Task { @MainActor [weak self] in await self?.refreshStartup() }
  }
  @MainActor func hide() { if canHide { windowCoordinator?.hide() } }

  @MainActor func selectTab(onlyPinned next: Bool) async {
    guard onlyPinned != next else { return }
    onlyPinned = next
    kindFilter = nil
    selectedID = nil
    await refresh()
  }
  @MainActor func selectKind(_ next: ClipKind?) async {
    guard kindFilter != next else { return }
    kindFilter = next
    selectedID = nil
    await refresh()
  }

  @MainActor func refresh() async {
    guard let store else { return }
    let requestedQuery = query
    let requestedPinned = onlyPinned
    let requestedKind = kindFilter
    let requestedSource = sourceFilter
    let found = await store.search(
      query: requestedQuery,
      filters: SearchFilters(
        sourceBundleID: requestedSource.isEmpty ? nil : requestedSource))
    guard query == requestedQuery, onlyPinned == requestedPinned, kindFilter == requestedKind,
      sourceFilter == requestedSource
    else { return }
    let projection = DesktopHistoryProjection(
      matching: found, onlyPinned: requestedPinned, kind: requestedKind)
    allItemsCount = projection.allCount
    pinnedItemsCount = projection.pinnedCount
    allTypesCount = projection.allTypesCount
    kindCounts = projection.kindCounts
    items = projection.items
    if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    await loadPreview()
  }
  @MainActor func togglePin() async {
    guard let store, let selected else { return }
    let wasPinned = selected.pinned
    await store.togglePin(id: selected.id)
    await store.flush()
    await refresh()
    status = wasPinned ? "Item unpinned" : "Item pinned"
  }
  @MainActor func deleteSelected() async {
    guard let store, let selectedID else { return }
    if let index = items.firstIndex(where: { $0.id == selectedID }) {
      self.selectedID =
        index + 1 < items.count ? items[index + 1].id : index > 0 ? items[index - 1].id : nil
    }
    analysisScheduler.cancel(id: selectedID)
    await store.delete(id: selectedID)
    await store.flush()
    await refresh()
    status = "Item deleted"
  }

  @MainActor private func nativeClipboard() async throws -> any RichClipboardAccess {
    if let clipboard { return clipboard }
    #if os(Linux)
      // This branch is reachable only in a synthetic, separately owned profile.
      if CommandLine.arguments.contains("--smoke-root")
        && CommandLine.arguments.contains("--smoke-copy-only")
      {
        let fallback = GtkCopyOnlyClipboard()
        clipboard = fallback
        return fallback
      }
    #endif
    if clipboardTask == nil {
      clipboardTask = Task.detached { try SystemRichClipboard() as any RichClipboardAccess }
    }
    guard let task = clipboardTask else { throw TextClipboardError.unavailable }
    do {
      let clipboard = try await task.value
      self.clipboard = clipboard
      clipboardTask = nil
      return clipboard
    } catch {
      clipboardTask = nil
      #if os(Linux)
        if ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] != nil {
          let fallback = GtkCopyOnlyClipboard()
          clipboard = fallback
          return fallback
        }
      #endif
      throw error
    }
  }
  @MainActor func copySelected() async {
    guard let selected else { return }
    do {
      let writer = RichPasteboardWriter(
        clipboard: try await nativeClipboard(), blobRoot: root?.appendingPathComponent("blobs"))
      try await Task.detached(priority: .userInitiated) { try writer.write(selected) }.value
      // Match macOS activation even when capture is paused: promote only after a successful copy.
      await store?.bumpToTop(id: selected.id)
      await store?.flush()
      await refresh()
      status = "Copied to clipboard"
    } catch { status = "Clipboard is unavailable in this session." }
  }

  @MainActor func toggleRecording() async { await setRecording(!recording) }
  @MainActor private func setRecording(_ enabled: Bool) async {
    guard !recordingTransition, ready, recording != enabled else { return }
    recordingTransition = true
    defer { recordingTransition = false }
    if !enabled {
      await stopCapture()
      status = "Recording paused"
    } else {
      do {
        let clipboard = try await nativeClipboard()
        guard clipboard.canMonitor else {
          status =
            "Clipboard capture is unavailable on this Wayland desktop. Copy remains available."
          return
        }
        let preferences = settings
        let monitor = await Task.detached {
          RichClipboardMonitor(
            clipboard: clipboard,
            filter: FilterChain(filters: [
              SizeFilter(maxClipSizeBytes: preferences.maxClipSizeBytes),
              SensitivityFilter(skipSensitive: preferences.skipSensitive),
              BlocklistFilter(
                blockedBundleIDs: preferences.blocklistEnabled ? Set(preferences.blockedAppIDs) : []
              ),
            ]), maxBytes: preferences.maxClipSizeBytes, interval: 0.3)
        }.value
        self.monitor = monitor
        let changes = monitor.changes
        captureTask = Task { @MainActor [weak self] in
          for await raw in changes {
            guard !Task.isCancelled, let self, let store = self.store else { break }
            await store.insert(raw)
          }
        }
        let skips = monitor.skips
        captureSkipsTask = Task { @MainActor [weak self] in
          for await skip in skips {
            guard !Task.isCancelled, let self else { break }
            if skip.reason == "unsupportedSession" {
              await self.stopCapture()
              self.clipboard = nil
              self.clipboardTask = nil
              self.shell?.updateRecording(false)
              self.status =
                "Clipboard capture is unavailable on this Wayland desktop. Copy remains available."
              break
            }
          }
        }
        recording = true
        status = "Recording clipboard"
        await Task.detached { monitor.start() }.value
      } catch { status = "Clipboard is unavailable in this session." }
    }
    let value = recording
    if let shell { await Task.detached { shell.updateRecording(value) }.value }
  }

  @MainActor private func stopCapture() async {
    let old = monitor
    monitor = nil
    recording = false
    captureTask?.cancel()
    captureTask = nil
    captureSkipsTask?.cancel()
    captureSkipsTask = nil
    await Task.detached { old?.stop() }.value
  }

  @MainActor func applyShortcut() async {
    guard let shell, let settingsStore else { return }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.shortcutEnabled = shortcutEnabledDraft
    next.shortcut = shortcutDraft
    do {
      try next.validate()
      let shortcut = next.shortcutEnabled ? try DesktopShortcut(parsing: next.shortcut) : nil
      let oldShortcut =
        settings.shortcutEnabled ? try DesktopShortcut(parsing: settings.shortcut) : nil
      let recording = recording
      try await Task.detached { try shell.start(shortcut: shortcut, recording: recording) }.value
      do { try await settingsStore.save(next) } catch {
        try? await Task.detached { try shell.start(shortcut: oldShortcut, recording: recording) }
          .value
        throw error
      }
      settings = next
      await Task.detached { shell.requestShortcutPermission() }.value
      shellStatus = ""
      reconcileShellCapabilities()
      status = "Shortcut saved"
    } catch DesktopShellError.shortcutConflict {
      status = "Shortcut already in use. Previous binding kept."
    } catch { status = "Shortcut could not be saved. Previous settings kept." }
  }
  @MainActor func applyBehavior() async {
    guard let settingsStore else { return }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.closeToTray = closeToTrayDraft
    next.showOnLaunch = showOnLaunchDraft
    next.recordingEnabled = recordOnLaunchDraft
    do {
      try await settingsStore.save(next)
      settings = next
      status = "Settings saved"
    } catch { status = "Settings could not be saved." }
  }

  @MainActor func applyContentSettings() async {
    guard let settingsStore, let store,
      let capacity = Int(capacityDraft),
      let byteLimit = DesktopSizeLimit.bytes(fromMiB: maxSizeDraft)
    else {
      status = "Enter a capacity of 1–5000 and a valid size in MiB."
      return
    }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.historyCapacity = capacity
    next.maxClipSizeBytes = byteLimit
    next.blockedAppIDs = blockedAppsDraft.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    next.blocklistEnabled = blocklistEnabledDraft
    next.skipSensitive = skipSensitiveDraft
    do {
      try next.validate()
      try await settingsStore.save(next)
      settings = next
      try await store.setCapacity(capacity)
      let wasRecording = recording
      if wasRecording {
        await setRecording(false)
        await setRecording(true)
      }
      await refresh()
      status = "Content settings saved"
    } catch { status = "Content settings could not be saved." }
  }
  @MainActor func clearHistory() async {
    guard let store else { return }
    confirmsClearHistory = false
    analysisScheduler.cancelAll()
    await store.clearAll()
    await store.flush()
    await refresh()
    status = "History cleared"
  }
  @MainActor func exportHistory(to destination: URL) async {
    guard let store else { return }
    let items = await store.all()
    let blobRoot = root?.appendingPathComponent("blobs")
    do {
      try await Task.detached {
        try DesktopHistoryArchive.write(items: items, blobRoot: blobRoot, to: destination)
      }.value
      status = "History exported. Sensitive items excluded."
    } catch { status = "Export failed. Check the destination and archive size (256 MiB maximum)." }
  }
  @MainActor func importHistory(from source: URL) async {
    guard let store else { return }
    do {
      let archive = try await Task.detached { try DesktopHistoryArchive.readResult(from: source) }
        .value
      // The store prepends imports. Reverse this newest-first archive so its
      // relative order survives insertion into an existing history.
      let result = await store.importItems(Array(archive.items.reversed()), blobsRoot: nil)
      await store.flush()
      await refresh()
      status =
        "Imported \(result.added) items; \(result.skipped + archive.skipped) skipped; \(result.blobsMissing + archive.blobsMissing) missing blobs."
    } catch { status = "Import failed. Choose a Clipboard ZIP or JSON archive." }
  }

  @MainActor func refreshStartup() async {
    guard let startup, showsSettings, !shuttingDown else { return }
    do { try await startup.refresh() } catch {
      if showsSettings, !shuttingDown {
        status =
          error as? DesktopServiceError == .startupConflict
          ? "Startup entry conflicts with this installation. Check system startup settings before retrying."
          : "Startup integration is unavailable in this session."
      }
    }
  }
  @MainActor func toggleStartup() async {
    guard let startup else {
      status = "Startup integration is unavailable in this session."
      return
    }
    guard !startupBusy, !shuttingDown else { return }
    do {
      if try await startup.apply(!startupEnabled), showsSettings, !shuttingDown {
        status = "Startup setting saved"
      }
    } catch {
      if showsSettings, !shuttingDown {
        status =
          error as? DesktopServiceError == .startupConflict
          ? "Startup entry conflicts with this installation. Check system startup settings before retrying."
          : "Startup setting could not be changed."
      }
    }
  }
  @MainActor func copyAnalysisResult() async {
    guard let item = selected, !item.sensitive, let text = item.summary else { return }
    do {
      let clipboard = try await nativeClipboard()
      try await Task.detached {
        try clipboard.write(
          payloads: [.init(pasteboardType: "public.utf8-plain-text", data: Data(text.utf8))],
          sensitive: false)
      }.value
      status = "Copied to clipboard"
    } catch { status = "Clipboard is unavailable in this session." }
  }
  @MainActor private var connectionConfiguration: DesktopAISettings {
    var value = settings.ai
    value.enabled = aiEnabledDraft
    value.endpoint = aiEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    value.model = aiModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    value.usesCredential = aiCredentialDraft
    return value
  }
  @MainActor var canTestAIConnection: Bool {
    ready && !shuttingDown && aiEnabledDraft && (try? connectionConfiguration.validate()) != nil
  }
  @MainActor func testAIConnection() {
    guard canTestAIConnection else { return }
    aiConnection.start(settings: connectionConfiguration)
  }
  @MainActor func cancelAIConnection() { aiConnection.cancel() }
  @MainActor func invalidateAIConnection() { aiConnection.invalidate() }
  var connectionMessage: String? {
    if connectionBusy { return "Testing connection…" }
    guard let connectionResult else { return nil }
    switch connectionResult {
    case .connected: return "AI connection is ready."
    case .disabled: return "Enable AI before testing the connection."
    case .invalidConfiguration:
      return "Check the model and endpoint. Use HTTPS, or HTTP for a loopback server."
    case .credentialsUnavailable:
      return "The saved API key is unavailable. Save or unlock it, then retry."
    case .authenticationFailed: return "Access was denied. Check the saved API key and permissions."
    case .notFound: return "Model or API path was not found. Check the model and endpoint."
    case .rateLimited: return "The service is rate limited. Try again later."
    case .requestRejected: return "The service rejected the test. Check the model and endpoint."
    case .serverError: return "The service is unavailable. Try again later."
    case .redirected: return "The service redirected the test. Set the final endpoint."
    case .unusableResponse: return "The service did not return a usable chat completion."
    case .networkFailure: return "Could not reach the service. Check the endpoint and network."
    case .cancelled: return "Connection test cancelled."
    }
  }
  @MainActor func saveAISettings() async {
    guard let settingsStore else { return }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.ai.enabled = aiEnabledDraft
    next.ai.allowText = aiTextDraft
    next.ai.allowImages = aiImagesDraft
    next.ai.allowFiles = aiFilesDraft
    next.ai.usesCredential = aiCredentialDraft
    next.ai.endpoint = aiEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    next.ai.model = aiModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    next.automaticSummaries = automaticSummariesDraft
    next.automaticOCR = automaticOCRDraft
    next.localTextSummariesEnabled = localTextSummariesDraft
    next.automaticLocalSummaries = automaticLocalSummariesDraft
    next.localFileSummariesEnabled = localFileSummariesDraft
    next.automaticLocalFileSummaries = automaticLocalFileSummariesDraft
    do {
      try next.validate()
      try await settingsStore.save(next)
      settings = next
      if let active = analysisScheduler.currentRequest {
        // Revoke synchronously with the settings update. A store await here can
        // let an already completed read/credential lookup initiate transport.
        // If the active item is outside the retained view, fail closed.
        let current = items.first(where: { $0.id == active.id })
        if analysisScheduler.recheckCurrent(id: active.id, item: current, settings: settings) {
          analysisProgress.remove(id: active.id)
        }
      }
      status = "AI settings saved"
    } catch { status = "Check the model and endpoint. Use HTTPS, or HTTP for a loopback server." }
  }
  @MainActor func saveAPIKey() async {
    guard ready, !aiKeyDraft.isEmpty else { return }
    invalidateAIConnection()
    // A test may start while the credential store suspends this operation.
    // Its result becomes stale when the saved key or selected-key draft changes.
    defer { invalidateAIConnection() }
    var configuration = settings.ai
    configuration.endpoint = aiEndpointDraft
    do {
      try configuration.validate()
      try await credentials.save(aiKeyDraft, account: configuration.credentialAccount)
      aiKeyDraft = ""
      aiCredentialDraft = true
      status = "API key saved in the system credential store. Save AI settings to use it."
    } catch {
      status = "Secure credential storage is unavailable or locked. No plaintext fallback was used."
    }
  }
  @MainActor func deleteAPIKey() async {
    invalidateAIConnection()
    // A test may start while the credential store suspends this operation.
    // Its result becomes stale when the saved key or selected-key draft changes.
    defer { invalidateAIConnection() }
    var configuration = settings.ai
    configuration.endpoint = aiEndpointDraft
    do {
      try await credentials.delete(account: configuration.credentialAccount)
      aiKeyDraft = ""
      aiCredentialDraft = false
      status = "API key deleted. Save AI settings to update the connection."
    } catch { status = "Secure credential storage is unavailable or locked." }
  }
  @MainActor private func enqueueAutomaticAnalysis(remote: Bool, item: ClipItem) {
    guard !shuttingDown, !item.sensitive, item.summary == nil else { return }
    let result = analysisScheduler.submit(.init(id: item.id, remote: remote, automatic: true))
    if result == .full {
      status = "Automatic analysis queue is full. Analyze skipped items manually."
    }
  }
  var selectedAnalysisProgress: DesktopItemAnalysisProgress? {
    guard let item = selected, !item.sensitive else { return nil }
    return itemAnalysisProgress[item.id]
  }
  @MainActor func retryAnalysis() {
    guard case .failed(let remote)? = selectedAnalysisProgress else { return }
    analyze(remote: remote)
  }
  @MainActor func analyze(remote: Bool, item requested: ClipItem? = nil) {
    guard !shuttingDown, let item = requested ?? selected, !item.sensitive else { return }
    analysisScheduler.submit(.init(id: item.id, remote: remote, automatic: false))
  }
  @MainActor private func performAnalysis(_ request: DesktopAnalysisScheduler.Request) async {
    guard let item = await store?.item(id: request.id) else { return }
    // Recheck live preferences after waiting; disabling automation revokes queued work.
    guard !shuttingDown, !Task.isCancelled, request.isAllowed(item: item, settings: settings)
    else { return }
    guard let ticket = analysisProgress.begin(id: item.id, remote: request.remote) else { return }
    let remote = request.remote
    let localText = !remote && item.kind != .image
    let configuration = settings.ai
    let service = DesktopAnalysis(
      credentials: credentials, transport: transport, ocr: ocr,
      blobRoot: root?.appendingPathComponent("blobs"), fileReader: NativeDesktopFileTextReader())
    let language = settings.languageOverride
    do {
      let result =
        try await
        (remote
        ? service.summarize(item, settings: configuration, language: language)
        : localText ? service.summarizeLocally(item) : service.recognize(item, language: language))
      try Task.checkCancellation()
      guard !result.isEmpty else {
        analysisProgress.finish(ticket, succeeded: false)
        status = "No text was recognized."
        return
      }
      guard let current = await store?.item(id: item.id), !shuttingDown,
        analysisProgress.isCurrent(ticket), request.isAllowed(item: current, settings: settings)
      else {
        analysisProgress.remove(id: item.id)
        return
      }
      await store?.updateSummary(
        id: item.id, summary: result,
        source: remote ? .remoteOpenAI : localText ? .localExtractive : .localOCR)
      await store?.flush()
      loadedPreviewID = nil
      await refresh()
      analysisProgress.finish(ticket, succeeded: true)
      status = remote || localText ? "Summary ready" : "OCR text ready"
    } catch is CancellationError {
      analysisProgress.remove(id: item.id)
      if !shuttingDown && !showsSettings && selectedID == item.id
        && items.contains(where: { $0.id == item.id })
      {
        status = "Analysis cancelled"
      }
    } catch {
      if Task.isCancelled {
        analysisProgress.remove(id: item.id)
        return
      }
      analysisProgress.finish(ticket, succeeded: false)
      if item.kind == .file,
        !remote
          || [DesktopServiceError.invalidValue, .tooLarge, .fileUnavailable].contains(
            error as? DesktopServiceError ?? .networkFailure)
      {
        status =
          "Use readable UTF-8 text or an unencrypted text PDF. File and text: at most 1 MiB; PDF: at most 256 pages. Local excerpts need at least 100 characters."
      } else {
        status =
          remote
          ? "Summary unavailable. Check AI settings and the connection."
          : localText
            ? "Local excerpts need at least 100 characters of readable text."
            : "OCR unavailable. Check the image and installed OCR language packs."
      }
    }
  }
  @MainActor func setAppearance(_ value: String) async {
    guard let settingsStore else { return }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.appearance = value
    do {
      try await settingsStore.save(next)
      settings = next
      appearance = value
      DesktopAppearance.apply(value)
      effectiveDark = DesktopAppearance.currentIsDark
      status = "Appearance saved"
    } catch { status = "Settings could not be saved." }
  }
  @MainActor func setLanguage(_ value: String?) async {
    guard let settingsStore else { return }
    await settingsSaveGate.acquire()
    defer { settingsSaveGate.release() }
    guard !shuttingDown else { return }
    var next = settings
    next.languageOverride = value
    do {
      try await settingsStore.save(next)
      settings = next
      uiLanguage = value
      shell?.updateLanguage(DesktopUILanguage.resolve(override: value).rawValue)
      status = "Language saved"
    } catch { status = "Settings could not be saved." }
  }
  @MainActor func t(_ value: String) -> String {
    DesktopLocalization.text(value, language: uiLanguage)
  }

  @MainActor func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
    startup?.stop()
    aiConnection.stop()
    resetSensitivePreview()
    analysisProgress.stop()
    analysisScheduler.stop()
    captureTask?.cancel()
    captureSkipsTask?.cancel()
    shellTask?.cancel()
    activationTask?.cancel()
    eventsTask?.cancel()
    let old = monitor
    monitor = nil
    let shell = shell
    await Task.detached {
      old?.stop()
      shell?.stop()
    }.value
    await store?.flush()
    let instance = DesktopApplicationContext.instance
    await Task.detached { instance?.stop() }.value
    nativeWindow?.quit()
  }
  deinit {
    monitor?.stop()
    shell?.stop()
    captureTask?.cancel()
    captureSkipsTask?.cancel()
    eventsTask?.cancel()
    shellTask?.cancel()
    activationTask?.cancel()
  }
}
