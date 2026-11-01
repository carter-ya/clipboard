import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum DesktopAIConnectionResult: Equatable, Sendable {
  case connected, disabled, invalidConfiguration, credentialsUnavailable
  case authenticationFailed, notFound, rateLimited, requestRejected, serverError
  case redirected, unusableResponse, networkFailure, cancelled
}

/// Explicit diagnostics accept configuration only: no history, payload resolver,
/// OCR service or store can enter this request.
public struct DesktopAIConnectionProbe: Sendable {
  private let credentials: any DesktopCredentialStoring
  private let transport: any DesktopAITransport
  public init(credentials: any DesktopCredentialStoring, transport: any DesktopAITransport) {
    self.credentials = credentials
    self.transport = transport
  }
  public func test(settings: DesktopAISettings) async -> DesktopAIConnectionResult {
    guard settings.enabled else { return .disabled }
    var configuration = settings
    configuration.endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (try? configuration.validate()) != nil,
      let base = validateRemoteAIBaseURL(configuration.endpoint)
    else { return .invalidConfiguration }
    if Task.isCancelled { return .cancelled }
    var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if configuration.usesCredential {
      do {
        guard let key = try await credentials.read(account: configuration.credentialAccount),
          !key.isEmpty
        else { return Task.isCancelled ? .cancelled : .credentialsUnavailable }
        if Task.isCancelled { return .cancelled }
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
      } catch { return Task.isCancelled ? .cancelled : .credentialsUnavailable }
    }
    do {
      try Task.checkCancellation()
      request.httpBody = try JSONEncoder().encode(
        RemoteOpenAIRequest(
          model: configuration.model, messages: buildRemoteOpenAITextMessages("reply OK"),
          maxTokens: 4, temperature: 0))
      let response = try await transport.send(request, maxResponseBytes: 64 * 1024)
      try Task.checkCancellation()
      guard response.data.count <= 64 * 1024 else { return .unusableResponse }
      switch response.status {
      case 200:
        guard let text = try? decodeRemoteOpenAIResponse(response.data),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unusableResponse }
        return .connected
      case 300...399: return .redirected
      case 401, 403: return .authenticationFailed
      case 404: return .notFound
      case 429: return .rateLimited
      case 400...499: return .requestRejected
      case 500...599: return .serverError
      default: return .unusableResponse
      }
    } catch is CancellationError { return .cancelled } catch {
      if Task.isCancelled { return .cancelled }
      return error as? DesktopServiceError == .tooLarge ? .unusableResponse : .networkFailure
    }
  }
}

/// One owned request at a time. Invalidation also protects against dependencies
/// which return successfully after cancellation.
@MainActor public final class DesktopAIConnectionState {
  public private(set) var busy = false
  public private(set) var result: DesktopAIConnectionResult?
  private let run: @Sendable (DesktopAISettings) async -> DesktopAIConnectionResult
  private let changed: @MainActor (Bool, DesktopAIConnectionResult?) -> Void
  private var task: Task<Void, Never>?
  private var revision: UInt64 = 0
  private var stopped = false
  public init(
    run: @escaping @Sendable (DesktopAISettings) async -> DesktopAIConnectionResult,
    changed: @escaping @MainActor (Bool, DesktopAIConnectionResult?) -> Void
  ) {
    self.run = run
    self.changed = changed
  }
  @discardableResult public func start(settings: DesktopAISettings) -> Task<Void, Never>? {
    guard !busy, !stopped else { return nil }
    revision &+= 1
    let expected = revision
    busy = true
    result = nil
    changed(busy, result)
    let run = run
    let operation = Task { [weak self] in
      let outcome = await run(settings)
      guard let self, self.revision == expected, !self.stopped else { return }
      self.task = nil
      self.busy = false
      self.result = outcome
      self.changed(self.busy, self.result)
    }
    task = operation
    return operation
  }
  deinit { task?.cancel() }
  public func invalidate() { clear(result: nil) }
  public func cancel() { if busy { clear(result: .cancelled) } }
  public func stop() {
    stopped = true
    clear(result: nil)
  }
  private func clear(result: DesktopAIConnectionResult?) {
    revision &+= 1
    task?.cancel()
    task = nil
    busy = false
    self.result = result
    changed(busy, result)
  }
}
