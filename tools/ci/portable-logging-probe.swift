import Foundation

// Compiled with the actual production Logging.swift, without clipboard/UI APIs.
@main enum PortableLoggingProbe {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { exit(2) }
    let message: Logger.Message = "secret=\("synthetic-private-value") public=\(42, privacy: .public)"
    guard message.text == "secret=<private> public=42" else { exit(3) }
    Log.store.info(message)
    Log.monitor.error(message)
    try Data("logging-completed\n".utf8).write(
      to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
  }
}
