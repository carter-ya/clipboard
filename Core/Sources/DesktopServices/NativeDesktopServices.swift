import CDesktopServices
import ClipboardCore
import Foundation

public final class NativeDesktopCredentials: DesktopCredentialStoring, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.clipboard.desktop.credentials")
  private let namespace: String
  public init(namespace: String = "production") { self.namespace = namespace }
  private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try operation() }) }
    }
  }
  public func read(account: String) async throws -> String? {
    let namespace = namespace
    return try await perform {
      let account = DesktopProfileIdentity.namespace(for: namespace + ":" + account)
      var value: UnsafeMutablePointer<CChar>?
      let result = account.withCString { cds_credential_read($0, &value) }
      defer { if let value { cds_free(value) } }
      if result == 0 { return nil }
      guard result == 1, let value else { throw DesktopServiceError.unavailable }
      return String(validatingUTF8: value)
    }
  }
  public func save(_ value: String, account: String) async throws {
    guard !value.contains("\0"), value.utf8.count <= 4096 else {
      throw DesktopServiceError.invalidValue
    }
    let namespace = namespace
    try await perform {
      let account = DesktopProfileIdentity.namespace(for: namespace + ":" + account)
      let result = account.withCString { account in
        value.withCString { cds_credential_save(account, $0) }
      }
      guard result == 1 else { throw DesktopServiceError.unavailable }
    }
  }
  public func delete(account: String) async throws {
    let namespace = namespace
    try await perform {
      let account = DesktopProfileIdentity.namespace(for: namespace + ":" + account)
      guard account.withCString({ cds_credential_delete($0) }) == 1 else {
        throw DesktopServiceError.unavailable
      }
    }
  }
}

public actor NativeDesktopStartup: DesktopStartupControlling {
  private let executable: URL
  private let name: String
  private let configRoot: URL
  public init(executable: URL, name: String = "com.clipboard.desktop", configRoot: URL? = nil)
    throws
  {
    guard !name.isEmpty, name.utf8.count < 100,
      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
      !executable.path.contains("\0"), !executable.path.contains(where: \.isNewline)
    else { throw DesktopServiceError.invalidValue }
    self.executable = executable.standardizedFileURL
    self.name = name
    let override = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    self.configRoot =
      configRoot ?? override.flatMap {
        $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
      }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".config", isDirectory: true)
  }
  private var command: String { "\"" + executable.path + "\" --background" }
  private var desktopFile: URL {
    configRoot.appendingPathComponent("autostart").appendingPathComponent(name + ".desktop")
  }
  private var desktopEntry: Data {
    var path = executable.path
    for character in ["\\", "\"", "$", "`"] {
      path = path.replacingOccurrences(of: character, with: "\\" + character)
    }
    path = path.replacingOccurrences(of: "%", with: "%%")
    return Data(
      "[Desktop Entry]\nType=Application\nName=Clipboard\nExec=\"\(path)\" --background\nIcon=edit-paste\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
        .utf8)
  }
  #if os(Linux)
    private func desktopString(_ raw: String) -> String? {
      var result = ""
      var characters = raw.makeIterator()
      while let character = characters.next() {
        if character != "\\" {
          result.append(character)
          continue
        }
        guard let escaped = characters.next() else { return nil }
        switch escaped {
        case "s": result.append(" ")
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "\\": result.append("\\")
        default: return nil
        }
      }
      return result
    }
    /// Read only the bounded application group. Presentation edits do not
    /// change ownership; a different command, malformed file or symlink does.
    private func ownedDesktopEntry() throws -> [String: String]? {
      let manager = FileManager.default
      let attributes: [FileAttributeKey: Any]
      do { attributes = try manager.attributesOfItem(atPath: desktopFile.path) } catch {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain,
          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
        {
          return nil
        }
        throw error
      }
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DesktopServiceError.startupConflict
      }
      let handle = try FileHandle(forReadingFrom: desktopFile)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 65537) ?? Data()
      guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
        throw DesktopServiceError.startupConflict
      }
      var fields: [String: String] = [:]
      var inApplication = false
      var foundApplication = false
      for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("[") {
          inApplication = line == "[Desktop Entry]"
          if inApplication {
            guard !foundApplication else { throw DesktopServiceError.startupConflict }
            foundApplication = true
          }
          continue
        }
        guard inApplication else { continue }
        guard let separator = line.firstIndex(of: "=") else {
          throw DesktopServiceError.startupConflict
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard fields[key] == nil else { throw DesktopServiceError.startupConflict }
        fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      }
      let expected = String(decoding: desktopEntry, as: UTF8.self)
        .components(separatedBy: .newlines).first { $0.hasPrefix("Exec=") }
      guard fields["Type"] == "Application", let expected,
        fields["Exec"] == String(expected.dropFirst(5))
      else { throw DesktopServiceError.startupConflict }
      return fields
    }
  #endif
  public func isEnabled() throws -> Bool {
    #if os(Windows)
      let status = name.withCString { name in command.withCString { cds_startup_read(name, $0) } }
      guard status != -3 else { throw DesktopServiceError.startupConflict }
      guard status >= 0 else { throw DesktopServiceError.unavailable }
      return status == 1
    #elseif os(Linux)
      guard let fields = try ownedDesktopEntry() else { return false }
      if fields["Hidden"] == "true" || fields["X-GNOME-Autostart-enabled"] == "false" {
        return false
      }
      // A modified entry can add session restrictions. Do not claim it will
      // launch when the current desktop is excluded or TryExec is unavailable.
      let desktops =
        ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"]?
        .split(separator: ":").map(String.init) ?? []
      if let only = fields["OnlyShowIn"],
        !only.split(separator: ";").contains(where: { desktops.contains(String($0)) })
      {
        return false
      }
      if let excluded = fields["NotShowIn"],
        excluded.split(separator: ";").contains(where: { desktops.contains(String($0)) })
      {
        return false
      }
      if fields["OnlyShowIn"] != nil && fields["NotShowIn"] != nil { return false }
      if let rawProgram = fields["TryExec"], !rawProgram.isEmpty {
        guard let program = desktopString(rawProgram) else { return false }
        guard program.hasPrefix("/") || !program.contains("/") else { return false }
        let candidates =
          program.hasPrefix("/")
          ? [program]
          : (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            String($0) + "/" + program
          }
        guard
          candidates.contains(where: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
              && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
          })
        else { return false }
      }
      return fields["DBusActivatable"] != "true"
    #else
      throw DesktopServiceError.unavailable
    #endif
  }
  public func setEnabled(_ enabled: Bool) throws {
    #if os(Windows)
      guard !executable.path.contains("\"") else { throw DesktopServiceError.invalidValue }
      let status = name.withCString { name in
        command.withCString { cds_startup_set(name, $0, enabled ? 1 : 0) }
      }
      guard status != -3 else { throw DesktopServiceError.startupConflict }
      guard status == 1 else { throw DesktopServiceError.unavailable }
    #elseif os(Linux)
      _ = try ownedDesktopEntry()
      if enabled {
        try FileManager.default.createDirectory(
          at: desktopFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try desktopEntry.write(to: desktopFile, options: .atomic)
      } else if FileManager.default.fileExists(atPath: desktopFile.path) {
        try FileManager.default.removeItem(at: desktopFile)
      }
    #else
      throw DesktopServiceError.unavailable
    #endif
  }
}

