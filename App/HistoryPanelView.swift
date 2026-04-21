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

  @FocusState private var searchFocused: Bool

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
    .background(keyboardShortcutButtons)
    .onChange(of: viewModel.currentTab) { _ in
      viewModel.resetSelection()
    }
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
      .focused($searchFocused)
      .onSubmit { activateSelected() }
      .accessibilityLabel("Search history")
    }
    .padding(10)
  }

  private var tabBar: some View {
    Picker("", selection: $viewModel.currentTab) {
      Text("All").tag(HistoryPanelTab.all)
      Text("Pinned").tag(HistoryPanelTab.pinned)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
    .accessibilityLabel("Tab")
  }

  private var list: some View {
    ScrollViewReader { proxy in
      List(viewModel.filteredItems, selection: $viewModel.selectedID) { item in
        ClipRowView(item: item, thumbnailLoader: thumbnailLoader)
          .tag(item.id)
          .contentShape(Rectangle())
          .onTapGesture { onActivate(item) }
          .contextMenu {
            Button(item.pinned ? "Unpin" : "Pin") { onTogglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { onDelete(item) }
          }
          .accessibilityLabel(accessibilityLabel(for: item))
      }
      .listStyle(.plain)
      .onChange(of: viewModel.scrollEpoch) { _ in
        if let id = viewModel.filteredItems.first?.id {
          proxy.scrollTo(id, anchor: .top)
        }
      }
    }
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

  private var keyboardShortcutButtons: some View {
    ZStack {
      Button("") { activateSelected() }
        .keyboardShortcut(.return, modifiers: [])
        .hidden()
      Button("") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
      Button("") { deleteSelected() }
        .keyboardShortcut(.delete, modifiers: .command)
        .hidden()
      Button("") { togglePinSelected() }
        .keyboardShortcut("p", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 0) }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 1) }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 2) }
        .keyboardShortcut("3", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 3) }
        .keyboardShortcut("4", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 4) }
        .keyboardShortcut("5", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 5) }
        .keyboardShortcut("6", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 6) }
        .keyboardShortcut("7", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 7) }
        .keyboardShortcut("8", modifiers: .command)
        .hidden()
      Button("") { selectQuick(index: 8) }
        .keyboardShortcut("9", modifiers: .command)
        .hidden()
    }
  }

  private func activateSelected() {
    if let item = selectedItem {
      onActivate(item)
    }
  }

  private func togglePinSelected() {
    if let item = selectedItem {
      onTogglePin(item)
    }
  }

  private func deleteSelected() {
    if let item = selectedItem {
      onDelete(item)
    }
  }

  private func selectQuick(index: Int) {
    let items = viewModel.filteredItems
    guard index < items.count else { return }
    onActivate(items[index])
  }

  private func accessibilityLabel(for item: ClipItem) -> String {
    var parts: [String] = [item.preview.isEmpty ? "empty" : item.preview]
    parts.append("kind \(item.kind.rawValue)")
    if item.pinned { parts.append("pinned") }
    if item.sensitive { parts.append("sensitive") }
    return parts.joined(separator: ", ")
  }
}
