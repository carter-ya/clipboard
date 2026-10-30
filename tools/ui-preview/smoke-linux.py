#!/usr/bin/env python3
"""Exercise accessible GTK controls in an isolated Xvfb/DBus desktop, no key injection."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

import pyatspi

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
history_root = out / ('history-' + uuid.uuid4().hex)
app = None
wm = None
log = open(out / 'application.log', 'w')


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    if not condition:
        raise RuntimeError(name)


def wait_for(predicate, name, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if app and app.poll() is not None:
            raise RuntimeError('application_exited')
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(0.15)
    raise RuntimeError(name)


def walk(node, depth=0):
    if depth > 25:
        return
    yield node
    try:
        for child in node:
            if child:
                yield from walk(child, depth + 1)
    except Exception:
        return


def root():
    for candidate in pyatspi.Registry.getDesktop(0):
        try:
            if candidate.get_process_id() == app.pid or 'ClipboardPreview' in candidate.name:
                return candidate
        except Exception:
            continue
    return None


def nodes():
    current = root()
    return list(walk(current)) if current else []


def has_text(text):
    for node in nodes():
        try:
            if node.name == text:
                return True
            if 'Text' in node.get_interfaces() and node.queryText().getText(0, -1) == text:
                return True
        except Exception:
            continue
    return False


def button(label):
    for node in nodes():
        try:
            if node.name == label and node.getRole() == pyatspi.ROLE_PUSH_BUTTON:
                return node
        except Exception:
            continue
    return None


def click(label):
    control = wait_for(lambda: button(label), 'button_' + label)
    if not control.queryAction().doAction(0):
        raise RuntimeError('invoke_' + label)


def editor():
    for node in nodes():
        try:
            if 'EditableText' in node.get_interfaces():
                return node
        except Exception:
            continue
    return None


def screenshot(name):
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    for line in tree.splitlines():
        if '"Clipboard Preview"' in line:
            window = line.strip().split()[0]
            subprocess.run(['import', '-window', window, str(out / name)], check=True, timeout=10)
            return
    raise RuntimeError('window_for_screenshot')


try:
    wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('3 items'), 'initial_history')
    check('native_window_and_history_visible', True)
    screenshot('history.png')
    edit = wait_for(editor, 'search_editable_control')
    edit.queryComponent().grabFocus()
    wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'programmatic_search_focus')
    check('native_search_control_focus', True)
    click('Copy')
    wait_for(lambda: has_text('Copied to clipboard'), 'copy_status')
    clipboard = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=10)
    check('copy_button_writes_native_clipboard', clipboard.decode('utf-8') == 'Release checklist · build, test, publish')
    wait_for(editor, 'search_editable_control').queryEditableText().setText('中文')
    wait_for(lambda: has_text('1 items') and has_text('中文笔记 · 设计评审与输入测试'), 'unicode_search_results')
    check('native_unicode_search_updates_list', True)
    screenshot('unicode-search.png')
    click('Pin / unpin')
    wait_for(lambda: has_text('Item pinned'), 'pin_status')
    click('Pinned')
    wait_for(lambda: has_text('1 items'), 'pinned_filter')
    check('pin_and_pinned_filter', True)
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'settings_view')
    screenshot('settings.png')
    click('Back to history')
    wait_for(lambda: has_text('1 items') and editor(), 'history_restored')
    check('settings_round_trip_preserves_search', editor().queryText().getText(0, -1) == '中文')
    click('Delete')
    wait_for(lambda: has_text('Item deleted') and has_text('0 items'), 'delete_in_pinned_list')
    check('delete_updates_real_store', True)
    click('All')
    wait_for(editor, 'search_after_delete').queryEditableText().setText('')
    wait_for(lambda: has_text('2 items'), 'remaining_history')
    history = json.loads((history_root / 'history.json').read_text())
    check('store_persistence_matches_ui', len(history['items']) == 2)
except Exception as error:
    checks.append({'name': 'ui_probe', 'passed': False, 'detail': str(error)[:160]})
    try:
        screenshot('failure.png')
    except Exception:
        pass
finally:
    if app and app.poll() is None:
        os.killpg(app.pid, signal.SIGTERM)
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(app.pid, signal.SIGKILL)
            app.wait(timeout=5)
    if wm and wm.poll() is None:
        wm.terminate()
        wm.wait(timeout=5)
    log.close()
    report = {'platform': 'linux-gtk4', 'passed': bool(checks) and all(c['passed'] for c in checks),
              'checks': checks, 'limitations': ['No keyboard injection; programmatic accessibility control operations only.',
                                               'Real Chinese IME composition and global hotkey focus transfer remain untested.']}
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
