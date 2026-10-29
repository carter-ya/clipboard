import AppKit
import ClipboardCore
import QuartzCore
import SwiftUI

/// Explicit OS state keeps policy tests independent of compositor timing
/// and desktop placement of same-app overlay windows.
@MainActor private final class OcclusionFixtureWindow: NSWindow {
  var reportsVisible = true
  override var occlusionState: NSWindow.OcclusionState { reportsVisible ? [.visible] : [] }
}

@MainActor final class WindowRegressionProbe: NSObject, NSApplicationDelegate {
  var panel: HistoryPanel!
  var settings: PreferencesWindowController!
  var vm: HistoryPanelViewModel!
  var checks: [[String: Any]] = []
  var commits = 0
  func pause() async { try? await Task.sleep(nanoseconds: 250_000_000) }
  func check(_ pass: Bool, _ label: String) { checks.append(["pass": pass, "check": label]) }
  func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
  func surfaceCount(_ window: NSWindow) -> Int { window.contentViewController!.view.subviews.count }
  func monitorsStopped() -> Bool {
    let fields = Mirror(reflecting: panel!).children
    return ["keyMonitor", "outsideClickMonitor"].allSatisfy { name in
      guard let value = fields.first(where: { $0.label == name })?.value else { return false }
      return Mirror(reflecting: value).children.isEmpty
    }
  }
  func displayChange() {
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  func select(_ tab: String) {
    if let item = settings.window!.toolbar!.items.first(where: {
      $0.itemIdentifier.rawValue == tab
    }), let action = item.action {
      _ = item.target?.perform(action, with: item)
    }
  }
  func selectAI() { select("ai") }
  func loginSwitch() -> NSView? {
    let views = descendants(settings.window!.contentView!)
    return views.first { $0.accessibilityIdentifier() == "launch-at-login" }
      ?? views.first { $0 is NSSwitch }
  }
  func loginSwitchValue() -> Bool? {
    if let control = loginSwitch() as? NSSwitch { return control.state == .on }
    if let control = loginSwitch() as? NSButton { return control.state == .on }
    return (loginSwitch()?.accessibilityValue() as? NSNumber)?.boolValue
  }
  func draft() -> String? {
    descendants(settings.window!.contentView!).compactMap { $0 as? NSSecureTextField }.first?
      .stringValue
  }
  func layers(_ layer: CALayer) -> [CALayer] {
    [layer] + (layer.sublayers ?? []).flatMap(layers)
  }
  func animationCount(_ view: NSView) -> Int {
    guard let layer = view.layer else { return 0 }
    return layers(layer).reduce(0) { count, layer in
      count + (layer.animationKeys() ?? []).filter { $0.hasPrefix("ai.") }.count
    }
  }
  func waitForAnimation(_ view: NSView, count: Int) async {
    for _ in 0..<40 {
      if animationCount(view) == count { return }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
  }
  func mouseEvent(
    _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    let event = NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    NSApp.postEvent(event, atStart: false)
  }
  func click(
    _ point: NSPoint, in window: NSWindow, releasingAt end: NSPoint? = nil,
    modifiers: NSEvent.ModifierFlags = []
  ) async {
    mouseEvent(.leftMouseDown, at: point, in: window, modifiers: modifiers)
    if let end { mouseEvent(.leftMouseDragged, at: end, in: window, modifiers: modifiers) }
    mouseEvent(.leftMouseUp, at: end ?? point, in: window, modifiers: modifiers)
    await pause()
  }
  func monitorsToolbarClicks(_ button: AISparkleToolbarButton) -> Bool {
    guard
      let value = Mirror(reflecting: button).children.first(where: {
        $0.label == "clickMonitor"
      })?.value
    else { return false }
    return !Mirror(reflecting: value).children.isEmpty
  }
  func checkAIAnimation() async {
    settings.show()
    // Keep this synthetic fixture exposed even if another app is active.
    // Production correctly suspends an entirely occluded toolbar.
    settings.window!.level = .floating
    settings.window!.collectionBehavior.insert(.moveToActiveSpace)
    settings.window!.orderFrontRegardless()
    await pause()
    guard
      let button = settings.window!.toolbar!.items.first(where: {
        $0.itemIdentifier.rawValue == "ai"
      })?.view as? AISparkleToolbarButton
    else {
      check(false, "AI uses an accessible animated native button")
      return
    }
    let expected = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 7
    let frame = settings.window!.frame
    let iconFrame = button.convert(button.bounds, to: nil)
    let primaryStar = button.layer?.sublayers?.first { $0.name == "ai.primary" }
    check(
      primaryStar?.position == NSPoint(x: button.bounds.midX, y: button.bounds.midY),
      "AI primary star is centered over its native toolbar label")
    let labelPoint = NSPoint(x: iconFrame.midX, y: iconFrame.minY - 10)
    if let container = button.superview {
      let tile = container.convert(container.bounds, to: nil)
      for y in [tile.minY + 10, tile.midY, tile.maxY - 4] {
        for x in [tile.minX + 1, tile.midX, tile.maxX - 1] {
          select("general")
          await click(NSPoint(x: x, y: y), in: settings.window!)
          check(
            settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
            "AI tile coordinate click opens AI at \(x),\(y)")
        }
      }
    } else {
      check(false, "AI toolbar tile is mounted")
    }
    select("general")
    await click(labelPoint, in: settings.window!)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
      "clicking native AI label opens AI")
    for point in [
      labelPoint,
      NSPoint(x: iconFrame.minX - 1, y: iconFrame.midY),
      NSPoint(x: iconFrame.midX, y: iconFrame.midY),
    ] {
      select("general")
      await click(point, in: settings.window!, modifiers: .control)
      check(
        settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "general",
        "Control-click does not select AI at \(point)")
    }
    await click(labelPoint, in: settings.window!)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
      "ordinary label click still works after Control-click")
    select("general")
    let outside = NSPoint(x: iconFrame.minX - 15, y: labelPoint.y)
    await click(labelPoint, in: settings.window!, releasingAt: outside)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "general",
      "dragging out of AI label cancels selection")
    mouseEvent(.leftMouseDown, at: labelPoint, in: settings.window!)
    await pause()
    // Simulate a release outside this app: the next fresh press must work.
    await click(NSPoint(x: iconFrame.midX - 56, y: iconFrame.midY), in: settings.window!)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "shortcuts",
      "a stale AI padding gesture does not swallow the next toolbar click")
    button.isEnabled = false
    await click(labelPoint, in: settings.window!)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "shortcuts",
      "disabled AI control does not activate through its label")
    button.isEnabled = true
    for tab in ["general", "shortcuts", "privacy", "data", "ai"] {
      select(tab)
      await pause()
      check(animationCount(button) == expected, "AI animation persists on \(tab) without hover")
      check(
        settings.window!.frame == frame && abs(settings.window!.contentLayoutRect.height - 440) < 1,
        "animated toolbar retains native form geometry on \(tab)")
    }
    select("general")
    button.performClick(nil)
    await pause()
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
      "native animated button selects AI")
    settings.window!.miniaturize(nil)
    await pause()
    check(animationCount(button) == 0, "minimized toolbar has no animation tracks")
    check(!monitorsToolbarClicks(button), "minimized toolbar releases its click monitor")
    settings.window!.deminiaturize(nil)
    await pause()
    check(animationCount(button) == expected, "restored toolbar resumes once")
    check(monitorsToolbarClicks(button), "restored toolbar resumes label clicks")
    NSApp.hide(nil)
    await pause()
    check(animationCount(button) == 0, "hidden app has no toolbar animation tracks")
    check(!monitorsToolbarClicks(button), "hidden app releases its toolbar click monitor")
    NSApp.unhide(nil)
    settings.window!.orderFrontRegardless()
    await waitForAnimation(button, count: expected)
    check(
      animationCount(button) == expected,
      "unhidden toolbar resumes once (tracks=\(animationCount(button)), visible=\(settings.window!.isVisible), occlusion=\(settings.window!.occlusionState.rawValue), hidden=\(button.isHiddenOrHasHiddenAncestor))"
    )
    settings.hide()
    await pause()
    check(animationCount(button) == 0, "settings handoff removes toolbar animation")
    check(!monitorsToolbarClicks(button), "settings handoff releases its toolbar click monitor")
    settings.show()
    await pause()
    settings.window!.close()
    await pause()
    check(animationCount(button) == 0, "window close removes toolbar animation")
    check(!monitorsToolbarClicks(button), "closed toolbar releases its click monitor")
    settings.show()
    await pause()
    check(animationCount(button) == expected, "closed toolbar resumes after reopening")
    select("general")
    let reopened = button.convert(button.bounds, to: nil)
    await click(NSPoint(x: reopened.midX, y: reopened.minY - 10), in: settings.window!)
    check(
      settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
      "AI label is clickable after closing and reopening settings")
    settings.hide()

    var reducedMotion = false
    let icon = AISparkleToolbarButton(reduceMotion: { reducedMotion })
    let window = OcclusionFixtureWindow(
      contentRect: NSRect(x: 100, y: 150, width: 160, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior.insert(.moveToActiveSpace)
    icon.frame.origin = NSPoint(x: 60, y: 30)
    window.contentView!.addSubview(icon)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    icon.allowsAnimation = true
    await pause()
    let satellites = (icon.layer?.sublayers ?? []).filter {
      $0.animation(forKey: "ai.twinkle") != nil
    }
    let primary = icon.layer?.sublayers?.first { $0.name == "ai.primary" }
    let flipped = icon.layer?.isGeometryFlipped ?? icon.isFlipped
    check(
      primary != nil && satellites.count == 7
        && satellites.prefix(2).allSatisfy {
          $0.position.x < primary!.position.x
            && (flipped ? $0.position.y < primary!.position.y : $0.position.y > primary!.position.y)
        }, "original satellite pair stays visually above and left of the main star")
    var brightness = [[Float]](repeating: [], count: satellites.count)
    var locations = [[CGPoint]](repeating: [], count: satellites.count)
    var primaryStayedSteady = primary != nil
    for _ in 0..<24 {
      if let visible = primary?.presentation(), let primary {
        primaryStayedSteady =
          primaryStayedSteady && visible.position == primary.position
          && CATransform3DIsIdentity(visible.transform) && visible.opacity == 1
      } else {
        primaryStayedSteady = false
      }
      for (index, layer) in satellites.enumerated() {
        if let visible = layer.presentation() {
          brightness[index].append(visible.opacity)
          locations[index].append(visible.position)
        }
      }
      await pause()
    }
    check(satellites.count == 7, "all seven small stars have independent animation")
    check(primaryStayedSteady, "primary star stays steady while surrounding glints animate")
    check(
      satellites.count == 7
        && brightness.allSatisfy {
          ($0.max() ?? 0) - ($0.min() ?? 0) > 0.2
        }, "every small star, including the upper-left pair, visibly twinkles")
    check(
      satellites.count == 7
        && locations.allSatisfy { points in
          guard let first = points.first else { return false }
          return points.contains { hypot($0.x - first.x, $0.y - first.y) > 0.3 }
        }, "every small star, including the upper-left pair, gently drifts")
    window.reportsVisible = false
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await pause()
    check(animationCount(icon) == 0, "OS-reported full occlusion removes all animation tracks")
    window.reportsVisible = true
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await pause()
    check(animationCount(icon) == 7, "OS-reported exposure restores animation once")
    reducedMotion = true
    displayChange()
    await pause()
    check(animationCount(icon) == 0, "Reduce Motion presents a static golden icon")
    reducedMotion = false
    displayChange()
    await pause()
    check(animationCount(icon) == 7, "disabling Reduce Motion resumes exactly seven tracks")
    icon.allowsAnimation = false
    check(animationCount(icon) == 0, "explicit suspension removes all icon tracks")
    window.orderOut(nil)
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      NSApp.setActivationPolicy(.accessory)
      vm = HistoryPanelViewModel(store: InMemoryClipStore())
      panel = HistoryPanel(
        rootView: HistoryPanelView(viewModel: vm, thumbnailLoader: nil, resolver: nil))
      panel.onWillCloseCommit = { [weak self = self] in self?.commits += 1 }
      var preparedBeforeDisplay = true
      panel.onDidOpen = { [weak self = self] in
        guard let self else { return }
        preparedBeforeDisplay = preparedBeforeDisplay && !self.panel.isVisible
        self.vm.resetSelection()
      }
      for (index, screen) in NSScreen.screens.enumerated() {
        panel.toggle(on: screen)
        await pause()
        check(
          screen.visibleFrame.contains(panel.frame),
          "screen \(index): entire panel within visible bounds")
        check(
          panel.frame.size == HistoryPanelLayout.size(fitting: screen.visibleFrame.size),
          "screen \(index): adaptive size")
        let host = (panel.contentViewController!.children.first! as! NSHostingController<AnyView>)
          .view
        let rect = host.convert(host.bounds, to: nil)
        check(
          abs(rect.width - panel.frame.width) < 0.5 && abs(rect.height - panel.frame.height) < 0.5
            && abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5,
          "screen \(index): foreground matches carrier")
        check(
          panel.isKeyWindow && (panel.firstResponder as? NSTextView)?.isFieldEditor == true,
          "screen \(index): native search focus")
        panel.suppressNextCloseCommit = true
        panel.close()
      }
      check(preparedBeforeDisplay, "new sessions prepare selection before first display")
      check(
        HistoryPanelLayout.size(fitting: NSSize(width: 720, height: 400))
          == NSSize(width: 720, height: 400), "short narrow screen bounded in both axes")
      panel.toggle()
      await pause()
      vm.setSearch("synthetic-search")
      for cycle in 0..<3 {
        NSApp.hide(nil)
        await pause()
        check(monitorsStopped(), "hide \(cycle): keyboard and outside-click monitors removed")
        check(
          NSApp.isHidden && !panel.isVisible && surfaceCount(panel) == 0,
          "hide \(cycle): history backdrop detached")
        displayChange()
        await pause()
        check(
          surfaceCount(panel) == 0,
          "hide \(cycle): accessibility notification cannot recreate backdrop")
        NSApp.unhideWithoutActivation()
        await pause()
        check(
          panel.isVisible && surfaceCount(panel) == 1,
          "unhide \(cycle): exactly one backdrop restored")
        check(vm.searchText == "synthetic-search", "unhide \(cycle): search preserved")
        panel.makeKeyAndOrderFront(nil)
        await pause()
        check(
          (panel.firstResponder as? NSTextView)?.isFieldEditor == true,
          "unhide \(cycle): search editor restored")
      }
      NSApp.hide(nil)
      await pause()
      let resumeScreen = NSScreen.screens.last!
      panel.toggle(on: resumeScreen)
      await pause()
      check(
        !NSApp.isHidden && panel.isVisible && panel.isKeyWindow && surfaceCount(panel) == 1,
        "hotkey-style toggle resumes hidden history")
      check(
        panel.screen === resumeScreen && resumeScreen.visibleFrame.contains(panel.frame),
        "hidden history resumes on invocation screen with adaptive size")
      check(commits == 0, "hiding and resuming never commits selected clipboard")
      panel.suppressNextCloseCommit = true
      panel.close()
      check(surfaceCount(panel) == 0, "history close releases backdrop")
      let domain = "com.clipboard.window-regression-fixtures"
      let defaults = UserDefaults(suiteName: domain)!
      defaults.removePersistentDomain(forName: domain)
      let store = PreferencesStore(defaults: defaults)
      var prefs = store.current
      prefs.summariesEnabled = true
      prefs.remoteAIEnabled = true
      store.save(prefs)
      var systemLoginEnabled = true
      var loginApplyCount = 0
      var rejectLoginChange = false
      settings = PreferencesWindowController(
        store: store, onChange: { _ in }, onClearHistory: {}, onExportHistory: {},
        onImportHistory: {}, onCheckForUpdates: {}, canCheckForUpdates: { false },
        readLaunchAtLogin: { systemLoginEnabled },
        applyLaunchAtLogin: {
          loginApplyCount += 1
          if rejectLoginChange { throw NSError(domain: "SyntheticLoginItemFailure", code: 1) }
          systemLoginEnabled = $0
        })
      settings.show()
      await pause()
      select("general")
      await pause()
      check(
        loginSwitchValue() == true && store.current.launchAtLogin,
        "initial login switch matches system")
      systemLoginEnabled = false
      settings.show()
      await pause()
      check(
        loginSwitchValue() == false && !store.current.launchAtLogin,
        "already-open settings refreshes login status")
      settings.window!.miniaturize(nil)
      await pause()
      systemLoginEnabled = true
      settings.window!.deminiaturize(nil)
      await pause()
      check(
        loginSwitchValue() == true && store.current.launchAtLogin,
        "Dock-style restore refreshes login status")
      NSApp.hide(nil)
      await pause()
      systemLoginEnabled = false
      NSApp.unhideWithoutActivation()
      await pause()
      check(
        loginSwitchValue() == false && !store.current.launchAtLogin,
        "unhide without show refreshes login status")
      let other = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
      other.isReleasedWhenClosed = false
      NSApp.activate(ignoringOtherApps: true)
      await pause()
      other.makeKeyAndOrderFront(nil)
      await pause()
      systemLoginEnabled = true
      settings.window!.makeKeyAndOrderFront(nil)
      await pause()
      check(
        loginSwitchValue() == true && store.current.launchAtLogin,
        "returning from another window refreshes login status (key=\(settings.window!.isKeyWindow), active=\(NSApp.isActive), stored=\(store.current.launchAtLogin), switch=\(String(describing: loginSwitchValue())))"
      )
      other.orderOut(nil)
      systemLoginEnabled = false
      settings.show()
      await pause()
      check(loginApplyCount == 0, "reconciliation never changes system registration")
      let control = loginSwitch() as? NSControl
      control?.performClick(nil)
      await pause()
      check(
        control != nil && loginApplyCount == 1 && systemLoginEnabled && store.current.launchAtLogin
          && loginSwitchValue() == true,
        "explicit switch action applies and displays system state")
      rejectLoginChange = true
      var dismissedFailure = false
      let dismissAlert = Timer(timeInterval: 0.25, repeats: false) { _ in
        MainActor.assumeIsolated {
          if let modal = NSApp.modalWindow {
            dismissedFailure = true
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            modal.orderOut(nil)
          }
        }
      }
      RunLoop.main.add(dismissAlert, forMode: .modalPanel)
      control?.performClick(nil)
      dismissAlert.invalidate()
      await pause()
      check(
        dismissedFailure && loginApplyCount == 2 && systemLoginEnabled
          && store.current.launchAtLogin && loginSwitchValue() == true,
        "failed system registration preserves switch and stored state")
      rejectLoginChange = false
      selectAI()
      await pause()
      if let field = descendants(settings.window!.contentView!).compactMap({
        $0 as? NSSecureTextField
      }).first {
        settings.window!.makeFirstResponder(field)
        (settings.window!.firstResponder as? NSTextView)?.insertText(
          "synthetic-unsaved-draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        settings.window!.makeFirstResponder(nil)
        await pause()
      }
      check(draft() == "synthetic-unsaved-draft", "synthetic unsaved settings draft entered")
      let draftField = descendants(settings.window!.contentView!).compactMap {
        $0 as? NSSecureTextField
      }.first
      systemLoginEnabled = false
      settings.show()
      await pause()
      check(
        !store.current.launchAtLogin && draft() == "synthetic-unsaved-draft"
          && settings.window!.toolbar!.selectedItemIdentifier?.rawValue == "ai",
        "login refresh preserves unsaved draft and selected tab")
      check(
        descendants(settings.window!.contentView!).contains { $0 === draftField },
        "login refresh preserves the mounted draft control")
      // Exercise another preference's save with a stale launchAtLogin in
      // the retained form snapshot. It must not overwrite reconciled state.
      let fields = descendants(settings.window!.contentView!).compactMap { $0 as? NSTextField }
      if let model = fields.first(where: {
        $0.placeholderString == String(localized: "remoteAI.model.placeholder")
      }) {
        settings.window!.makeFirstResponder(model)
        (settings.window!.firstResponder as? NSTextView)?.insertText(
          "synthetic-model",
          replacementRange: NSRange(location: 0, length: model.stringValue.utf16.count))
        settings.window!.makeFirstResponder(nil)
        await pause()
      }
      check(
        store.current.remoteAIModel == "synthetic-model" && !store.current.launchAtLogin,
        "other preference saves retain reconciled login state")
      select("general")
      await pause()
      check(loginSwitchValue() == false, "returning to General shows refreshed login switch")
      selectAI()
      await pause()
      check(draft() == "synthetic-unsaved-draft", "login refresh preserves draft across tabs")
      for cycle in 0..<3 {
        settings.window!.miniaturize(nil)
        await pause()
        check(
          settings.window!.isMiniaturized && surfaceCount(settings.window!) == 0,
          "minimize \(cycle): settings backdrop detached")
        displayChange()
        await pause()
        check(
          surfaceCount(settings.window!) == 0, "minimize \(cycle): no hidden accessibility rebuild")
        if cycle == 1 { settings.show() } else { settings.window!.deminiaturize(nil) }
        await pause()
        check(
          !settings.window!.isMiniaturized && surfaceCount(settings.window!) == 1,
          "restore \(cycle): one settings backdrop")
        check(
          draft() == "synthetic-unsaved-draft",
          "restore \(cycle): unsaved draft and AI tab retained")
      }
      NSApp.hide(nil)
      await pause()
      check(
        NSApp.isHidden && surfaceCount(settings.window!) == 0, "hidden settings backdrop detached")
      NSApp.unhide(nil)
      await pause()
      check(
        surfaceCount(settings.window!) == 1 && draft() == "synthetic-unsaved-draft",
        "unhidden settings retains draft and backdrop")
      settings.show()
      await pause()
      check(
        draft() == "synthetic-unsaved-draft",
        "reopen after system unhide retains unsaved draft")
      NSApp.hide(nil)
      await pause()
      settings.show()
      await pause()
      check(
        !NSApp.isHidden && surfaceCount(settings.window!) == 1
          && draft() == "synthetic-unsaved-draft", "show hidden settings retains draft")
      settings.hide()
      await pause()
      check(surfaceCount(settings.window!) == 0, "settings close releases backdrop")
      displayChange()
      await pause()
      check(
        surfaceCount(panel) == 0 && surfaceCount(settings.window!) == 0,
        "closed windows stay detached after display change")
      await checkAIAnimation()
      defaults.removePersistentDomain(forName: domain)
      let report: [String: Any] = [
        "checks": checks, "failures": checks.filter { ($0["pass"] as? Bool) != true }.count,
      ]
      let bytes = try! JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try! bytes.write(
        to: URL(
          fileURLWithPath: CommandLine.arguments.dropFirst().first
            ?? "/tmp/clipboard-ui-qa/window-regression-results.json"))
      // Production preferences briefly promote the app to regular. Let
      // Launch Services and Dock process the return to accessory before
      // exiting this test process, so transient Dock tiles don't linger.
      NSApp.setActivationPolicy(.accessory)
      await pause()
      await pause()
      NSApp.terminate(nil)
    }
  }
}
@main struct Main {
  static func main() {
    let app = NSApplication.shared
    let delegate = WindowRegressionProbe()
    app.delegate = delegate
    app.run()
  }
}
