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
  @Published var startupEnabled = false
  @Published var startupAvailable = false
  @Published var aiEnabledDraft = false
  @Published var aiImagesDraft = false
  @Published var aiCredentialDraft = false
  @Published var aiEndpointDraft = "https://api.openai.com/v1"
  @Published var aiModelDraft = ""
  @Published var aiKeyDraft = ""
  @Published var automaticSummariesDraft = false
  @Published var automaticOCRDraft = false
  @Published var appearance = "system"
  @Published var effectiveDark = false
  @Published var uiLanguage: String?
  private var credentials = NativeDesktopCredentials()
  private let ocr = NativeDesktopOCR()
  private let transport = BoundedDesktopAITransport()
  private var startup: NativeDesktopStartup?
  @MainActor private lazy var analysisScheduler = DesktopAnalysisScheduler(
    busyChanged: { [weak self] in self?.analysisBusy = $0 },
    perform: { [weak self] in await self?.performAnalysis($0) })
  @Published var items: [ClipItem] = []
  @Published var query = ""
  @Published var onlyPinned = false
  @Published var selectedID: UUID?
  @Published var showsSettings = false
  @Published var status = "Loading history"
  @Published var recording = false
  @Published var recordingTransition = false
  @Published var ready = false
  @Published var previewText = "Choose an item to preview its content."
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
  @MainActor private var nativeWindow: GtkDesktopWindow?
  @MainActor private weak var searchEntry: Gtk.Entry?
  @MainActor private var windowCoordinator: DesktopWindowCoordinator?
  @MainActor private var startupActivationRequested = false
  @MainActor private var shuttingDown = false
  @MainActor private var applyingSettings = false

  static let fixtures = [
    "Welcome to Clipboard Preview",
    "中文笔记 · 设计评审与输入测试",
    "Release checklist · build, test, publish",
  ]
  var selected: ClipItem? { items.first { $0.id == selectedID } }

  @MainActor var canSummarize: Bool {
    guard settings.ai.enabled, let item = selected, !item.sensitive, item.kind != .file else {
      return false
    }
    if item.kind == .image {
      return settings.ai.allowImages
        && item.payloads.contains(where: {
          ["public.png", "public.jpeg"].contains($0.pasteboardType)
        })
    }
    return true
  }

  @MainActor func attachWindow(_ window: Gtk.Window) {
    if nativeWindow == nil {
      let presenter = GtkDesktopWindow()
      nativeWindow = presenter
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
      return
    }
    guard loadedPreviewID != selected.id else { return }
    loadedPreviewID = selected.id
    previewImage = nil
    previewTruncated = false
    if selected.sensitive {
      previewText = "Sensitive content is hidden."
      return
    }
    previewText = "Loading preview…"
    let resolver = PayloadResolver(blobRoot: root?.appendingPathComponent("blobs"))
    let result = await Task.detached(priority: .userInitiated) {
      () -> (String, DesktopPreviewImage?, Bool) in
      if selected.kind == .image,
        let payload = selected.payloads.first(where: {
          ClipKind.imagePayloadTypes.contains($0.pasteboardType)
        }),
        let bytes = try? resolver.data(for: payload)
      {
        return ("Image · \(selected.sizeBytes) bytes", DesktopPreviewImage.decode(bytes), false)
      }
      if selected.kind == .file,
        let payload = selected.payloads.first(where: { $0.pasteboardType == "public.file-url" }),
        let bytes = try? resolver.data(for: payload),
        let urls = try? ClipboardFormats.fileURLs(from: bytes)
      {
        return (urls.map(\.path).joined(separator: "\n"), nil, false)
      }
      if let payload = selected.payloads.first(where: {
        ["public.utf8-plain-text", "public.plain-text", "public.string"].contains($0.pasteboardType)
      }),
        let bytes = try? resolver.data(for: payload),
        let text = String(data: bytes, encoding: .utf8)
      {
        let preview = DesktopTextPreview(text)
        return (preview.text, nil, preview.isTruncated)
      }
      let rich = selected.payloads.compactMap { payload -> RawPayload? in
        guard ["public.html", "public.rtf"].contains(payload.pasteboardType),
          let bytes = try? resolver.data(for: payload)
        else { return nil }
        return .init(pasteboardType: payload.pasteboardType, data: bytes)
      }
      let text = RichTextPreview.text(from: rich)
      return (
        text.isEmpty
          ? (selected.preview.isEmpty
            ? "Rich content · copy to use its original formatting." : selected.preview) : text, nil,
        false
      )
    }.value
    guard selectedID == selected.id else { return }
    previewText = result.0
    previewImage = result.1
    previewTruncated = result.2
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
      aiImagesDraft = settings.ai.allowImages
      aiCredentialDraft = settings.ai.usesCredential
      aiEndpointDraft = settings.ai.endpoint
      aiModelDraft = settings.ai.model
      automaticSummariesDraft = settings.automaticSummaries
      automaticOCRDraft = settings.automaticOCR
      if DesktopApplicationContext.profile == "production" {
        startup = try? NativeDesktopStartup(
          executable: DesktopApplicationContext.executableURL)
        startupAvailable = startup != nil
      }
      capacityDraft = String(settings.historyCapacity)
      maxSizeDraft = String(settings.maxClipSizeBytes / (1024 * 1024))
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
      let events = store.events
      eventsTask = Task { @MainActor [weak self] in
        for await event in events {
          guard !Task.isCancelled, let self else { break }
          // Keep native editors/drafts while hidden, without rerendering history
          // for every captured item. Refresh once before the next presentation.
          if self.nativeWindow?.isVisible != false && !self.showsSettings { await self.refresh() }
          if case .inserted(let item) = event, !item.sensitive {
            if self.settings.automaticSummaries && self.settings.ai.enabled && item.kind != .file
              && (item.kind != .image || self.settings.ai.allowImages)
            {
              self.enqueueAutomaticAnalysis(remote: true, item: item)
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
      nativeWindow?.focusSearch()
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
    shell.updateLanguage(settings.languageOverride ?? Locale.preferredLanguages.first ?? "en")
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
    if !ready { startupActivationRequested = true }
    if showsSettings { showsSettings = false }
    await refresh()
    await Task.yield()
    windowCoordinator?.showHistory()
  }
  @MainActor func showPreferences() {
    if !ready { startupActivationRequested = true }
    if !showsSettings { showsSettings = true }
    windowCoordinator?.showPreferences()
    Task { @MainActor [weak self] in await self?.refreshStartup() }
  }
  @MainActor func hide() { if canHide { windowCoordinator?.hide() } }

  @MainActor func refresh() async {
    guard let store else { return }
    let requestedQuery = query
    let requestedPinned = onlyPinned
    let requestedKind = kindFilter
    let requestedSource = sourceFilter
    let found = await store.search(
      query: requestedQuery,
      filters: SearchFilters(
        kinds: requestedKind.map { Set([$0]) },
        sourceBundleID: requestedSource.isEmpty ? nil : requestedSource))
    guard query == requestedQuery, onlyPinned == requestedPinned, kindFilter == requestedKind,
      sourceFilter == requestedSource
    else { return }
    items = requestedPinned ? found.filter(\.pinned) : found
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
    guard !applyingSettings, let shell, let settingsStore else { return }
    applyingSettings = true
    defer { applyingSettings = false }
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
    guard !applyingSettings, let settingsStore else { return }
    applyingSettings = true
    defer { applyingSettings = false }
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
    guard !applyingSettings, let settingsStore, let store,
      let capacity = Int(capacityDraft), let megabytes = Int(maxSizeDraft),
      (1...16).contains(megabytes)
    else {
      status = "Enter a capacity of 1–5000 and a size of 1–16 MiB."
      return
    }
    applyingSettings = true
    defer { applyingSettings = false }
    var next = settings
    next.historyCapacity = capacity
    next.maxClipSizeBytes = megabytes * 1024 * 1024
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
      let items = try await Task.detached { try DesktopHistoryArchive.read(from: source) }.value
      let result = await store.importItems(items, blobsRoot: nil)
      await store.flush()
      await refresh()
      status = "Imported \(result.added) items; \(result.skipped) duplicates skipped."
    } catch { status = "Import failed. Choose a self-contained Clipboard JSON archive." }
  }

  @MainActor func refreshStartup() async {
    guard let startup else { return }
    do { startupEnabled = try await startup.isEnabled() } catch {
      status = "Startup integration is unavailable in this session."
    }
  }
  @MainActor func toggleStartup() async {
    guard let startup else {
      status = "Startup integration is unavailable in this session."
      return
    }
    do {
      try await startup.setEnabled(!startupEnabled)
      startupEnabled = try await startup.isEnabled()
      status = "Startup setting saved"
    } catch { status = "Startup setting could not be changed." }
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
  @MainActor func saveAISettings() async {
    guard !applyingSettings, let settingsStore else { return }
    applyingSettings = true
    defer { applyingSettings = false }
    var next = settings
    next.ai.enabled = aiEnabledDraft
    next.ai.allowImages = aiImagesDraft
    next.ai.usesCredential = aiCredentialDraft
    next.ai.endpoint = aiEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    next.ai.model = aiModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    next.automaticSummaries = automaticSummariesDraft
    next.automaticOCR = automaticOCRDraft
    do {
      try next.validate()
      try await settingsStore.save(next)
      settings = next
      status = "AI settings saved"
    } catch { status = "Check the model and endpoint. Use HTTPS, or HTTP for a loopback server." }
  }
  @MainActor func saveAPIKey() async {
    guard ready, !aiKeyDraft.isEmpty else { return }
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
  @MainActor func analyze(remote: Bool, item requested: ClipItem? = nil) {
    guard !shuttingDown, let item = requested ?? selected, !item.sensitive else { return }
    analysisScheduler.submit(.init(id: item.id, remote: remote, automatic: false))
  }
  @MainActor private func performAnalysis(_ request: DesktopAnalysisScheduler.Request) async {
    guard let item = await store?.item(id: request.id) else { return }
    // Recheck live preferences after waiting; disabling automation revokes queued work.
    guard !shuttingDown, !Task.isCancelled, request.isAllowed(item: item, settings: settings)
    else { return }
    let remote = request.remote
    let configuration = settings.ai
    let service = DesktopAnalysis(
      credentials: credentials, transport: transport, ocr: ocr,
      blobRoot: root?.appendingPathComponent("blobs"))
    let language = settings.languageOverride
    do {
      let result =
        try await
        (remote
        ? service.summarize(item, settings: configuration, language: language)
        : service.recognize(item, language: language))
      try Task.checkCancellation()
      guard !result.isEmpty else {
        status = "No text was recognized."
        return
      }
      await store?.updateSummary(
        id: item.id, summary: result, source: remote ? .remoteOpenAI : .localOCR)
      await store?.flush()
      loadedPreviewID = nil
      await refresh()
      status = remote ? "Summary ready" : "OCR text ready"
    } catch is CancellationError { status = "Analysis cancelled" } catch {
      status =
        remote
        ? "Summary unavailable. Check AI settings and the connection."
        : "OCR unavailable. Check the image and installed OCR language packs."
    }
  }
  @MainActor func setAppearance(_ value: String) async {
    guard !applyingSettings, let settingsStore else { return }
    applyingSettings = true
    defer { applyingSettings = false }
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
    guard !applyingSettings, let settingsStore else { return }
    applyingSettings = true
    defer { applyingSettings = false }
    var next = settings
    next.languageOverride = value
    do {
      try await settingsStore.save(next)
      settings = next
      uiLanguage = value
      shell?.updateLanguage(value ?? Locale.preferredLanguages.first ?? "en")
      status = "Language saved"
    } catch { status = "Settings could not be saved." }
  }
  @MainActor func t(_ value: String) -> String {
    DesktopLocalization.text(value, language: uiLanguage)
  }

  @MainActor func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
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
