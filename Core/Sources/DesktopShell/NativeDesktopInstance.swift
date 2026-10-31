import CDesktopShell
import ClipboardCore
import Foundation

private final class ActivationBridge: @unchecked Sendable {
  let continuation: AsyncStream<Void>.Continuation
  init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
}

/// Owns a per-session/profile rendezvous before the store or UI is opened.
public final class NativeDesktopInstance: DesktopInstanceAccess, @unchecked Sendable {
  public let isPrimary: Bool
  public let activations: AsyncStream<Void>
  private let bridge: ActivationBridge
  private let lock = NSLock()
  private var handle: OpaquePointer?
  public init(identity: String) throws {
    let stream = AsyncStream.makeStream(of: Void.self)
    activations = stream.stream
    let bridge = ActivationBridge(stream.continuation)
    self.bridge = bridge
    var status: Int32 = -1
    let context = Unmanaged.passUnretained(bridge).toOpaque()
    let digest = DesktopProfileIdentity.namespace(for: identity)
    handle = digest.withCString { identity in
      clipboard_instance_create(
        identity,
        { context, _, _ in
          guard let context else { return }
          Unmanaged<ActivationBridge>.fromOpaque(context).takeUnretainedValue().continuation.yield(
            ())
        }, context, &status)
    }
    guard status >= 0 else { throw DesktopShellError.unavailable }
    isPrimary = status == 1
  }
  public func stop() {
    lock.withLock {
      if let handle { clipboard_instance_destroy(handle) }
      handle = nil
    }
  }
  deinit {
    if let handle { clipboard_instance_destroy(handle) }
    bridge.continuation.finish()
  }
}
