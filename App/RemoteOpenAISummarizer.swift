import ClipboardCore
import Foundation
import PDFKit

/// Build the default `URLSession` used by `RemoteOpenAISummarizer`.
///
/// Configuration choices matter for privacy / hygiene:
/// - `.ephemeral` so cookies, credentials and caches stay in memory
///   only and never touch disk.
/// - `httpAdditionalHeaders = [:]` so we never accidentally inherit
///   App-wide headers (none today, defensive).
/// - cookies fully off — OpenAI-compatible APIs don't use them, and
///   leaving them on risks pinning identity across requests.
/// - `urlCache = nil` so completion bodies never end up cached on disk.
/// - `waitsForConnectivity = false` so a remote summary attempt fails
///   fast when offline rather than parking forever; the caller falls
///   back to local engines.
@Sendable func makeDefaultRemoteAISession(timeout: TimeInterval) -> URLSession {
  let cfg = URLSessionConfiguration.ephemeral
  cfg.httpAdditionalHeaders = [:]
  cfg.httpCookieAcceptPolicy = .never
  cfg.httpShouldSetCookies = false
  cfg.urlCache = nil
  cfg.timeoutIntervalForRequest = timeout
  cfg.waitsForConnectivity = false
  return URLSession(configuration: cfg)
}

/// Remote summarizer that talks to any OpenAI-compatible Chat
/// Completions endpoint (OpenAI, Ollama, vLLM, OpenRouter, DeepSeek,
/// etc.). Used by `SummaryCoordinator` as the first leg of the
/// remote → Foundation Models → NaturalLanguage waterfall when the
/// user has explicitly enabled and configured remote AI.
///
/// Logging hygiene is strict: we never emit URL, request/response
/// body, prompt/completion text, the `Authorization` header, or the
/// API key length. Status code, error class, and byte counts are
/// fair game.
struct RemoteOpenAISummarizer: TextSummarizer, ImageSummarizer, Sendable {
  /// Test seam — a `@Sendable` async closure used in place of
  /// `URLSession.data(for:)` so tests (Core / future App) can stub
  /// HTTP without touching the network. The default closure simply
  /// forwards to `URLSession`.
  typealias Fetcher = @Sendable (URLRequest, URLSession) async throws -> (Data, URLResponse)

  let baseURL: URL
  let keyProvider: @Sendable () -> String?
  let model: String
  let timeout: TimeInterval
  let maxImageBytes: Int
  let session: URLSession
  let fetcher: Fetcher
  let responseLanguageProvider: @Sendable () -> String?

  /// Cap remote summaries the same way `FoundationModelsSummarizer`
  /// caps its output, so the preview pane stays consistent regardless
  /// of which engine produced the string.
  private static let maxSummaryLength = 200

  init(
    baseURL: URL,
    keyProvider: @escaping @Sendable () -> String?,
    model: String,
    timeout: TimeInterval,
    maxImageBytes: Int,
    session: URLSession? = nil,
    fetcher: @escaping Fetcher = { req, sess in try await sess.data(for: req) },
    responseLanguageProvider: @escaping @Sendable () -> String? = { nil }
  ) {
    self.baseURL = baseURL
    self.keyProvider = keyProvider
    self.model = model
    self.timeout = timeout
    self.maxImageBytes = maxImageBytes
    self.session = session ?? makeDefaultRemoteAISession(timeout: timeout)
    self.fetcher = fetcher
    self.responseLanguageProvider = responseLanguageProvider
  }

  // MARK: - TextSummarizer

  nonisolated func summarize(text: String) async -> String? {
    let key = keyProvider()
    let lang = responseLanguageProvider()
    Log.ui.info(
      "summary.remote.text.start chars=\(text.count) hasKey=\(key != nil) lang=\(lang ?? "nil", privacy: .public)"
    )
    let messages = buildRemoteOpenAITextMessages(text, responseLanguage: lang)
    // No `max_tokens` cap on background summarisation. The system prompt
    // already constrains length ("single sentence under 160 characters"),
    // the response body decoder rejects > 64 KiB, and we trim to 200 chars
    // before display. A client-side cap on token *output* is a
    // whack-a-mole game with reasoning models — Qwen3-think / DeepSeek-R1
    // routinely spend 1000+ tokens inside `<think>` before producing the
    // final summary, and any fixed cap (we tried 80 → 400 → 1200 → 4000)
    // gets exhausted by something. Let the model self-terminate at EOS;
    // providers that bill by output token still bill what's actually
    // emitted, not the cap.
    let request = RemoteOpenAIRequest(
      model: model,
      messages: messages,
      temperature: 0.2
    )
    return await dispatch(request: request, key: key, kind: .text)
  }

  // MARK: - ImageSummarizer

