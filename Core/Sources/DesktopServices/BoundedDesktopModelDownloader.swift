import ClipboardCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Anonymous streaming transfer of an explicitly selected bundled model.
/// Large responses never accumulate in memory or bypass the exact byte limit.
public struct BoundedDesktopModelDownloader: DesktopModelAssetDownloading, @unchecked Sendable {
  private let testConfiguration: URLSessionConfiguration?
  public init() { testConfiguration = nil }
  init(configuration: URLSessionConfiguration) {
    testConfiguration = configuration.copy() as? URLSessionConfiguration
  }
  public func download(
    _ asset: DesktopModelAsset, to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard ModelDownloadOperation.allowed(asset.url), asset.url.host == "huggingface.co",
      asset.size > 0, asset.size <= 8 * 1024 * 1024 * 1024
    else {
      throw DesktopModelAssetError.invalidLocation
    }
    let operation = ModelDownloadOperation(
      asset: asset, destination: destination, progress: progress)
    let configuration = (testConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpAdditionalHeaders = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 3600
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        operation.start(configuration: configuration, continuation: continuation)
      }
    } onCancel: {
      operation.cancel()
    }
  }
}

final class ModelDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let asset: DesktopModelAsset
  private let destination: URL
  private let progress: @Sendable (Int64) -> Void
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var file: FileHandle?
  private var cancelled = false
  private var failure: DesktopModelAssetError?
  private var accepted = false
  private var received: Int64 = 0
  private var reported: Int64 = 0
  private var reportTime = Date.distantPast
  private var redirects = 0

  init(asset: DesktopModelAsset, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
    self.asset = asset
    self.destination = destination
    self.progress = progress
  }
  static func allowed(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", parts.user == nil, parts.password == nil,
      parts.fragment == nil, parts.port == nil || parts.port == 443,
      let host = parts.host?.lowercased()
    else { return false }
    return host == "huggingface.co" || host == "hf.co" || host.hasSuffix(".hf.co")
  }
  private static func request(_ url: URL) -> URLRequest {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
  }
  func start(configuration: URLSessionConfiguration, continuation: CheckedContinuation<Void, Error>)
  {
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    do {
      guard destination.isFileURL, [nil, "", "localhost"].contains(destination.host),
        !destination.path.contains("\0"),
        let parts = URLComponents(url: destination, resolvingAgainstBaseURL: false),
        parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil
      else {
        throw DesktopModelAssetError.invalidLocation
      }
      let values = try FileManager.default.attributesOfItem(atPath: destination.path)
      guard values[.type] as? FileAttributeType == .typeRegular,
        (values[.size] as? NSNumber)?.int64Value == 0
      else {
        throw DesktopModelAssetError.invalidLocation
      }
      file = try FileHandle(forWritingTo: destination)
    } catch {
      lock.unlock()
      continuation.resume(throwing: (error as? DesktopModelAssetError) ?? .unavailable)
      return
    }
    self.continuation = continuation
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    let task = session.dataTask(with: Self.request(asset.url))
    self.task = task
    lock.unlock()
    task.resume()
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let task = task
    lock.unlock()
    // Completion runs on the serial delegate queue after any current write,
    // closes the stream, then resumes the caller. Never race close with write.
    task?.cancel()
  }
  private func fail(_ value: DesktopModelAssetError) {
    lock.lock()
    if failure == nil { failure = value }
    let task = task
    lock.unlock()
    task?.cancel()
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, let url = http.url, Self.allowed(url),
      http.statusCode == 200,
      http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" })
        ?? true
    else {
      fail(.invalidResponse)
      completionHandler(.cancel)
      return
    }
    if let length = http.value(forHTTPHeaderField: "Content-Length"), Int64(length) != asset.size {
      fail(.wrongSize)
      completionHandler(.cancel)
      return
    }
    lock.lock()
    accepted = !cancelled && failure == nil
    let allow = accepted
    lock.unlock()
    completionHandler(allow ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard continuation != nil, !cancelled, failure == nil else {
      lock.unlock()
      return
    }
    guard accepted, Int64(data.count) <= asset.size - received, let file else {
      lock.unlock()
      fail(.wrongSize)
      return
    }
    do { try file.write(contentsOf: data) } catch {
      lock.unlock()
      fail(.unavailable)
      return
    }
    received += Int64(data.count)
    let now = Date()
    let report =
      received == asset.size || received - reported >= 1024 * 1024
      || now.timeIntervalSince(reportTime) >= 0.25
    let count = received
    if report {
      reportTime = now
      reported = received
    }
    lock.unlock()
    if report { progress(count) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.lock()
    redirects += 1
    let active = !cancelled && failure == nil && redirects <= 8
    lock.unlock()
    guard active, let url = request.url, Self.allowed(url) else {
      fail(.invalidResponse)
      completionHandler(nil)
      return
    }
    // Strip inherited headers and credentials on every redirect, including a
    // redirect within the publisher's allowed CDN hosts.
    completionHandler(Self.request(url))
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // corelibs Foundation does not expose the server-trust constant, but its
    // protocol identifier is shared with Darwin. TLS validation stays native.
    if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
      completionHandler(.performDefaultHandling, nil)
    } else {
      fail(.invalidResponse)
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    var result: Result<Void, Error>
    if cancelled {
      result = .failure(CancellationError())
    } else if let failure {
      result = .failure(failure)
    } else if error != nil || !accepted {
      result = .failure(DesktopModelAssetError.invalidResponse)
    } else if received != asset.size {
      result = .failure(DesktopModelAssetError.wrongSize)
    } else {
      result = .success(())
    }
    if !cancelled && failure == nil && error == nil {
      do { try file?.synchronize() } catch { result = .failure(DesktopModelAssetError.unavailable) }
    }
    do { try file?.close() } catch {
      if !cancelled { result = .failure(DesktopModelAssetError.unavailable) }
    }
    file = nil
    self.task = nil
    self.session = nil
    lock.unlock()
    session.invalidateAndCancel()
    continuation?.resume(with: result)
  }
}
