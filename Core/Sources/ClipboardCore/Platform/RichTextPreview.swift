import Foundation

/// Plain previews only: no HTML engine, remote resource loading or embedded RTF objects.
public enum RichTextPreview {
  public struct Result: Equatable, Sendable {
    public let text: String
    public let isTruncated: Bool
  }

  /// Display-only rendering; parser budgets never change the original payload.
  public static func preview(from payloads: [RawPayload]) -> Result {
    let parsed = render(payloads, limit: 64 * 1024 + 1)
    let display = DesktopTextPreview(parsed.text)
    return Result(text: display.text, isTruncated: parsed.isTruncated || display.isTruncated)
  }

  public static func text(from payloads: [RawPayload], limit: Int = 8000) -> String {
    render(payloads, limit: min(16000, max(0, limit))).text
  }

  private static func render(_ payloads: [RawPayload], limit: Int) -> Result {
    for type in ["public.utf8-plain-text", "public.plain-text", "public.string"] {
      if let data = payloads.first(where: { $0.pasteboardType == type })?.data,
        let text = String(data: data, encoding: .utf8), !text.isEmpty
      {
        return Result(text: String(text.prefix(limit)), isTruncated: text.count > limit)
      }
    }
    if let data = payloads.first(where: { $0.pasteboardType == "public.rtf" })?.data {
      return rtf(data, limit: limit)
    }
    if let data = payloads.first(where: { $0.pasteboardType == "public.html" })?.data {
      return html(data, limit: limit)
    }
    return Result(text: "", isTruncated: false)
  }
  private static func html(_ data: Data, limit: Int) -> Result {
    let input = Array(String(decoding: data.prefix(256 * 1024), as: UTF8.self))
    var result = ""
    var index = 0
    var emitted = 0
    var hidden: String?
    while index < input.count && emitted < limit {
      let character = input[index]
      if character == "<" {
        let start = index + 1
        var end = start
        while end < input.count && end - start < 1024 && input[end] != ">" { end += 1 }
        guard end < input.count, input[end] == ">" else { break }
        let tag = String(input[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        let name = String(
          tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }))
        if tag.hasPrefix("/"), hidden == name {
          hidden = nil
        } else if hidden == nil, !tag.hasPrefix("/"), ["script", "style", "head"].contains(name) {
          hidden = name
        }
        if hidden == nil && ["br", "p", "div", "li", "tr"].contains(name) {
          result.append("\n")
          emitted += 1
        }
        index = end + 1
        continue
      }
      if hidden != nil {
        index += 1
        continue
      }
      if character == "&" {
        var end = index + 1
        while end < input.count && end - index <= 12 && input[end] != ";" { end += 1 }
        if end < input.count, input[end] == ";" {
          let entity = String(input[(index + 1)..<end])
          let common = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
          if let replacement = common[entity] {
            result += replacement
            emitted += 1
            index = end + 1
            continue
          }
          let value =
            entity.hasPrefix("#x")
            ? UInt32(entity.dropFirst(2), radix: 16)
            : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
          if let value, let scalar = UnicodeScalar(value) {
            result.unicodeScalars.append(scalar)
            emitted += 1
            index = end + 1
            continue
          }
        }
      }
      result.append(character)
      emitted += 1
      index += 1
    }
    return Result(
      text: String(result.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines),
      isTruncated: index < input.count || data.count > 256 * 1024)
  }
  private struct RTFState {
    var hidden = false
    var unicodeSkip = 1
  }
  private static func rtf(_ data: Data, limit: Int) -> Result {
    let bytes = Array(data.prefix(256 * 1024))
    guard bytes.starts(with: Array("{\\rtf".utf8)) else {
      return Result(text: "", isTruncated: false)
    }
    var state = RTFState()
    var stack: [RTFState] = []
    var units: [UInt16] = []
    var index = 0
    var fallback = 0
    func asciiLetter(_ value: UInt8) -> Bool {
      (65...90).contains(value) || (97...122).contains(value)
    }
    func emit(_ value: UInt16) {
      if fallback > 0 { fallback -= 1 } else if !state.hidden { units.append(value) }
    }
    while index < bytes.count && units.count < limit * 2 {
      let byte = bytes[index]
      index += 1
      if byte == 123 {
        guard stack.count < 100 else { break }
        stack.append(state)
        continue
      }
      if byte == 125 {
        if let previous = stack.popLast() { state = previous }
        continue
      }
      if byte != 92 {
        if byte != 10 && byte != 13 { emit(UInt16(byte)) }
        continue
      }
      guard index < bytes.count else { break }
      let control = bytes[index]
      index += 1
      if control == 92 || control == 123 || control == 125 {
        emit(UInt16(control))
        continue
      }
      if control == 42 {
        state.hidden = true
        continue
      }
      if control == 39, index + 1 < bytes.count {
        let hex = String(decoding: bytes[index...index + 1], as: UTF8.self)
        if let value = UInt16(hex, radix: 16) { emit(value) }
        index += 2
        continue
      }
      if control == 126 {
        emit(32)
        continue
      }
      if !asciiLetter(control) { continue }
      let start = index - 1
      while index < bytes.count && asciiLetter(bytes[index]) { index += 1 }
      let word = String(decoding: bytes[start..<index], as: UTF8.self)
      let numberStart = index
      if index < bytes.count && bytes[index] == 45 { index += 1 }
      while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
      let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
      if index < bytes.count && bytes[index] == 32 { index += 1 }
      if ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer"]
        .contains(word)
      {
        state.hidden = true
      } else if word == "bin", let number, number >= 0 {
        index = min(bytes.count, index + min(number, bytes.count))
      } else if word == "uc", let number {
        state.unicodeSkip = min(16, max(0, number))
      } else if word == "u", let number {
        if !state.hidden { units.append(UInt16(truncatingIfNeeded: number)) }
        fallback = state.unicodeSkip
      } else if word == "par" || word == "line" {
        if !state.hidden { units.append(10) }
      } else if word == "tab" {
        if !state.hidden { units.append(9) }
      } else if word == "emdash" {
        emit(0x2014)
      } else if word == "endash" {
        emit(0x2013)
      } else if word == "bullet" {
        emit(0x2022)
      }
    }
    let unfinished = index < bytes.count || data.count > 256 * 1024
    // A parser budget may end between a UTF-16 surrogate pair.
    if unfinished, let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
    let decoded = String(decoding: units, as: UTF16.self)
    return Result(
      text: String(decoded.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines),
      isTruncated: unfinished || decoded.count > limit)
  }
}
