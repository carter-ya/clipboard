import ClipboardCore
import Foundation
import SwiftCrossUI

#if os(Windows) || os(Linux)
  import DesktopClipboard
#endif

/// Presentation state only; search, persistence, pinning and deletion use Core.
final class HistoryModel: ObservableObject {
  @Published var items: [ClipItem] = []
  @Published var query = ""
  @Published var onlyPinned = false
  @Published var selectedID: UUID?
  @Published var showsSettings = false
  @Published var status = "Loading history"
  @Published var recording = false
  @Published var ready = false
  @Published var previewText = "Choose an item to preview its content."

  private var store: JSONSnapshotClipStore?
  private var root: URL?
  private var clipboard: (any TextClipboardAccess)?
  private var monitor: TextClipboardMonitor?
  private var captureTask: Task<Void, Never>?
  private var eventsTask: Task<Void, Never>?
  private var loadedPreviewID: UUID?

  static let fixtures = [
    "Welcome to Clipboard Preview",
    "中文笔记 · 设计评审与输入测试",
    "Release checklist · build, test, publish",
  ]

  var selected: ClipItem? { items.first { $0.id == selectedID } }
  @MainActor func loadPreview() async {
    guard let selected else {
      loadedPreviewID = nil
      previewText = "Choose an item to preview its content."
      return
    }
    guard loadedPreviewID != selected.id else { return }
    loadedPreviewID = selected.id
    if selected.sensitive {
      previewText = "Sensitive content is hidden."
      return
    }
    previewText = "Loading preview…"
    let resolver = PayloadResolver(blobRoot: root?.appendingPathComponent("blobs"))
    let text = await Task.detached(priority: .userInitiated) {
      guard
        let payload = selected.payloads.first(where: {
          $0.pasteboardType == "public.utf8-plain-text"
        }),
        let bytes = try? resolver.data(for: payload),
        let text = String(data: bytes, encoding: .utf8)
      else { return selected.preview }
      return String(text.prefix(8000))
    }.value
    guard selectedID == selected.id else { return }
    previewText = text
  }

  @MainActor func load() async {
    guard store == nil else { return }
    do {
      let args = CommandLine.arguments
      let directory: URL
      if let position = args.firstIndex(of: "--smoke-root"), position + 1 < args.count {
        directory = URL(fileURLWithPath: args[position + 1], isDirectory: true)
      } else {
        directory = try await Task.detached {
          try AppPaths.defaultStoreRoot(directoryName: "ClipboardCrossUIPrototype")
        }.value
      }
      root = directory
      let store = try await JSONSnapshotClipStore(root: directory)
      self.store = store
      let existing = await store.all()
      if existing.isEmpty {
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
          await self.refresh()
        }
      }
      await refresh()
      ready = true
      status = "Ready"
    } catch { status = "History could not be opened." }
  }

  @MainActor func refresh() async {
    guard let store else { return }
    let requestedQuery = query
    let requestedPinned = onlyPinned
    let found = await store.search(query: requestedQuery, filters: SearchFilters())
    guard query == requestedQuery, onlyPinned == requestedPinned else { return }
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

  @MainActor private func nativeClipboard() throws -> any TextClipboardAccess {
    if let clipboard { return clipboard }
    #if os(Windows) || os(Linux)
      let native = try SystemTextClipboard()
      clipboard = native
      return native
    #else
      throw TextClipboardError.unsupportedSession
    #endif
  }

  @MainActor func copySelected() async {
    guard let selected else { return }
    do {
      let writer = try TextPasteboardWriter(
        clipboard: nativeClipboard(), blobRoot: root?.appendingPathComponent("blobs"))
      try await Task.detached(priority: .userInitiated) { try writer.write(selected) }.value
      status = "Copied to clipboard"
    } catch { status = "Clipboard is unavailable in this session." }
  }

  @MainActor func toggleRecording() {
    if recording {
      monitor?.stop()
      captureTask?.cancel()
      monitor = nil
      captureTask = nil
      recording = false
      status = "Recording paused"
      return
    }
    do {
      let monitor = TextClipboardMonitor(clipboard: try nativeClipboard())
      self.monitor = monitor
      captureTask = Task { @MainActor [weak self] in
        for await raw in monitor.changes {
          guard !Task.isCancelled, let self, let store = self.store else { break }
          await store.insert(raw)
          await store.flush()
        }
      }
      monitor.start()
      recording = true
      status = "Recording text clipboard"
    } catch { status = "Clipboard is unavailable in this session." }
  }

  deinit {
    monitor?.stop()
    captureTask?.cancel()
    eventsTask?.cancel()
  }
}
