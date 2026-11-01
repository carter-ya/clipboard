import ClipboardCore
import Foundation
import GtkBackend
import SwiftCrossUI

@main
struct ClipboardDesktopApp: App {
  var body: some Scene {
    WindowGroup("Clipboard") {
      if CommandLine.arguments.contains("--ui-baseline") {
        BaselineView()
      } else {
        HistoryView()
      }
    }
    .defaultSize(width: 960, height: 640)
  }
}

struct HistoryView: View {
  @State var model = HistoryModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if model.showsSettings {
        settings
      } else {
        history
      }
      Spacer()
      Divider()
      HStack {
        Text(model.status).foregroundColor(.gray)
        Spacer()
        Text("Local history").foregroundColor(.gray)
      }
    }
    .padding(24)
    .task { await model.load() }
    .onChange(of: model.selectedID) { Task { @MainActor in await model.loadPreview() } }
  }

  var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Clipboard").font(.system(size: 26))
        Text("Your clipboard history, on this device.").foregroundColor(.gray)
      }
      Spacer()
      Button("Settings") { model.showsSettings = true }
    }
  }

  var history: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField("Search history", text: $model.query)
        .onChange(of: model.query) { Task { @MainActor in await model.refresh() } }
      HStack(spacing: 10) {
        Button("All") {
          model.onlyPinned = false
          Task { @MainActor in await model.refresh() }
        }
        Button("Pinned") {
          model.onlyPinned = true
          Task { @MainActor in await model.refresh() }
        }
        Spacer()
        Text("\(model.items.count) items").foregroundColor(.gray)
      }
      Divider()
      HStack(alignment: .top, spacing: 20) {
        ScrollView {
          List(model.items, selection: $model.selectedID) { item in
            VStack(alignment: .leading, spacing: 7) {
              Text(item.sensitive ? "Sensitive content" : item.preview)
                .lineLimit(2)
              Text(item.pinned ? "Pinned · Text" : "Text")
                .font(.system(size: 12)).foregroundColor(.gray)
            }.padding(10)
          }
        }.frame(minWidth: 300, maxWidth: 340, minHeight: 350)
        Divider()
        preview.frame(minWidth: 340, maxWidth: .infinity, minHeight: 350)
      }
    }
  }

  var preview: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Preview").font(.system(size: 18))
      ScrollView {
        Text(model.previewText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 220)
      HStack(spacing: 10) {
        Button("Copy") { Task { @MainActor in await model.copySelected() } }.disabled(
          model.selected == nil)
        Button("Pin / unpin") { Task { @MainActor in await model.togglePin() } }
          .disabled(model.selected == nil)
        Button("Delete") { Task { @MainActor in await model.deleteSelected() } }
          .disabled(model.selected == nil)
      }
      Text("Copy here, then paste in your app.")
        .font(.system(size: 12)).foregroundColor(.gray)
    }
  }

  var settings: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Preferences").font(.system(size: 22))
      Text("History stays on this device. Sensitive items stay in memory.")
      Text("History capacity: 100 items")
      Text("Clipboard recording starts only when you enable it.")
      Button(model.recording ? "Pause recording" : "Start recording") { model.toggleRecording() }
        .disabled(!model.ready)
      Button("Back to history") { model.showsSettings = false }
    }.frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
  }
}

/// Isolates backend/window/control startup from asynchronous Core history updates.
struct BaselineView: View {
  @State var count = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("SwiftCrossUI baseline").font(.system(size: 24))
      Text("Counter: \(count)")
      Button("Increment") { count += 1 }
    }.padding(24)
  }
}
