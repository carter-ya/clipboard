#!/usr/bin/env python3
"""Installed Linux system-language UI check using only an owned synthetic profile."""
import argparse
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', required=True)
parser.add_argument('--catalog', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
if shutil.which('swift'):
    raise RuntimeError('Use the runtime-only image')
package = Path(args.package).resolve()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
catalog = json.loads(Path(args.catalog).read_text(encoding='utf-8'))['zh-Hans']
checks = []
completed = False
app = None
wm = None


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    if not condition:
        raise RuntimeError(name)


def wait_for(predicate, name, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if app and app.poll() is not None:
            raise RuntimeError('owned_application_exited')
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(.1)
    raise RuntimeError(name)


profile_directory = tempfile.TemporaryDirectory(prefix='clipboard-system-ui-')
try:
    root = Path(profile_directory.name)
    profile = root / 'profile'
    profile.mkdir()
    home = root / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / 'data'),
               XDG_CONFIG_HOME=str(home / 'config'), GSETTINGS_BACKEND='memory',
               LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='zh_CN:zh',
               GTK_A11Y='atspi', GDK_BACKEND='x11')
    installed = root / 'installed 中文'
    subprocess.run(['/usr/bin/python3', str(package / 'install.py'), '--prefix', str(installed),
                    '--applications-dir', str(home / 'data/applications'),
                    '--bin-dir', str(home / 'bin'), '--config-home', str(home / 'config')],
                   env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    body = ('Apple Inc. CEO Tim Cook met officials in Tokyo to discuss the company investment. '
            'The meeting focused on the research center and jobs for local engineers.')
    item = dict(id=str(uuid.uuid4()), createdAt='2023-11-14T22:13:20Z', kind='text',
                preview=body, pinned=False, sensitive=False, sha256=hashlib.sha256(body.encode()).hexdigest(),
                sizeBytes=len(body.encode()), payloads=[dict(pasteboardType='public.utf8-plain-text',
                inlineData=base64.b64encode(body.encode()).decode())])
    history = profile / 'history.json'
    history.write_text(json.dumps(dict(version=1, items=[item])), encoding='utf-8')
    settings = dict(languageOverride=None, localLanguageSummariesEnabled=True, shortcutEnabled=False,
                    closeToTray=False, recordingEnabled=False)
    (profile / 'desktop-settings.json').write_text(json.dumps(settings), encoding='utf-8')
    wm = subprocess.Popen(['openbox'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = subprocess.Popen([str(installed / 'bin/ClipboardDesktop'), '--data-root', str(profile)],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import pyatspi

    def walk(node, depth=0):
        if depth > 60:
            return
        try:
            node.clearCache()
        except Exception:
            pass
        yield node
        try:
            for child in node:
                if child:
                    yield from walk(child, depth + 1)
        except Exception:
            return

    def nodes():
        for candidate in pyatspi.Registry.getDesktop(0):
            try:
                if candidate.get_process_id() == app.pid:
                    return list(walk(candidate))
            except Exception:
                pass
        return []

    def visible_text(value):
        for node in nodes():
            try:
                if node.name == value or ('Text' in node.get_interfaces() and
                        node.queryText().getText(0, node.queryText().characterCount) == value):
                    return True
            except Exception:
                pass
        return False

    def press(key):
        label = catalog.get(key, key)
        def button():
            for node in nodes():
                try:
                    if node.name != label:
                        continue
                    for _ in range(10):
                        if node.getRole() == pyatspi.ROLE_PUSH_BUTTON:
                            return node
                        node = node.parent
                        if node is None:
                            break
                except Exception:
                    pass
            return None
        control = wait_for(button, 'owned_translated_button')
        check('native_translated_control_' + key.lower().replace(' ', '_'), control.queryAction().doAction(0))

    wait_for(lambda: visible_text(catalog['Ready']) and visible_text(catalog['Settings']), 'system_chinese_labels')
    check('system_priority_localizes_installed_ui_without_override', True)
    baseline = json.loads(history.read_text())['items'][0]
    press('Summarize locally')
    def result():
        value = json.loads(history.read_text())['items'][0]
        return value if value.get('summarySource') == 'localLanguage' else None
    analyzed = wait_for(result, 'actual_bundled_language_analysis')
    check('system_priority_localizes_actual_language_name', analyzed['summary'].startswith('英语 · '))
    wait_for(lambda: visible_text(analyzed['summary']) and visible_text(catalog['Summary ready']), 'localized_result_visible')
    check('native_preview_shows_system_localized_result', True)
    # The seeded wire format predates its first store serialization. Compare
    # UUID/date values and complete payload bytes, not formatting/default keys.
    def identity(value):
        return (uuid.UUID(value['id']), datetime.fromisoformat(value['createdAt'].replace('Z', '+00:00')),
                value['kind'], value['preview'], value['sha256'], value['sizeBytes'],
                [(p['pasteboardType'], base64.b64decode(p['inlineData'], validate=True)) for p in value['payloads']])
    check('analysis_preserves_original_record', identity(analyzed) == identity(baseline))
    print(json.dumps({'seed_wire_fields_normalized': [key for key in
          ['id', 'createdAt', 'payloads'] if analyzed[key] != baseline[key]]}))
    check('bundled_language_analysis_creates_no_optional_model_root', not (profile / 'models').exists())
    saved = json.loads((profile / 'desktop-settings.json').read_text())
    check('system_language_and_upload_permissions_remain_unchanged', saved.get('languageOverride') is None
          and not saved.get('ai', {}).get('enabled', False) and not saved.get('localGenerativeSummariesEnabled', False))
    press('Settings')
    wait_for(lambda: visible_text(catalog['Preferences']), 'translated_preferences')
    press('Quit Clipboard')
    app.wait(timeout=10)
    check('owned_installed_application_quits_cleanly', app.returncode == 0)
    completed = True
finally:
    for process in [app, wm]:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    profile_directory.cleanup()
    report = dict(passed=completed and bool(checks) and all(c['passed'] for c in checks), checks=checks)
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
