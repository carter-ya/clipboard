import Foundation
import Security

public enum RemoteAICredentialsError: Error, Equatable {
  case unhandled(OSStatus)
  case invalidEncoding
  case authFailed
  case interactionNotAllowed
  case duplicateItem
  case missingItem
}

public enum RemoteAICredentials {
  public static let service = "com.clipboard.app.remoteAI"

  public static func read(baseURL: String) -> String? {
    var query = baseQuery(account: baseURL)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func hasKey(baseURL: String) -> Bool {
    var query = baseQuery(account: baseURL)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess
  }

  public static func save(_ value: String, baseURL: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw RemoteAICredentialsError.invalidEncoding
    }
    let lookup = baseQuery(account: baseURL)
    let probe = SecItemCopyMatching(lookup as CFDictionary, nil)
    switch probe {
    case errSecSuccess:
      let updates: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      ]
      let status = SecItemUpdate(lookup as CFDictionary, updates as CFDictionary)
      guard status == errSecSuccess else { throw mapStatus(status) }
    case errSecItemNotFound:
      var attrs = lookup
      attrs[kSecValueData as String] = data
      attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(attrs as CFDictionary, nil)
      guard status == errSecSuccess else { throw mapStatus(status) }
    default:
      throw mapStatus(probe)
    }
  }

  public static func delete(baseURL: String) throws {
    let query = baseQuery(account: baseURL)
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    throw mapStatus(status)
  }

  private static func baseQuery(account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  private static func mapStatus(_ status: OSStatus) -> RemoteAICredentialsError {
    switch status {
    case errSecAuthFailed: return .authFailed
    case errSecInteractionNotAllowed: return .interactionNotAllowed
    case errSecDuplicateItem: return .duplicateItem
    case errSecItemNotFound: return .missingItem
    default: return .unhandled(status)
    }
  }
}
