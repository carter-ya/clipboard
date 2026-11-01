import ClipboardCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One ephemeral session per request. Redirects, cookies and credential/cache
/// persistence are disabled; response bytes are bounded while receiving them.
public struct BoundedDesktopAITransport: DesktopAITransport {
  public init() {}
  public func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> DesktopHTTPResponse
  {
    guard (1...(1024 * 1024)).contains(maxResponseBytes) else {
      throw DesktopServiceError.invalidValue
    }
    let operation = HTTPRequestOperation(limit: maxResponseBytes)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        operation.start(request, continuation: continuation)
      }
    } onCancel: {
      operation.cancel()
    }
  }
}

private final class HTTPRequestOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var bytes = Data()
  private var status = 0
  private var cancelled = false
  private var continuation: CheckedContinuation<DesktopHTTPResponse, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  init(limit: Int) { self.limit = limit }
  func start(_ request: URLRequest, continuation: CheckedContinuation<DesktopHTTPResponse, Error>) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = min(120, max(1, request.timeoutInterval))
    configuration.timeoutIntervalForResource = configuration.timeoutIntervalForRequest
    lock.lock()
    if cancelled {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    lock.unlock()
    task.resume()
  }
  func cancel() {
    lock.withLock { cancelled = true }
    finish(.failure(CancellationError()))
  }
  private func finish(_ result: Result<DesktopHTTPResponse, Error>) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    task = nil
    bytes.removeAll(keepingCapacity: false)
    lock.unlock()
    session?.invalidateAndCancel()
    continuation?.resume(with: result)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(DesktopServiceError.networkFailure))
      return
    }
    guard response.expectedContentLength <= Int64(limit) else {
      completionHandler(.cancel)
      finish(.failure(DesktopServiceError.tooLarge))
      return
    }
    lock.withLock { status = http.statusCode }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let accepted = lock.withLock {
      guard continuation != nil, data.count <= limit - bytes.count else { return false }
      bytes.append(data)
      return true
    }
    if !accepted { finish(.failure(DesktopServiceError.tooLarge)) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if error != nil {
      finish(.failure(DesktopServiceError.networkFailure))
      return
    }
    let response = lock.withLock { DesktopHTTPResponse(data: bytes, status: status) }
    finish(.success(response))
  }
}
