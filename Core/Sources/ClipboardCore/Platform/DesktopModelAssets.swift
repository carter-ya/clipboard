import Foundation

public enum DesktopModelKind: String, Codable, CaseIterable, Hashable, Sendable {
  case generative
  case entities
}

/// Public, immutable catalog metadata. Normal application construction reads
/// only bundled definitions; callers cannot supply a download endpoint.
public struct DesktopModelAsset: Equatable, Sendable {
  public let kind: DesktopModelKind
  public let id: String
  public let filename: String
  public let url: URL
  public let sha256: String
  public let size: Int64
  public let license: String
  public let licenseURL: URL
  public let cardURL: URL
  public let licenseAcceptanceRequired: Bool

  public static func bundled(_ kind: DesktopModelKind) throws -> Self {
    switch kind {
    case .generative:
      let value = try DesktopLocalLanguageModelDefinition.bundled()
      return Self(
        kind: kind, id: value.id, filename: value.filename, url: value.url, sha256: value.sha256,
        size: value.size, license: value.license, licenseURL: value.licenseURL,
        cardURL: value.cardURL, licenseAcceptanceRequired: false)
    case .entities:
      let value = try DesktopLocalEntityModelDefinition.bundled()
      return Self(
        kind: kind, id: value.id, filename: value.filename, url: value.url, sha256: value.sha256,
        size: value.size, license: value.license, licenseURL: value.licenseURL,
        cardURL: value.cardURL, licenseAcceptanceRequired: value.licenseAcceptanceRequired)
    }
  }
}

public enum DesktopModelAssetError: Error, Equatable, Sendable {
  case busy
  case licenseNotAccepted
  case invalidLocation
  case unavailable
  case wrongSize
  case digestMismatch
  case invalidResponse
  case insufficientSpace
}

public enum DesktopModelAssetStatus: Equatable, Sendable {
  case missing
  case checking
  case downloading(received: Int64, total: Int64)
  case verifying
  case ready
  case cancelling
  case removing
  case failed(DesktopModelAssetError)
}

public struct DesktopModelAssetState: Equatable, Sendable {
  public let status: DesktopModelAssetStatus
  /// Availability is independent of a later failed installation attempt.
  public let installed: Bool
  public init(status: DesktopModelAssetStatus, installed: Bool) {
    self.status = status
    self.installed = installed
  }
}

/// One explicitly requested public-model transfer. Implementations own the
/// session and destination stream, enforce the exact byte ceiling, report only
/// byte counts and finish cancellation/cleanup before returning. History,
/// credentials and arbitrary server endpoints are intentionally absent.
public protocol DesktopModelAssetDownloading: Sendable {
  func download(
    _ asset: DesktopModelAsset, to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
}
