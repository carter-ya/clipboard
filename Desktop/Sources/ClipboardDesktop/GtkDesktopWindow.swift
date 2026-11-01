import CGtk
import ClipboardCore
import Foundation
import Gtk

private final class GtkActionBox: @unchecked Sendable {
  let immediate: Bool
  let action: @MainActor @Sendable () -> Void
  init(immediate: Bool = false, _ action: @escaping @MainActor @Sendable () -> Void) {
    self.immediate = immediate
    self.action = action
  }
}

/// Native presentation/focus owner. Hidden widgets retain editor drafts without
/// a focus timer, and every native signal is disconnected during explicit quit.
@MainActor final class GtkDesktopWindow: DesktopWindowControlling {
  private weak var window: Gtk.Window?
  private weak var search: Gtk.Entry?
  private var application: UnsafeMutablePointer<GApplication>?
  private var signals: [(UnsafeMutableRawPointer, gulong)] = []
  private var focusRequested = false
  private var lastMappedWidth: Double?
  private var lastMappedHeight: Double?
  var activationToken: String?
  var activationTimestamp: UInt32 = 0
  var closeRequested: (@MainActor () -> Void)?
  var reopenRequested: (@MainActor () -> Void)?
  var hidden: (@MainActor () -> Void)?
  var presentationChanged: (@MainActor () -> Void)?

  var isVisible: Bool {
    guard let window else { return false }
    return gtk_widget_get_visible(window.widgetPointer) != 0
  }

  /// GeometryReader also evaluates measurement proposals while GTK is hidden.
  /// Responsive branches must follow the allocated native viewport, not those
  /// temporary proposals, or live controls are removed and recreated.
  func responsiveWidth(fallback: Double) -> Double {
    if let window, gtk_widget_get_mapped(window.widgetPointer) != 0 {
      let width = gtk_widget_get_width(window.widgetPointer)
      if width > 0 { lastMappedWidth = Double(width) }
    }
    return lastMappedWidth ?? fallback
  }

  func responsiveHeight(fallback: Double) -> Double {
    if let window, gtk_widget_get_mapped(window.widgetPointer) != 0 {
      let height = gtk_widget_get_height(window.widgetPointer)
      if height > 0 { lastMappedHeight = Double(height) }
    }
    return lastMappedHeight ?? fallback
  }

  func attach(_ native: Gtk.Window) {
    guard window !== native else { return }
    lastMappedWidth = nil
    lastMappedHeight = nil
    window = native
    let pointer = UnsafeMutablePointer<GtkWindow>(OpaquePointer(native.widgetPointer))
    gtk_window_set_hide_on_close(pointer, 1)
    if let app = gtk_window_get_application(pointer) {
      let gapp = UnsafeMutablePointer<GApplication>(OpaquePointer(app))
      application = gapp
      g_application_hold(gapp)
      connect(UnsafeMutableRawPointer(gapp), signal: "activate") { [weak self] in
        self?.reopenRequested?()
      }
    }
    connect(UnsafeMutableRawPointer(native.widgetPointer), signal: "map") { [weak self] in
      guard let self else { return }
      if self.focusRequested { self.focusSearch() }
      self.presentationChanged?()
    }
    observeActivation(native)
    // Revoke sensitive previews synchronously before a hidden window can be restored.
    connect(UnsafeMutableRawPointer(native.widgetPointer), signal: "unmap", immediate: true) {
      [weak self] in self?.hidden?()
    }
    // Install after SwiftCrossUI has attached its scene close handler.
    Task { @MainActor [weak self, weak native] in
      guard let self, let native else { return }
      native.onCloseRequest = { [weak self] _ in
        Task { @MainActor in self?.closeRequested?() }
      }
    }
  }

  private func observeActivation(_ native: Gtk.Window) {
    let context = Unmanaged.passRetained(
      GtkActionBox { [weak self] in
        guard let self, let window = self.window, self.isVisible,
          gtk_window_is_active(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window.widgetPointer)))
            != 0
        else { return }
        self.presentationChanged?()
      }
    ).toOpaque()
    let callback:
      @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void =
        {
          _, _, context in
          guard let context else { return }
          let box = Unmanaged<GtkActionBox>.fromOpaque(context).takeUnretainedValue()
          Task { @MainActor in box.action() }
        }
    let object = UnsafeMutableRawPointer(native.widgetPointer)
    let id = g_signal_connect_data(
      object, "notify::is-active", unsafeBitCast(callback, to: GCallback.self), context,
      { context, _ in if let context { Unmanaged<GtkActionBox>.fromOpaque(context).release() } },
      GConnectFlags(rawValue: 0))
    signals.append((object, id))
  }

  func observeAppearance(_ action: @escaping @MainActor @Sendable (String) -> Void) {
    guard let settings = gtk_settings_get_default() else { return }
    let object = UnsafeMutableRawPointer(settings)
    for name in ["notify::gtk-application-prefer-dark-theme", "notify::gtk-theme-name"] {
      let context = Unmanaged.passRetained(GtkActionBox { action(name) }).toOpaque()
      let callback:
        @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void =
          { _, _, context in
            guard let context else { return }
            // GtkSettings notifications run synchronously on the GTK main context.
            // Preserve that ordering to distinguish our override from system changes.
            MainActor.assumeIsolated {
              guard !DesktopAppearance.applying else { return }
              Unmanaged<GtkActionBox>.fromOpaque(context).takeUnretainedValue().action()
            }
          }
      let id = g_signal_connect_data(
        object, name, unsafeBitCast(callback, to: GCallback.self), context,
        { context, _ in if let context { Unmanaged<GtkActionBox>.fromOpaque(context).release() } },
        GConnectFlags(rawValue: 0))
      signals.append((object, id))
    }
  }

  func attachSearch(_ entry: Gtk.Entry) {
    search = entry
    if focusRequested { focusSearch() }
  }
  func present() {
    guard let window else { return }
    let pointer = UnsafeMutablePointer<GtkWindow>(OpaquePointer(window.widgetPointer))
    if let token = activationToken {
      gtk_window_set_startup_id(pointer, token)
      activationToken = nil
    }
    gtk_window_present_with_time(pointer, activationTimestamp)
  }
  func hide() {
    focusRequested = false
    window?.hide()
  }
  func focusSearch() {
    focusRequested = true
    guard let search else { return }
    let pointer = search.widgetPointer
    if let root = gtk_widget_get_root(pointer), let current = gtk_root_get_focus(root),
      current == pointer || gtk_widget_is_ancestor(current, pointer) != 0
    {
      focusRequested = false
      return
    }
    if gtk_widget_grab_focus(pointer) != 0 { focusRequested = false }
  }
  func quit() {
    for (object, id) in signals { g_signal_handler_disconnect(object, id) }
    signals.removeAll()
    if let application {
      g_application_release(application)
      g_application_quit(application)
    }
    application = nil
  }

  private func connect(
    _ object: UnsafeMutableRawPointer, signal: String, immediate: Bool = false,
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    let context = Unmanaged.passRetained(GtkActionBox(immediate: immediate, action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
      _, context in
      guard let context else { return }
      let box = Unmanaged<GtkActionBox>.fromOpaque(context).takeUnretainedValue()
      if box.immediate {
        MainActor.assumeIsolated { box.action() }
      } else {
        Task { @MainActor in box.action() }
      }
    }
    let id = g_signal_connect_data(
      object, signal, unsafeBitCast(callback, to: GCallback.self), context,
      { context, _ in if let context { Unmanaged<GtkActionBox>.fromOpaque(context).release() } },
      GConnectFlags(rawValue: 0))
    signals.append((object, id))
  }
}
