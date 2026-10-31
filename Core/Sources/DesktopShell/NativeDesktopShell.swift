import CDesktopShell
import ClipboardCore
import Foundation

private final class ShellEventBridge: @unchecked Sendable {
  let continuation: AsyncStream<DesktopShellAction>.Continuation
  init(_ continuation: AsyncStream<DesktopShellAction>.Continuation) {
    self.continuation = continuation
  }
}

/// Serializes native ownership; callers start/stop it away from the UI actor.
public final class NativeDesktopShell: DesktopShellAccess, @unchecked Sendable {
  public let actions: AsyncStream<DesktopShellAction>
  private let continuation: AsyncStream<DesktopShellAction>.Continuation
  private let bridge: ShellEventBridge
  private let queue = DispatchQueue(label: "com.clipboard.desktop.shell")
  private var handle: OpaquePointer?
  private var currentShortcut: DesktopShortcut?
  private var started = false

  public init() {
    let stream = AsyncStream.makeStream(of: DesktopShellAction.self)
    actions = stream.stream
    continuation = stream.continuation
    bridge = ShellEventBridge(stream.continuation)
  }

  public var capabilities: DesktopShellCapabilities {
    queue.sync {
      let flags = clipboard_shell_capabilities(handle)
      return .init(tray: flags & 1 != 0, globalShortcut: flags & 2 != 0)
    }
  }

  public var activationTimestamp: UInt32 { queue.sync { clipboard_shell_activation_time(handle) } }

  public func start(shortcut: DesktopShortcut?, recording: Bool) throws {
    try queue.sync {
      if started && currentShortcut == shortcut {
        clipboard_shell_set_recording(handle, recording ? 1 : 0)
        return
      }
      var error: Int32 = 0
      let context = Unmanaged.passUnretained(bridge).toOpaque()
      let next = (shortcut?.key ?? "").withCString { key in
        clipboard_shell_create(
          key, shortcut?.modifiers.rawValue ?? 0, recording ? 1 : 0,
          { context, rawAction in
            guard let context, let action = DesktopShellAction(rawValue: rawAction) else { return }
            Unmanaged<ShellEventBridge>.fromOpaque(context).takeUnretainedValue()
              .continuation.yield(action)
          }, context, &error)
      }
      guard let next else { throw DesktopShellError.unavailable }
      // Keep a working previous binding if the new shortcut conflicts. Creating
      // the replacement before destroying the old one avoids an unbound gap.
      if error != 0, handle != nil {
        clipboard_shell_destroy(next)
        throw error == 2 ? DesktopShellError.shortcutConflict : DesktopShellError.unavailable
      }
      if let handle { clipboard_shell_destroy(handle) }
      handle = next
      currentShortcut = error == 0 ? shortcut : nil
      started = true
      if error != 0 {
        throw error == 2 ? DesktopShellError.shortcutConflict : DesktopShellError.unavailable
      }
    }
  }

  public func updateRecording(_ enabled: Bool) {
    queue.sync { clipboard_shell_set_recording(handle, enabled ? 1 : 0) }
  }
  public func stop() {
    queue.sync {
      if let handle { clipboard_shell_destroy(handle) }
      handle = nil
      currentShortcut = nil
      started = false
    }
  }
  deinit {
    if let handle { clipboard_shell_destroy(handle) }
    continuation.finish()
  }
}
