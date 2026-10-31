import CGtk
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI

private final class DecodeBounds {
  var rejected = false
}

/// Only a bounded, decoded thumbnail crosses onto the UI actor. Original bytes
/// remain in the Core payload; sensitive images require an explicit active reveal.
/// Decoding stays in memory and never creates a preview file.
final class DesktopPreviewImage: @unchecked Sendable {
  let pixbuf: OpaquePointer
  let peekPixbuf: OpaquePointer
  private init(_ pixbuf: OpaquePointer, peek: OpaquePointer) {
    self.pixbuf = pixbuf
    self.peekPixbuf = peek
  }
  deinit {
    g_object_unref(UnsafeMutableRawPointer(pixbuf))
    g_object_unref(UnsafeMutableRawPointer(peekPixbuf))
  }
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
    // Prepare the hover image off the UI actor too. Its intrinsic dimensions
    // bound the native tooltip instead of relying on a minimum size request.
    let width = gdk_pixbuf_get_width(pixbuf)
    let height = gdk_pixbuf_get_height(pixbuf)
    let scale = min(1.0, 600.0 / Double(max(width, height)))
    guard
      let peek = gdk_pixbuf_scale_simple(
        pixbuf, max(1, Int32(Double(width) * scale)), max(1, Int32(Double(height) * scale)),
        GDK_INTERP_BILINEAR)
    else { return nil }
    _ = g_object_ref(UnsafeMutableRawPointer(pixbuf))
    return DesktopPreviewImage(pixbuf, peek: peek)
  }
}

struct DesktopImagePreview: GtkWidgetRepresentable {
  let image: DesktopPreviewImage
  let accessibilityLabel: String
  func makeGtkWidget(context: Context) -> Gtk.Picture {
    let picture = Gtk.Picture()
    picture.canShrink = true
    picture.keepAspectRatio = true
    // Accept pointer targeting for hover without making the image focusable.
    gtk_widget_set_can_target(picture.widgetPointer, 1)
    gtk_widget_set_has_tooltip(picture.widgetPointer, 1)
    let query:
      @convention(c) (
        UnsafeMutablePointer<GtkWidget>?, Int32, Int32, gboolean, OpaquePointer?,
        UnsafeMutableRawPointer?
      ) -> gboolean = { widget, _, _, _, tooltip, _ in
        guard let widget, let tooltip, gtk_widget_get_mapped(widget) != 0,
          let texture = g_object_get_data(
            UnsafeMutablePointer<CGtk.GObject>(OpaquePointer(widget)), "clipboard-image-peek"),
          let preview = gtk_picture_new_for_paintable(OpaquePointer(texture))
        else { return 0 }
        let pointer = OpaquePointer(preview)
        gtk_picture_set_can_shrink(pointer, 1)
        gtk_picture_set_keep_aspect_ratio(pointer, 1)
        gtk_picture_set_alternative_text(
          pointer, gtk_picture_get_alternative_text(OpaquePointer(widget)))
        // GTK owns the floating child and closes its tooltip when the anchor
        // is unmapped/destroyed. No timer, extra window owner or payload file.
        gtk_tooltip_set_custom(tooltip, preview)
        return 1
      }
    g_signal_connect_data(
      picture.widgetPointer, "query-tooltip", unsafeBitCast(query, to: GCallback.self), nil, nil,
      GConnectFlags(rawValue: 0))
    return picture
  }
  func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Picture, context: Context)
    -> ViewSize
  {
    let width = Double(gdk_pixbuf_get_width(image.pixbuf))
    let height = Double(gdk_pixbuf_get_height(image.pixbuf))
    let scale = min(
      1, max(0, proposal.width ?? width) / width,
      max(0, proposal.height ?? height) / height)
    return ViewSize(width * scale, height * scale)
  }
  func updateGtkWidget(_ widget: Gtk.Picture, context: Context) {
    widget.alternativeText = accessibilityLabel
    let peekTexture = gdk_texture_new_for_pixbuf(image.peekPixbuf)
    g_object_set_data_full(
      UnsafeMutablePointer<CGtk.GObject>(OpaquePointer(widget.widgetPointer)),
      "clipboard-image-peek",
      peekTexture.map { UnsafeMutableRawPointer($0) },
      { pointer in if let pointer { g_object_unref(pointer) } })
    if let texture = gdk_texture_new_for_pixbuf(image.pixbuf) {
      widget.setPaintable(texture)
      g_object_unref(UnsafeMutableRawPointer(texture))
    }
    // Refresh an open tooltip if this surviving widget receives another image.
    gtk_widget_trigger_tooltip_query(widget.widgetPointer)
  }
}
