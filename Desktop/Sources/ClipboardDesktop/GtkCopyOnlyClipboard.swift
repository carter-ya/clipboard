import CGtk
import ClipboardCore
import Foundation

/// GTK's normal clipboard remains writable on restricted Wayland compositors.
/// It cannot observe other applications, and never advertises capture support.
final class GtkCopyOnlyClipboard: RichClipboardAccess, @unchecked Sendable {
  var canMonitor: Bool { false }
  func revision() -> UInt64 { 0 }
  func read(maxBytes: Int) throws -> RichClipboardSnapshot? {
    throw TextClipboardError.unsupportedSession
  }
  func write(payloads: [RawPayload], sensitive: Bool) throws {
    guard payloads.reduce(0, { $0 + $1.data.count }) <= 16 * 1024 * 1024 else {
      throw TextClipboardError.tooLarge(16 * 1024 * 1024 + 1)
    }
    // GDK must run on the GTK main context. Copy happens away from the UI actor.
    if Thread.isMainThread {
      try MainActor.assumeIsolated { try Self.publish(payloads, sensitive) }
    } else {
      try DispatchQueue.main.sync {
        try MainActor.assumeIsolated { try Self.publish(payloads, sensitive) }
      }
    }
  }
  @MainActor private static func publish(_ payloads: [RawPayload], _ sensitive: Bool) throws {
    guard let display = gdk_display_get_default(),
      let clipboard = gdk_display_get_clipboard(display)
    else {
      throw TextClipboardError.unavailable
    }
    let types = [
      "public.utf8-plain-text": "text/plain;charset=utf-8",
      "public.plain-text": "text/plain;charset=utf-8",
      "public.string": "text/plain;charset=utf-8", "public.html": "text/html",
      "public.rtf": "text/rtf",
      "public.png": "image/png", "public.jpeg": "image/jpeg", "public.tiff": "image/tiff",
      "com.microsoft.bmp": "image/bmp", "public.file-url": "text/uri-list",
    ]
    var providers: [UnsafeMutablePointer<GdkContentProvider>?] = []
    var seen: Set<String> = []
    func append(_ mime: String, _ data: Data) {
      guard seen.insert(mime).inserted else { return }
      data.withUnsafeBytes { bytes in
        guard let value = g_bytes_new(bytes.baseAddress, gsize(bytes.count)) else { return }
        defer { g_bytes_unref(value) }
        if let provider = gdk_content_provider_new_for_bytes(mime, value) {
          providers.append(provider)
        }
      }
    }
    for payload in payloads {
      guard let mime = types[payload.pasteboardType] else { continue }
      append(mime, payload.data)
    }
    if sensitive { append("x-kde-passwordManagerHint", Data("secret".utf8)) }
    guard !providers.isEmpty else { throw TextClipboardError.noTextPayload }
    // new_union takes ownership of all provider references and copies the array.
    guard
      let union = providers.withUnsafeMutableBufferPointer({
        gdk_content_provider_new_union($0.baseAddress, gsize($0.count))
      })
    else {
      for case let provider? in providers { g_object_unref(UnsafeMutableRawPointer(provider)) }
      throw TextClipboardError.unavailable
    }
    defer { g_object_unref(UnsafeMutableRawPointer(union)) }
    guard gdk_clipboard_set_content(clipboard, union) != 0 else {
      throw TextClipboardError.unavailable
    }
  }
}
