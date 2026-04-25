import ClipboardCore
import Foundation
import PDFKit

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// On-device LLM summarizer powered by Apple's Foundation Models
/// framework. Produces a one-sentence natural-language summary for
/// text snippets or referenced files (PDF + plain-text).
///
/// Only runs on macOS 26+ with an Apple Silicon device that has
/// Apple Intelligence set up; use `AICapability.isFoundationModelsAvailable`
/// to gate before constructing this type. When unavailable, callers
/// should fall back to VisionImageSummarizer / NaturalLanguageTextSummarizer.
@available(macOS 26.0, *)
struct FoundationModelsSummarizer: Sendable, TextSummarizer {
  private static let maxSummaryLength = 200

  /// Returns nil if the prompt is effectively empty or the model
  /// refused / errored. Callers use nil as "fallback to baseline
  /// summarizer".
  func summarize(text: String) async -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let session = LanguageModelSession(
      instructions: """
        You write a single concise sentence summarising clipboard \
        snippets for a history viewer. Return only the sentence — no \
        preamble, no quoting, no bullet list. Keep it under 160 \
        characters.
        """
    )
    do {
      let response = try await session.respond(
        to: "Summarise the following:\n\n\(trimmed)"
      )
      let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !output.isEmpty else {
        Log.ui.info("summary.fm.emptyResponse chars=\(trimmed.count)")
        return nil
      }
      return String(output.prefix(Self.maxSummaryLength))
    } catch {
      Log.ui.error(
        "summary.fm.error chars=\(trimmed.count) err=\(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  /// Summarise a file referenced by a clip (file-url payload).
  /// PDFs are handed to PDFKit to pull a flat text representation;
  /// `.txt` / `.md` / other UTF-8 readable files are loaded directly.
  /// Everything else returns nil (image/binary files don't pass
  /// through here in S66 — images still go through Vision).
  func summarizeFile(url: URL) async -> String? {
    let ext = url.pathExtension.lowercased()
    let body: String?
    if ext == "pdf" {
      body = PDFDocument(url: url)?.string
      if body == nil {
        Log.ui.info(
          "summary.fm.file.pdfDecodeFailed path=\(url.path, privacy: .public)"
        )
      }
    } else {
      do {
        body = try String(contentsOf: url, encoding: .utf8)
      } catch {
        body = nil
        Log.ui.info(
          "summary.fm.file.utf8DecodeFailed ext=\(ext, privacy: .public) err=\(String(describing: error), privacy: .public)"
        )
      }
    }
    guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      Log.ui.info(
        "summary.fm.file.noText ext=\(ext, privacy: .public) path=\(url.path, privacy: .public)"
      )
      return nil
    }
    Log.ui.info(
      "summary.fm.file.extracted ext=\(ext, privacy: .public) chars=\(text.count)"
    )
    return await summarize(text: text)
  }
}
