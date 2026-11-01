import Foundation

/// A fixed optional entity asset. Installation must present its license and
/// record explicit acceptance; this metadata never initiates a download.
public struct DesktopLocalEntityModelDefinition: Decodable, Equatable, Sendable {
  public let id: String
  public let repository: String
  public let revision: String
  public let filename: String
  public let url: URL
  public let sha256: String
  public let size: Int64
  public let license: String
  public let licenseURL: URL
  public let cardURL: URL
  public let licenseAcceptanceRequired: Bool

  public init(from decoder: any Decoder) throws {
    enum Key: String, CodingKey {
      case id, repository, revision, filename, url, sha256, size, license, licenseURL, cardURL
      case licenseAcceptanceRequired
    }
    let fields = try decoder.container(keyedBy: Key.self)
    id = try fields.decode(String.self, forKey: .id)
    repository = try fields.decode(String.self, forKey: .repository)
    revision = try fields.decode(String.self, forKey: .revision)
    filename = try fields.decode(String.self, forKey: .filename)
    url = try fields.decode(URL.self, forKey: .url)
    sha256 = try fields.decode(String.self, forKey: .sha256)
    size = try fields.decode(Int64.self, forKey: .size)
    license = try fields.decode(String.self, forKey: .license)
    licenseURL = try fields.decode(URL.self, forKey: .licenseURL)
    cardURL = try fields.decode(URL.self, forKey: .cardURL)
    licenseAcceptanceRequired = try fields.decode(Bool.self, forKey: .licenseAcceptanceRequired)
    try validate()
  }
  public static func bundled() throws -> Self {
    guard
      let file = Bundle.module.url(forResource: "DesktopLocalEntityModel", withExtension: "json")
    else { throw DesktopServiceError.unavailable }
    return try decode(Data(contentsOf: file))
  }
  public static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 4096 else { throw DesktopServiceError.tooLarge }
    do { return try JSONDecoder().decode(Self.self, from: data) } catch {
      throw DesktopServiceError.invalidValue
    }
  }
  public func validate() throws {
    func name(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum && value != "." && value != ".."
        && value.utf8.allSatisfy {
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        }
    }
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard name(id, maximum: 80), parts.count == 2,
      parts.allSatisfy({ name(String($0), maximum: 100) }),
      name(filename, maximum: 120), filename.hasSuffix(".onnx"),
      revision.utf8.count == 40,
      revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (1...(2 * 1024 * 1024 * 1024)).contains(size), license == "AFL-3.0",
      licenseAcceptanceRequired,
      url.absoluteString
        == "https://huggingface.co/\(repository)/resolve/\(revision)/onnx/\(filename)",
      licenseURL.absoluteString == "https://opensource.org/license/afl-3.0",
      cardURL.absoluteString == "https://huggingface.co/\(repository)/blob/\(revision)/README.md"
    else { throw DesktopServiceError.invalidValue }
  }
}
