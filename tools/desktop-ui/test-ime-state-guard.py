#!/usr/bin/env python3
"""Compile the actual fixture authorization without GTK or desktop access."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Desktop/Sources/ClipboardDesktop/DesktopImeStateFixture.swift').read_text()
start = source.index('  nonisolated static func allowed(')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
runner = r'''
var checked = 0
for mask in 0..<32 {
  for profile in ["", "production", "private-fixture"] {
    let windows = mask & 1 != 0
    let actions = mask & 2 != 0
    let hasRoot = mask & 4 != 0
    let smoke = mask & 8 != 0
    let trace = mask & 16 != 0
    var arguments: [String] = []
    if smoke { arguments.append("--smoke-root") }
    if trace { arguments.append("--smoke-ime-state") }
    let actual = Guard.allowed(arguments: arguments, actions: actions,
      windows: windows, hasRoot: hasRoot, profile: profile)
    let expected = mask == 31 && profile == "private-fixture"
    precondition(actual == expected)
    checked += 1
  }
}
print("Actual native-state authorization cases passed: \(checked)")
'''
with tempfile.TemporaryDirectory(prefix='clipboard-ime-guard-') as temporary:
    directory = Path(temporary)
    executable = directory / ('guard.exe' if os.name == 'nt' else 'guard')
    probe = directory / 'main.swift'
    probe.write_text('@MainActor enum Guard {\n' + method + '\n}\n' + runner)
    subprocess.run(['swiftc', '-module-cache-path', str(directory / 'module-cache'),
                    str(probe), '-o', str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=10)
