import CDesktopChrome
import CGtk
import ClipboardCore
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI

/// One scoped provider per display. Selection and theme changes only toggle
/// classes; layout passes never reload a stylesheet or replace an editor.
@MainActor enum DesktopChrome {
  private static var installed = false

  static func apply(to window: Gtk.Window, dark: Bool, language: DesktopUILanguage) {
    if !installed, let display = gtk_widget_get_display(window.widgetPointer),
      let provider = gtk_css_provider_new()
    {
      #if os(Windows)
        let fontRules = """
          .clipboard-desktop { font-family: "Segoe UI", "Microsoft YaHei UI", sans-serif; }
          .clipboard-desktop.clipboard-font-sc { font-family: "Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", sans-serif; }
          .clipboard-desktop.clipboard-font-tc { font-family: "Microsoft JhengHei UI", "Microsoft JhengHei", "Segoe UI", sans-serif; }
          .clipboard-desktop.clipboard-font-jp { font-family: "Yu Gothic UI", "Meiryo UI", "Segoe UI", sans-serif; }
          .clipboard-desktop.clipboard-font-kr { font-family: "Malgun Gothic", "Segoe UI", sans-serif; }
          """
      #else
        let fontRules = """
          .clipboard-desktop { font-family: "Noto Sans", "Noto Sans CJK SC", sans-serif; }
          .clipboard-desktop.clipboard-font-sc { font-family: "Noto Sans CJK SC", sans-serif; }
          .clipboard-desktop.clipboard-font-tc { font-family: "Noto Sans CJK TC", sans-serif; }
          .clipboard-desktop.clipboard-font-jp { font-family: "Noto Sans CJK JP", sans-serif; }
          .clipboard-desktop.clipboard-font-kr { font-family: "Noto Sans CJK KR", sans-serif; }
          """
      #endif
      // The pinned backend maps regular to 500. Use native regular 400 for this
      // application's text; keep OS antialiasing, scaling and fallback intact.
      let css = """
        \(fontRules)
        .clipboard-desktop { font-size: 14px; }
        .clipboard-desktop label, .clipboard-desktop entry, .clipboard-desktop text { font-weight: 400; }
        .clipboard-desktop { background: #eeedeb; color: #242424; }
        .clipboard-desktop.clipboard-dark { background: #262627; color: #f3f3f3; }
        .clipboard-desktop.csd { border-radius: 16px; }
        .clipboard-desktop.csd.maximized, .clipboard-desktop.csd.fullscreen { border-radius: 0; }
        .clipboard-desktop .clipboard-titlebar { min-height: 30px; padding: 0 8px; background: transparent; box-shadow: none; }
        .clipboard-desktop.clipboard-material { background: rgba(238, 237, 235, 0.82); }
        .clipboard-desktop.clipboard-material.clipboard-dark { background: rgba(38, 38, 39, 0.85); }
        .clipboard-desktop .clipboard-preview { background: #f7f6f4; }
        .clipboard-desktop.clipboard-dark .clipboard-preview { background: #2b2b2d; }
        .clipboard-desktop.clipboard-material .clipboard-preview { background: rgba(255, 255, 255, 0.12); }
        .clipboard-desktop.clipboard-material.clipboard-dark .clipboard-preview { background: rgba(255, 255, 255, 0.025); }
        .clipboard-desktop .clipboard-search-surface { border-radius: 12px; background: #fafaf9; box-shadow: 0 1px 2px #00000013; }
        .clipboard-desktop.clipboard-dark .clipboard-search-surface { background: #38383a; }
        .clipboard-desktop entry.clipboard-search:focus-within { outline: none; box-shadow: none; }
        .clipboard-desktop .clipboard-search-surface:focus-within { outline: 2px solid #74adff; }
        .clipboard-desktop .clipboard-more button { background: transparent; box-shadow: none; border: none; padding: 0; }
        .clipboard-desktop .clipboard-more popover button { padding: 6px 12px; border-radius: 5px; }
        .clipboard-desktop .clipboard-more popover button:hover { background: #e5edf6; }
        .clipboard-desktop.clipboard-dark .clipboard-more popover button:hover { background: #334257; }
        .clipboard-desktop entry.clipboard-search { background: transparent; border: none; box-shadow: none; padding: 0; }
        .clipboard-desktop .clipboard-segments { border-radius: 7px; background: #dcdcd9; }
        .clipboard-desktop.clipboard-dark .clipboard-segments { background: #3c3c40; }
        .clipboard-desktop .clipboard-segment { border-radius: 5px; }
        .clipboard-desktop .clipboard-segment.clipboard-selected { background: #fafaf9; color: #242424; box-shadow: 0 1px 3px #00000013; }
        .clipboard-desktop .clipboard-segment.clipboard-selected label { color: #242424; }
        .clipboard-desktop.clipboard-dark .clipboard-segment.clipboard-selected { background: #38383a; color: #f3f3f3; }
        .clipboard-desktop.clipboard-dark .clipboard-segment.clipboard-selected label { color: #f3f3f3; }
        .clipboard-desktop .clipboard-settings-tab.clipboard-selected { background: #e5edf6; color: #087af5; }
        .clipboard-desktop .clipboard-settings-tab.clipboard-selected label { color: #087af5; }
        .clipboard-desktop.clipboard-dark .clipboard-settings-tab.clipboard-selected { background: #334257; color: #69acfa; }
        .clipboard-desktop.clipboard-dark .clipboard-settings-tab.clipboard-selected label { color: #69acfa; }
        .clipboard-desktop .clipboard-toolbar button { border-radius: 7px; }
        .clipboard-desktop .clipboard-filter { border-radius: 6px; }
        .clipboard-desktop .clipboard-preview-badge { border-radius: 12px; background: #e5edf6; color: #087af5; }
        .clipboard-desktop.clipboard-dark .clipboard-preview-badge { background: #334257; color: #69acfa; }
        .clipboard-desktop .clipboard-selected { background: #087af5; color: white; }
        .clipboard-desktop .clipboard-selected label { color: white; }
        .clipboard-desktop .clipboard-history { background: transparent; }
        .clipboard-desktop .clipboard-history row { border-radius: 8px; margin: 1px 0; padding: 0; }
        .clipboard-desktop .clipboard-history row:selected { background: #087af5; }
        .clipboard-desktop .clipboard-history row:selected label,
        .clipboard-desktop .clipboard-history row:selected image,
        .clipboard-desktop .clipboard-history row:selected .clipboard-kind { color: white; }
        .clipboard-desktop .clipboard-secondary, .clipboard-desktop .clipboard-secondary label { color: #686867; }
        .clipboard-desktop.clipboard-dark .clipboard-secondary, .clipboard-desktop.clipboard-dark .clipboard-secondary label { color: #b5b5b5; }
        .clipboard-desktop .clipboard-history row:selected .clipboard-secondary label { color: #ffffffdc; }
        .clipboard-desktop .clipboard-kind { color: #087af5; background: #e5edf6; border-radius: 4px; }
        .clipboard-desktop .clipboard-history row:selected .clipboard-kind { background: #ffffff26; }
        .clipboard-desktop.clipboard-dark .clipboard-kind { color: #69acfa; background: #334257; }
        """
      css.withCString { gtk_css_provider_load_from_data(provider, $0, -1) }
      gtk_style_context_add_provider_for_display(
        display, OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2))
      g_object_unref(provider)
      installed = true
    }
    setClass("clipboard-desktop", on: window, enabled: true)
    let changed = (gtk_widget_has_css_class(window.widgetPointer, "clipboard-dark") != 0) != dark
    setClass("clipboard-dark", on: window, enabled: dark)
    clipboard_window_chrome_install(window.widgetPointer)
    if changed { clipboard_window_chrome_refresh(window.widgetPointer) }
    for (name, matches) in [
      ("sc", language == .simplifiedChinese), ("tc", language == .traditionalChinese),
      ("jp", language == .japanese), ("kr", language == .korean),
    ] {
      setClass("clipboard-font-" + name, on: window, enabled: matches)
    }
  }

  static func setClass(_ name: String, on widget: Gtk.Widget, enabled: Bool = true) {
    let present = gtk_widget_has_css_class(widget.widgetPointer, name) != 0
    guard present != enabled else { return }
    if enabled {
      gtk_widget_add_css_class(widget.widgetPointer, name)
    } else {
      gtk_widget_remove_css_class(widget.widgetPointer, name)
    }
  }

  static func label(_ text: String, on widget: Gtk.Widget, alwaysUpdate: Bool = false) {
    let object = UnsafeMutablePointer<CGtk.GObject>(OpaquePointer(widget.widgetPointer))
    if !alwaysUpdate, let cached = g_object_get_data(object, "clipboard-accessible-label"),
      String(cString: cached.assumingMemoryBound(to: CChar.self)) == text
    {
      return
    }
    g_object_set_data_full(object, "clipboard-accessible-label", g_strdup(text), { g_free($0) })
    var value = GValue()
    _ = g_value_init(&value, g_type_from_name("gchararray"))
    defer { g_value_unset(&value) }
    text.withCString { g_value_set_string(&value, $0) }
    var property = GTK_ACCESSIBLE_PROPERTY_LABEL
    gtk_accessible_update_property_value(OpaquePointer(widget.widgetPointer), 1, &property, &value)
  }
}

