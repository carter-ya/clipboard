import AppKit
import Foundation

public protocol WorkspaceProvider: Sendable {
  func frontmostBundleIdentifier() -> String?
}

public struct SystemWorkspaceProvider: WorkspaceProvider {
  public init() {}

  public func frontmostBundleIdentifier() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }
}

public struct StubWorkspaceProvider: WorkspaceProvider {
  private let bundleID: String?

  public init(bundleID: String?) {
    self.bundleID = bundleID
  }

  public func frontmostBundleIdentifier() -> String? { bundleID }
}
