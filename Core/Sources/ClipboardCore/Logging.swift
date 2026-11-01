import Foundation

#if canImport(OSLog)
  import OSLog
#else
  // Validation-only stderr backend. Apple platforms retain unified logging.
  // Interpolated values are redacted unless the caller marks them public.
  public struct Logger: Sendable {
    public enum Privacy {
      case `public`
      case `private`
    }

    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
      public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
          text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) { text += literal }

        public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .private) {
          switch privacy {
          case .public: text += String(describing: value)
          case .private: text += "<private>"
          }
        }
      }

      let text: String
      public init(stringLiteral value: String) { text = value }
      public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    }

    private let subsystem: String
    private let category: String

    public init(subsystem: String, category: String) {
      self.subsystem = subsystem
      self.category = category
    }

    public func info(_ message: Message) { write(message, level: "info") }
    public func error(_ message: Message) { write(message, level: "error") }

    private func write(_ message: Message, level: String) {
      let line = "[\(subsystem):\(category)] \(level) \(message.text)\n"
      FileHandle.standardError.write(Data(line.utf8))
    }
  }
#endif

public enum Log {
  public static let subsystem = "com.clipboard.app"
  public static let monitor = Logger(subsystem: subsystem, category: "monitor")
  public static let store = Logger(subsystem: subsystem, category: "store")
  public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
  public static let paste = Logger(subsystem: subsystem, category: "paste")
  public static let ui = Logger(subsystem: subsystem, category: "ui")
  public static let scenario = Logger(subsystem: subsystem, category: "scenario")
}
