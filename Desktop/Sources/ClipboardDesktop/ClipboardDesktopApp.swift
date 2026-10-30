import ClipboardCore
import Foundation
import GtkBackend
import SwiftCrossUI

struct ClipboardDesktopApp: App {
  var backend: GtkBackend {
    let profile = DesktopApplicationContext.profile
    return GtkBackend(
      appIdentifier: profile == "production"
        ? "com.clipboard.desktop" : "com.clipboard.desktop.p" + String(profile.prefix(24)))
  }
  var body: some Scene {
    WindowGroup("Clipboard") {
      if DesktopApplicationContext.startupFailed {
        VStack(spacing: 16) {
          Text("Clipboard could not safely open this profile.")
          Text("Close another instance or check the desktop session, then try again.")
          Button("Quit") { exit(1) }
        }.padding(24)
      } else if CommandLine.arguments.contains("--ui-baseline") {
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
  @Environment(\.chooseFile) var chooseFile
  @Environment(\.chooseFileSaveDestination) var chooseSaveDestination

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
    .inspectWindow { model.attachWindow($0) }
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
      Button(model.recording ? "Pause recording" : "Start recording") {
        Task { @MainActor in await model.toggleRecording() }
      }.disabled(!model.ready || model.recordingTransition)
      if model.canHide { Button("Hide") { model.hide() } }
      Button("Settings") { model.showPreferences() }
    }
  }

  var history: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField("Search history", text: $model.query)
        .inspect { model.attachSearch($0) }
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
      HStack(spacing: 8) {
        Button("All types") {
          model.kindFilter = nil
          Task { @MainActor in await model.refresh() }
        }
        ForEach(ClipKind.allCases.filter { $0 != .mixed }, id: \.self) { kind in
          Button(kind.rawValue.capitalized) {
            model.kindFilter = kind
            Task { @MainActor in await model.refresh() }
          }
        }
      }
      TextField("Source app ID (optional)", text: $model.sourceFilter)
        .onChange(of: model.sourceFilter) { Task { @MainActor in await model.refresh() } }
      Divider()
      HStack(alignment: .top, spacing: 20) {
        ScrollView {
          List(model.items, selection: $model.selectedID) { item in
            VStack(alignment: .leading, spacing: 7) {
              Text(item.sensitive ? "Sensitive content" : item.preview)
                .lineLimit(2)
              Text((item.pinned ? "Pinned · " : "") + item.kind.rawValue.capitalized)
                .font(.system(size: 12)).foregroundColor(.gray)
            }.padding(10)
          }
        }.frame(minWidth: 300, maxWidth: 340, minHeight: 280)
        Divider()
        preview.frame(minWidth: 340, maxWidth: .infinity, minHeight: 280)
      }
    }
  }

  var preview: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Preview").font(.system(size: 18))
      if let source = model.selected?.sourceBundleID {
        Text("Source: " + source).font(.system(size: 12)).foregroundColor(.gray)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let image = model.previewImage {
            DesktopImagePreview(image: image).frame(
              minWidth: 250, maxWidth: .infinity, minHeight: 180, maxHeight: 240)
          }
          Text(model.previewText).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.frame(minHeight: 180, maxHeight: 220)
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

  var contentSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("History capacity (1–5000)")
      TextField("100", text: $model.capacityDraft)
      Text("Maximum clipboard item (MiB, 1–16)")
      TextField("10", text: $model.maxSizeDraft)
      Toggle("Mark blocked source apps as sensitive", isOn: $model.blocklistEnabledDraft)
      TextField("Blocked app IDs, separated by commas", text: $model.blockedAppsDraft)
      Button("Save content settings") {
        Task { @MainActor in await model.applyContentSettings() }
      }
      Button("Export history") {
        Task { @MainActor in
          if let destination = await chooseSaveDestination(
            title: "Export history", defaultFileName: "clipboard-history.clipboard.json")
          {
            await model.exportHistory(to: destination)
          }
        }
      }
      if model.confirmsClearHistory {
        Text("Delete all history, including pinned items?")
        HStack {
          Button("Delete all history") { Task { @MainActor in await model.clearHistory() } }
          Button("Cancel") { model.confirmsClearHistory = false }
        }
      } else {
        Button("Clear history") { model.confirmsClearHistory = true }
      }
      Button("Import history") {
        Task { @MainActor in
          if let source = await chooseFile(title: "Import history") {
            await model.importHistory(from: source)
          }
        }
      }
    }
  }

  var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Preferences").font(.system(size: 22))
        Spacer()
        Button("Back to history") { Task { @MainActor in await model.showHistory() } }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("History stays on this device. Sensitive items stay in memory.")
          contentSettings
          Text("Recording: \(model.recording ? "On" : "Paused")")
          Toggle("Enable global shortcut", isOn: $model.shortcutEnabledDraft)
          TextField("Ctrl+Alt+V", text: $model.shortcutDraft)
          Button("Apply shortcut") { Task { @MainActor in await model.applyShortcut() } }
          Toggle("Keep running when closing the window", isOn: $model.closeToTrayDraft)
          Toggle("Show history when starting", isOn: $model.showOnLaunchDraft)
          Toggle("Record when starting", isOn: $model.recordOnLaunchDraft)
          Button("Save behavior") { Task { @MainActor in await model.applyBehavior() } }
          if !model.shellStatus.isEmpty { Text(model.shellStatus).lineLimit(3) }
          Button("Quit Clipboard") { Task { @MainActor in await model.shutdown() } }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
      }.frame(minHeight: 320, maxHeight: 360)
    }.frame(maxWidth: .infinity, alignment: .topLeading)
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
