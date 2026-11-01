#if os(Linux) || os(Windows)
  import CDesktopClipboard
  import ClipboardCore
  import Foundation

  /// Text-only platform experiment. X11 ownership is served by a socket read
  /// source, including while capture is paused. It does not launch xclip or
  /// synthesize keyboard input. Callers must keep this object alive to own X11 data.
  public final class SystemTextClipboard: TextClipboardAccess, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clipboard.native.text")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let session: OpaquePointer
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
          cb_pump(self.session)
        }
        self.source = source
        source.resume()
      }
    }

    public func revision() -> UInt64 { sync { cb_revision(session) } }

    public func read(maxBytes: Int) throws -> TextClipboardSnapshot? {
      guard maxBytes > 0, maxBytes <= 16 * 1024 * 1024 else {
        throw TextClipboardError.invalidText
      }
      return try sync {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        var sensitive: Int32 = 0
        var revision: UInt64 = 0
        let result = cb_read_utf8(session, maxBytes, &pointer, &length, &sensitive, &revision)
        defer { if let pointer { cb_free(pointer) } }
        if result == CB_EMPTY { return nil }
        try checked(result, bytes: length)
        guard let pointer,
          let text = String(data: Data(bytes: pointer, count: length), encoding: .utf8)
        else { throw TextClipboardError.invalidText }
        #if os(Windows)
          let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        #else
          let normalized = text
        #endif
        return TextClipboardSnapshot(
          text: normalized, sensitive: sensitive != 0, revision: revision)
      }
    }

    public func write(text: String, sensitive: Bool = false) throws {
      guard !text.contains("\0"), text.utf8.count <= 16 * 1024 * 1024 else {
        throw TextClipboardError.invalidText
      }
      #if os(Windows)
        // CF_UNICODETEXT requires CRLF; Core text uses LF on readback.
        let nativeText = text.replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\n", with: "\r\n")
      #else
        let nativeText = text
      #endif
      guard nativeText.utf8.count <= 16 * 1024 * 1024 else {
        throw TextClipboardError.tooLarge(nativeText.utf8.count)
      }
      try sync {
        try nativeText.utf8CString.withUnsafeBufferPointer { buffer in
          try checked(
            cb_write_utf8(session, buffer.baseAddress, buffer.count - 1, sensitive ? 1 : 0),
            bytes: buffer.count - 1)
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
