import ClipboardCore
import Foundation

/// Per-clip ephemeral state owned by the App layer (UI affordance,
/// not a data-model concept). `SummaryCoordinator` emits
/// `SummaryProgressEvent`s which the panel VM folds into a
/// `[UUID: SummaryProgress]` dictionary; the preview pane reads that
/// dictionary to render a "Summarising…" placeholder while the
/// engine waterfall runs and a "Couldn't generate summary" + Retry
/// affordance once every engine has been exhausted. State is not
/// persisted — restart wipes both the dictionary and the in-flight
/// guard, and clips with `summary == nil` after restart simply have
/// a clean preview.
enum SummaryProgress: Equatable, Sendable {
  case inProgress(engine: SummarySource)
  case failed
}

enum SummaryProgressEvent: Sendable {
  case started(id: UUID, engine: SummarySource)
  case finished(id: UUID)
  case failed(id: UUID)
}
