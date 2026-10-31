import Foundation

public enum DesktopProfileIdentity {
  /// Namespace local IPC without exposing user paths in object names or logs.
  public static func namespace(for identity: String) -> String {
    Hashing.sha256(of: Data(identity.utf8))
  }
}

public protocol DesktopInstanceAccess: AnyObject, Sendable {
  var isPrimary: Bool { get }
  var activations: AsyncStream<Void> { get }
  func stop()
}

public final class FakeDesktopInstance: DesktopInstanceAccess, @unchecked Sendable {
  public let isPrimary: Bool
  public let activations: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var running = true
  public init(isPrimary: Bool = true) {
    self.isPrimary = isPrimary
    (activations, continuation) = AsyncStream.makeStream()
  }
  public func activate() {
    if lock.withLock({ running && isPrimary }) { continuation.yield(()) }
  }
  public func stop() { lock.withLock { running = false } }
  deinit { continuation.finish() }
}
