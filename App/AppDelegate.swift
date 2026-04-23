import AppKit
import ClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  static let reopenNotification = Notification.Name("com.clipboard.app.reopen")

  private var panel: HistoryPanel?
  private var wiring: AppWiring?
  private var preferencesController: PreferencesWindowController?
  private var onboarding: OnboardingController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()

    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleReopenNotification(_:)),
      name: Self.reopenNotification,
      object: nil
    )

    let wiring = AppWiring()
    wiring.onHotkey = { [weak self] in
      MainActor.assumeIsolated {
        self?.togglePanel()
      }
    }
    wiring.onStoreCorrupted = { [weak self] path in
      MainActor.assumeIsolated {
        self?.notifyCorruptionRecovery(path: path)
      }
    }
    wiring.onHotkeyUnbound = { [weak self] in
      MainActor.assumeIsolated {
        self?.openPreferences()
      }
    }
    self.wiring = wiring
    Task { @MainActor in
      await wiring.start()
      self.installPanelIfReady()
      let onboarding = OnboardingController()
      self.onboarding = onboarding
      onboarding.showIfFirstRun()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    DistributedNotificationCenter.default().removeObserver(self)
    guard let wiring else { return }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      await wiring.stop()
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2.0)
  }

  @objc private func handleReopenNotification(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.openPreferences()
      }
    }
  }

  /// Relaunching the app (double-click Clipboard.app from Finder /
  /// Dock / Spotlight) opens Preferences — the only fallback path
  /// we offer now that there is no menu bar icon.
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    openPreferences()
    return true
  }

  @MainActor
  @objc private func togglePanel() {
    preferencesController?.window?.orderOut(nil)
    installPanelIfReady()
    guard let panel else { return }
    if panel.isVisible {
      panel.close()
      return
    }
    wiring?.viewModel?.resetSelection()
    panel.toggle()
  }

  @MainActor
  @objc private func openPreferences() {
    panel?.close()
    installPreferencesIfReady()
    preferencesController?.show()
  }

  @MainActor
  @objc private func clearHistory() {
    let alert = NSAlert()
    alert.messageText = String(localized: "Clear all clipboard history?")
    alert.informativeText = String(
      localized: "Pinned items will also be removed. This cannot be undone."
    )
    alert.addButton(withTitle: String(localized: "Clear"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let wiring else { return }
    Task { await wiring.clearHistory() }
  }

  /// Install NSApp.mainMenu so standard Cocoa key equivalents
  /// (⌘A / ⌘C / ⌘V / ⌘X / ⌘Z / ⌘Q / ⌘H) reach the current first
  /// responder. Our app is LSUIElement=true so this menu is never
  /// visible, but AppKit still routes keyEquivalents through it.
  @MainActor
  private func installMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: String(localized: "Hide Clipboard"),
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = appMenu.addItem(
      withTitle: String(localized: "Hide Others"),
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: String(localized: "Show All"),
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: String(localized: "Quit Clipboard"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      withTitle: String(localized: "Undo"),
      action: Selector(("undo:")),
      keyEquivalent: "z"
    )
    let redo = editMenu.addItem(
      withTitle: String(localized: "Redo"),
      action: Selector(("redo:")),
      keyEquivalent: "z"
    )
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(
      withTitle: String(localized: "Cut"),
      action: #selector(NSText.cut(_:)),
      keyEquivalent: "x"
    )
    editMenu.addItem(
      withTitle: String(localized: "Copy"),
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    editMenu.addItem(
      withTitle: String(localized: "Paste"),
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    editMenu.addItem(
      withTitle: String(localized: "Select All"),
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApp.mainMenu = mainMenu
  }

  @MainActor
  private func notifyCorruptionRecovery(path: String) {
    let alert = NSAlert()
    alert.messageText = String(localized: "History was recovered from a backup")
    alert.informativeText = String(
      localized:
        "The original file appeared corrupted and has been renamed to history.json.bak. Clipboard started with an empty history."
    )
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }

  @MainActor
  private func installPanelIfReady() {
    guard panel == nil, let wiring = wiring, let vm = wiring.viewModel else { return }
    let root = HistoryPanelView(
      viewModel: vm,
      thumbnailLoader: wiring.thumbnailLoader,
      resolver: wiring.payloadResolver,
      onClose: { [weak self] in
        self?.panel?.close()
      },
      onActivate: { [weak self] item in
        self?.panel?.suppressNextCloseCommit = true
        wiring.activate(item)
        self?.panel?.close()
      },
      onTogglePin: { item in
        Task { await vm.togglePin(item) }
      },
      onDelete: { item in
        Task { await vm.delete(item) }
      },
      onShowPreferences: { [weak self] in
        MainActor.assumeIsolated {
          self?.panel?.suppressNextCloseCommit = true
          self?.openPreferences()
        }
      }
    )
    let panel = HistoryPanel(rootView: root)
    panel.onWillCloseCommit = { [weak self] in
      guard let self,
        let vm = self.wiring?.viewModel,
        let id = vm.selectedID,
        let item = vm.filteredItems.first(where: { $0.id == id })
      else { return }
      self.wiring?.activate(item)
    }
    panel.onArrowDown = { [weak vm] in vm?.selectNext() }
    panel.onArrowUp = { [weak vm] in vm?.selectPrevious() }
    panel.onDidOpen = { [weak vm] in vm?.resetSelection() }
    self.panel = panel
  }

  @MainActor
  private func installPreferencesIfReady() {
    guard preferencesController == nil, let wiring else { return }
    preferencesController = PreferencesWindowController(
      store: wiring.preferencesStore,
      onChange: { prefs in wiring.applyPreferences(prefs) },
      onClearHistory: { [weak self] in self?.clearHistory() },
      onExportHistory: { [weak self] in self?.exportHistory() },
      onImportHistory: { [weak self] in self?.importHistory() }
    )
  }

  @MainActor
  private func exportHistory() {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = "clipboard-history.zip"
    savePanel.allowedContentTypes = [.zip]
    guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
    do {
      let root = try AppPaths.defaultStoreRoot()
      try zipDirectory(root, to: url)
    } catch {
      Log.ui.error("export.failed err=\(String(describing: error), privacy: .public)")
      showAlert(
        title: String(localized: "Export failed"),
        message: String(describing: error)
      )
    }
  }

  @MainActor
  private func importHistory() {
    let openPanel = NSOpenPanel()
    openPanel.allowedContentTypes = [.zip]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    openPanel.canChooseFiles = true
    guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard-import-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(
        at: tempDir, withIntermediateDirectories: true
      )
      try unzipArchive(url, to: tempDir)
      guard let wiring else { return }
      Task { @MainActor [weak self] in
        defer {
          try? FileManager.default.removeItem(at: tempDir)
        }
        do {
          let result = try await self?.performImport(
            from: tempDir, wiring: wiring
          )
          self?.showImportSummary(result)
        } catch {
          self?.showAlert(
            title: String(localized: "Import failed"),
            message: String(describing: error)
          )
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: tempDir)
      showAlert(
        title: String(localized: "Import failed"),
        message: String(describing: error)
      )
    }
  }

  private struct ImportEnvelope: Decodable {
    var version: Int
    var items: [ClipItem]
  }

  @MainActor
  private func performImport(from dir: URL, wiring: AppWiring) async throws -> ImportResult {
    let historyURL = dir.appendingPathComponent("history.json")
    let data = try Data(contentsOf: historyURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(ImportEnvelope.self, from: data)
    guard let store = wiring.store else {
      return ImportResult(added: 0, skipped: 0, blobsMissing: 0)
    }
    let blobsRoot = dir.appendingPathComponent("blobs")
    return await store.importItems(envelope.items, blobsRoot: blobsRoot)
  }

  @MainActor
  private func showImportSummary(_ result: ImportResult?) {
    guard let result else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Import complete")
    let template = String(
      localized:
        "Added: %1$d\nSkipped (duplicates): %2$d\nSkipped (missing blobs): %3$d"
    )
    alert.informativeText = String(
      format: template, result.added, result.skipped, result.blobsMissing
    )
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }

  @MainActor
  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }

  /// Zip a directory into a single .zip at `dest`. Uses
  /// NSFileCoordinator's `.forUploading` option which produces a
  /// deterministic zip in a system temp location; we then copy to
  /// the user's chosen destination.
  private func zipDirectory(_ source: URL, to dest: URL) throws {
    let coordinator = NSFileCoordinator()
    var nsError: NSError?
    var thrown: Error?
    coordinator.coordinate(
      readingItemAt: source,
      options: [.forUploading],
      error: &nsError
    ) { zippedURL in
      do {
        if FileManager.default.fileExists(atPath: dest.path) {
          try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: zippedURL, to: dest)
      } catch {
        thrown = error
      }
    }
    if let thrown { throw thrown }
    if let nsError { throw nsError }
  }

  private func unzipArchive(_ zipURL: URL, to destDir: URL) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    task.arguments = ["-q", "-o", zipURL.path, "-d", destDir.path]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      throw NSError(
        domain: "com.clipboard.import",
        code: Int(task.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey:
            "unzip exited with status \(task.terminationStatus)"
        ]
      )
    }
  }
}
