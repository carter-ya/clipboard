#!/usr/bin/env python3
"""Capture the actual GTK application with the owned, public design fixture."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
import pyatspi

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
profile = out / ('design-' + uuid.uuid4().hex)
subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('create-design-fixtures.py')),
                '--output', str(profile)], check=True, timeout=20)
app = wm = None
checks = []
log = open(out / 'application.log', 'w')


def walk(node):
    node.clearCache()
    yield node
    for child in node:
        if child:
            yield from walk(child)


def nodes():
    for node in pyatspi.Registry.getDesktop(0):
        if node.get_process_id() == app.pid:
            return list(walk(node))
    return []


def wait(test, label):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError('owned_application_exited')
        try:
            result = test()
            if result:
                return result
        except Exception:
            pass
        time.sleep(.1)
    raise RuntimeError(label)


def named(name):
    return next((n for n in nodes() if n.name == name or (name in ['Item actions', 'Appearance options', 'Language options', '条目操作', '选择外观', '选择语言', '選擇外觀', '選擇語言', '外観の選択', '言語の選択', '모양 선택', '언어 선택', 'Darstellung auswählen', 'Sprache auswählen', 'Elegir apariencia', 'Elegir idioma'] and n.name.startswith(name + " "))), None)


def click(name):
    def control():
        node = named(name)
        for _ in range(10):
            if node is None:
                break
            if node.getRole() in (pyatspi.ROLE_PUSH_BUTTON, pyatspi.ROLE_TOGGLE_BUTTON, pyatspi.ROLE_MENU_ITEM) and node.queryAction().nActions > 0:
                return node
            node = node.parent
    node = wait(control, 'control_' + name)
    if not node.queryAction().doAction(0):
        raise RuntimeError('invoke_' + name)


def snapshot(name):
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    handle = next(int(line.strip().split()[0], 16) for line in tree.splitlines() if '"Clipboard"' in line)
    # Move the private Xvfb pointer out of rows, so hover does not look selected.
    x11 = ctypes.CDLL('libX11.so.6')
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XWarpPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                                ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                                ctypes.c_int, ctypes.c_int]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError('private_display_unavailable')
    try:
        x11.XWarpPointer(display, 0, handle, 0, 0, 0, 0, 2, 2)
        x11.XSync(display, 0)
    finally:
        x11.XCloseDisplay(display)
    # Capture the real screen rectangle, including native popup surfaces.
    stats = subprocess.check_output(['xwininfo', '-id', hex(handle)], text=True)
    values = {key: int(next(line.split(':', 1)[1] for line in stats.splitlines()
                            if line.strip().startswith(key + ':')))
              for key in ['Absolute upper-left X', 'Absolute upper-left Y', 'Width', 'Height']}
    geometry = f"{values['Width']}x{values['Height']}+{values['Absolute upper-left X']}+{values['Absolute upper-left Y']}"
    # Accessibility publication can precede the rendered frame. Require two
    # consecutive identical content frames instead of a partially painted UI.
    # Exclude the header only from comparison: its native search caret blinks;
    # the saved screenshot itself always contains the complete actual window.
    previous = None
    for _ in range(10):
        subprocess.run(['import', '-window', 'root', '-crop', geometry, '+repage', str(out / name)],
                       check=True, timeout=10)
        pixels = subprocess.check_output(['convert', str(out / name), '-crop',
                                          f"{values['Width']}x{values['Height']-68}+0+68",
                                          'rgba:-'], timeout=10)
        if pixels == previous:
            return
        previous = pixels
        time.sleep(.1)
    raise RuntimeError('render_did_not_settle_' + name)


try:
    env = dict(os.environ, GSK_RENDERER='cairo')
    wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(profile)],
                           env=env, stdout=log, stderr=log)
    wait(lambda: named('图片预览') and named('5 条'), 'image_history_ready')
    snapshot('history-image.png')
    checks.append('actual_five_record_image_history')
    click('条目操作')
    wait(lambda: named('复制') and named('删除'), 'item_menu_ready')
    snapshot('history-menu.png')
    menu_copy = next(n for n in nodes() if n.name == '复制' and n.getRole() == pyatspi.ROLE_PUSH_BUTTON and any(a.name == 'GtkPopover' for a in [n.parent, n.parent.parent, n.parent.parent.parent]))
    if not menu_copy.queryAction().doAction(0):
        raise RuntimeError('menu_copy_action')
    wait(lambda: named('已复制到剪贴板'), 'menu_copy')
    copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'image/png'], timeout=5)
    if copied != (profile / 'palette.png').read_bytes():
        raise RuntimeError('menu_copy_changed_original_png')
    count_bounds = named('5 条').queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    if count_bounds.width <= 0 or count_bounds.height <= 0:
        raise RuntimeError('copied_history_count_has_empty_bounds')
    snapshot('history-image.png')
    checks.append('native_menu_copies_the_selected_original')
    click('设置')
    wait(lambda: named('选择外观') and named('选择语言'), 'general_settings')
    snapshot('settings-general.png')
    click('选择外观')
    click('深色')
    wait(lambda: named('外观已保存'), 'dark_saved')
    snapshot('settings-dark.png')
    click('返回历史')
    wait(lambda: named('图片预览'), 'dark_history')
    snapshot('history-dark.png')
    checks.append('native_theme_and_preferences')
finally:
    for process in [app, wm]:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    log.close()
    (out / 'results.json').write_text(json.dumps({'checks': checks, 'passed': len(checks) == 3}, indent=2))