/// Small application-owned vectors do not depend on an optional SVG loader or
/// on the host icon theme. GTK supplies the current (including selected) color.
struct DesktopSymbol: GtkWidgetRepresentable {
  let name: String
  var size: Int = 16
  final class Coordinator { var name = "" }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeGtkWidget(context: Context) -> Gtk.DrawingArea {
    let area = Gtk.DrawingArea()
    let pointer = Unmanaged.passRetained(context.coordinator).toOpaque()
    gtk_drawing_area_set_draw_func(
      UnsafeMutablePointer<GtkDrawingArea>(area.opaquePointer),
      { area, cr, width, height, data in
        guard let area, let cr, let data, width > 0, height > 0 else { return }
        let name = Unmanaged<Coordinator>.fromOpaque(data).takeUnretainedValue().name
        let widget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(area))
        var color = GdkRGBA()
        gtk_style_context_get_color(gtk_widget_get_style_context(widget), &color)
        cairo_set_source_rgba(
          cr, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
        cairo_scale(cr, Double(width) / 24, Double(height) / 24)
        cairo_set_line_width(cr, 1.7)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        func path(_ points: [(Double, Double)], closed: Bool = false) {
          guard let first = points.first else { return }
          cairo_move_to(cr, first.0, first.1)
          for point in points.dropFirst() { cairo_line_to(cr, point.0, point.1) }
          if closed { cairo_close_path(cr) }
          cairo_stroke(cr)
        }
        func circle(_ x: Double, _ y: Double, _ radius: Double) {
          cairo_arc(cr, x, y, radius, 0, 2 * Double.pi)
          cairo_stroke(cr)
        }
        switch name {
        case "search":
          circle(10, 10, 6)
          path([(15, 15), (21, 21)])
        case "settings":
          circle(12, 12, 3)
          path(
            [
              (9, 3), (15, 3), (16, 6), (19, 7), (21, 12), (19, 17), (16, 18), (15, 21), (9, 21),
              (8, 18), (5, 17), (3, 12), (5, 7), (8, 6),
            ], closed: true)
        case "filter":
          path([(3, 5), (21, 5)])
          path([(6, 12), (18, 12)])
          path([(9, 19), (15, 19)])
        case "pin":
          path(
            [(8, 3), (16, 3), (15, 10), (19, 14), (19, 16), (5, 16), (5, 14), (9, 10)], closed: true
          )
          path([(12, 16), (12, 22)])
        case "copy":
          path([(8, 8), (20, 8), (20, 21), (8, 21)], closed: true)
          path([(16, 8), (16, 3), (3, 3), (3, 16), (8, 16)])
        case "delete":
          path([(3, 6), (21, 6)])
          path([(9, 6), (9, 3), (15, 3), (15, 6)])
          path([(6, 6), (7, 21), (17, 21), (18, 6)])
          path([(10, 10), (10, 17)])
          path([(14, 10), (14, 17)])
        case "record": circle(12, 12, 7)
        case "pause":
          path([(8, 5), (8, 19)])
          path([(16, 5), (16, 19)])
        case "hide": path([(4, 15), (20, 15)])
        case "back":
          path([(10, 5), (3, 12), (10, 19)])
          path([(3, 12), (21, 12)])
        case "text":
          path([(5, 6), (19, 6)])
          path([(5, 12), (19, 12)])
          path([(5, 18), (14, 18)])
        case "image":
          path([(3, 3), (21, 3), (21, 21), (3, 21)], closed: true)
          circle(8, 8, 2)
          path([(3, 18), (8, 13), (12, 17), (16, 10), (21, 18)])
        case "file", "rich":
          path([(5, 3), (14, 3), (19, 8), (19, 21), (5, 21)], closed: true)
          path([(14, 3), (14, 9), (19, 9)])
          if name == "rich" {
            path([(8, 13), (16, 13)])
            path([(8, 17), (14, 17)])
          }
        case "lock":
          path([(5, 10), (19, 10), (19, 21), (5, 21)], closed: true)
          path([(8, 10), (8, 5), (16, 5), (16, 10)])
          path([(12, 14), (12, 17)])
        case "keyboard":
          path([(2, 5), (22, 5), (22, 19), (2, 19)], closed: true)
          for x in [5.0, 9.0, 13.0, 17.0] {
            path([(x, 9), (x + 1, 9)])
            path([(x, 12), (x + 1, 12)])
          }
          path([(6, 16), (18, 16)])
        case "ai":
          path(
            [
              (12, 3), (14.5, 9.5), (21, 12), (14.5, 14.5), (12, 21), (9.5, 14.5), (3, 12),
              (9.5, 9.5),
            ], closed: true)
        case "data":
          path([(4, 3), (20, 3), (20, 21), (4, 21)], closed: true)
          path([(4, 9), (20, 9)])
          path([(4, 15), (20, 15)])
          circle(16, 6, 0.5)
          circle(16, 12, 0.5)
          circle(16, 18, 0.5)
        default:
          circle(4, 12, 1)
          circle(12, 12, 1)
          circle(20, 12, 1)
        }
      }, pointer, { if let pointer = $0 { Unmanaged<Coordinator>.fromOpaque(pointer).release() } })
    return area
  }
  func updateGtkWidget(_ widget: Gtk.DrawingArea, context: Context) {
    guard context.coordinator.name != name else { return }
    context.coordinator.name = name
    gtk_widget_queue_draw(widget.widgetPointer)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.DrawingArea, context: Context)
    -> ViewSize
  {
    ViewSize(Double(size), Double(size))
  }
}

extension HistoryView {
  func iconButton(
    _ label: String, symbol: String, action: @escaping @MainActor @Sendable () -> Void
  )
    -> some View
  {
    Button(action: action) { DesktopSymbol(name: symbol).frame(width: 30, height: 30) }
      .inspect([.onCreate, .afterUpdate]) { DesktopChrome.label(model.t(label), on: $0) }
      .buttonStyle(.borderless).help(model.t(label))
  }
}
