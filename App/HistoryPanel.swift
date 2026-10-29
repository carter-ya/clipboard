import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class HistoryPanel: NSPanel {
  var onWillCloseCommit: (() -> Void)?
  var onArrowDown: (() -> Void)?
  var onArrowUp: (() -> Void)?
  var onCommandModifierChanged: ((Bool) -> Void)?
  /// Prepare each new session before mounting or showing its content.
  /// The delegate uses this to reset selection + scroll to the top
  /// so "every open is a fresh session" — the most recent clip is
  /// always selected when you summon the panel.
  var onDidOpen: (() -> Void)?
  var onDidClose: (() -> Void)?
  var suppressNextCloseCommit = false

  private var outsideClickMonitor: Any?
  private var keyMonitor: Any?
  private var handledCurrentClose = false
  private var notifiedCurrentClose = true
  private var loggedKeyDelivery = false
  private let rootView: AnyView
  private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
  private lazy var surfaceController = NativeWindowSurfaceController(
    hostingController: hostingController, role: .history,
    contentSize: NSSize(width: HistoryPanelLayout.width, height: HistoryPanelLayout.height)
  )

  init(rootView: some View) {
    self.rootView = AnyView(rootView)
    super.init(
      contentRect: NSRect(
        x: 0, y: 0, width: HistoryPanelLayout.width, height: HistoryPanelLayout.height),
      styleMask: [.nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Keep a borderless nonactivating panel for background hotkey input.
    // A visually hidden titlebar still changes AppKit's focus handling.
    // The native glass surface owns the corners; title remains available
    // to Accessibility without adding a titled window frame.
    title = String(localized: "Clipboard")
    isFloatingPanel = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    // This is an input-first panel, not a passive inspector. Requiring
    // a click on an editable control can leave a Settings handoff keyless.
    becomesKeyOnlyIfNeeded = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    // SwiftUI defines the rounded surface. AppKit supplies the single
    // window shadow; rows and preview content do not add their own.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none

    // Keep the carrier's size stable when the hidden SwiftUI tree is
    // released, including relative-date refreshes and preview images.
    hostingController.sizingOptions = []
    hostingController.preferredContentSize = NSSize(
      width: HistoryPanelLayout.width, height: HistoryPanelLayout.height)
    contentViewController = surfaceController
    setContentSize(hostingController.preferredContentSize)
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationWillHide),
      name: NSApplication.willHideNotification, object: NSApp)
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidUnhide),
      name: NSApplication.didUnhideNotification, object: NSApp)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func becomeKey() {
    super.becomeKey()
    focusSearchField()
    if isVisible {
      onCommandModifierChanged?(NSEvent.modifierFlags.contains(.command))
    }
  }

  override func resignKey() {
    super.resignKey()
    onCommandModifierChanged?(false)
  }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  func toggle(on screen: NSScreen? = nil) {
    if NSApp.isHidden {
      NSApp.unhideWithoutActivation()
      if !notifiedCurrentClose {
        positionAtCursorScreen(screen)
        makeKeyAndOrderFront(nil)
        focusSearchField()
        return
      }
    }
    if isVisible {
      close()
      return
    }
    handledCurrentClose = false
    notifiedCurrentClose = false
    loggedKeyDelivery = false
    suppressNextCloseCommit = false
    positionAtCursorScreen(screen)
    onDidOpen?()
    hostingController.rootView = rootView
    surfaceController.activate()
    // Resolve layout and the initial responder while still offscreen.
    // The first presented frame should already contain the final search
    // field, rather than switching from its cell to an editor afterward.
    _ = prepareSearchField()
    makeKeyAndOrderFront(nil)
    startOutsideClickMonitor()
    startKeyMonitor()
    focusSearchField()
  }

  @objc private func applicationWillHide() {
    onCommandModifierChanged?(false)
    stopOutsideClickMonitor()
    stopKeyMonitor()
  }

  @objc private func applicationDidUnhide() {
    guard isVisible, !notifiedCurrentClose else { return }
    // Mount before restoring the responder; notification delivery order
    // between this panel and its surface controller is unspecified.
    surfaceController.activate()
    startOutsideClickMonitor()
    startKeyMonitor()
    focusSearchField()
  }

  private func focusSearchField() {
    guard isVisible, isKeyWindow else { return }
    guard let search = prepareSearchField() else { return }
    let editingField = (firstResponder as? NSTextView)?.delegate as? NSTextField
    // Don't restart an existing field editor or marked-text session.
    guard editingField !== search else { return }
    let accepted = makeFirstResponder(search)
    Log.ui.debug("panel.search_focus_requested accepted=\(accepted)")
  }

  private func prepareSearchField() -> NSTextField? {
    // Lay out the mounted field before presentation. AppKit can then
    // use it as the initial responder; visible/key recovery uses the
    // same lookup without a second SwiftUI automatic-focus request.
    hostingController.view.layoutSubtreeIfNeeded()
    func editableFields(in view: NSView) -> [NSTextField] {
      if let field = view as? NSTextField, field.isEditable, field.isEnabled {
        return [field]
      }
      return view.subviews.flatMap { editableFields(in: $0) }
    }
    let fields = editableFields(in: hostingController.view)
    guard
      let search = fields.first(where: { $0.accessibilityIdentifier() == "history-search" })
        ?? (fields.count == 1 ? fields.first : nil)
    else { return nil }
    initialFirstResponder = search
    return search
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, !loggedKeyDelivery {
      loggedKeyDelivery = true
      let field = (firstResponder as? NSTextView)?.delegate as? NSTextField
      // Record routing once per opening, never key codes or typed text.
      Log.ui.info("panel.first_key_received textFieldFocused=\(field?.isEditable == true)")
    }
    super.sendEvent(event)
  }

  override func close() {
    commitBeforeCloseIfNeeded()
    onCommandModifierChanged?(false)
    stopOutsideClickMonitor()
    stopKeyMonitor()
    super.close()
    hostingController.rootView = AnyView(EmptyView())
    surfaceController.deactivate()
    notifyClosedIfNeeded()
  }

  override func orderOut(_ sender: Any?) {
    commitBeforeCloseIfNeeded()
    onCommandModifierChanged?(false)
    stopOutsideClickMonitor()
    stopKeyMonitor()
    super.orderOut(sender)
    hostingController.rootView = AnyView(EmptyView())
    surfaceController.deactivate()
    notifyClosedIfNeeded()
  }

  private func notifyClosedIfNeeded() {
    guard !isVisible, !notifiedCurrentClose else { return }
    notifiedCurrentClose = true
    onDidClose?()
  }

  private func commitBeforeCloseIfNeeded() {
    // AppKit can call orderOut from inside close while still visible.
    // Consume this session before invoking callbacks or entering AppKit.
    guard isVisible, !handledCurrentClose else { return }
    handledCurrentClose = true
    if suppressNextCloseCommit {
      suppressNextCloseCommit = false
      return
    }
    onWillCloseCommit?()
  }

  private func startOutsideClickMonitor() {
    stopOutsideClickMonitor()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self else { return }
      // `.nonactivatingPanel` never activates our app, so AppKit
      // forwards even our own chrome clicks (title bar, close/resize
      // widgets) to the global monitor as "other app" events.
      // Gate on frame containment to keep self-clicks from closing us.
      let location = NSEvent.mouseLocation
      MainActor.assumeIsolated {
        guard self.isVisible else { return }
        if !self.frame.contains(location) {
          self.close()
        }
      }
    }
  }

  private func stopOutsideClickMonitor() {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
  }

  private func startKeyMonitor() {
    stopKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      guard let self else { return event }
      if event.type == .flagsChanged {
        MainActor.assumeIsolated {
          guard self.isVisible, self.isKeyWindow else { return }
          self.onCommandModifierChanged?(event.modifierFlags.contains(.command))
        }
        // Observing modifiers must not consume shortcuts or text input.
        return event
      }
      // Only intercept events targeting our panel window.
      guard event.window === self else { return event }
      switch event.keyCode {
      case 125:  // down arrow
        MainActor.assumeIsolated { self.onArrowDown?() }
        return nil
      case 126:  // up arrow
        MainActor.assumeIsolated { self.onArrowUp?() }
        return nil
      default:
        return event
      }
    }
    onCommandModifierChanged?(NSEvent.modifierFlags.contains(.command))
  }

  private func stopKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }

  private func positionAtCursorScreen(_ sourceScreen: NSScreen?) {
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      sourceScreen
      ?? NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first!
    let visibleFrame = screen.visibleFrame
    let panelSize = HistoryPanelLayout.size(fitting: visibleFrame.size)
    hostingController.preferredContentSize = panelSize
    surfaceController.preferredContentSize = panelSize
    setContentSize(panelSize)
    let origin = NSPoint(
      x: visibleFrame.midX - panelSize.width / 2,
      y: visibleFrame.midY - panelSize.height / 2
    )
    setFrameOrigin(origin)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
