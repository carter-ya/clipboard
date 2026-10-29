import AppKit
import ClipboardCore
import KeyboardShortcuts
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  private let store: PreferencesStore
  private let onChange: (Preferences) -> Void
  private let onClearHistory: () -> Void
  private let onExportHistory: () -> Void
  private let onImportHistory: () -> Void
  private let onCheckForUpdates: () -> Void
  private let canCheckForUpdates: () -> Bool
  private let readLaunchAtLogin: @MainActor () -> Bool
  private let applyLaunchAtLogin: @MainActor (Bool) throws -> Void
  private let navigation = PreferencesNavigation()
  private let systemState = PreferencesSystemState()

  // Keep one hosting controller and rebuild its root only for a new
  // session. Resuming preserves drafts; swapping the controller would
  // briefly collapse the frame and drift AppKit's top-left anchoring.
  private let hostingController = NSHostingController(rootView: AnyView(Color.clear))
  private lazy var surfaceController = NativeWindowSurfaceController(
    hostingController: hostingController, role: .preferences,
    contentSize: NSSize(width: PreferencesLayout.width, height: PreferencesLayout.height)
  )
  private var contentRevision = 0
  private var handingOffToHistory = false
  private var hasOpenSession = false

  init(
    store: PreferencesStore,
    onChange: @escaping (Preferences) -> Void,
    onClearHistory: @escaping () -> Void,
    onExportHistory: @escaping () -> Void,
    onImportHistory: @escaping () -> Void,
    onCheckForUpdates: @escaping () -> Void,
    canCheckForUpdates: @escaping () -> Bool,
    readLaunchAtLogin: @escaping @MainActor () -> Bool = { LoginItemController.isEnabled },
    applyLaunchAtLogin: @escaping @MainActor (Bool) throws -> Void = {
      try LoginItemController.apply($0)
    }
  ) {
    self.store = store
    self.onChange = onChange
    self.onClearHistory = onClearHistory
    self.onExportHistory = onExportHistory
    self.onImportHistory = onImportHistory
    self.onCheckForUpdates = onCheckForUpdates
    self.canCheckForUpdates = canCheckForUpdates
    self.readLaunchAtLogin = readLaunchAtLogin
    self.applyLaunchAtLogin = applyLaunchAtLogin

    let window = NSWindow(
      contentRect: NSRect(
        x: 0, y: 0, width: PreferencesLayout.width, height: PreferencesLayout.height),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Clipboard Preferences")
    // A real preferences toolbar owns its title-bar layout and adopts
    // the system appearance, including Liquid Glass on macOS 26.
    // Content stays below the toolbar without manual safe-area offsets.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.hasShadow = true
    window.toolbarStyle = .preference
    // Don't let macOS auto-restore last-known frame — the state
    // machine otherwise wrestles with our setFrameOrigin in show()
    // and the window drifts (it ends up parked in the upper-right
    // corner every second open).
    window.isRestorable = false
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "ClipboardPreferencesToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    hostingController.sizingOptions = []
    window.contentViewController = surfaceController
    rebuildContent()
    // Persist & restore the window position across open/close and app
    // launches. Replaces the old "re-center on every show()" behavior,
    // which jumped the window (and parked it upper-right when a content
    // swap briefly reported a 0×0 frame). On first run there's no saved
    // frame, so center once as the default. `setFrameUsingName` is the
    // last word on the frame, so it runs after content is installed.
    let autosaveName = NSWindow.FrameAutosaveName("ClipboardPreferences")
    if !window.setFrameUsingName(autosaveName) {
      window.center()
    }
    // Older releases saved a smaller content rect. Preserve its top-left
    // position while migrating to the native toolbar's content size.
    let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    fitBodyPreservingTopLeft()
    window.setFrameTopLeftPoint(topLeft)
    window.setFrameAutosaveName(autosaveName)
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidUnhide),
      name: NSApplication.didUnhideNotification, object: NSApp)
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification, object: NSApp)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Unavailable")
  }

  func show(on sourceScreen: NSScreen? = nil) {
    let targetScreen =
      sourceScreen
      ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main ?? NSScreen.screens.first
    handingOffToHistory = false
    // Refresh the persisted prefs view against the OS's real login-item
    // state so we don't lie if the user disabled us in System Settings.
    // Finder/Dock can unhide the app before delivering a reopen request.
    // A still-open form must retain its draft in that path as well.
    let resuming =
      hasOpenSession
      && (window?.isVisible == true || NSApp.isHidden || window?.isMiniaturized == true)
    reconcileLaunchAtLogin()
    if !resuming { rebuildContent() }
    hasOpenSession = true
    surfaceController.activate()
    fitBodyPreservingTopLeft()
    position(on: targetScreen)
    // LSUIElement apps can't normally get keyboard focus; temporarily
    // promote activation so KeyboardShortcuts.Recorder etc. work.
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    fitBodyPreservingTopLeft()
    position(on: targetScreen)
    NSApp.activate(ignoringOtherApps: true)
    // Drop the auto-picked first responder so the Language Picker (or
    // any other control in tab order) doesn't show a focus ring on
    // first open. The user can still click or tab into any control.
    window?.makeFirstResponder(nil)
  }

  private func position(on screen: NSScreen?) {
    guard let window, let screen else { return }
    let visible = screen.visibleFrame
    let size = window.frame.size
    let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
    // Preserve a user-chosen position on this screen; a frame restored
    // on another display must not override the current invocation's screen.
    let proposed =
      screen.frame.contains(center)
      ? window.frame.origin
      : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    let right = max(visible.minX, visible.maxX - size.width)
    let top = visible.maxY - size.height
    let bottom = min(visible.minY, top)
    let origin = NSPoint(
      x: min(max(proposed.x, visible.minX), right),
      y: min(max(proposed.y, bottom), top)
    )
    if window.frame.origin != origin { window.setFrameOrigin(origin) }
  }

  private func fitBodyPreservingTopLeft() {
    guard let window else { return }
    // AppKit finalizes toolbar metrics during layout/first display.
    // The layout guide, not a fixed titlebar spacer, defines the body.
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    let widthDelta = PreferencesLayout.width - window.contentLayoutRect.width
    let heightDelta = PreferencesLayout.height - window.contentLayoutRect.height
    let canvasSize = NSSize(
      width: surfaceController.view.bounds.width + widthDelta,
      height: surfaceController.view.bounds.height + heightDelta
    )
    let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    // The controller's preferred size describes the full canvas, not
    // just the form. Otherwise AppKit shrinks it again on a tab change.
    surfaceController.preferredContentSize = canvasSize
    window.contentMinSize = canvasSize
    window.contentMaxSize = canvasSize
    if abs(widthDelta) > 0.5 || abs(heightDelta) > 0.5 {
      window.setContentSize(canvasSize)
      window.setFrameTopLeftPoint(topLeft)
    }
    window.contentView?.superview?.layoutSubtreeIfNeeded()
  }

  private func reconcileLaunchAtLogin() {
    var prefs = store.current
    let systemEnabled = readLaunchAtLogin()
    if systemState.launchAtLogin != systemEnabled {
      systemState.launchAtLogin = systemEnabled
    }
    if prefs.launchAtLogin != systemEnabled {
      prefs.launchAtLogin = systemEnabled
      store.save(prefs)
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    refreshVisibleSystemState()
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    refreshVisibleSystemState()
  }

  @objc private func applicationDidUnhide() {
    refreshVisibleSystemState()
  }

  @objc private func applicationDidBecomeActive() {
    refreshVisibleSystemState()
  }

  private func refreshVisibleSystemState() {
    guard hasOpenSession, !NSApp.isHidden,
      window?.isVisible == true, window?.isMiniaturized == false
    else { return }
    reconcileLaunchAtLogin()
  }

  func windowWillClose(_ notification: Notification) {
    releaseContent()
  }

  func hide() {
    guard hasOpenSession else { return }
    window?.orderOut(nil)
    releaseContent()
  }

  func hideForHistory() {
    guard hasOpenSession else { return }
    handingOffToHistory = true
    window?.orderOut(nil)
    releaseContent(restoringAccessoryPolicy: false)
  }

  func finishHistoryHandoff() {
    guard handingOffToHistory else { return }
    handingOffToHistory = false
    NSApp.setActivationPolicy(.accessory)
  }

  func cancelHistoryHandoff() {
    handingOffToHistory = false
  }

  private func releaseContent(restoringAccessoryPolicy: Bool = true) {
    // Cancels view-scoped work (including the connection probe) and
    // releases the form while keeping the inexpensive window carrier.
    hostingController.rootView = AnyView(EmptyView())
    hasOpenSession = false
    surfaceController.deactivate()
    // Deactivation can revoke a newly opened nonactivating panel's key
    // focus. During a Settings→history handoff, wait until history closes.
    if restoringAccessoryPolicy {
      handingOffToHistory = false
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private func rebuildContent() {
    let hotkeyMissing = KeyboardShortcuts.getShortcut(for: .toggleHistoryPanel) == nil
    navigation.selectedTab = hotkeyMissing ? .shortcuts : .general
    window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(
      navigation.selectedTab.rawValue)
    let view = PreferencesView(
      prefs: store.current,
      navigation: navigation,
      systemState: systemState,
      onSave: { [weak self] prefs in
        guard let self else { return }
        // The retained form can hold an older snapshot after an external
        // login-item change. Never overwrite the reconciled system value.
        var updated = prefs
        updated.launchAtLogin = self.systemState.launchAtLogin
        self.store.save(updated)
        self.onChange(updated)
      },
      onClearHistory: { [weak self] in self?.onClearHistory() },
      onExportHistory: { [weak self] in self?.onExportHistory() },
      onImportHistory: { [weak self] in self?.onImportHistory() },
      onApplyLaunchAtLogin: { [weak self] desired in
        guard let self else { return true }
        do {
          try self.applyLaunchAtLogin(desired)
          self.reconcileLaunchAtLogin()
          return true
        } catch {
          self.showLaunchAtLoginFailure(error: error)
          return false
        }
      },
      onApplyLanguage: { [weak self] code in
        self?.applyLanguageOverride(code)
      },
      onApplyAppearance: { [weak self] appearance in
        guard let self else { return }
        var prefs = self.store.current
        prefs.appearance = appearance
        self.store.save(prefs)
        AppearanceController.apply(appearance)
      },
      onCheckForUpdates: { [weak self] in self?.onCheckForUpdates() },
      canCheckForUpdates: canCheckForUpdates(),
      hotkeyMissing: hotkeyMissing
    )
    // Bump the identity so SwiftUI rebuilds @State (fresh prefs snapshot,
    // tab reset) without us swapping the contentViewController.
    contentRevision += 1
    hostingController.rootView = AnyView(view.id(contentRevision))
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    PreferencesTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let tab = PreferencesTab(rawValue: identifier.rawValue) else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = tab.title
    item.paletteLabel = tab.title
    item.toolTip = tab.title
    item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
    item.target = self
    item.action = #selector(selectTab(_:))
    return item
  }

  @objc private func selectTab(_ sender: NSToolbarItem) {
    guard let tab = PreferencesTab(rawValue: sender.itemIdentifier.rawValue) else { return }
    guard tab != navigation.selectedTab else { return }
    window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    navigation.selectedTab = tab
  }

  private func applyLanguageOverride(_ code: String?) {
    if let code {
      UserDefaults.standard.set([code], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
  }

  private func showLaunchAtLoginFailure(error: Error) {
    let alert = NSAlert()
    alert.messageText = String(localized: "Could not update Start at Login")
    alert.informativeText =
      (error as? LocalizedError)?.errorDescription
      ?? String(describing: error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
