import AppKit
import ClipboardCore
import SwiftUI

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
