import ClipboardCore
import SwiftCrossUI

extension HistoryView {
  var desktopModelSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.t("Local text models")).font(.system(size: 18))
      Text(
        model.t("Models run on this device. Downloading them does not upload clipboard content.")
      )
      .desktopCaption()
      modelCard(.generative)
      modelCard(.entities)
      Button(model.t("Verify local models")) { model.refreshModels() }
        .disabled(!model.ready || model.modelWorkBusy)
      Text(model.t("Downloads continue while Clipboard is running. Quitting cancels the download."))
        .desktopCaption()
    }
  }
  func modelCard(_ kind: DesktopModelKind) -> some View {
    let asset = model.modelAssets[kind]
    let state = model.modelAssetStates[kind] ?? .init(status: .missing, installed: false)
    let summary = kind == .generative
    let download = summary ? "Download summary model" : "Download names model"
    let importTitle = summary ? "Import summary model" : "Import names model"
    return VStack(alignment: .leading, spacing: 8) {
      Text(model.t(summary ? "Summary model" : "Language and names"))
        .font(.system(size: 16))
      Text(
        model.t(
          summary
            ? "Creates a one-sentence summary. Requires a supported processor and sufficient memory."
            : "Language detection is included. Add this model to recognize people, organizations and places."
        )
      )
      .desktopCaption()
      if let asset {
        Text("\((asset.size + 999999) / 1_000_000) MB · \(asset.license)")
        Button(model.t(summary ? "Read summary model license" : "Read names model license")) {
          openURL(model.modelLicenseURL(kind) ?? asset.licenseURL)
        }
        if !summary {
          Toggle(
            model.t("I agree to the names model license"), isOn: $model.entityModelLicenseAccepted
          )
          .disabled(model.modelWorkBusy)
        }
      }
      Text(model.t(modelStatusMessage(state.status))).lineLimit(3)
      if case .downloading(let received, let total) = state.status {
        Text("\(received / 1_000_000) / \((total + 999999) / 1_000_000) MB")
      }
      if model.modelAssetSupport[kind] == false {
        Text(model.t("This local model is unavailable on this computer."))
          .desktopCaption()
      }
      VStack(alignment: .leading, spacing: 6) {
        Button(model.t(download)) { model.installModel(kind) }
          .disabled(model.modelWorkBusy || !model.canInstallModel(kind))
        Button(model.t(importTitle)) {
          Task { @MainActor in
            guard model.beginModelImport(kind) else { return }
            let source = await chooseFile(
              title: model.t(importTitle), initialDirectory: modelImportDirectory)
            if let source { modelImportDirectory = source.deletingLastPathComponent() }
            model.finishModelImport(kind, from: source)
          }
        }.disabled(model.modelWorkBusy || !model.canInstallModel(kind))
      }
      HStack {
        Button(model.t(summary ? "Remove summary model" : "Remove names model")) {
          model.removeModel(kind)
        }
        .disabled(!model.ready || model.modelWorkBusy)
        if modelOperationCanCancel(state.status) {
          Button(model.t("Cancel")) { model.cancelModel(kind) }
        }
      }
      if state.installed, case .failed = state.status {
        Text(model.t("The previously verified model is still available."))
          .desktopCaption()
      }
      Divider()
    }
  }
  private func modelOperationCanCancel(_ status: DesktopModelAssetStatus) -> Bool {
    switch status {
    case .checking, .downloading, .verifying: return true
    default: return false
    }
  }
  private func modelStatusMessage(_ status: DesktopModelAssetStatus) -> String {
    switch status {
    case .missing: return "Model not installed"
    case .checking: return "Checking model files…"
    case .downloading: return "Downloading model…"
    case .verifying: return "Verifying model…"
    case .ready: return "Model ready"
    case .cancelling: return "Cancelling model operation…"
    case .removing: return "Removing model files…"
    case .failed(.digestMismatch), .failed(.wrongSize):
      return "Model verification failed. Choose the original file or download again."
    case .failed(.licenseNotAccepted): return "Please accept the model license first."
    case .failed(.insufficientSpace): return "There is not enough free disk space for this model."
    case .failed(.invalidLocation): return "Model files are not in a supported location."
    case .failed: return "The model operation failed. Please try again."
    }
  }
}
