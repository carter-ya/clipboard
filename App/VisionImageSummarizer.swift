import Foundation
import ImageIO
import Vision

/// Generates a short plain-English summary for an image clip using
/// the on-device Vision framework. Combines the top classifier labels
/// (e.g. "dog, mammal") with any recognized text pulled out of the
/// image so the user can read something meaningful in the preview
/// pane even before opening the thumbnail.
///
/// Vision is available everywhere we ship (macOS 13+), so this is the
/// baseline engine used by the S64 summarizer pipeline. Richer
/// narratives will replace the output on devices that also have
/// Writing Tools (S65) or Foundation Models (S66).
struct VisionImageSummarizer: Sendable {
  private static let maxEmbeddedTextLength = 160
  private static let minClassifierConfidence: VNConfidence = 0.4

  func summarize(imageData: Data) async -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false

        do {
          try handler.perform([classifyRequest, textRequest])
        } catch {
          continuation.resume(returning: nil)
          return
        }

        let labels =
          (classifyRequest.results as? [VNClassificationObservation])?
          .filter { $0.confidence >= Self.minClassifierConfidence }
          .prefix(3)
          .map(\.identifier) ?? []

        let recognizedText =
          (textRequest.results as? [VNRecognizedTextObservation])?
          .compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: " ") ?? ""

        var parts: [String] = []
        if !labels.isEmpty {
          parts.append(labels.joined(separator: ", "))
        }
        if !recognizedText.isEmpty {
          let trimmed = recognizedText.prefix(Self.maxEmbeddedTextLength)
          parts.append("Contains text: \(trimmed)")
        }

        if parts.isEmpty {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: parts.joined(separator: ". "))
        }
      }
    }
  }
}
