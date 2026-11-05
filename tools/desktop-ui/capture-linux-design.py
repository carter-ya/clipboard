#!/usr/bin/env python3
"""Capture the actual GTK application with the owned, public design fixture."""
import argparse
import ctypes
import json
import os
import re
from pathlib import Path
import subprocess
import time
import uuid
import pyatspi

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--composited', action='store_true', help='Own KWin in Xvfb to capture native corners and material')
parser.add_argument('--scale', type=int, choices=[1, 2], default=1)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
profile = out / ('design-' + uuid.uuid4().hex)
subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('create-design-fixtures.py')),
                '--output', str(profile)], check=True, timeout=20)
app = wm = compositor = backdrop = None
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
        if app is not None and app.poll() is not None:
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


def window_geometry(handle):
    stats = subprocess.check_output(['xwininfo', '-id', hex(handle)], text=True)
    return {key: int(next(line.split(':', 1)[1] for line in stats.splitlines()
                            if line.strip().startswith(key + ':')))
              for key in ['Absolute upper-left X', 'Absolute upper-left Y', 'Width', 'Height']}


def check_native_drag():
    handle = int(subprocess.check_output(['xwininfo', '-name', 'Clipboard', '-int'], text=True)
                 .split('Window id: ', 1)[1].split()[0])
    bounds = window_geometry(handle)
    x = bounds['Absolute upper-left X'] + bounds['Width'] // 2
    # X includes CSD shadows; GTK reports the search inset in logical pixels.
    extents = subprocess.check_output(['xprop', '-id', hex(handle), '_GTK_FRAME_EXTENTS'], text=True)
    _, _, top, _ = map(int, extents.split('=', 1)[1].split(','))
    y = bounds['Absolute upper-left Y'] + top + 6 * args.scale
    mouse = pyatspi.Registry.generateMouseEvent
    mouse(x, y, 'abs')
    mouse(x, y, 'b1p')
    try:
        # Let GTK recognize the gesture and transfer the grab to the WM
        # before releasing it, just like a continuous physical drag.
        for step in range(1, 11):
            time.sleep(.04)
            mouse(x + step * 8, y + step * 5, 'abs')
    finally:
        mouse(x + 80, y + 50, 'b1r')
    wait(lambda: window_geometry(handle)['Absolute upper-left X'] != bounds['Absolute upper-left X'],
         'top_inset_drag_moves_window')


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
    values = window_geometry(handle)
    geometry = f"{values['Width']}x{values['Height']}+{values['Absolute upper-left X']}+{values['Absolute upper-left Y']}"
    # Accessibility publication can precede the rendered frame. Require two
    # consecutive identical content frames instead of a partially painted UI.
    # Exclude the header only from comparison: its native search caret blinks;
    # the saved screenshot itself always contains the complete actual window.
    toolbar_button = named('设置').queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    content_top = min(values['Height'] - 1, (toolbar_button.y + toolbar_button.height + 18) * args.scale)
    previous = None
    for _ in range(10):
        subprocess.run(['import', '-window', 'root', '-crop', geometry, '+repage', str(out / name)],
                       check=True, timeout=10)
        pixels = subprocess.check_output(['convert', str(out / name), '-crop',
                                          f"{values['Width']}x{values['Height']-content_top}+0+{content_top}",
                                          'rgba:-'], timeout=10)
        if pixels == previous:
            return
        previous = pixels
        time.sleep(.1)
    raise RuntimeError('render_did_not_settle_' + name)


try:
    env = dict(os.environ, GSK_RENDERER='cairo', GDK_SCALE=str(args.scale), GDK_DPI_SCALE='1')
    if args.composited:
        display_id = re.fullmatch(r':(\d+)(?:\.0)?', os.environ.get('DISPLAY', ''))
        if not display_id:
            raise RuntimeError('private_xvfb_required')
        server_pid = int(Path('/tmp/.X' + display_id[1] + '-lock').read_text().strip())
        if Path('/proc', str(server_pid), 'exe').resolve().name != 'Xvfb':
            raise RuntimeError('private_xvfb_required')
        # The private DBus daemon may have started before xvfb-run set DISPLAY.
        subprocess.run(['dbus-update-activation-environment', 'DISPLAY', 'XAUTHORITY'],
                       check=True, timeout=5)
        compositor = subprocess.Popen(['kwin_x11'], env=dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1'), stdout=log, stderr=log)
        xlib = ctypes.CDLL('libX11.so.6')
        xlib.XOpenDisplay.restype = ctypes.c_void_p
        xlib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        xlib.XInternAtom.restype = ctypes.c_ulong
        xlib.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        xlib.XGetSelectionOwner.restype = ctypes.c_ulong
        xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        display = xlib.XOpenDisplay(None)
        if not display:
            raise RuntimeError('private_display_unavailable')
        try:
            atom = xlib.XInternAtom(display, b'_NET_WM_CM_S0', 0)
            wait(lambda: xlib.XGetSelectionOwner(display, atom) != 0, 'private_compositor_ready')
        finally:
            xlib.XCloseDisplay(display)
        # Software-rendered KWin may leave the blur effect disabled by default.
        # Ask the private compositor to load the actual effect and verify that
        # it advertises support before opening the application.
        def blur_effect(method):
            subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.kde.KWin',
                            '--object-path', '/Effects', '--method', 'org.kde.kwin.Effects.' + method,
                            'blur'], check=True, timeout=10, stdout=log, stderr=log)
        blur_effect('loadEffect')
        def blur_property(*target):
            result = subprocess.run(['xprop', *target, '_KDE_NET_WM_BLUR_BEHIND_REGION'],
                                    capture_output=True, text=True, timeout=3)
            return result.returncode == 0 and result.stdout.startswith('_KDE_NET_WM_BLUR_BEHIND_REGION(')
        wait(lambda: blur_property('-root'), 'private_compositor_blur_available')
        backdrop = subprocess.Popen(['display', '-immutable', '-title', 'Material fixture',
                                     '-geometry', '2560x1600+0+0', '-size', '2560x1600',
                                     'gradient:#477db2-#e4ad83'], stdout=log, stderr=log)
        wait(lambda: 'Material fixture' in subprocess.check_output(['xwininfo', '-root', '-tree'],
                                                                   text=True), 'owned_backdrop')
    else:
        wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(profile)],
                           env=env, stdout=log, stderr=log)
    wait(lambda: named('图片预览') and named('5 条'), 'image_history_ready')
    if args.composited:
        wait(lambda: blur_property('-name', 'Clipboard'), 'native_window_requests_blur')
        blur_effect('unloadEffect')
        wait(lambda: not blur_property('-root') and not blur_property('-name', 'Clipboard'),
             'focused_window_returns_to_opaque')
        blur_effect('loadEffect')
        wait(lambda: blur_property('-root') and blur_property('-name', 'Clipboard'),
             'focused_window_restores_blur')
        check_native_drag()
        checks.append('compositor_blur_requested_and_top_inset_drags')
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
    for process in [app, backdrop, wm, compositor]:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    log.close()
    (out / 'results.json').write_text(json.dumps({'checks': checks, 'passed': len(checks) == (4 if args.composited else 3)}, indent=2))
