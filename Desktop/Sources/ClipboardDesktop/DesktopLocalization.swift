import ClipboardCore

enum DesktopLocalization {
  static func text(_ value: String, language: String?) -> String {
    DesktopStringCatalog.text(value, language: language)
  }
}
