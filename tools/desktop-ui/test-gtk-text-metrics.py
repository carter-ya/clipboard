#!/usr/bin/env python3
"""Compare the actual patched GTK sizing method with its pinned implementation."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def method(source):
    start = source.index('    public func size(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('public func', 'func', 1)


DRIVER = r'''
import Foundation
import CGtk
enum EllipsizeMode {
  case none, end
  func toGtk() -> PangoEllipsizeMode { self == .none ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END }
}
class Widget {
  let widgetPointer: UnsafeMutablePointer<GtkWidget>
  let provider: UnsafeMutablePointer<GtkCssProvider>
  let style: String
  static var next = 0
  init() {
    Self.next += 1; style = "private-metric-\(Self.next)"
    widgetPointer = gtk_label_new("")!
    _ = g_object_ref_sink(widgetPointer)
    provider = gtk_css_provider_new()!
    gtk_widget_add_css_class(widgetPointer, style)
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), 800)
  }
  func font(_ size: Int) {
    let css = ".\(style) { font-family: sans-serif; font-size: \(size)px; }"
    gtk_css_provider_load_from_data(provider, css, -1)
  }
  deinit {
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), OpaquePointer(provider))
    g_object_unref(provider); g_object_unref(widgetPointer)
  }
}
final class CustomLabel: Widget { var ellipsize: EllipsizeMode = .end }
final class TextView: Widget {}
struct LineLimit { var limit: Int; var reservesSpace: Bool }
struct EnvironmentValues { var fontSize: Int; var lineLimitSettings: LineLimit? }
struct Logger { func warning(_ message: String) {} }
final class Backend {
  let logger = Logger()
  let measurementCustomLabel = CustomLabel()
  var styleReloads = 0
  func updateTextView(_ widget: CustomLabel, content: String, environment: EnvironmentValues) {
    styleReloads += 1
    widget.font(environment.fontSize)
  }
__CURRENT__
__REFERENCE__
}
__PANGO__
gtk_init()
let backend = Backend(), label = CustomLabel()
var cases = 0, mismatches = 0, repeatedStyleLoads = 0
for font in [10, 16, 24] {
  label.font(font)
  for text in ["Short", "One line\nTwo lines\nThree lines", "中文与 English 混排测试", String(repeating: "longword", count: 12)] {
    for width: Int? in [nil, 1, 80, 300] {
      for height: Int? in [nil, 20, 70] {
        for limit: LineLimit? in [nil, LineLimit(limit: 1, reservesSpace: false), LineLimit(limit: 2, reservesSpace: false), LineLimit(limit: 2, reservesSpace: true)] {
          let environment = EnvironmentValues(fontSize: font, lineLimitSettings: limit)
          let reference = backend.referenceSize(of: text, whenDisplayedIn: label, proposedWidth: width, proposedHeight: height, environment: environment)
          backend.styleReloads = 0
          let actual = backend.size(of: text, whenDisplayedIn: label, proposedWidth: width, proposedHeight: height, environment: environment)
          if actual != reference { mismatches += 1 }
          repeatedStyleLoads += backend.styleReloads
          cases += 1
        }
      }
    }
  }
}
let report: [String: Any] = ["passed": mismatches == 0 && repeatedStyleLoads == 0 && cases == 576,
  "cases": cases, "geometryMismatches": mismatches, "sharedMeasurementStyleReloads": repeatedStyleLoads]
let result = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: result, encoding: .utf8)!)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', type=Path, default=ROOT / 'Desktop/.build/checkouts/swift-cross-ui')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    pin = next(p for p in json.loads((ROOT / 'Desktop/Package.resolved').read_text())['pins']
               if p['identity'] == 'swift-cross-ui')['state']['revision']
    revision = subprocess.check_output(['git', '-C', str(args.checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != pin:
        raise RuntimeError('Text metrics require the pinned backend')
    path = 'Sources/GtkBackend/Features/TextViews.swift'
    reference = subprocess.check_output(['git', '-C', str(args.checkout), 'show', pin + ':' + path], text=True)
    current = (args.checkout / path).read_text()
    pango = (args.checkout / 'Sources/Gtk/Utility/Pango.swift').read_text().replace('public ', '')
    source = DRIVER.replace('__CURRENT__', method(current)).replace(
        '__REFERENCE__', method(reference).replace('func size(', 'func referenceSize(', 1)).replace('__PANGO__', pango)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'gtk4'], text=True))
    libs = shlex.split(subprocess.check_output(['pkg-config', '--libs', 'gtk4'], text=True))
    header = next(Path(flag[2:]) / 'gtk/gtk.h' for flag in flags
                  if flag.startswith('-I') and (Path(flag[2:]) / 'gtk/gtk.h').is_file())
    with tempfile.TemporaryDirectory(prefix='clipboard-text-metrics-') as directory:
        folder = Path(directory)
        (folder / 'module.modulemap').write_text('module CGtk [system] { header "' + header.as_posix() + '" export * }\n')
        (folder / 'main.swift').write_text(source, encoding='utf-8')
        binary = folder / ('probe.exe' if os.name == 'nt' else 'probe')
        command = ['swiftc', '-swift-version', '5', '-module-cache-path', str(folder/'modules'),
                   '-I', str(folder), str(folder/'main.swift'), '-o', str(binary)]
        for flag in flags:
            command.extend(['-Xcc', flag])
        subprocess.run(command + libs, check=True, timeout=90)
        result = subprocess.run([str(binary)], capture_output=True, text=True, encoding='utf-8', check=True, timeout=30)
        report = json.loads(result.stdout)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
        if not report['passed']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
