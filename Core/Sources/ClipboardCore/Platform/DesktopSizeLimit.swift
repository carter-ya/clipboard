import Foundation

/// Exact MiB conversion without losing a saved fractional byte threshold.
public enum DesktopSizeLimit {
  private static let unit = Decimal(1024 * 1024)
  public static func bytes(fromMiB raw: String) -> Int? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
      value.utf8.contains(where: { (48...57).contains($0) }),
      value.filter({ $0 == "." }).count <= 1,
      let mib = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !mib.isNaN
    else { return nil }
    var amount = mib * unit
    guard !amount.isNaN else { return nil }
    var whole = Decimal()
    NSDecimalRound(&whole, &amount, 0, .down)
    // A tiny positive value must not silently become zero and disable filtering.
    guard amount == 0 || whole >= 1 else { return nil }
    return Int(NSDecimalNumber(decimal: whole).stringValue)
  }
  public static func mibString(forBytes bytes: Int) -> String {
    NSDecimalNumber(decimal: Decimal(max(0, bytes)) / unit).stringValue
  }
}
