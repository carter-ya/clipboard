import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum DesktopServiceError: Error, Equatable {
  case unavailable, locked, invalidValue, tooLarge, cancelled, networkFailure, disabled,
    sensitiveContent, startupConflict
}

public protocol DesktopCredentialStoring: Sendable {
  func read(account: String) async throws -> String?
  func save(_ value: String, account: String) async throws
  func delete(account: String) async throws
}
public actor InMemoryDesktopCredentials: DesktopCredentialStoring {
  private var values: [String: String] = [:]
  public init() {}
  public func read(account: String) -> String? { values[account] }
  public func save(_ value: String, account: String) { values[account] = value }
  public func delete(account: String) { values.removeValue(forKey: account) }
}

public protocol DesktopStartupControlling: Sendable {
  func isEnabled() async throws -> Bool
  func setEnabled(_ enabled: Bool) async throws
}
public actor FakeDesktopStartup: DesktopStartupControlling {
  private var enabled = false
  public init() {}
  public func isEnabled() -> Bool { enabled }
  public func setEnabled(_ enabled: Bool) { self.enabled = enabled }
}

public protocol DesktopOCRRecognizing: Sendable {
  func recognize(_ image: Data, language: String?) async throws -> String
}
public actor FakeDesktopOCR: DesktopOCRRecognizing {
  public private(set) var calls = 0
  private let result: String
  public init(result: String = "Synthetic OCR fixture") { self.result = result }
  public func recognize(_ image: Data, language: String?) -> String {
    calls += 1
    return result
  }
}

