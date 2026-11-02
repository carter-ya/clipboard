import CGtk
import Foundation
import Gtk

/// Read-only native state for the owned Windows input test. No text, focus or
/// selection is changed; ordinary profiles never attach observers or write data.
@MainActor enum DesktopImeStateFixture {
  private final class Identity {
    weak var entry: Gtk.Entry?
    let id: Int
    init(_ entry: Gtk.Entry, id: Int) {
      self.entry = entry
      self.id = id
    }
  }
  private struct State: Encodable {
    let event: String
    let entry: Int
    let characters: Int
    let cursor: Int
    let selected: Bool
    let start: Int32
    let end: Int32
    let focused: Bool
    let mapped: Bool
  }
  private struct Receipt: Encodable {
    let sequence: Int
    let current: State?
    let events: [State]
  }
  private static var root: URL?
  private static weak var current: Gtk.Entry?
  private static var identities: [ObjectIdentifier: Identity] = [:]
  private static var nextID = 0
  private static var sequence = 0
  private static var events: [State] = []

  nonisolated static func allowed(
    arguments: [String], actions: Bool, windows: Bool, hasRoot: Bool, profile: String
  ) -> Bool {
    windows && actions && hasRoot && !profile.isEmpty && profile != "production"
      && arguments.contains("--smoke-root") && arguments.contains("--smoke-ime-state")
  }

  static func attach(_ entry: Gtk.Entry) {
    #if os(Windows)
      let windows = true
    #else
      let windows = false
    #endif
    guard
      allowed(
        arguments: CommandLine.arguments,
        actions: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
        windows: windows, hasRoot: DesktopApplicationContext.dataRoot != nil,
        profile: DesktopApplicationContext.profile),
      let directory = DesktopApplicationContext.dataRoot
    else { return }
    root = directory
    current = entry
    let key = ObjectIdentifier(entry)
    if identities[key]?.entry === entry { return }
    guard nextID < 64 else { return }
    nextID += 1
    identities[key] = Identity(entry, id: nextID)
    entry.notifyCursorPosition = { entry, _ in
      MainActor.assumeIsolated { record("cursor", entry) }
    }
    entry.notifySelectionBound = { entry, _ in
      MainActor.assumeIsolated { record("selection", entry) }
    }
    entry.notifyText = { entry, _ in
      MainActor.assumeIsolated { record("text", entry) }
    }
    record("attach", entry)
  }

  private static func activeEntry() -> Gtk.Entry? {
    for identity in identities.values {
      guard let entry = identity.entry, gtk_widget_get_mapped(entry.widgetPointer) != 0,
        let root = gtk_widget_get_root(entry.widgetPointer), let focus = gtk_root_get_focus(root)
      else { continue }
      if focus == entry.widgetPointer || gtk_widget_is_ancestor(focus, entry.widgetPointer) != 0 {
        return entry
      }
    }
    return current
  }

  private static func state(_ event: String, _ entry: Gtk.Entry) -> State {
    let pointer = entry.widgetPointer
    var start: Int32 = -1
    var end: Int32 = -1
    let selected = gtk_editable_get_selection_bounds(OpaquePointer(pointer), &start, &end) != 0
    var focused = false
    if let root = gtk_widget_get_root(pointer), let focus = gtk_root_get_focus(root) {
      focused = focus == pointer || gtk_widget_is_ancestor(focus, pointer) != 0
    }
    return State(
      event: event, entry: identities[ObjectIdentifier(entry)]?.id ?? 0,
      characters: entry.text.unicodeScalars.count, cursor: entry.cursorPosition,
      selected: selected, start: start, end: end, focused: focused,
      mapped: gtk_widget_get_mapped(pointer) != 0)
  }

  private static func record(_ event: String, _ entry: Gtk.Entry) {
    guard let root else { return }
    sequence += 1
    events.append(state(event, entry))
    if events.count > 256 { events.removeFirst(events.count - 256) }
    let receipt = Receipt(
      sequence: sequence, current: activeEntry().map { state("current", $0) }, events: events)
    guard let data = try? JSONEncoder().encode(receipt) else { return }
    try? data.write(to: root.appendingPathComponent("ime-state.json"), options: .atomic)
  }
}
