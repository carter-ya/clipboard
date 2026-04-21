import ClipboardCore
import SwiftUI

struct HistoryPanelView: View {
  @ObservedObject var viewModel: HistoryPanelViewModel
  var onClose: () -> Void = {}
  var onActivate: (ClipItem) -> Void = { _ in }

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      if viewModel.items.isEmpty {
        emptyState
      } else {
        list
      }
    }
    .frame(width: 420, height: 520)
    .background(.regularMaterial)
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
    List(viewModel.items, selection: $viewModel.selectedID) { item in
      ClipRowView(item: item)
        .tag(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onActivate(item) }
    }
    .listStyle(.plain)
    .background(
      Button("") { activateSelected() }
        .keyboardShortcut(.return, modifiers: [])
        .hidden()
    )
  }

  private func activateSelected() {
    if let id = viewModel.selectedID,
      let item = viewModel.items.first(where: { $0.id == id })
    {
      onActivate(item)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      Text(viewModel.searchText.isEmpty ? "No history yet" : "No matches")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
