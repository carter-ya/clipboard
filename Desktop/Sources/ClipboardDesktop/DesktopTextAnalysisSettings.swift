import SwiftCrossUI

extension HistoryView {
  var optionalTextAnalysisSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        model.t("Enable local generated summaries"), isOn: $model.localGenerativeSummariesDraft)
      Toggle(
        model.t("Automatically generate local summaries"),
        isOn: $model.automaticLocalGenerativeSummariesDraft
      ).disabled(!model.localGenerativeSummariesDraft)
      Toggle(model.t("Enable local language and names"), isOn: $model.localLanguageSummariesDraft)
      Toggle(
        model.t("Automatically identify language and names"),
        isOn: $model.automaticLocalLanguageSummariesDraft
      ).disabled(!model.localLanguageSummariesDraft)
      Text(
        model.t(
          "Uses installed local models only. Summary weights are required for generation; names require the optional licensed model. Language detection works without those weights."
        )
      ).desktopCaption()
      Text(
        model.t(
          "Tries permitted engines in order: configured AI, local generation, language and names, then excerpt. Each automatic engine needs its own permission."
        )
      ).desktopCaption()
    }
  }
}
