import ClipboardCore
import DesktopClipboard
import DesktopShell
import Foundation
import Gtk
import SwiftCrossUI

/// Presentation state; persistence, filters and native ownership stay in Core/adapters.
final class HistoryModel: ObservableObject {
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
  private var eventsTask: Task<Void, Never>?
  private var shellTask: Task<Void, Never>?
  private var activationTask: Task<Void, Never>?
  private var loadedPreviewID: UUID?
  @MainActor private var nativeWindow: GtkDesktopWindow?
  @MainActor private weak var searchEntry: Gtk.Entry?
  @MainActor private var windowCoordinator: DesktopWindowCoordinator?
  @MainActor private var shuttingDown = false
  @MainActor private var applyingSettings = false

  static let fixtures = [
    "Welcome to Clipboard Preview",
    "中文笔记 · 设计评审与输入测试",
    "Release checklist · build, test, publish",
  ]
  var selected: ClipItem? { items.first { $0.id == selectedID } }

  @MainActor func attachWindow(_ window: Gtk.Window) {
    if nativeWindow == nil {
      let presenter = GtkDesktopWindow()
      nativeWindow = presenter
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
      previewText = "Choose an item to preview its content."
      return
    }
    guard loadedPreviewID != selected.id else { return }
    loadedPreviewID = selected.id
    previewImage = nil
    if selected.sensitive {
      previewText = "Sensitive content is hidden."
      return
    }
    previewText = "Loading preview…"
    let resolver = PayloadResolver(blobRoot: root?.appendingPathComponent("blobs"))
    let result = await Task.detached(priority: .userInitiated) {
      () -> (String, DesktopPreviewImage?) in
      if selected.kind == .image,
        let payload = selected.payloads.first(where: {
          ClipKind.imagePayloadTypes.contains($0.pasteboardType)
        }),
        let bytes = try? resolver.data(for: payload)
      {
        return ("Image · \(selected.sizeBytes) bytes", DesktopPreviewImage.decode(bytes))
      }
      if selected.kind == .file,
        let payload = selected.payloads.first(where: { $0.pasteboardType == "public.file-url" }),
        let bytes = try? resolver.data(for: payload),
        let urls = try? ClipboardFormats.fileURLs(from: bytes)
      {
        return (urls.map(\.path).joined(separator: "\n"), nil)
      }
      if let payload = selected.payloads.first(where: {
        ["public.utf8-plain-text", "public.plain-text", "public.string"].contains($0.pasteboardType)
      }),
        let bytes = try? resolver.data(for: payload),
        let text = String(data: bytes, encoding: .utf8)
      {
        return (String(text.prefix(8000)), nil)
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
            ? "Rich content · copy to use its original formatting." : selected.preview) : text, nil
      )
    }.value
    guard selectedID == selected.id else { return }
    previewText = result.0
    previewImage = result.1
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
      let settingsStore = JSONDesktopSettingsStore(root: directory)
      self.settingsStore = settingsStore
      do { settings = try await settingsStore.load() } catch {
        shellStatus = "Saved settings could not be read. Recording starts paused."
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
        for await _ in events {
          guard !Task.isCancelled, let self else { break }
          // Keep native editors/drafts while hidden, without rerendering history
          // for every captured item. Refresh once before the next presentation.
          if self.nativeWindow?.isVisible != false && !self.showsSettings { await self.refresh() }
        }
      }
      await refresh()
      await configureShell()
      ready = true
      status = "Ready"
      nativeWindow?.focusSearch()
      if settings.recordingEnabled { await setRecording(true) }
      if !settings.showOnLaunch && canHide { windowCoordinator?.hide() }
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
      for await action in actions {
        guard !Task.isCancelled, let self else { break }
        self.nativeWindow?.activationTimestamp = shell.activationTimestamp
        switch action {
        case .toggleHistory:
          if self.nativeWindow?.isVisible == true && !self.showsSettings {
            self.hide()
          } else {
            await self.showHistory()
          }
        case .showHistory: await self.showHistory()
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
    if showsSettings { showsSettings = false }
    await refresh()
    await Task.yield()
    windowCoordinator?.showHistory()
  }
  @MainActor func showPreferences() {
    if !showsSettings { showsSettings = true }
    windowCoordinator?.showPreferences()
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
    if clipboardTask == nil {
      clipboardTask = Task.detached { try SystemRichClipboard() as any RichClipboardAccess }
    }
    guard let task = clipboardTask else { throw TextClipboardError.unavailable }
    do {
      let clipboard = try await task.value
      self.clipboard = clipboard
      return clipboard
    } catch {
      clipboardTask = nil
      throw error
    }
  }
  @MainActor func copySelected() async {
    guard let selected else { return }
    do {
      let writer = RichPasteboardWriter(
        clipboard: try await nativeClipboard(), blobRoot: root?.appendingPathComponent("blobs"))
      try await Task.detached(priority: .userInitiated) { try writer.write(selected) }.value
      status = "Copied to clipboard"
    } catch { status = "Clipboard is unavailable in this session." }
  }

  @MainActor func toggleRecording() async { await setRecording(!recording) }
  @MainActor private func setRecording(_ enabled: Bool) async {
    guard !recordingTransition, ready, recording != enabled else { return }
    recordingTransition = true
    defer { recordingTransition = false }
    if !enabled {
      let old = monitor
      monitor = nil
      captureTask?.cancel()
      captureTask = nil
      await Task.detached { old?.stop() }.value
      recording = false
      status = "Recording paused"
    } else {
      do {
        let clipboard = try await nativeClipboard()
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
        await Task.detached { monitor.start() }.value
        recording = true
        status = "Recording clipboard"
      } catch { status = "Clipboard is unavailable in this session." }
    }
    let value = recording
    if let shell { await Task.detached { shell.updateRecording(value) }.value }
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

  @MainActor func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
    captureTask?.cancel()
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
    eventsTask?.cancel()
    shellTask?.cancel()
    activationTask?.cancel()
  }
}
