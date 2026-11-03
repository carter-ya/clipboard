#!/usr/bin/env python3
"""Run the real search attachment/submit closure through pinned backend updates."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end], source[opening + 1:end - 1]


parser = argparse.ArgumentParser()
parser.add_argument('--checkout', type=Path, default=ROOT / 'Desktop/.build/checkouts/swift-cross-ui')
args = parser.parse_args()
pin = next(p for p in json.loads((ROOT / 'Desktop/Package.resolved').read_text(encoding='utf-8'))['pins']
           if p['identity'] == 'swift-cross-ui')
revision = subprocess.check_output(['git', '-C', str(args.checkout), 'rev-parse', 'HEAD'], text=True).strip()
if revision != pin['state']['revision']:
    raise RuntimeError('Search regression requires the actual pinned backend checkout')
backend = (args.checkout / 'Sources/GtkBackend/Features/TextFields.swift').read_text(encoding='utf-8')
update, _ = block(backend, '    public func updateTextField(')
model = (ROOT / 'Desktop/Sources/ClipboardDesktop/HistoryModel.swift').read_text(encoding='utf-8')
attach, _ = block(model, '  @MainActor func attachSearch(')
view = (ROOT / 'Desktop/Sources/ClipboardDesktop/ClipboardDesktopApp.swift').read_text(encoding='utf-8')
search = view[view.index('TextField(model.t("Search history")'):]
search = search[:search.index('.onChange(of: model.query)')]
submit = 'nil'
if '.onSubmit' in search:
    _, body = block(search, '.onSubmit')
    submit = '{' + body + '}'

fixture = r'''
import Foundation
@MainActor final class Entry {
  var activate: ((Entry) -> Void)?
  var changed: ((Entry) -> Void)?
  var sensitive = true
  var placeholderText = ""
  var text = ""
  let css = CSS()
}
@MainActor final class CSS {
  func clear() {}
  func set(properties: [String: String], clear: Bool = false) {}
}
enum Gtk { typealias Entry = __Entry }
typealias __Entry = Entry
typealias Widget = AnyObject
struct EnvironmentValues { var isEnabled = true }
@MainActor final class GtkBackend {
  static func cssProperties(for environment: EnvironmentValues, isControl: Bool) -> [String: String] { [:] }
__UPDATE__
}
@MainActor final class NativeWindow {
  func attachSearch(_ entry: Entry) {}
}
@MainActor final class Model {
  var searchEntry: Entry?
  let nativeWindow: NativeWindow? = NativeWindow()
  var selectedID: UUID?
  var activated: [UUID] = []
  func activateHistoryItem(id: UUID) async { activated.append(id) }
__ATTACH__
}
@main struct Probe {
  @MainActor static func main() async {
    let model = Model()
    let entry = Entry()
    let backend = GtkBackend()
    model.attachSearch(entry)
    let onSubmit: (() -> Void)? = __SUBMIT__
    for index in 0..<3 {
      let selected = UUID()
      model.selectedID = selected
      entry.text = "synthetic-query-\(index)"
      // The actual pinned backend replaces activate on every view update.
      backend.updateTextField(entry, placeholder: "Search", environment: EnvironmentValues(),
                              onChange: { _ in }, onSubmit: onSubmit ?? {})
      entry.activate?(entry)
      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      while model.activated.count < index + 1 && ContinuousClock.now < deadline { await Task.yield() }
      guard model.activated.count == index + 1, model.activated.last == selected else {
        fatalError("search_submit_lost_after_backend_update")
      }
    }
    model.selectedID = nil
    backend.updateTextField(entry, placeholder: "Search", environment: EnvironmentValues(),
                            onChange: { _ in }, onSubmit: onSubmit ?? {})
    entry.activate?(entry)
    for _ in 0..<100 { await Task.yield() }
    guard model.activated.count == 3, model.searchEntry === entry else {
      fatalError("search_submit_used_stale_selection_or_replaced_editor")
    }
    print("Actual search submit survives repeated backend updates and reads current selection")
  }
}
'''.replace('__UPDATE__', update).replace('__ATTACH__', attach).replace('__SUBMIT__', submit)
with tempfile.TemporaryDirectory(prefix='clipboard-search-submit-') as directory:
    source = Path(directory) / 'probe.swift'
    executable = Path(directory) / ('probe.exe' if sys.platform == 'win32' else 'probe')
    source.write_text(fixture, encoding='utf-8')
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(Path(directory) / 'modules'),
                    '-parse-as-library', str(source), '-o', str(executable)],
                   check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=10)
