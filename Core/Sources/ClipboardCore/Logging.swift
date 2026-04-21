import OSLog

public enum Log {
  public static let subsystem = "com.clipboard.app"
  public static let monitor = Logger(subsystem: subsystem, category: "monitor")
  public static let store = Logger(subsystem: subsystem, category: "store")
  public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
  public static let paste = Logger(subsystem: subsystem, category: "paste")
  public static let ui = Logger(subsystem: subsystem, category: "ui")
  public static let scenario = Logger(subsystem: subsystem, category: "scenario")
}
