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
        // Vision defaults to English-only. Screenshots of Chinese UI /
        // docs come back empty unless we ask for zh-Hans/zh-Hant
        // explicitly. Listing Chinese first biases the recognizer
        // toward CJK when a glyph is ambiguous between scripts; English
        // still works because it remains in the list.
        textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

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
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Priority: OCR text wins when present — it's the most
        // informative signal and stands on its own. Labels are
        // secondary; they're jargon like "document, screenshot" that
        // isn't useful when real text was already extracted. If
        // neither panned out, fall back to "Image (w×h)" so the UI
        // still displays *something*.
        if !recognizedText.isEmpty {
          continuation.resume(
            returning: String(recognizedText.prefix(Self.maxEmbeddedTextLength)))
          return
        }
        if !labels.isEmpty {
          continuation.resume(returning: labels.joined(separator: ", "))
          return
        }
        continuation.resume(returning: "Image (\(width)×\(height))")
      }
    }
  }
}
