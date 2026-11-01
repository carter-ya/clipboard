import CDesktopShell
import ClipboardCore
import Foundation

/// Keeps an installed bundle stable while any of its profile windows are open.
/// Windows installers observe the named mutex; Linux installers lock the bundle directory.
public final class NativeDesktopInstallationLock: @unchecked Sendable {
  private let handle: OpaquePointer
  public init(directory: URL) throws {
    guard let handle = directory.path.withCString({ clipboard_installation_lock_create($0) }) else {
      throw DesktopShellError.unavailable
    }
    self.handle = handle
  }
  deinit { clipboard_installation_lock_destroy(handle) }
}
