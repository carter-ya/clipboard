import Foundation

public protocol DesktopImageClassifying: Sendable {
  func classify(_ image: Data) async throws -> DesktopImageClassification
}

/// Bounded metadata from the private image worker, never image bytes or paths.
public struct DesktopImageClassification: Equatable, Sendable {
  public struct Label: Codable, Equatable, Sendable {
    public let name: String
    public let confidence: Double
    public init(name: String, confidence: Double) {
      self.name = name
      self.confidence = confidence
    }
  }
  public let width: Int
  public let height: Int
  public let labels: [Label]

  public init(width: Int, height: Int, labels: [Label]) throws {
    guard (1...32768).contains(width), (1...32768).contains(height),
      width * height <= 30_000_000, labels.count <= 3,
      labels.allSatisfy({
        !$0.name.isEmpty && $0.name.utf8.count <= 128
          && $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
          && !$0.name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
          && $0.confidence.isFinite && (0...1).contains($0.confidence)
      })
    else { throw DesktopServiceError.invalidValue }
    self.width = width
    self.height = height
    self.labels = labels.sorted { $0.confidence > $1.confidence }
  }

  public init(workerOutput: Data) throws {
    struct Wire: Decodable {
      let width: Int
      let height: Int
      let labels: [Label]
    }
    guard !workerOutput.isEmpty, workerOutput.count <= 4096 else {
      throw DesktopServiceError.tooLarge
    }
    let wire: Wire
    do { wire = try JSONDecoder().decode(Wire.self, from: workerOutput) } catch {
      throw DesktopServiceError.invalidValue
    }
    try self.init(width: wire.width, height: wire.height, labels: wire.labels)
  }

  public var summary: String {
    var names: [String] = []
    for label in labels where label.confidence >= 0.1 && !names.contains(label.name) {
      names.append(label.name)
    }
    return names.isEmpty ? "Image (\(width)×\(height))" : names.joined(separator: ", ")
  }
}

public struct DesktopLocalImageResult: Equatable, Sendable {
  public let text: String
  public let source: SummarySource
  public init(text: String, source: SummarySource) {
    self.text = text
    self.source = source
  }
}
