import ClipboardCore
import Combine
import Foundation

enum HistoryPanelTab: Equatable, Hashable {
  case all
  case pinned
}

@MainActor
final class HistoryPanelViewModel: ObservableObject {
  @Published private(set) var items: [ClipItem] = []
  @Published var searchText: String = ""
  @Published var selectedID: UUID?
  @Published var currentTab: HistoryPanelTab = .all
  @Published var kindFilter: ClipKind?
  @Published var lastSkip: SkipEvent?
  /// Bumped every time the UI should force-scroll the list back to
  /// its top (e.g., when the panel reopens). The view observes
  /// changes to this value via .onChange.
  @Published private(set) var scrollEpoch: Int = 0

  private let store: any ClipStore
  private var searchTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  init(store: any ClipStore) {
    self.store = store
  }

  var filteredItems: [ClipItem] {
    var result = items
    if let kind = kindFilter {
      result = result.filter { $0.kind == kind }
    }
    switch currentTab {
    case .all: return result
    case .pinned: return result.filter(\.pinned)
    }
  }

  /// Count for the "All" tab: total items under the current search.
  /// Intentionally ignores the kind chip selection so the top-level
  /// tab reads as a stable "library total", not a filtered subset.
  var allTabCount: Int {
    items.count
  }

  /// Count for the "Pinned" tab: pinned items under the current
  /// search, ignoring kind chip selection for the same reason as
  /// allTabCount.
  var pinnedTabCount: Int {
    items.filter(\.pinned).count
  }

  /// Count for a kind chip (nil = All chip): items under current
  /// search + current tab filter, restricted to the given kind.
  func kindChipCount(for kind: ClipKind?) -> Int {
    items.filter { tabMatches($0) && (kind == nil || $0.kind == kind) }.count
  }

  private func tabMatches(_ item: ClipItem) -> Bool {
    switch currentTab {
    case .all: return true
    case .pinned: return item.pinned
    }
  }

  func start() {
    Task { await self.refresh() }
    observeTask = Task { [weak self] in
      guard let self else { return }
      for await _ in self.store.events {
        if Task.isCancelled { break }
        await self.refresh()
      }
    }
  }

  func stop() {
    observeTask?.cancel()
    searchTask?.cancel()
  }

  /// Move the selection to the first visible row (honouring the
  /// current tab + search filter) and ask the view to scroll the
  /// list back to the top. Called by the delegate whenever the
  /// panel is (re)opened so stale state from last session doesn't
  /// stick around.
  func resetSelection() {
    // "Every open is a fresh session" — clear transient filters that
    // the user may have forgotten about between sessions.
    kindFilter = nil
    selectedID = filteredItems.first?.id
    scrollEpoch &+= 1
  }

  /// Called when the kind filter changes within a session. Keeps
  /// selection on a visible row without wiping kindFilter itself
  /// (which would cause a feedback loop with .onChange observers).
  func realignAfterFilterChange() {
    selectedID = filteredItems.first?.id
    scrollEpoch &+= 1
  }

  /// Move selection one row down. Clamps at the last row (no wrap).
  func selectNext() {
    let items = filteredItems
    guard !items.isEmpty else {
      selectedID = nil
      return
    }
    if let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) {
      let next = min(idx + 1, items.count - 1)
      selectedID = items[next].id
    } else {
      selectedID = items.first?.id
    }
  }

  /// Move selection one row up. Clamps at the first row (no wrap).
  func selectPrevious() {
    let items = filteredItems
    guard !items.isEmpty else {
      selectedID = nil
      return
    }
    if let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) {
      let prev = max(idx - 1, 0)
      selectedID = items[prev].id
    } else {
      selectedID = items.last?.id
    }
  }

  func setSearch(_ text: String) {
    searchText = text
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      if Task.isCancelled { return }
      await self?.refresh()
    }
  }

  func recordSkip(_ skip: SkipEvent) {
    lastSkip = skip
  }

  func clearLastSkip() {
    lastSkip = nil
  }

  /// Whether `lastSkip` should be shown. We keep the banner visible
  /// for 60 seconds by default so the user has time to go open the
  /// panel after their big copy didn't land.
  func shouldShowLastSkip(now: Date = Date(), window: TimeInterval = 60) -> Bool {
    guard let skip = lastSkip else { return false }
    return now.timeIntervalSince(skip.timestamp) < window
  }

  func togglePin(_ item: ClipItem) async {
    // Optimistic local flip: mutate items on the main actor before
    // awaiting the store so the UI reacts in the very next frame.
    // The store's .updated event will come back and overwrite this
    // same index with the canonical value — content-identical, no
    // flicker.
    if let idx = items.firstIndex(where: { $0.id == item.id }) {
      items[idx].pinned.toggle()
    }
    await store.togglePin(id: item.id)
  }

  func delete(_ item: ClipItem) async {
    // When the deleted row was the current selection, pre-pick a
    // neighbour so refresh()'s "selected vanished" fallback doesn't
    // snap back to the top of the list. Prefer the next row (the one
    // that slides up into the deleted slot); if we're deleting the
    // last visible row, keep the previous.
    if item.id == selectedID {
      let visible = filteredItems
      if let idx = visible.firstIndex(where: { $0.id == item.id }) {
        if idx + 1 < visible.count {
          selectedID = visible[idx + 1].id
        } else if idx > 0 {
          selectedID = visible[idx - 1].id
        } else {
          selectedID = nil
        }
      }
    }
    await store.delete(id: item.id)
  }

  private func refresh() async {
    let results = await store.search(query: searchText, filters: .all)
    await MainActor.run {
      self.items = results
      if let selected = self.selectedID,
        !results.contains(where: { $0.id == selected })
      {
        self.selectedID = self.filteredItems.first?.id
      }
    }
  }
}
