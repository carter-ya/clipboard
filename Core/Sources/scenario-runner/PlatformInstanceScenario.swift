import ClipboardCore
import Foundation

#if os(Linux) || os(Windows)
  import DesktopShell
  #if os(Linux)
    import Glibc
  #endif

  func runInstancePeer() throws {
    guard CommandLine.arguments.count > 2 else { throw DesktopShellError.unavailable }
    let instance = try NativeDesktopInstance(identity: CommandLine.arguments[2])
    defer { instance.stop() }
    if !instance.isPrimary {
      FileHandle.standardOutput.write(Data("secondary\n".utf8))
      return
    }
    let stream = instance.activations
    let task = Task.detached {
      for await _ in stream {
        guard !Task.isCancelled else { break }
        FileHandle.standardOutput.write(Data("activated\n".utf8))
      }
    }
    defer { task.cancel() }
    FileHandle.standardOutput.write(Data("primary\n".utf8))
    _ = readLine()
  }

  private func instanceLine(_ pipe: Pipe) throws -> String {
    var line = Data()
    while line.last != 10 {
      let byte = pipe.fileHandleForReading.readData(ofLength: 1)
      guard !byte.isEmpty else { throw DesktopShellError.unavailable }
      line.append(byte)
      guard line.count <= 32 else { throw DesktopShellError.unavailable }
    }
    return String(decoding: line.dropLast(), as: UTF8.self)
  }

  func runPlatformInstance() async -> Report {
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 30)
    watchdog.setEventHandler { exit(2) }
    watchdog.resume()
    defer { watchdog.cancel() }
    var checks: [CheckResult] = []
    let identity = "fixture-" + UUID().uuidString
    do {
      let first = try NativeDesktopInstance(identity: identity)
      defer { first.stop() }
      check("first_process_claims_profile", first.isPrimary, into: &checks)
      let secondary = Process()
      let output = Pipe()
      secondary.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      secondary.arguments = ["instance-peer", identity]
      secondary.standardOutput = output
      try secondary.run()
      let result = try instanceLine(output)
      secondary.waitUntilExit()
      check(
        "secondary_process_does_not_claim_profile",
        result == "secondary" && secondary.terminationStatus == 0, into: &checks)
      var activations = first.activations.makeAsyncIterator()
      let activation: Void? = await activations.next()
      check("secondary_activates_existing_process", activation != nil, into: &checks)
      first.stop()
      let owner = Process()
      let input = Pipe()
      let ownerOutput = Pipe()
      owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      owner.arguments = ["instance-peer", identity]
      owner.standardInput = input
      owner.standardOutput = ownerOutput
      try owner.run()
      defer {
        try? input.fileHandleForWriting.close()
        if owner.isRunning { owner.terminate() }
        owner.waitUntilExit()
      }
      check(
        "stopping_releases_profile_ownership", try instanceLine(ownerOutput) == "primary",
        into: &checks)
      let next = try NativeDesktopInstance(identity: identity)
      var activated = false
      if !next.isPrimary { activated = try instanceLine(ownerOutput) == "activated" }
      check("new_owner_receives_activation", !next.isPrimary && activated, into: &checks)
      next.stop()
      #if os(Linux)
        // Test abrupt owner loss, including an orphaned socket. SIGTERM may be
        // inherited as blocked by Foundation's Linux process launcher.
        _ = Glibc.kill(owner.processIdentifier, SIGKILL)
      #else
        owner.terminate()
      #endif
      owner.waitUntilExit()
      let recovered = try NativeDesktopInstance(identity: identity)
      defer { recovered.stop() }
      check("terminated_owner_is_recovered", recovered.isPrimary, into: &checks)
    } catch {
      check(
        "native_instance_scenario", false, detail: "instance_handoff_unavailable", into: &checks)
    }
    return Report(
      scenario: "platform-instance", passed: !checks.isEmpty && checks.allSatisfy(\.passed),
      checks: checks)
  }
#else
  func runPlatformInstance() async -> Report {
    Report(
      scenario: "platform-instance", passed: false,
      checks: [CheckResult(name: "unsupported_platform", passed: false, detail: nil)])
  }
#endif
