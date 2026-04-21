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
