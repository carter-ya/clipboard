import XCTest

@testable import ClipboardCore

final class DesktopLocalTextPipelineTests: XCTestCase {
  private func item() -> ClipItem {
    let body = String(
      repeating: "A synthetic project schedules its library opening for Friday. ", count: 3)
    return .init(
      createdAt: Date(), kind: .text, preview: "synthetic", sha256: "synthetic",
      sizeBytes: body.utf8.count,
      payloads: [.init(pasteboardType: "public.utf8-plain-text", inlineData: Data(body.utf8))])
  }
  private func enabled() -> DesktopSettings {
    var settings = DesktopSettings()
    settings.localGenerativeSummariesEnabled = true
    settings.localLanguageSummariesEnabled = true
    settings.localTextSummariesEnabled = true
    return settings
  }
  private actor Processor: DesktopLocalLanguageProcessing {
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func process(text: String, task: DesktopLocalLanguageTask, language: String?) throws
      -> DesktopLocalLanguageOutput
    {
      if fails { throw DesktopServiceError.unavailable }
      return try .init(
        task: task, summary: task == .summary ? "The library opens on Friday." : nil,
        languageCode: task == .enrichment ? "en" : nil,
        entities: task == .enrichment ? ["Friday"] : [])
    }
  }
  private func service(fails: Bool = false) -> DesktopAnalysis {
    .init(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: FakeDesktopOCR(), blobRoot: nil, localLanguage: Processor(fails: fails))
  }
  @MainActor func testLegacySettingsDoNotOptIntoNewEnginesAndExplicitFlagsRoundTrip() throws {
    var settings = try JSONDecoder().decode(
      DesktopSettings.self,
      from: Data(#"{"localTextSummariesEnabled":true,"automaticLocalSummaries":true}"#.utf8))
    XCTAssertFalse(settings.localGenerativeSummariesEnabled)
    XCTAssertFalse(settings.automaticLocalGenerativeSummaries)
    XCTAssertFalse(settings.localLanguageSummariesEnabled)
    XCTAssertFalse(settings.automaticLocalLanguageSummaries)
    settings.localGenerativeSummariesEnabled = true
    settings.automaticLocalLanguageSummaries = true
    let restored = try JSONDecoder().decode(
      DesktopSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored, settings)
    XCTAssertFalse(restored.localLanguageSummariesEnabled)
  }
  @MainActor func testFirstSuccessUsesFixedOrderWithoutStartingLaterEngines() async throws {
    let candidate = item()
    let settings = enabled()
    var calls: [DesktopLocalTextEngine] = []
    let result = try await DesktopLocalTextPipeline.run(
      id: candidate.id, automatic: false,
      context: { .init(item: candidate, settings: settings) },
      service: { engine in
        calls.append(engine)
        return self.service()
      })
    XCTAssertEqual(calls, [.generative])
    XCTAssertEqual(result.engine, .generative)
    XCTAssertEqual(result.text, "The library opens on Friday.")
    XCTAssertEqual(
      candidate.payloads[0].inlineData,
      Data(
        String(
          repeating:
            "A synthetic project schedules its library opening for Friday. ", count: 3
        ).utf8))
  }
  @MainActor func testUnavailableModelFallsBackOnlyToIndependentlyAuthorizedLanguage() async throws
  {
    let candidate = item()
    var settings = enabled()
    settings.localTextSummariesEnabled = false
    var calls: [DesktopLocalTextEngine] = []
    let result = try await DesktopLocalTextPipeline.run(
      id: candidate.id, automatic: false,
      context: { .init(item: candidate, settings: settings) },
      service: { engine in
        calls.append(engine)
        return self.service(fails: engine == .generative)
      })
    XCTAssertEqual(calls, [.generative, .language])
    XCTAssertEqual(result.engine, .language)
    XCTAssertTrue(result.text.contains("Friday"))
    settings.localLanguageSummariesEnabled = false
    calls.removeAll()
    do {
      _ = try await DesktopLocalTextPipeline.run(
        id: candidate.id, automatic: false,
        context: { .init(item: candidate, settings: settings) },
        service: { engine in
          calls.append(engine)
          return self.service(fails: true)
        })
      XCTFail("Unauthorized language or excerpt fallback succeeded")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
    XCTAssertEqual(calls, [.generative])
  }
  @MainActor func testPolicyRequiresAutomaticAndFilePermissionsForEachEngine() {
    let candidate = item()
    var settings = enabled()
    for engine in DesktopLocalTextEngine.allCases {
      XCTAssertTrue(engine.isAllowed(item: candidate, settings: settings, automatic: false))
      XCTAssertFalse(engine.isAllowed(item: candidate, settings: settings, automatic: true))
    }
    settings.automaticLocalGenerativeSummaries = true
    XCTAssertTrue(
      DesktopLocalTextEngine.generative.isAllowed(
        item: candidate, settings: settings, automatic: true))
    XCTAssertFalse(
      DesktopLocalTextEngine.language.isAllowed(
        item: candidate, settings: settings, automatic: true))
    var file = candidate
    file.kind = .file
    XCTAssertFalse(
      DesktopLocalTextEngine.generative.isAllowed(
        item: file, settings: settings, automatic: false))
    settings.localFileSummariesEnabled = true
    XCTAssertTrue(
      DesktopLocalTextEngine.generative.isAllowed(
        item: file, settings: settings, automatic: false))
    XCTAssertFalse(
      DesktopLocalTextEngine.generative.isAllowed(
        item: file, settings: settings, automatic: true))
    settings.automaticLocalFileSummaries = true
    XCTAssertTrue(
      DesktopLocalTextEngine.generative.isAllowed(
        item: file, settings: settings, automatic: true))
  }
  @MainActor func testPrivateDeletedAndAlreadySummarizedItemsNeverResolveModels() async {
    let original = item()
    var sensitive = original
    sensitive.sensitive = true
    var concealed = original
    concealed.payloads.append(.init(pasteboardType: SensitivityFilter.concealedType))
    var summarized = original
    summarized.summary = "Existing first success"
    var image = original
    image.kind = .image
    var settings = enabled()
    settings.automaticLocalGenerativeSummaries = true
    settings.automaticLocalLanguageSummaries = true
    settings.automaticLocalSummaries = true
    for candidate in [sensitive, concealed, summarized, image] {
      do {
        _ = try await DesktopLocalTextPipeline.run(
          id: candidate.id, automatic: true,
          context: { .init(item: candidate, settings: settings) },
          service: { _ in
            XCTFail("Ineligible item reached model resolution")
            return self.service()
          })
        XCTFail("Ineligible item was analyzed")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    }
    do {
      _ = try await DesktopLocalTextPipeline.run(
        id: original.id, automatic: false, context: { nil },
        service: { _ in
          XCTFail("Deleted item reached model resolution")
          return self.service()
        })
      XCTFail("Deleted item was analyzed")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
  }
  @MainActor func testRevocationDuringModelResolutionPreventsPayloadAndNextUnauthorizedEngine()
    async
  {
    let candidate = item()
    var settings = enabled()
    settings.localLanguageSummariesEnabled = false
    settings.localTextSummariesEnabled = false
    var phases: [DesktopLocalTextEngine] = []
    do {
      _ = try await DesktopLocalTextPipeline.run(
        id: candidate.id, automatic: false,
        context: { .init(item: candidate, settings: settings) },
        service: { _ in
          settings.localGenerativeSummariesEnabled = false
          return self.service()
        }, began: { phases.append($0) })
      XCTFail("Revoked engine resolved its payload")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    XCTAssertTrue(phases.isEmpty)
  }
  @MainActor func testCancellationNeverStartsFallbackEvenIfDependencyReturnsSuccess() async {
    let candidate = item()
    let started = expectation(description: "model factory suspended")
    var release: CheckedContinuation<Void, Never>?
    var calls: [DesktopLocalTextEngine] = []
    let task = Task { @MainActor in
      do {
        _ = try await DesktopLocalTextPipeline.run(
          id: candidate.id, automatic: false,
          context: { .init(item: candidate, settings: self.enabled()) },
          service: { engine in
            calls.append(engine)
            await withCheckedContinuation {
              release = $0
              started.fulfill()
            }
            return self.service(fails: true)
          })
        XCTFail("Cancelled analysis returned a result")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
    await fulfillment(of: [started], timeout: 3)
    task.cancel()
    release?.resume()
    await task.value
    XCTAssertEqual(calls, [.generative])
  }
  @MainActor func testBothUnavailableWorkersReachOnlyTheAuthorizedExcerpt() async throws {
    let candidate = item()
    let settings = enabled()
    var calls: [DesktopLocalTextEngine] = []
    let result = try await DesktopLocalTextPipeline.run(
      id: candidate.id, automatic: false,
      context: { .init(item: candidate, settings: settings) },
      service: { engine in
        calls.append(engine)
        return self.service(fails: true)
      })
    XCTAssertEqual(calls, [.generative, .language, .excerpt])
    XCTAssertEqual(result.engine, .excerpt)
    XCTAssertTrue(result.text.contains("synthetic project"))
  }
  @MainActor func testLateSuccessIsDiscardedAfterRevocationDeletionOrFirstAutomaticWrite() async {
    let original = item()
    for change in 0..<3 {
      var reads = 0
      var calls: [DesktopLocalTextEngine] = []
      var settings = enabled()
      settings.localLanguageSummariesEnabled = false
      settings.localTextSummariesEnabled = false
      settings.automaticLocalGenerativeSummaries = true
      do {
        _ = try await DesktopLocalTextPipeline.run(
          id: original.id, automatic: true,
          context: {
            reads += 1
            var candidate = original
            if reads >= 3 {
              if change == 0 { settings.localGenerativeSummariesEnabled = false }
              if change == 1 { return nil }
              if change == 2 { candidate.summary = "Earlier first success" }
            }
            return .init(item: candidate, settings: settings)
          },
          service: { engine in
            calls.append(engine)
            return self.service()
          })
        XCTFail("Late inference replaced an ineligible item")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
      XCTAssertEqual(calls, [.generative])
    }
  }

}
