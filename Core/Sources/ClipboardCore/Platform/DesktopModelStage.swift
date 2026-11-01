import CDesktopModelFiles
import Foundation

/// A durable ownership record paired with an OS lease. Process death releases
/// the lease; it never makes a live transfer eligible for recovery.
final class DesktopModelStage {
  let file: URL
  private let owner: URL
  private let leaseFile: URL
  private var lease: UnsafeMutableRawPointer?

  init(directory: URL, asset: DesktopModelAsset, accepted: Bool, id: UUID) throws {
    file = directory.appendingPathComponent(".pending-" + id.uuidString)
    owner = directory.appendingPathComponent(".stage-owner-" + id.uuidString + ".json")
    leaseFile = directory.appendingPathComponent(".stage-lease-" + id.uuidString)
    guard
      let acquired = leaseFile.withUnsafeFileSystemRepresentation({
        clipboard_model_stage_lock($0, 1)
      })
    else {
      throw DesktopModelAssetError.unavailable
    }
    lease = acquired
    var recorded = false
    do {
      // Ownership reaches disk before a potentially large stage is created.
      // Existing UUID paths cannot be adopted or overwritten.
      guard try DesktopModelFiles.attributes(owner) == nil,
        try DesktopModelFiles.attributes(file) == nil
      else { throw DesktopModelAssetError.invalidLocation }
      try DesktopModelFiles.writeRecord(.init(asset, accepted: accepted), to: owner)
      recorded = true
      try Data().write(to: file, options: .withoutOverwriting)
    } catch {
      if recorded { try? FileManager.default.removeItem(at: owner) }
      release()
      try? FileManager.default.removeItem(at: leaseFile)
      throw error
    }
  }
  deinit { release() }
  private func release() {
    if let lease { clipboard_model_stage_unlock(lease) }
    lease = nil
  }
  func cleanup() {
    // Keep the ownership proof and lease if deleting the bytes fails, so a
    // later explicit operation can retry after the OS releases file handles.
    do {
      if try DesktopModelFiles.regular(file) { try FileManager.default.removeItem(at: file) }
      try FileManager.default.removeItem(at: owner)
      release()
      try? FileManager.default.removeItem(at: leaseFile)
    } catch { release() }
  }
  static func recover(in directory: URL, kind: DesktopModelKind) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard names.count <= 4096 else { throw DesktopModelAssetError.invalidLocation }
    for name in names where name.hasPrefix(".stage-owner-") && name.hasSuffix(".json") {
      let suffix = String(name.dropFirst(".stage-owner-".count).dropLast(".json".count))
      guard let id = UUID(uuidString: suffix), id.uuidString == suffix else { continue }
      let owner = directory.appendingPathComponent(name)
      // Malformed/foreign records and legacy unrecorded stages are preserved.
      guard (try? DesktopModelFiles.record(owner, kind: kind)) != nil else { continue }
      let leaseFile = directory.appendingPathComponent(".stage-lease-" + suffix)
      guard
        let lease = leaseFile.withUnsafeFileSystemRepresentation({
          clipboard_model_stage_lock($0, 0)
        })
      else {
        continue
      }
      do {
        // Re-read after acquiring the lease: another recovery may have already
        // removed the record while this caller was enumerating the directory.
        guard try DesktopModelFiles.record(owner, kind: kind) != nil else {
          clipboard_model_stage_unlock(lease)
          continue
        }
        let file = directory.appendingPathComponent(".pending-" + suffix)
        if try DesktopModelFiles.regular(file) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.removeItem(at: owner)
        clipboard_model_stage_unlock(lease)
        try? FileManager.default.removeItem(at: leaseFile)
      } catch {
        clipboard_model_stage_unlock(lease)
        throw error
      }
    }
  }
}
