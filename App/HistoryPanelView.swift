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
  var onShowPreferences: () -> Void = {}

  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      HStack(spacing: 0) {
        listColumn
          .frame(width: 480)
        Divider()
        ClipPreviewView(
          item: selectedItem,
          thumbnailLoader: thumbnailLoader,
          resolver: resolver
        )
        .frame(width: 239)
      }
    }
    .frame(width: 720, height: 491)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
    )
    .background(keyboardShortcutButtons)
    .onAppear { searchFocused = true }
    .onChange(of: viewModel.currentTab) { _ in
      viewModel.resetSelection()
    }
    .onChange(of: viewModel.kindFilter) { _ in
      viewModel.realignAfterFilterChange()
    }
  }

  private var listColumn: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        tabBar
        KindChipBar(
          selection: $viewModel.kindFilter,
          count: { viewModel.kindChipCount(for: $0) }
        )
      }
      .frame(height: 64)
      Divider()
      if let skip = viewModel.lastSkip, viewModel.shouldShowLastSkip() {
        SkipBannerView(skip: skip) {
          viewModel.clearLastSkip()
        }
      }
      if viewModel.filteredItems.isEmpty {
        emptyState
      } else {
        list
      }
    }
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
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
    )
    .padding(10)
  }

  private var tabBar: some View {
    Picker("", selection: $viewModel.currentTab) {
      (Text("All") + Text(verbatim: " (\(viewModel.allTabCount))"))
        .tag(HistoryPanelTab.all)
      (Text("Pinned") + Text(verbatim: " (\(viewModel.pinnedTabCount))"))
        .tag(HistoryPanelTab.pinned)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 10)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .accessibilityLabel("Tab")
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(viewModel.filteredItems) { item in
            ClipRowView(
              item: item,
              isSelected: viewModel.selectedID == item.id,
              thumbnailLoader: thumbnailLoader
            )
            .id(item.id)
            .onTapGesture {
              viewModel.selectedID = item.id
              onActivate(item)
            }
            .contextMenu {
              Button(
                LocalizedStringKey(item.pinned ? "Unpin" : "Pin")
              ) { onTogglePin(item) }
              Divider()
              Button("Delete", role: .destructive) { onDelete(item) }
            }
            .accessibilityLabel(accessibilityLabel(for: item))
            .accessibilityAddTraits(
              viewModel.selectedID == item.id ? .isSelected : []
            )
          }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
      }
      .onChange(of: viewModel.scrollEpoch) { _ in
        if let id = viewModel.filteredItems.first?.id {
          withAnimation(nil) { proxy.scrollTo(id, anchor: .top) }
        }
      }
      .onChange(of: viewModel.selectedID) { newID in
        if let newID { withAnimation(nil) { proxy.scrollTo(newID, anchor: .center) } }
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

  private var emptyStateText: LocalizedStringKey {
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
      Button("") { deleteSelected() }
        .keyboardShortcut(.delete, modifiers: .command)
        .hidden()
      Button("") { togglePinSelected() }
        .keyboardShortcut("p", modifiers: .command)
        .hidden()
      Button("") { onShowPreferences() }
        .keyboardShortcut(",", modifiers: .command)
        .hidden()
      Button("") { viewModel.cycleTab(forward: false) }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .hidden()
      Button("") { viewModel.cycleTab(forward: true) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .hidden()
      Button("") { viewModel.kindFilter = nil }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { viewModel.kindFilter = .text }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
      Button("") { viewModel.kindFilter = .image }
        .keyboardShortcut("3", modifiers: .command)
        .hidden()
      Button("") { viewModel.kindFilter = .file }
        .keyboardShortcut("4", modifiers: .command)
        .hidden()
      Button("") { viewModel.kindFilter = .rtf }
        .keyboardShortcut("5", modifiers: .command)
        .hidden()
      Button("") { viewModel.kindFilter = .mixed }
        .keyboardShortcut("6", modifiers: .command)
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

  private func accessibilityLabel(for item: ClipItem) -> String {
    var parts: [String] = [item.preview.isEmpty ? "empty" : item.preview]
    parts.append("kind \(item.kind.rawValue)")
    if item.pinned { parts.append("pinned") }
    if item.sensitive { parts.append("sensitive") }
    return parts.joined(separator: ", ")
  }
}
