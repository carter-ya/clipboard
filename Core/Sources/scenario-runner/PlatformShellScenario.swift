import ClipboardCore
import Foundation

#if os(Linux) || os(Windows)
  import DesktopShell

  func runShellPeer() throws {
    let shell = NativeDesktopShell()
    let shortcut = try DesktopShortcut(parsing: "Ctrl+Alt+F12")
    try shell.start(shortcut: shortcut, recording: false)
    defer { shell.stop() }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    _ = readLine()
  }

  func runTrayPeer() throws {
    let shell = NativeDesktopShell()
    try shell.start(shortcut: nil, recording: false)
    defer { shell.stop() }
    guard shell.capabilities.tray else { throw DesktopShellError.unavailable }
    let actions = shell.actions
    let task = Task.detached {
      for await action in actions {
        guard !Task.isCancelled else { break }
        FileHandle.standardOutput.write(Data("action:\(action.rawValue)\n".utf8))
      }
    }
    defer { task.cancel() }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    while let command = readLine() {
      if command == "quit" { break }
      if command == "language:zh" { shell.updateLanguage("zh-Hans") }
      if command == "language:en" { shell.updateLanguage("en") }
      if command == "recording:on" { shell.updateRecording(true) }
      if command == "recording:off" { shell.updateRecording(false) }
    }
  }

  func runPortalPeer() throws {
    guard ProcessInfo.processInfo.environment["CLIPBOARD_PRIVATE_PORTAL_TEST"] == "1" else {
      throw DesktopShellError.unavailable
    }
    let shell = NativeDesktopShell()
    try shell.start(shortcut: DesktopShortcut(parsing: "Ctrl+Alt+F12"), recording: false)
    defer { shell.stop() }
    let task = Task.detached {
      for await action in shell.actions where action == .showHistory {
        let expected = shell.takeActivationToken() == "synthetic-activation-token"
        let consumed = shell.takeActivationToken() == nil
        FileHandle.standardOutput.write(Data("activated:\(expected && consumed)\n".utf8))
      }
    }
    defer { task.cancel() }
    while let command = readLine() {
      if command == "quit" { break }
      if command == "request" { shell.requestShortcutPermission() }
      if command == "status" {
        let caps = shell.capabilities
        FileHandle.standardOutput.write(
          Data("status:\(caps.shortcutPortal.rawValue):\(caps.globalShortcut)\n".utf8))
      }
    }
  }

  func runPlatformShell() async -> Report {
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 30)
    watchdog.setEventHandler { exit(2) }
    watchdog.resume()
    defer { watchdog.cancel() }
    var checks: [CheckResult] = []
    let first = NativeDesktopShell()
    let second = NativeDesktopShell()
    defer {
      first.stop()
      second.stop()
    }
    do {
      let shortcut = try DesktopShortcut(parsing: "Ctrl+Alt+F12")
      try first.start(shortcut: shortcut, recording: false)
      check("native_shortcut_registered", first.capabilities.globalShortcut, into: &checks)
      var conflict = false
      do { try second.start(shortcut: shortcut, recording: false) } catch DesktopShellError
        .shortcutConflict
      { conflict = true }
      check("second_native_owner_reports_conflict", conflict, into: &checks)
      second.stop()
      first.updateRecording(true)
      first.updateRecording(false)
      check(
        "tray_state_updates_preserve_shortcut", first.capabilities.globalShortcut, into: &checks)
      first.stop()
      try second.start(shortcut: shortcut, recording: false)
      check("stop_releases_native_shortcut", second.capabilities.globalShortcut, into: &checks)
      second.stop()
      check(
        "stopped_shell_has_no_capabilities",
        !second.capabilities.globalShortcut && !second.capabilities.tray, into: &checks)
      // Exercise a process boundary: a separate owner must hold the shortcut,
      // and exiting it must release the OS registration. No keys are injected.
      let peer = Process()
      let input = Pipe()
      let output = Pipe()
      peer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      peer.arguments = ["shell-peer"]
      peer.standardInput = input
      peer.standardOutput = output
      try peer.run()
      defer {
        try? input.fileHandleForWriting.close()
        if peer.isRunning { peer.terminate() }
        peer.waitUntilExit()
      }
      var line = Data()
      while line.last != 10 {
        let next = output.fileHandleForReading.readData(ofLength: 1)
        guard !next.isEmpty else { throw DesktopShellError.unavailable }
        line.append(next)
        guard line.count < 32 else { throw DesktopShellError.unavailable }
      }
      conflict = false
      do { try first.start(shortcut: shortcut, recording: false) } catch DesktopShellError
        .shortcutConflict
      { conflict = true }
      check("independent_process_owns_shortcut", conflict, into: &checks)
      first.stop()
      try? input.fileHandleForWriting.close()
      peer.waitUntilExit()
      try first.start(shortcut: shortcut, recording: false)
      check(
        "independent_process_exit_releases_shortcut", first.capabilities.globalShortcut,
        into: &checks)
    } catch {
      check("native_shell_scenario", false, detail: "native_shell_unavailable", into: &checks)
    }
    return Report(
      scenario: "platform-shell", passed: !checks.isEmpty && checks.allSatisfy(\.passed),
      checks: checks)
  }
#else
  func runPlatformShell() async -> Report {
    Report(
      scenario: "platform-shell", passed: false,
      checks: [CheckResult(name: "unsupported_platform", passed: false, detail: nil)])
  }
#endif
