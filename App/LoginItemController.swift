import Foundation
import ServiceManagement

/// Thin wrapper around SMAppService.mainApp for "Start at Login".
/// Returns an explicit result enum so the UI can roll back a Toggle
/// on failure and show a helpful error to the user.
@MainActor
enum LoginItemController {
  enum ApplyError: Error, LocalizedError {
    case notAllowed
    case underlying(Error)

    var errorDescription: String? {
      switch self {
      case .notAllowed:
        return String(
          localized:
            "Clipboard must live in /Applications and be code-signed before it can launch at login."
        )
      case .underlying(let err):
        return err.localizedDescription
      }
    }
  }

  /// Whether the system currently has us registered for launch at login.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Ensure the system's state matches `desired`. Throws on failure so
  /// the caller can roll back its UI / persisted state.
  static func apply(_ desired: Bool) throws {
    let service = SMAppService.mainApp
    do {
      if desired {
        if service.status == .enabled { return }
        try service.register()
      } else {
        if service.status == .notRegistered { return }
        try service.unregister()
      }
    } catch {
      if service.status == .requiresApproval {
        throw ApplyError.notAllowed
      }
      throw ApplyError.underlying(error)
    }
  }
}
