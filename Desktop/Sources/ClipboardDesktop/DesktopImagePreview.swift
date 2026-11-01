import CGtk
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI

private final class DecodeBounds {
  var rejected = false
}

/// Only a bounded, decoded thumbnail crosses onto the UI actor. Original bytes
/// remain in the Core payload; sensitive images are never passed to this loader.
final class DesktopPreviewImage: @unchecked Sendable {
  let pixbuf: OpaquePointer
  private init(_ pixbuf: OpaquePointer) { self.pixbuf = pixbuf }
  deinit { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
  static func decode(_ data: Data) -> DesktopPreviewImage? {
    guard data.count <= 16 * 1024 * 1024, let loader = gdk_pixbuf_loader_new() else { return nil }
    defer { g_object_unref(loader) }
    let bounds = DecodeBounds()
    let context = Unmanaged.passUnretained(bounds).toOpaque()
    let callback:
      @convention(c) (
        UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, UnsafeMutableRawPointer?
      ) -> Void = { loader, width, height, context in
        guard let loader, let context else { return }
        let bounds = Unmanaged<DecodeBounds>.fromOpaque(context).takeUnretainedValue()
        guard width > 0, height > 0, width <= 32768, height <= 32768,
          Int64(width) * Int64(height) <= 80_000_000
        else {
          bounds.rejected = true
          gdk_pixbuf_loader_set_size(loader, 1, 1)
          return
        }
        let scale = min(1.0, 1280.0 / Double(max(width, height)))
        gdk_pixbuf_loader_set_size(
          loader, max(1, Int32(Double(width) * scale)), max(1, Int32(Double(height) * scale)))
      }
    let signal = g_signal_connect_data(
      loader, "size-prepared", unsafeBitCast(callback, to: GCallback.self), context, nil,
      GConnectFlags(rawValue: 0))
    defer { g_signal_handler_disconnect(loader, signal) }
    var error: UnsafeMutablePointer<GError>?
    defer { if let error { g_error_free(error) } }
    let written = data.withUnsafeBytes { bytes in
      gdk_pixbuf_loader_write(
        loader, bytes.bindMemory(to: UInt8.self).baseAddress, gsize(bytes.count), &error)
    }
    guard written != 0 else { return nil }
    guard gdk_pixbuf_loader_close(loader, &error) != 0, !bounds.rejected,
      let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader)
    else { return nil }
    _ = g_object_ref(UnsafeMutableRawPointer(pixbuf))
    return DesktopPreviewImage(pixbuf)
  }
}

struct DesktopImagePreview: GtkWidgetRepresentable {
  let image: DesktopPreviewImage
  func makeGtkWidget(context: Context) -> Gtk.Picture {
    let picture = Gtk.Picture()
    picture.canShrink = true
    picture.keepAspectRatio = true
    return picture
  }
  func updateGtkWidget(_ widget: Gtk.Picture, context: Context) {
    if let texture = gdk_texture_new_for_pixbuf(image.pixbuf) {
      widget.setPaintable(texture)
      g_object_unref(UnsafeMutableRawPointer(texture))
    }
  }
}
