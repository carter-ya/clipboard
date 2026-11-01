import Foundation

#if os(Windows)
  import WinSDK
#elseif os(Linux)
  import Glibc
#else
  import Darwin
#endif

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

/// Synchronizes cancellation with the final, small filesystem transaction.
/// Cancellation cannot turn a committed model into a reported failed install.
final class DesktopModelCommitGate: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var committed = false
  func cancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !committed else { return false }
    cancelled = true
    return true
  }
  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }
  func commit<T>(_ action: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    let result = try action()
    committed = true
    return result
  }
}

struct DesktopModelFileRecord: Codable, Equatable, Sendable {
  let version: Int
  let kind: DesktopModelKind
  let id: String
  let sha256: String
  let size: Int64
  let license: String
  let licenseAccepted: Bool
  var filename: String { sha256 + (kind == .generative ? ".gguf" : ".onnx") }
  init(_ asset: DesktopModelAsset, accepted: Bool) {
    version = 1
    kind = asset.kind
    id = asset.id
    sha256 = asset.sha256
    size = asset.size
    license = asset.license
    licenseAccepted = accepted
  }
  func validate(kind expected: DesktopModelKind) throws {
    guard version == 1, kind == expected, DesktopModelFiles.name(id),
      DesktopModelFiles.digest(sha256), size > 0, size <= 8 * 1024 * 1024 * 1024,
      (kind == .generative && license == "Apache-2.0")
        || (kind == .entities && license == "AFL-3.0" && licenseAccepted)
    else { throw DesktopModelAssetError.invalidLocation }
  }
  func matches(_ asset: DesktopModelAsset) -> Bool {
    kind == asset.kind && id == asset.id && sha256 == asset.sha256 && size == asset.size
      && license == asset.license && (!asset.licenseAcceptanceRequired || licenseAccepted)
  }
}

