import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Strict bounded SemVer precedence, independent of release-list ordering.
public struct DesktopReleaseVersion: Comparable, Sendable {
  private let numbers: [UInt64]
  private let prerelease: [String]
  public var isPrerelease: Bool { !prerelease.isEmpty }
  public init?(_ value: String) {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || [43, 45, 46].contains($0)
      })
    else { return nil }
    let build = value.split(separator: "+", omittingEmptySubsequences: false)
    guard build.count <= 2 else { return nil }
    func identifiers(_ value: Substring) -> [String]? {
      let parts = value.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.allSatisfy({ !$0.isEmpty && !$0.contains("+") }) else { return nil }
      return parts.map(String.init)
    }
    if build.count == 2 && identifiers(build[1]) == nil { return nil }
    let main = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let fields = main[0].split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count == 3 else { return nil }
    var numbers: [UInt64] = []
    for field in fields {
      guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
        field.count == 1 || field.first != "0", let number = UInt64(field)
      else { return nil }
      numbers.append(number)
    }
    var pre: [String] = []
    if main.count == 2 {
      guard let parts = identifiers(main[1]),
        parts.allSatisfy({ part in
          !part.utf8.allSatisfy({ (48...57).contains($0) }) || part.count == 1 || part.first != "0"
        })
      else { return nil }
      pre = parts
    }
    self.numbers = numbers
    prerelease = pre
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
      return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
    }
    for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
      let numericA = a.utf8.allSatisfy { (48...57).contains($0) }
      let numericB = b.utf8.allSatisfy { (48...57).contains($0) }
      if numericA != numericB { return numericA }
      if numericA && a.count != b.count { return a.count < b.count }
      return a < b
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }
}

public enum DesktopUpdateTarget: String, Sendable {
  case windowsX64 = "windows-x64"
  case linuxX64 = "linux-x64"
  case linuxARM64 = "linux-arm64"
}
public struct DesktopAvailableUpdate: Equatable, Sendable {
  public let version: String
  public let page: URL
}
public enum DesktopUpdateResult: Equatable, Sendable {
  case available(DesktopAvailableUpdate)
  case upToDate, noCompatibleRelease
  case invalidVersion, rateLimited, failed, cancelled
}
public protocol DesktopUpdateChecking: Sendable {
  func check() async -> DesktopUpdateResult
}
public struct FakeDesktopUpdateChecker: DesktopUpdateChecking {
  public let result: DesktopUpdateResult
  public init(result: DesktopUpdateResult) { self.result = result }
  public func check() async -> DesktopUpdateResult { result }
}

/// Explicit public-release metadata only. No history, settings or credentials
/// are dependencies. The only external navigation is a constructed official page.
public struct DesktopUpdateChecker: DesktopUpdateChecking {
  private let currentVersion: String
  private let target: DesktopUpdateTarget
  private let transport: any DesktopAITransport
  public init(
    currentVersion: String, target: DesktopUpdateTarget, transport: any DesktopAITransport
  ) {
    self.currentVersion = currentVersion
    self.target = target
    self.transport = transport
  }
  private struct Release: Decodable {
    let tagName: String
    private enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case draft, prerelease, assets
    }
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
  }
  private struct Asset: Decodable {
    let name: String
    let state: String
    let size: Int64
  }
  public func check() async -> DesktopUpdateResult {
    guard let current = DesktopReleaseVersion(currentVersion) else { return .invalidVersion }
    guard
      let url = URL(string: "https://api.github.com/repos/carter-ya/clipboard/releases?per_page=20")
    else { return .failed }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("ClipboardDesktop-update-check", forHTTPHeaderField: "User-Agent")
    do {
      try Task.checkCancellation()
      let response = try await transport.send(request, maxResponseBytes: 1024 * 1024)
      try Task.checkCancellation()
      if response.status == 403 || response.status == 429 { return .rateLimited }
      guard response.status == 200, response.data.count <= 1024 * 1024,
        let releases = try? JSONDecoder().decode([Release].self, from: response.data),
        releases.count <= 20
      else { return .failed }
      var best: (DesktopReleaseVersion, DesktopAvailableUpdate)?
      var compatible = false
      for release in releases where !release.draft && release.assets.count <= 100 {
        let tag = release.tagName
        let raw: String
        if tag.hasPrefix("desktop-v") {
          raw = String(tag.dropFirst(9))
        } else if tag.hasPrefix("v") {
          raw = String(tag.dropFirst())
        } else {
          continue
        }
        guard let version = DesktopReleaseVersion(raw),
          release.prerelease == version.isPrerelease,
          current.isPrerelease || !release.prerelease
        else { continue }
        let filename =
          "ClipboardDesktop-\(raw)-\(target.rawValue)"
          + (target == .windowsX64 ? "-setup.exe" : ".tar.gz")
        let uploaded = Set(
          release.assets.filter { $0.state == "uploaded" && $0.size > 0 }.map(\.name))
        guard uploaded.contains(filename), uploaded.contains("SHA256SUMS") else { continue }
        compatible = true
        guard version > current, best == nil || version > best!.0,
          let page = URL(string: "https://github.com/carter-ya/clipboard/releases/tag/" + tag)
        else { continue }
        best = (version, .init(version: raw, page: page))
      }
      if let best { return .available(best.1) }
      return compatible ? .upToDate : .noCompatibleRelease
    } catch {
      return Task.isCancelled ? .cancelled : .failed
    }
  }
}

@MainActor public final class DesktopUpdateState {
  public private(set) var busy = false
  public private(set) var result: DesktopUpdateResult?
  private let checker: any DesktopUpdateChecking
  private let changed: @MainActor (Bool, DesktopUpdateResult?) -> Void
  private var task: Task<Void, Never>?
  private var revision: UInt64 = 0
  private var stopped = false
  public init(
    checker: any DesktopUpdateChecking,
    changed: @escaping @MainActor (Bool, DesktopUpdateResult?) -> Void
  ) {
    self.checker = checker
    self.changed = changed
  }
  deinit { task?.cancel() }
  public func start() {
    guard !busy, !stopped else { return }
    revision &+= 1
    let expected = revision
    busy = true
    result = nil
    changed(busy, result)
    task = Task { [weak self, checker] in
      let result = await checker.check()
      guard let self, !self.stopped, self.revision == expected else { return }
      self.task = nil
      self.busy = false
      self.result = result
      self.changed(false, result)
    }
  }
  public func cancel() {
    revision &+= 1
    task?.cancel()
    task = nil
    busy = false
    result = nil
    changed(false, nil)
  }
  public func stop() {
    stopped = true
    cancel()
  }
}
