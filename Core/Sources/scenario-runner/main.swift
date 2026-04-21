import ClipboardCore
import Foundation

struct CheckResult: Codable {
  let name: String
  let passed: Bool
  let detail: String?
}

struct Report: Codable {
  let scenario: String
  let passed: Bool
  let checks: [CheckResult]
}

@discardableResult
func check(
  _ name: String,
  _ condition: Bool,
  detail: String? = nil,
  into out: inout [CheckResult]
) -> Bool {
  out.append(CheckResult(name: name, passed: condition, detail: detail))
  return condition
}

func rawText(_ text: String) -> RawClipItem {
  let data = Data(text.utf8)
  return RawClipItem(
    payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
    bundleID: nil,
    changeCount: 1,
    totalBytes: data.count,
    timestamp: Date()
  )
}

func rawImage(bytes: Int) -> RawClipItem {
  let data = Data(repeating: 0x42, count: bytes)
  return RawClipItem(
    payloads: [RawPayload(pasteboardType: "public.png", data: data)],
    bundleID: nil,
    changeCount: 1,
    totalBytes: bytes,
    timestamp: Date()
  )
}

func runRichTypes() async -> Report {
  var checks: [CheckResult] = []
  let store = InMemoryClipStore()

  // 1. text dedup regardless of UTI metadata decoration
  await store.insert(rawText("hello"))
  let onceAlone = Data("hello".utf8)
  let decorated = RawClipItem(
    payloads: [
      RawPayload(pasteboardType: "public.utf8-plain-text", data: onceAlone),
      RawPayload(pasteboardType: "NSStringPboardType", data: onceAlone),
    ],
    bundleID: nil,
    changeCount: 2,
    totalBytes: onceAlone.count,
    timestamp: Date()
  )
  await store.insert(decorated)
  let afterDedup = await store.all()
  check(
    "dedup_across_uti_metadata",
    afterDedup.count == 1,
    detail: "expected 1 item after dedup, got \(afterDedup.count)",
    into: &checks
  )

  // 2. image kind inference
  await store.insert(rawImage(bytes: 256))
  let all = await store.all()
  let imageItem = all.first(where: { $0.kind == .image })
  check(
    "image_kind_inference",
    imageItem != nil,
    detail: imageItem.map { _ in "ok" } ?? "no .image item present",
    into: &checks
  )

  // 3. bump to head refreshes ordering
  if let textItem = all.first(where: { $0.kind == .text }) {
    await store.bumpToTop(id: textItem.id)
    let afterBump = await store.all()
    check(
      "bump_to_top_puts_item_first",
      afterBump.first?.id == textItem.id,
      into: &checks
    )
  }

  // 4. togglePin flips atomically
  if let any = (await store.all()).first {
    await store.togglePin(id: any.id)
    let pinned = await store.item(id: any.id)
    check(
      "toggle_pin_flips",
      pinned?.pinned == true,
      into: &checks
    )
    await store.togglePin(id: any.id)
    let unpinned = await store.item(id: any.id)
    check(
      "toggle_pin_flips_back",
      unpinned?.pinned == false,
      into: &checks
    )
  }

  let passed = checks.allSatisfy(\.passed)
  return Report(scenario: "rich-types", passed: passed, checks: checks)
}

@main
enum ScenarioRunner {
  static func main() async {
    let scenario = CommandLine.arguments.dropFirst().first ?? "rich-types"
    let report: Report
    switch scenario {
    case "rich-types":
      report = await runRichTypes()
    default:
      report = Report(
        scenario: scenario,
        passed: false,
        checks: [CheckResult(name: "unknown_scenario", passed: false, detail: scenario)]
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report),
      let text = String(data: data, encoding: .utf8)
    {
      print(text)
    }
    exit(report.passed ? 0 : 1)
  }
}
