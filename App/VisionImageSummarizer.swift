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
  /// Previously 0.4 — too strict for screenshots of app UI, code
  /// editors, and other synthetic content where the classifier is
  /// rarely confident. 0.1 lets the top labels through; we still
  /// only surface the top 3.
  private static let minClassifierConfidence: VNConfidence = 0.1

  func summarize(imageData: Data) async -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    let width = cgImage.width
    let height = cgImage.height

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
          // Even if Vision fails outright we can still return a
          // dimensions-only placeholder so the preview pane shows
          // *something* for every image clip.
          continuation.resume(returning: "Image (\(width)×\(height))")
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

        // Always return something — an image clip with neither
        // meaningful labels nor legible text still deserves a marker
        // so users see that summarization ran. Dimensions double as a
        // tiny hint (e.g., "Image (1920×1080)" reads as a screenshot).
        if parts.isEmpty {
          continuation.resume(returning: "Image (\(width)×\(height))")
        } else {
          continuation.resume(returning: parts.joined(separator: ". "))
        }
      }
    }
  }
}
