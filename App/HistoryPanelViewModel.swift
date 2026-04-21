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
    switch currentTab {
    case .all: return items
    case .pinned: return items.filter(\.pinned)
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
    selectedID = filteredItems.first?.id
    scrollEpoch &+= 1
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

  func togglePin(_ item: ClipItem) async {
    if item.pinned {
      await store.unpin(id: item.id)
    } else {
      await store.pin(id: item.id)
    }
  }

  func delete(_ item: ClipItem) async {
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
