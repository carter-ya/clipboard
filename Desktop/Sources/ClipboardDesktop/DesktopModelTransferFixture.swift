import ClipboardCore
import DesktopServices
import Foundation

/// Deterministic transfer failure/cancellation in private native-control tests.
/// Ordinary profiles always use the anonymous bounded network downloader.
enum DesktopModelTransferFixture {
  @MainActor static func downloader() -> any DesktopModelAssetDownloading {
    guard CommandLine.arguments.contains("--smoke-root"),
      CommandLine.arguments.contains("--smoke-model-transfers"),
      DesktopApplicationContext.profile != "production",
      let root = DesktopApplicationContext.dataRoot
    else { return BoundedDesktopModelDownloader() }
    try? Data("1".utf8).write(
      to: root.appendingPathComponent(".model-transfer-fixture-ready"), options: .atomic)
    return HeldTransfer(root: root)
  }
  private actor HeldTransfer: DesktopModelAssetDownloading {
    let root: URL
    var calls: [DesktopModelKind: Int] = [:]
    init(root: URL) { self.root = root }
    func download(
      _ asset: DesktopModelAsset, to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
      let count = (calls[asset.kind] ?? 0) + 1
      calls[asset.kind] = count
      let prefix = ".model-transfer-" + asset.kind.rawValue
      defer {
        try? Data(String(count).utf8).write(
          to: root.appendingPathComponent(prefix + "-finished"), options: .atomic)
      }
      do {
        try Data(repeating: 0, count: 4096).write(to: destination)
        progress(4096)
        try Data(String(count).utf8).write(
          to: root.appendingPathComponent(prefix + "-started"), options: .atomic)
      } catch { throw DesktopModelAssetError.unavailable }
      let deadline = ContinuousClock.now.advanced(by: .seconds(60))
      while !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(prefix + "-release").path)
      {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DesktopModelAssetError.unavailable }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try Task.checkCancellation()
      // Never publish fake model bytes or reach the network from this fixture.
      throw DesktopModelAssetError.unavailable
    }
  }
}
