import Foundation

public protocol DesktopFileTextReading: Sendable {
  func text(from file: URL, maxBytes: Int) async throws -> String
}

/// Conservative copied-file policy. Only the first local URL is used, and its
/// path/name is never added to a prompt. PDF extraction runs in a bounded worker.
public enum DesktopFileTextPolicy {
  public static let maximumBytes = 1024 * 1024
  public static func validate(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") || (url.path.dropFirst().first == ":"),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.host == nil || components.host == "" || components.host == "localhost",
      !url.path.contains("\0"), url.path.utf8.count <= 65535,
      [
        "txt", "md", "markdown", "json", "csv", "xml", "yaml", "yml", "swift", "py", "js", "ts",
        "go", "rs", "sh", "html", "css", "log", "pdf",
      ].contains(url.pathExtension.lowercased())
    else { throw DesktopServiceError.invalidValue }
  }
}