public final class NativeDesktopOCR: DesktopOCRRecognizing, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.clipboard.desktop.ocr")
  public init() {}
  public func recognize(_ image: Data, language: String? = nil) async throws -> String {
    guard !image.isEmpty, image.count <= 16 * 1024 * 1024 else {
      throw DesktopServiceError.tooLarge
    }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(
          with: Result {
            #if os(Windows)
              return try Self.windowsOCR(image, language: language)
            #else
              var text: UnsafeMutablePointer<CChar>?
              let requested = language?.hasPrefix("zh") == true ? "eng+chi_sim" : "eng"
              let result = image.withUnsafeBytes { bytes in
                requested.withCString {
                  cds_ocr(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, $0, &text)
                }
              }
              defer { if let text { cds_free(text) } }
              guard result == 1, let text else { throw DesktopServiceError.unavailable }
              return String(String(cString: text).prefix(8000)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            #endif
          })
      }
    }
  }
  #if os(Windows)
    private static func windowsOCR(_ data: Data, language: String?) throws -> String {
      guard let script = Bundle.module.url(forResource: "WindowsOCR", withExtension: "ps1"),
        let windows = ProcessInfo.processInfo.environment.first(where: {
          $0.key.caseInsensitiveCompare("SystemRoot") == .orderedSame
        })?.value
      else { throw DesktopServiceError.unavailable }
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: windows).appendingPathComponent(
        "System32/WindowsPowerShell/v1.0/powershell.exe")
      process.arguments = [
        "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy",
        "Bypass", "-File",
        script.path,
      ]
      if let language, !language.isEmpty {
        process.arguments = (process.arguments ?? []) + ["-Language", language]
      }
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + 45)
      timer.setEventHandler { if process.isRunning { process.terminate() } }
      timer.resume()
      defer {
        timer.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
      }
      try input.fileHandleForWriting.write(contentsOf: Data(data.base64EncodedString().utf8))
      try input.fileHandleForWriting.close()
      var bytes = Data()
      while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
        guard chunk.count <= 64 * 1024 - bytes.count else { throw DesktopServiceError.tooLarge }
        bytes.append(chunk)
      }
      process.waitUntilExit()
      guard process.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8) else {
        throw DesktopServiceError.unavailable
      }
      return String(text.prefix(8000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  #endif
}
