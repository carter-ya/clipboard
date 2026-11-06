#!/usr/bin/env python3
"""Measure native navigation and verify production startup on a private X11 bus."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
import pyatspi

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
checks, timings = [], []
app = wm = history_counter = None


def check(name, value):
    checks.append(dict(name=name, passed=bool(value)))
    print(name, bool(value), flush=True)
    if not value and not args.baseline:
        raise RuntimeError(name)


def walk(node):
    node.clearCache()
    yield node
    for child in node:
        if child:
            yield from walk(child)


def nodes():
    for root in pyatspi.Registry.getDesktop(0):
        if root.get_process_id() == app.pid:
            yield from walk(root)
            return


def named(name, button=False):
    for node in nodes():
        if node.name == name and (not button or node.getRole() == pyatspi.ROLE_PUSH_BUTTON):
            return node


def wait(predicate):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError('application_exited')
        try:
            result = predicate()
            if result:
                return result
        except Exception:
            pass
        time.sleep(.01)
    raise RuntimeError('expected_ui_missing')


def action(label, expected):
    control = wait(lambda: named(label, True))
    time.sleep(.15)  # Do not include idle settling in the measurement.
    start = time.monotonic()
    assert control.queryAction().doAction(0)
    if expected.endswith(' items') and history_counter is not None:
        def updated_count():
            history_counter.clearCache()
            return history_counter.name == expected
        wait(updated_count)
    else:
        wait(lambda: named(expected))
    elapsed = (time.monotonic() - start) * 1000
    timings.append(dict(action=label, milliseconds=round(elapsed, 2)))


def screenshot(name):
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    windows = [line.strip().split()[0] for line in tree.splitlines() if '"Clipboard":' in line]
    if len(windows) != 1:
        raise RuntimeError('owned_window_not_unique')
    subprocess.run(['import', '-window', windows[0], str(out / name)], check=True)


with tempfile.TemporaryDirectory(prefix='clipboard-interaction-') as directory, \
        open(out / 'application.log', 'w') as log:
    try:
        root = Path(directory)
        fixtures = root / 'fixtures'
        subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('create-preview-fixtures.py')),
                        '--output', str(fixtures)], check=True)
        env = dict(os.environ, GTK_A11Y='atspi', GDK_BACKEND='x11', GSK_RENDERER='cairo',
                   GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
        wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
        app = subprocess.Popen([args.executable, '--data-root', str(fixtures)], env=env, stdout=log, stderr=log)
        history_counter = wait(lambda: named('100 items'))
        for _ in range(3):
            for label, expected in [('Image', '5 items'), ('Text', '95 items'),
                                    ('Pinned', '10 items'), ('All', '100 items')]:
                action(label, expected)
        action('Settings', 'Appearance')
        labels = ['General', 'Shortcuts', 'AI', 'Privacy', 'Data']
        widths = [named(label, True).queryComponent().getExtents(pyatspi.WINDOW_COORDS).width for label in labels]
        check('settings_tabs_equal_width', min(widths) > 0 and max(widths) - min(widths) <= 1)
        editor = next(n for n in nodes() if 'EditableText' in n.get_interfaces())
        editor.queryEditableText().setTextContents('321')
        for _ in range(3):
            for label, expected in [('Shortcuts', 'Enable global shortcut'), ('AI', 'Local text models'),
                                    ('Privacy', 'Maximum clipboard item (MiB)'), ('Data', 'Export history'),
                                    ('General', 'Appearance')]:
                action(label, expected)
        restored = next(n for n in nodes() if 'EditableText' in n.get_interfaces())
        check('settings_preserve_editor_identity_and_draft', restored == editor and restored.queryText().getText(0, restored.queryText().characterCount) == '321')
        check('hidden_settings_are_not_accessible', not named('Export history') and not named('Local text models'))
        screenshot('settings-english.png')
        history_counter = None
        action('Back to history', '100 items')
        app.terminate()
        app.wait(timeout=10)

        # A real default profile in an isolated home, with legacy recording off.
        # No test-profile arguments: this exercises the production startup path.
        home = root / 'home'
        profile = home / 'data' / 'Clipboard'
        profile.mkdir(parents=True)
        (profile / 'desktop-settings.json').write_text(json.dumps(dict(
            languageOverride=None, recordingEnabled=False, shortcutEnabled=False)))
        env.update(HOME=str(home), XDG_DATA_HOME=str(home / 'data'),
                   XDG_CONFIG_HOME=str(home / 'config'), LANGUAGE='zh_CN:en_US')
        app = subprocess.Popen([args.executable], env=env, stdout=log, stderr=log)
        wait(lambda: named('设置', True))
        check('system_chinese_applies_without_override', bool(named('设置', True)))
        if not args.baseline:
            wait(lambda: named('正在录制剪贴板'))
        check('normal_profile_automatically_monitors_after_upgrade', bool(named('正在录制剪贴板')))
        check('normal_profile_has_no_recording_switch', not named('开始录制', True) and not named('暂停录制', True))
        action('设置', '外观')
        chinese = ['通用', '快捷键', 'AI', '隐私', '数据']
        widths = [named(label, True).queryComponent().getExtents(pyatspi.WINDOW_COORDS).width for label in chinese]
        check('chinese_tabs_equal_width', min(widths) > 0 and max(widths) - min(widths) <= 1)
        check('no_record_on_start_setting', not named('启动时录制'))
        screenshot('settings-chinese.png')
        if not args.baseline:
            action('返回历史', '0 条')
            subprocess.run(['xclip', '-selection', 'clipboard'], input=b'Automatic monitoring regression', check=True)
            wait(lambda: named('Automatic monitoring regression'))
            check('normal_profile_captures_without_manual_enable', True)
    except Exception as error:
        checks.append(dict(name='interaction_probe', passed=False, detail=str(error)))
        try:
            (out / 'failure-names.json').write_text(json.dumps([n.name for n in nodes()], ensure_ascii=False))
        except Exception:
            pass
    finally:
        for child in [app, wm]:
            if child and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        medians = {name: round(statistics.median(t['milliseconds'] for t in timings if t['action'] == name), 2)
                   for name in sorted(set(t['action'] for t in timings))}
        result = dict(checks=checks, timings=timings, medians=medians,
                      measurement='native action to accessibility result; includes observation overhead')
        (out / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(medians), flush=True)
        if not args.baseline and any(not c['passed'] for c in checks):
            raise SystemExit(1)
