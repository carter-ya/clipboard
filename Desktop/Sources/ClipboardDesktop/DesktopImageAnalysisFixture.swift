import ClipboardCore
import DesktopServices
import Foundation

/// A private native-control fixture only. Ordinary profiles always use the
/// actual classifier and cannot select a model, delay or failure through settings.
enum DesktopImageAnalysisFixture {
  @MainActor static func classifier() -> any DesktopImageClassifying {
    guard CommandLine.arguments.contains("--smoke-root"),
      CommandLine.arguments.contains("--smoke-local-image"),
      DesktopApplicationContext.profile != "production",
      let root = DesktopApplicationContext.dataRoot
    else { return NativeDesktopImageClassifier() }
    return HeldClassifier(root: root)
  }
  private actor HeldClassifier: DesktopImageClassifying {
    let root: URL
    var calls = 0
    init(root: URL) { self.root = root }
    func classify(_ image: Data) async throws -> DesktopImageClassification {
      calls += 1
      let count = calls
      defer {
        try? Data(String(count).utf8).write(
          to: root.appendingPathComponent(".local-image-finished"), options: .atomic)
      }
      do {
        try Data(String(count).utf8).write(
          to: root.appendingPathComponent(".local-image-started"), options: .atomic)
      } catch { throw DesktopServiceError.unavailable }
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".local-image-release").path)
      {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DesktopServiceError.unavailable }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try Task.checkCancellation()
      if count == 1 { throw DesktopServiceError.unavailable }
      return try await NativeDesktopImageClassifier().classify(image)
    }
  }
}
