import Foundation

#if os(macOS)
  import AppKit
#endif

public protocol WorkspaceProvider: Sendable {
  func frontmostBundleIdentifier() -> String?
}

#if os(macOS)
  public struct SystemWorkspaceProvider: WorkspaceProvider {
    public init() {}

    public func frontmostBundleIdentifier() -> String? {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
  }

#endif

public struct StubWorkspaceProvider: WorkspaceProvider {
  private let bundleID: String?

  public init(bundleID: String?) {
    self.bundleID = bundleID
  }

  public func frontmostBundleIdentifier() -> String? { bundleID }
}
