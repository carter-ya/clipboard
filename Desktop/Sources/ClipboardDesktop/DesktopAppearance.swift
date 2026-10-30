import CGtk
import Foundation

@MainActor enum DesktopAppearance {
  private static var systemPrefersDark: Bool?
  private static var systemThemeName: String?
  private(set) static var applying = false
  private static var object: UnsafeMutablePointer<GObject>? {
    gtk_settings_get_default().map { UnsafeMutablePointer<GObject>($0) }
  }
  private static func boolProperty(_ name: String) -> Bool {
    guard let object else { return false }
    var value = GValue()
    _ = g_value_init(&value, g_type_from_name("gboolean"))
    defer { g_value_unset(&value) }
    g_object_get_property(object, name, &value)
    return g_value_get_boolean(&value) != 0
  }
  private static func stringProperty(_ name: String) -> String? {
    guard let object else { return nil }
    var value = GValue()
    _ = g_value_init(&value, g_type_from_name("gchararray"))
    defer { g_value_unset(&value) }
    g_object_get_property(object, name, &value)
    return g_value_get_string(&value).map { String(cString: $0) }
  }
  static var currentIsDark: Bool {
    boolProperty("gtk-application-prefer-dark-theme")
      || (stringProperty("gtk-theme-name")?.lowercased().hasSuffix("-dark") ?? false)
  }
  static func recordSystem(property: String? = nil) {
    if property == nil || property?.hasSuffix("gtk-application-prefer-dark-theme") == true {
      systemPrefersDark = boolProperty("gtk-application-prefer-dark-theme")
    }
    if property == nil || property?.hasSuffix("gtk-theme-name") == true {
      systemThemeName = stringProperty("gtk-theme-name")
    }
  }
  static func apply(_ appearance: String) {
    guard let object else { return }
    if systemPrefersDark == nil { recordSystem() }
    applying = true
    defer { applying = false }
    var boolean = GValue()
    _ = g_value_init(&boolean, g_type_from_name("gboolean"))
    defer { g_value_unset(&boolean) }
    let dark = appearance == "system" ? (systemPrefersDark ?? false) : appearance == "dark"
    if let name = systemThemeName {
      let selected =
        appearance == "system" ? name : name.hasSuffix("-dark") ? String(name.dropLast(5)) : name
      var string = GValue()
      _ = g_value_init(&string, g_type_from_name("gchararray"))
      selected.withCString { g_value_set_string(&string, $0) }
      g_object_set_property(object, "gtk-theme-name", &string)
      g_value_unset(&string)
    }
    g_value_set_boolean(&boolean, dark ? 1 : 0)
    g_object_set_property(object, "gtk-application-prefer-dark-theme", &boolean)
  }
}
