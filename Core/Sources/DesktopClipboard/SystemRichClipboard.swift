#if os(Linux) || os(Windows)
  import CDesktopClipboard
  import ClipboardCore
  import Foundation

  /// Native rich clipboard adapter. X11 ownership is served by a socket read
  /// source, including while capture is paused. It does not launch xclip or
  /// synthesize keyboard input. Callers must keep this object alive to own X11 data.
  public final class SystemRichClipboard: RichClipboardAccess, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clipboard.native.rich")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let session: OpaquePointer
    private var transferTimer: DispatchSourceTimer?
    private var source: DispatchSourceRead?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
      #if os(Linux)
        guard environment["WAYLAND_DISPLAY"] == nil else {
          throw TextClipboardError.unsupportedSession
        }
        guard let display = environment["DISPLAY"], !display.isEmpty else {
          throw TextClipboardError.unavailable
        }
      #endif
      guard let session = cb_open() else { throw TextClipboardError.unavailable }
      self.session = session
      queue.setSpecific(key: queueKey, value: true)
      let fd = cb_connection_fd(session)
      if fd >= 0 {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
          guard let self else { return }
          self.pump()
        }
        self.source = source
        source.resume()
      }
    }

    private func pump() {
      cb_pump(session)
      if cb_pending_transfers(session) != 0 && transferTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pump() }
        transferTimer = timer
        timer.resume()
      } else if cb_pending_transfers(session) == 0 {
        transferTimer?.cancel()
        transferTimer = nil
      }
    }

    public func revision() -> UInt64 { sync { cb_revision(session) } }

    public func read(maxBytes: Int) throws -> RichClipboardSnapshot? {
      guard maxBytes > 0, maxBytes <= 16 * 1024 * 1024 else { throw TextClipboardError.invalidText }
      return try sync {
        var pointer: UnsafeMutablePointer<cb_bundle>?
        let result = cb_read_bundle(session, maxBytes, &pointer)
        defer { if let pointer { cb_bundle_free(pointer) } }
        if result == CB_EMPTY { return nil }
        try checked(result, bytes: maxBytes + 1)
        guard let pointer else { throw TextClipboardError.unavailable }
        let bundle = pointer.pointee
        var payloads: [RawPayload] = []
        for native in UnsafeBufferPointer(start: bundle.payloads, count: bundle.count) {
          guard let type = Self.types[native.format], let bytes = native.data else { continue }
          var data = Data(bytes: bytes, count: native.length)
          #if os(Windows)
            if native.format == CB_TEXT {
              guard let text = String(data: data, encoding: .utf8) else {
                throw TextClipboardError.invalidText
              }
              data = Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
            } else if native.format == CB_HTML {
              data = try ClipboardFormats.htmlFromWindows(data)
            } else if native.format == CB_FILES {
              let paths = data.split(separator: 0)
              let urls = try paths.map { path in
                guard let value = String(data: Data(path), encoding: .utf8) else {
                  throw TextClipboardError.invalidText
                }
                return URL(fileURLWithPath: value)
              }
              data = ClipboardFormats.fileURLData(urls)
            }
          #endif
          if native.format == CB_FILES {
            data = ClipboardFormats.fileURLData(try ClipboardFormats.fileURLs(from: data))
          }
          payloads.append(.init(pasteboardType: type, data: data))
        }
        #if os(Windows)
          let source = bundle.source_app.map { String(cString: $0).lowercased() }
        #else
          let source = bundle.source_app.map { String(cString: $0) }
        #endif
        return .init(
          payloads: payloads, sourceAppID: source, sensitive: bundle.sensitive != 0,
          revision: bundle.revision)
      }
    }
    private static let types: [Int32: String] = [
      1: "public.utf8-plain-text", 2: "public.html", 3: "public.rtf", 4: "public.png",
      5: "public.jpeg", 6: "com.microsoft.bmp", 7: "public.file-url", 8: "public.tiff",
    ]
    public func write(payloads: [RawPayload], sensitive: Bool = false) throws {
      var values: [(Int32, Data)] = []
      var total = 0
      for payload in payloads {
        let type =
          ["public.plain-text", "public.string"].contains(payload.pasteboardType)
          ? "public.utf8-plain-text" : payload.pasteboardType
        guard let format = Self.types.first(where: { $0.value == type })?.key else { continue }
        guard !values.contains(where: { $0.0 == format }) else { continue }
        var data = payload.data
        if format == CB_TEXT {
          guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw TextClipboardError.invalidText
          }
          #if os(Windows)
            data = Data(
              text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
                of: "\n", with: "\r\n"
              ).utf8)
          #endif
        } else if format == CB_FILES {
          let urls = try ClipboardFormats.fileURLs(from: data)
          guard !urls.isEmpty else { throw TextClipboardError.invalidText }
          #if os(Windows)
            data = Data(urls.map(\.path).joined(separator: "\0").utf8)
            data.append(0)
          #else
            data = ClipboardFormats.fileURLData(urls)
          #endif
        } else if format == CB_HTML {
          #if os(Windows)
            data = try ClipboardFormats.windowsHTML(data)
          #endif
        }
        total += data.count
        guard total <= 16 * 1024 * 1024 else { throw TextClipboardError.tooLarge(total) }
        values.append((format, data))
      }
      guard !values.isEmpty else { throw TextClipboardError.noTextPayload }
      let native = values.map { format, data -> cb_payload in
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
        data.copyBytes(to: pointer, count: data.count)
        return cb_payload(format: format, data: pointer, length: data.count)
      }
      defer { for payload in native { payload.data?.deallocate() } }
      try sync {
        try native.withUnsafeBufferPointer { buffer in
          try checked(
            cb_write_bundle(session, buffer.baseAddress, buffer.count, sensitive ? 1 : 0),
            bytes: total)
        }
      }
    }

    private func checked(_ result: Int32, bytes: Int) throws {
      switch Int(result) {
      case CB_OK: return
      case CB_TOO_LARGE: throw TextClipboardError.tooLarge(bytes)
      case CB_TIMEOUT: throw TextClipboardError.timeout
      case CB_INVALID: throw TextClipboardError.invalidText
      case CB_UNSUPPORTED: throw TextClipboardError.unsupportedSession
      default: throw TextClipboardError.unavailable
      }
    }

    private func sync<T>(_ operation: () throws -> T) rethrows -> T {
      if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
      return try queue.sync(execute: operation)
    }

    deinit {
      transferTimer?.cancel()
      source?.cancel()
      let session = session
      if DispatchQueue.getSpecific(key: queueKey) != nil {
        cb_close(session)
      } else {
        queue.sync { cb_close(session) }
      }
    }
  }
#endif
