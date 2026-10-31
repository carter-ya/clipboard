import Foundation

/// Public download metadata only. Model bytes are optional app data and are
/// never silently fetched by analysis, startup or a preference migration.
public struct DesktopLocalLanguageModelDefinition: Decodable, Equatable, Sendable {
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

  public init(from decoder: any Decoder) throws {
    enum Key: String, CodingKey {
      case id, repository, revision, filename, url, sha256, size, license, licenseURL, cardURL
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
    try validate()
  }

  public static func bundled() throws -> Self {
    guard
      let file = Bundle.module.url(forResource: "DesktopLocalLanguageModel", withExtension: "json")
    else { throw DesktopServiceError.unavailable }
    let data = try Data(contentsOf: file)
    return try Self.decode(data)
  }

  public static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 4096 else { throw DesktopServiceError.tooLarge }
    let definition: Self
    do { definition = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw DesktopServiceError.invalidValue
    }
    return definition
  }

  public func validate() throws {
    func asciiName(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum && value != "." && value != ".."
        && value.utf8.allSatisfy {
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        }
    }
    let names = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard asciiName(id, maximum: 80), names.count == 2,
      names.allSatisfy({ asciiName(String($0), maximum: 100) }),
      asciiName(filename, maximum: 120), filename.hasSuffix(".gguf"),
      revision.utf8.count == 40,
      revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (1...(8 * 1024 * 1024 * 1024)).contains(size), license == "Apache-2.0",
      url.absoluteString == "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)",
      licenseURL.absoluteString
        == "https://huggingface.co/\(repository)/resolve/\(revision)/LICENSE"
        || licenseURL.absoluteString == "https://www.apache.org/licenses/LICENSE-2.0.txt",
      cardURL.absoluteString == "https://huggingface.co/\(repository)/blob/\(revision)/README.md"
    else { throw DesktopServiceError.invalidValue }
  }
}