  nonisolated func summarize(imageData: Data) async -> String? {
    let key = keyProvider()
    let lang = responseLanguageProvider()
    guard
      let (encoded, mime) = downscaleImageForRemote(
        data: imageData,
        maxBytes: maxImageBytes
      )
    else {
      Log.ui.info("summary.remote.image.skip reason=tooLarge")
      return nil
    }
    Log.ui.info(
      "summary.remote.image.start bytes=\(imageData.count) encoded=\(encoded.count) mime=\(mime, privacy: .public) hasKey=\(key != nil)"
    )
    let messages = buildRemoteOpenAIImageMessages(
      encoded, mime: mime, responseLanguage: lang)
    // No `max_tokens` cap — see comment in `summarize(text:)` above.
    let request = RemoteOpenAIRequest(
      model: model,
      messages: messages,
      temperature: 0.2
    )
    return await dispatch(request: request, key: key, kind: .image)
  }

  // MARK: - File summarisation

  /// Summarise a file referenced by a clip's file-url payload through
  /// the remote endpoint. Used when Foundation Models is unavailable
  /// (e.g. China-region SKU) but the user has Remote AI configured.
  ///
  /// Supported inputs:
  ///   - `.pdf` → PDFKit text extraction.
  ///   - UTF-8 text extensions in the conservative allow-list below
  ///     (loaded via `String(contentsOf:)`).
  ///   - Anything else → nil + `summary.remote.file.unsupported` log.
  ///
  /// `maxBodyBytes` caps the locally-extracted body length AFTER read;
  /// callers pass `prefs.maxClipSizeBytes` so this matches the rest of
  /// the app's size policy. The 16 KiB wire cap inside
  /// `buildRemoteOpenAITextMessages` still applies on top.
  ///
  /// **NEVER logs file path or file content.** Extension and byte
  /// counts are non-sensitive and are logged with `privacy: .public`.
  nonisolated func summarize(
    fileURL url: URL,
    maxBodyBytes: Int = 1 * 1024 * 1024
  ) async -> String? {
    let ext = url.pathExtension.lowercased()
    let body: String?
    if ext == "pdf" {
      body = PDFDocument(url: url)?.string
      if body == nil {
        Log.ui.info("summary.remote.file.pdfDecodeFailed")
      }
    } else if [
      "txt", "md", "markdown", "json", "csv", "xml", "yaml", "yml",
      "swift", "py", "js", "ts", "go", "rs", "sh", "html", "css", "log",
    ].contains(ext) {
      body = (try? String(contentsOf: url, encoding: .utf8))
    } else {
      Log.ui.info("summary.remote.file.unsupported ext=\(ext, privacy: .public)")
      return nil
    }
    guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    if text.utf8.count > maxBodyBytes {
      Log.ui.info(
        "summary.remote.file.tooLarge ext=\(ext, privacy: .public) bytes=\(text.utf8.count) max=\(maxBodyBytes)"
      )
      return nil
    }
    Log.ui.info(
      "summary.remote.file.start ext=\(ext, privacy: .public) chars=\(text.count)"
    )
    return await summarize(text: text)
  }

  // MARK: - Internal

  private enum Kind {
    case text
    case image
  }

  /// Encode + POST + decode. Centralised so the text and image paths
  /// share the same status-code / error-class / log-key handling.
  private func dispatch(
    request: RemoteOpenAIRequest,
    key: String?,
    kind: Kind
  ) async -> String? {
    let endpoint = baseURL.appendingPathComponent("chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // NEVER log this header or its length. Local OpenAI-compatible
    // endpoints (Ollama, vLLM default) accept requests without an
    // Authorization header — only set it when we actually have a key.
    if let k = key, !k.isEmpty {
      urlRequest.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
    }
    do {
      urlRequest.httpBody = try JSONEncoder().encode(request)
    } catch {
      Log.ui.info(
        "summary.remote.error class=\(String(describing: type(of: error)), privacy: .public)"
      )
      return nil
    }

    do {
      try Task.checkCancellation()
      let (data, response) = try await fetcher(urlRequest, session)
      guard let http = response as? HTTPURLResponse else {
        Log.ui.info("summary.remote.http status=-1")
        return nil
      }
      let status = http.statusCode
      guard status == 200 else {
        Log.ui.info("summary.remote.http status=\(status)")
        return nil
      }
      do {
        let content = try decodeRemoteOpenAIResponse(data)
        switch kind {
        case .text:
          Log.ui.info("summary.remote.text.done bytes=\(data.count)")
        case .image:
          Log.ui.info("summary.remote.image.done bytes=\(data.count)")
        }
        return String(content.prefix(Self.maxSummaryLength))
      } catch let decodeErr as RemoteOpenAIDecodeError {
        Log.ui.info(
          "summary.remote.decode err=\(String(describing: decodeErr), privacy: .public) bytes=\(data.count)"
        )
        return nil
      } catch {
        Log.ui.info(
          "summary.remote.error class=\(String(describing: type(of: error)), privacy: .public)"
        )
        return nil
      }
    } catch let urlError as URLError {
      Log.ui.info("summary.remote.network code=\(urlError.code.rawValue)")
      return nil
    } catch is CancellationError {
      // Cancellation is expected (e.g. coordinator tore down). No log.
      return nil
    } catch {
      Log.ui.info(
        "summary.remote.error class=\(String(describing: type(of: error)), privacy: .public)"
      )
      return nil
    }
  }
}
