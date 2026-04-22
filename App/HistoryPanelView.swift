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
      Divider()
      footerBar
    }
    .frame(width: 680, height: 520)
    .background(.regularMaterial)
    .background(keyboardShortcutButtons)
    .onAppear { searchFocused = true }
    .onChange(of: viewModel.currentTab) { _ in
      viewModel.resetSelection()
    }
    .onChange(of: viewModel.kindFilter) { _ in
      viewModel.realignAfterFilterChange()
    }
  }

  private var footerBar: some View {
    HStack(spacing: 14) {
      ShortcutHint(keys: "↑↓", label: "Select")
      ShortcutHint(keys: "↵", label: "Copy")
      ShortcutHint(keys: "⌘P", label: "Pin")
      ShortcutHint(keys: "⌘⌫", label: "Delete")
      Spacer(minLength: 0)
      ShortcutHint(keys: "⌘,", label: "Preferences")
      ShortcutHint(keys: "Esc", label: "Close")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(height: 28)
    .background(Color.primary.opacity(0.04))
  }

  private var listColumn: some View {
    VStack(spacing: 0) {
      searchField
      tabBar
      KindChipBar(selection: $viewModel.kindFilter)
      if let skip = viewModel.lastSkip, viewModel.shouldShowLastSkip() {
        SkipBannerView(skip: skip) {
          viewModel.clearLastSkip()
        }
      }
      Divider()
      if viewModel.filteredItems.isEmpty {
        emptyState
      } else {
        list
      }
    }
    .frame(width: 420)
    .background(Color.primary.opacity(0.04))
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
