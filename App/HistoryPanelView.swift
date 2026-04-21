import ClipboardCore
import SwiftUI

struct HistoryPanelView: View {
  @ObservedObject var viewModel: HistoryPanelViewModel
  let thumbnailLoader: ThumbnailLoader?
  let resolver: PayloadResolver?
  var onClose: () -> Void = {}
  var onActivate: (ClipItem) -> Void = { _ in }
  var onTogglePin: (ClipItem) -> Void = { _ in }
  var onDelete: (ClipItem) -> Void = { _ in }

  var body: some View {
    HStack(spacing: 0) {
      listColumn
      Divider()
      ClipPreviewView(
        item: selectedItem,
        thumbnailLoader: thumbnailLoader,
        resolver: resolver
      )
      .frame(width: 260)
    }
    .frame(width: 680, height: 520)
    .background(.regularMaterial)
  }

  private var listColumn: some View {
    VStack(spacing: 0) {
      searchField
      tabBar
      Divider()
      if viewModel.filteredItems.isEmpty {
        emptyState
      } else {
        list
      }
    }
    .frame(width: 420)
  }

  private var tabBar: some View {
    Picker("", selection: $viewModel.currentTab) {
      Text("All").tag(HistoryPanelTab.all)
      Text("Pinned").tag(HistoryPanelTab.pinned)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(
        "Search",
        text: Binding(
          get: { viewModel.searchText },
          set: { viewModel.setSearch($0) }
        )
      )
      .textFieldStyle(.plain)
      .onSubmit {}
    }
    .padding(10)
  }

  private var list: some View {
    List(viewModel.filteredItems, selection: $viewModel.selectedID) { item in
      ClipRowView(item: item, thumbnailLoader: thumbnailLoader)
        .tag(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onActivate(item) }
        .contextMenu {
          Button(item.pinned ? "Unpin" : "Pin") { onTogglePin(item) }
          Divider()
          Button("Delete", role: .destructive) { onDelete(item) }
        }
    }
    .listStyle(.plain)
    .background(
      Button("") { activateSelected() }
        .keyboardShortcut(.return, modifiers: [])
        .hidden()
    )
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      Text(emptyStateText)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateText: String {
    if viewModel.currentTab == .pinned { return "No pinned items" }
    if !viewModel.searchText.isEmpty { return "No matches" }
    return "No history yet"
  }

  private var selectedItem: ClipItem? {
    guard let id = viewModel.selectedID else { return nil }
    return viewModel.filteredItems.first(where: { $0.id == id })
  }

  private func activateSelected() {
    if let item = selectedItem {
      onActivate(item)
    }
  }
}
