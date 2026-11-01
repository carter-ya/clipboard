import ClipboardCore
import DesktopShell
import Foundation
import SwiftCrossUI

@MainActor enum DesktopApplicationContext {
  static var instance: (any DesktopInstanceAccess)?
  static var profile = "production"
  static var dataRoot: URL?
  static var startupFailed = false
}

@main enum DesktopLauncher {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    do {
      let defaultRoot = try AppPaths.defaultStoreLocation().standardizedFileURL
        .resolvingSymlinksInPath()
      var root = defaultRoot
      if let index = arguments.firstIndex(of: "--smoke-root")
        ?? arguments.firstIndex(of: "--data-root")
      {
        guard index + 1 < arguments.count else { throw DesktopShellError.unavailable }
        root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
          .resolvingSymlinksInPath()
      }
      var identity = root.path
      var defaultIdentity = defaultRoot.path
      #if os(Windows)
        identity = identity.lowercased()
        defaultIdentity = defaultIdentity.lowercased()
      #endif
      // An explicit alias of the default path must share its single-instance gate.
      if arguments.contains("--smoke-root"), identity == defaultIdentity {
        throw DesktopShellError.unavailable
      }
      DesktopApplicationContext.profile =
        identity == defaultIdentity ? "production" : DesktopProfileIdentity.namespace(for: identity)
      DesktopApplicationContext.dataRoot = root
      let instance = try NativeDesktopInstance(identity: identity)
      guard instance.isPrimary else { return }
      DesktopApplicationContext.instance = instance
    } catch { DesktopApplicationContext.startupFailed = true }
    ClipboardDesktopApp.main()
  }
}