public struct DesktopAISettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var allowImages = false
  public var allowText = true
  public var usesCredential = false
  public var endpoint = "https://api.openai.com/v1"
  public var model = ""
  public var timeoutSeconds = 60
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case enabled, allowImages, allowText, usesCredential, endpoint, model, timeoutSeconds
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Existing complete configurations keep their opt-ins and gain the prior
    // text behavior. Malformed/missing existing fields still fail closed.
    enabled = try values.decode(Bool.self, forKey: .enabled)
    allowImages = try values.decode(Bool.self, forKey: .allowImages)
    allowText = values.contains(.allowText) ? try values.decode(Bool.self, forKey: .allowText) : true
    usesCredential = try values.decode(Bool.self, forKey: .usesCredential)
    endpoint = try values.decode(String.self, forKey: .endpoint)
    model = try values.decode(String.self, forKey: .model)
    timeoutSeconds = try values.decode(Int.self, forKey: .timeoutSeconds)
  }
  public func allowsSummary(of kind: ClipKind) -> Bool {
    guard enabled else { return false }
    switch kind {
    case .image: return allowImages
    case .text, .rtf, .mixed: return allowText
    case .file: return false
    }
  }
  public func validate() throws {
    guard let url = validateRemoteAIBaseURL(endpoint),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil,
      (1...120).contains(timeoutSeconds), model.utf8.count <= 200
    else { throw DesktopServiceError.invalidValue }
    // Cleartext is useful for explicitly configured local model servers only.
    if components.scheme == "http",
      !["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host ?? "")
    {
      throw DesktopServiceError.invalidValue
    }
    if enabled && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw DesktopServiceError.invalidValue
    }
  }
  public var credentialAccount: String {
    DesktopProfileIdentity.namespace(
      for: validateRemoteAIBaseURL(endpoint)?.absoluteString
        ?? endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public struct DesktopHTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public init(data: Data, status: Int) {
    self.data = data
    self.status = status
  }
}
public protocol DesktopAITransport: Sendable {
  func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> DesktopHTTPResponse
}
public actor FakeDesktopAITransport: DesktopAITransport {
  public private(set) var requests: [URLRequest] = []
  private let response: DesktopHTTPResponse
  public init(
    response: DesktopHTTPResponse = .init(
      data: Data("{\"choices\":[{\"message\":{\"content\":\"Fixture summary\"}}]}".utf8),
      status: 200)
  ) { self.response = response }
  public func send(_ request: URLRequest, maxResponseBytes: Int) throws -> DesktopHTTPResponse {
    requests.append(request)
    guard response.data.count <= maxResponseBytes else { throw DesktopServiceError.tooLarge }
    return response
  }
}

/// A second privacy gate next to native hints and the store's memory-only rule.
/// No payload resolution, credential lookup or request happens for sensitive clips.
public struct DesktopAnalysis: Sendable {
  private let credentials: any DesktopCredentialStoring
  private let transport: any DesktopAITransport
  private let ocr: any DesktopOCRRecognizing
  private let resolver: PayloadResolver
  public init(
    credentials: any DesktopCredentialStoring, transport: any DesktopAITransport,
    ocr: any DesktopOCRRecognizing, blobRoot: URL?
  ) {
    self.credentials = credentials
    self.transport = transport
    self.ocr = ocr
    resolver = .init(blobRoot: blobRoot)
  }
  private func allow(_ item: ClipItem) throws {
    guard !item.sensitive,
      !item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType })
    else { throw DesktopServiceError.sensitiveContent }
  }
  public func recognize(_ item: ClipItem, language: String? = nil) async throws -> String {
    try allow(item)
    guard
      let payload = item.payloads.first(where: {
        ClipKind.imagePayloadTypes.contains($0.pasteboardType)
      })
    else { throw DesktopServiceError.invalidValue }
    let resolver = resolver
    let data = try await Task.detached { try resolver.data(for: payload) }.value
    guard data.count <= 16 * 1024 * 1024 else { throw DesktopServiceError.tooLarge }
    return String(try await ocr.recognize(data, language: language).prefix(8000))
  }
  public func summarize(_ item: ClipItem, settings: DesktopAISettings, language: String? = nil)
    async throws -> String
  {
    try allow(item)
    guard settings.allowsSummary(of: item.kind) else { throw DesktopServiceError.disabled }
    try settings.validate()
    try Task.checkCancellation()
    guard let base = validateRemoteAIBaseURL(settings.endpoint) else {
      throw DesktopServiceError.invalidValue
    }
    let messages: [RemoteOpenAIMessage]
    let resolver = resolver
    if item.kind == .image {
      guard settings.allowImages,
        let payload = item.payloads.first(where: {
          ["public.png", "public.jpeg"].contains($0.pasteboardType)
        })
      else { throw DesktopServiceError.disabled }
      let data = try await Task.detached { try resolver.data(for: payload) }.value
      guard data.count <= 2 * 1024 * 1024 else { throw DesktopServiceError.tooLarge }
      messages = buildRemoteOpenAIImageMessages(
        data, mime: payload.pasteboardType == "public.png" ? "image/png" : "image/jpeg",
        responseLanguage: language)
    } else if item.kind == .file {
      // File contents require a separate explicit user selection; clipboard paths
      // alone must never cause arbitrary files to leave the device.
      throw DesktopServiceError.disabled
    } else {
      let payloads = try await Task.detached {
        try item.payloads.filter {
          [
            "public.utf8-plain-text", "public.plain-text", "public.string", "public.html",
            "public.rtf",
          ].contains($0.pasteboardType)
        }.map { RawPayload(pasteboardType: $0.pasteboardType, data: try resolver.data(for: $0)) }
      }.value
      let text = RichTextPreview.text(from: payloads, limit: 16000)
      guard !text.isEmpty else { throw DesktopServiceError.invalidValue }
      messages = buildRemoteOpenAITextMessages(text, responseLanguage: language)
    }
    var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.timeoutInterval = TimeInterval(settings.timeoutSeconds)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if settings.usesCredential {
      guard let key = try await credentials.read(account: settings.credentialAccount), !key.isEmpty
      else { throw DesktopServiceError.unavailable }
      request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(
      RemoteOpenAIRequest(model: settings.model, messages: messages, temperature: 0.2))
    let response = try await transport.send(request, maxResponseBytes: 64 * 1024)
    guard response.status == 200 else { throw DesktopServiceError.networkFailure }
    return String(try decodeRemoteOpenAIResponse(response.data).prefix(200))
  }
}