enum DesktopModelFiles {
  static func replace(_ source: URL, to target: URL) throws {
    guard local(source), local(target),
      source.deletingLastPathComponent() == target.deletingLastPathComponent()
    else {
      throw DesktopModelAssetError.invalidLocation
    }
    #if os(Windows)
      let from = try windowsPath(source)
      let to = try windowsPath(target)
      let moved = from.withUnsafeBufferPointer { first in
        to.withUnsafeBufferPointer { second in
          MoveFileExW(
            first.baseAddress, second.baseAddress,
            DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        }
      }
    #else
      let moved = source.withUnsafeFileSystemRepresentation { first in
        target.withUnsafeFileSystemRepresentation { second in
          guard let first, let second else { return false }
          return rename(first, second) == 0
        }
      }
    #endif
    guard moved else { throw DesktopModelAssetError.unavailable }
  }
  #if os(Windows)
    private static func windowsPath(_ url: URL) throws -> [UInt16] {
      guard var path = url.withUnsafeFileSystemRepresentation({ $0.map { String(cString: $0) } })
      else {
        throw DesktopModelAssetError.invalidLocation
      }
      path = path.replacingOccurrences(of: "/", with: "\\")
      if path.hasPrefix("\\\\?\\") { path.removeFirst(4) }
      let characters = Array(path.utf16)
      guard characters.count >= 3, characters.count <= 32760,
        (65...90).contains(characters[0]) || (97...122).contains(characters[0]),
        characters[1] == 58, characters[2] == 92
      else { throw DesktopModelAssetError.invalidLocation }
      let drive = [characters[0], UInt16(58), UInt16(92), UInt16(0)]
      let type = drive.withUnsafeBufferPointer { GetDriveTypeW($0.baseAddress) }
      guard type == DRIVE_FIXED || type == DRIVE_REMOVABLE || type == DRIVE_RAMDISK else {
        throw DesktopModelAssetError.invalidLocation
      }
      return Array(("\\\\?\\" + path).utf16) + [0]
    }
  #endif
  static let marker = Data("Clipboard local model assets v1\n".utf8)
  static func name(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 120 && value != "." && value != ".."
      && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || [45, 46, 95].contains($0)
      }
  }
  static func digest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func local(_ url: URL) -> Bool {
    guard url.isFileURL, [nil, "", "localhost"].contains(url.host),
      !url.path.contains("\0"), url.path.utf8.count <= 65535,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return false }
    return parts.user == nil && parts.password == nil && parts.query == nil && parts.fragment == nil
  }
  static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch {
      if (error as NSError).domain == NSCocoaErrorDomain,
        [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code)
      {
        return nil
      }
      // Foundation also reports a missing final component as a POSIX error.
      if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == 2 {
        return nil
      }
      throw DesktopModelAssetError.unavailable
    }
  }
  static func regular(_ url: URL, size: Int64? = nil) throws -> Bool {
    guard let values = try attributes(url) else { return false }
    guard values[.type] as? FileAttributeType == .typeRegular else {
      throw DesktopModelAssetError.invalidLocation
    }
    if let size, (values[.size] as? NSNumber)?.int64Value != size {
      throw DesktopModelAssetError.wrongSize
    }
    return true
  }
  static func small(_ url: URL, maximum: Int = 16384) throws -> Data? {
    guard let values = try attributes(url) else { return nil }
    guard values[.type] as? FileAttributeType == .typeRegular,
      let size = values[.size] as? NSNumber, size.int64Value <= maximum
    else { throw DesktopModelAssetError.invalidLocation }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: maximum + 1) ?? Data()
    guard data.count <= maximum else { throw DesktopModelAssetError.invalidLocation }
    return data
  }
  static func directory(_ url: URL, create: Bool) throws -> Bool {
    if let values = try attributes(url) {
      guard values[.type] as? FileAttributeType == .typeDirectory else {
        throw DesktopModelAssetError.invalidLocation
      }
      return true
    }
    guard create else { return false }
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return true
  }
  static func root(_ url: URL, create: Bool) throws -> Bool {
    guard try directory(url, create: create) else { return false }
    let stamp = url.appendingPathComponent(".clipboard-model-assets-v1")
    if let data = try small(stamp, maximum: 128) {
      guard data == marker else { throw DesktopModelAssetError.invalidLocation }
    } else {
      let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
      guard contents.isEmpty else { throw DesktopModelAssetError.invalidLocation }
      guard create else { return false }
      try marker.write(to: stamp, options: .withoutOverwriting)
    }
    return true
  }
  static func record(_ url: URL, kind: DesktopModelKind) throws -> DesktopModelFileRecord? {
    guard let data = try small(url) else { return nil }
    let record: DesktopModelFileRecord
    do { record = try JSONDecoder().decode(DesktopModelFileRecord.self, from: data) } catch {
      throw DesktopModelAssetError.invalidLocation
    }
    try record.validate(kind: kind)
    return record
  }
  static func writeRecord(_ record: DesktopModelFileRecord, to url: URL) throws {
    if try attributes(url) != nil { _ = try regular(url) }
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
  }
  static func verify(_ url: URL, asset: DesktopModelAsset, gate: DesktopModelCommitGate) throws {
    try gate.check()
    guard local(url), try regular(url, size: asset.size) else {
      throw DesktopModelAssetError.unavailable
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var count: Int64 = 0
    while true {
      try Task.checkCancellation()
      try gate.check()
      let bytes = try file.read(upToCount: 1024 * 1024) ?? Data()
      if bytes.isEmpty { break }
      guard Int64(bytes.count) <= asset.size - count else { throw DesktopModelAssetError.wrongSize }
      count += Int64(bytes.count)
      hash.update(data: bytes)
    }
    guard count == asset.size else { throw DesktopModelAssetError.wrongSize }
    let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard value == asset.sha256 else { throw DesktopModelAssetError.digestMismatch }
    try gate.check()
  }
  static func copy(
    _ source: URL, to destination: URL, asset: DesktopModelAsset, gate: DesktopModelCommitGate
  ) throws {
    guard local(source), try regular(source, size: asset.size) else {
      throw DesktopModelAssetError.invalidLocation
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var count: Int64 = 0
    while true {
      try Task.checkCancellation()
      try gate.check()
      let bytes = try input.read(upToCount: 1024 * 1024) ?? Data()
      if bytes.isEmpty { break }
      guard Int64(bytes.count) <= asset.size - count else { throw DesktopModelAssetError.wrongSize }
      count += Int64(bytes.count)
      try output.write(contentsOf: bytes)
    }
    guard count == asset.size else { throw DesktopModelAssetError.wrongSize }
    try output.synchronize()
  }
}
