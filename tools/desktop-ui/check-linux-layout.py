#!/usr/bin/env python3
"""Resize native GTK controls at an explicit display scale in private Xvfb/DBus."""
import argparse
import ctypes
import json
import os
import re
from types import SimpleNamespace
from pathlib import Path
import subprocess
import time
import uuid
import pyatspi

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--scale', type=int, choices=[1, 2], default=1)
args = parser.parse_args()
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
app = wm = None
completed = False
log = open(out / 'application.log', 'w')


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    print(name + ': ' + str(bool(condition)), flush=True)
    if not condition:
        raise RuntimeError(name)


def wait_for(predicate, name):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if app and app.poll() is not None:
            raise RuntimeError('application_exited')
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(.1)
    raise RuntimeError(name)


def walk(node):
    try:
        node.clearCache()
    except Exception:
        pass
    yield node
    try:
        for child in node:
            if child:
                yield from walk(child)
    except Exception:
        pass


def nodes():
    for node in pyatspi.Registry.getDesktop(0):
        try:
            if node.get_process_id() == app.pid:
                return list(walk(node))
        except Exception:
            pass
    return []


def has_text(value):
    return any(node.name == value for node in nodes())


def editor():
    return next((node for node in nodes() if 'EditableText' in node.get_interfaces()), None)


def window():
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    for line in tree.splitlines():
        if '"Clipboard"' in line:
            return int(line.strip().split()[0], 16)
    return None


def dimensions():
    output = subprocess.check_output(['xwininfo', '-id', hex(window()), '-stats'], text=True)
    return tuple(int(next(line.split(':', 1)[1] for line in output.splitlines() if line.strip().startswith(key + ':')))
                 for key in ['Width', 'Height'])


def resize(width, height):
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError('private_display_unavailable')
    try:
        x11.XResizeWindow(display, window(), width * args.scale, height * args.scale)
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)
    wait_for(lambda: dimensions() == (width * args.scale, height * args.scale), 'window_resize')


def button(label):
    for node in nodes():
        if node.name != label and not (label in ['Item actions', 'Appearance options', 'Language options', '条目操作', '选择外观', '选择语言', '選擇外觀', '選擇語言', '外観の選択', '言語の選択', '모양 선택', '언어 선택', 'Darstellung auswählen', 'Sprache auswählen', 'Elegir apariencia', 'Elegir idioma'] and node.name.startswith(label + " ")):
            continue
        for _ in range(10):
            if node.getRole() in (pyatspi.ROLE_PUSH_BUTTON, pyatspi.ROLE_MENU_ITEM, pyatspi.ROLE_TOGGLE_BUTTON) and node.queryAction().nActions > 0:
                return node
            node = node.parent
            if node is None:
                break
    return None


def native_bounds(node):
    rect = node.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    ancestor = node
    while ancestor and ancestor.getRole() != pyatspi.ROLE_FRAME:
        if ancestor.name == 'GtkPopover':
            # GTK 4.6 AT-SPI incorrectly uses the anchor's origin for popovers.
            # Resolve the actual mapped X11 surface owned by this process; keep
            # the accessibility-reported local child offset and logical scale.
            popover = ancestor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
            candidates = []
            origin = None
            main_handle = window()
            for line in tree.splitlines():
                match = re.search(r'(0x[0-9a-f]+).*? (\d+)x(\d+)[+-]\d+[+-]\d+\s+([+-]\d+)([+-]\d+)$', line)
                if not match:
                    continue
                handle, w, h, x, y = match.groups()
                if int(handle, 16) == main_handle:
                    origin = (int(x), int(y))
                if (int(w), int(h)) == (popover.width * args.scale, popover.height * args.scale):
                    props = subprocess.check_output(['xprop', '-id', handle, '_NET_WM_PID'], text=True)
                    stats = subprocess.check_output(['xwininfo', '-id', handle], text=True)
                    if props.strip().endswith('= ' + str(app.pid)) and 'Map State: IsViewable' in stats:
                        candidates.append((int(x), int(y)))
            if origin is None or len(candidates) != 1:
                raise RuntimeError('owned_popover_surface_not_unique')
            x, y = candidates[0]
            return SimpleNamespace(x=(x-origin[0])/args.scale + rect.x-popover.x,
                                   y=(y-origin[1])/args.scale + rect.y-popover.y,
                                   width=rect.width, height=rect.height)
        ancestor = ancestor.parent
    return rect


def fully_visible(node, width, height):
    rect = native_bounds(node)
    if not (rect.x >= 0 and rect.y >= 0 and rect.width > 0 and rect.height > 0
            and rect.x + rect.width <= width and rect.y + rect.height <= height):
        return False
    ancestor = node.parent
    while ancestor and ancestor.getRole() != pyatspi.ROLE_FRAME:
        if ancestor.getRole() == pyatspi.ROLE_SCROLL_PANE:
            viewport = ancestor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            if not (rect.x >= viewport.x and rect.y >= viewport.y
                    and rect.x + rect.width <= viewport.x + viewport.width
                    and rect.y + rect.height <= viewport.y + viewport.height):
                return False
        ancestor = ancestor.parent
    return True


def screenshot(name):
    subprocess.run(['import', '-window', hex(window()), str(out / name)], check=True, timeout=10)


x11 = ctypes.CDLL('libX11.so.6')
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint, ctypes.c_uint]
x11.XFlush.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
x11.XWarpPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                             ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.c_int]
xtest = ctypes.CDLL('libXtst.so.6')
xtest.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]

try:
    env = os.environ.copy()
    env.update(GDK_SCALE=str(args.scale), GDK_DPI_SCALE='1', GSK_RENDERER='cairo')
    wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(out / ('history-' + uuid.uuid4().hex))],
                           env=env, stdout=log, stderr=log)
    wait_for(lambda: has_text('Ready') and editor() and window(), 'initial_scaled_window')
    resize(960, 640)
    initial = editor()
    initial.queryEditableText().setTextContents('中文')
    wait_for(lambda: has_text('1 items'), 'unicode_query')
    button('Item actions').queryAction().doAction(0)
    wait_for(lambda: all(button(label) and fully_visible(button(label), 960, 640)
                         for label in ['Copy', 'Pin / unpin', 'Delete']), 'wide_action_bounds')
    check('wide_item_actions_are_fully_visible', True)
    button('Item actions').queryAction().doAction(0)
    header_controls = {label: wait_for(lambda label=label: button(label), 'header_' + label)
                       for label in ['Start recording', 'Settings']}
    if button('Hide'):
        header_controls['Hide'] = button('Hide')
    screenshot('wide.png')
    resize(640, 480)
    wait_for(lambda: has_text('1 items') and editor(), 'compact_layout')
    check('narrow_window_respects_logical_size', dimensions() == (640 * args.scale, 480 * args.scale))
    check('narrow_layout_preserves_search_editor', not initial.getState().contains(pyatspi.STATE_DEFUNCT)
          and initial.queryText().getText(0, initial.queryText().characterCount) == '中文')
    screenshot('compact.png')
    copy = wait_for(lambda: button('Copy'), 'compact_copy_button')
    def inside(node):
        rect = node.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        # GTK reports these bounds in logical pixels, independently of GDK_SCALE.
        return rect.x >= 0 and rect.y >= 0 and rect.width > 0 and rect.height > 0 and rect.x + rect.width <= 640 and rect.y + rect.height <= 480
    wait_for(lambda: inside(copy), 'compact_copy_bounds')
    check('quick_copy_remains_inside_small_viewport', inside(copy))
    def header_controls_still_live():
        try:
            return all(not node.getState().contains(pyatspi.STATE_DEFUNCT)
                       and node.getState().contains(pyatspi.STATE_VISIBLE)
                       and node == button(label)
                       for label, node in header_controls.items())
        except Exception:
            return False
    check('compact_layout_preserves_native_header_actions', header_controls_still_live())
    row = wait_for(lambda: next((node for node in nodes() if node.getRole() == pyatspi.ROLE_LIST_ITEM), None), 'visible_history_row')
    row_bounds = row.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    check('history_row_remains_readable_inside_small_viewport', inside(row) and row_bounds.height >= 40)
    check('history_row_uses_approved_seven_pixel_vertical_insets', row_bounds.height == 54)
    bounds = copy.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    display = x11.XOpenDisplay(None)
    try:
        x11.XWarpPointer(display, 0, window(), 0, 0, 0, 0,
                         int((bounds.x + bounds.width / 2) * args.scale),
                         int((bounds.y + bounds.height / 2) * args.scale))
        xtest.XTestFakeButtonEvent(display, 1, 1, 0)
        xtest.XTestFakeButtonEvent(display, 1, 0, 0)
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)
    wait_for(lambda: has_text('Copied to clipboard'), 'mouse_copy_status')
    copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=5)
    check('visible_copy_button_accepts_mouse_and_keeps_unicode', copied.decode() == '中文笔记 · 设计评审与输入测试')
    screenshot('compact-preview.png')
    resize(960, 640)
    wait_for(lambda: has_text('1 items'), 'wide_layout_restored')
    check('wide_layout_restores_without_resetting_query', editor().queryText().getText(0, editor().queryText().characterCount) == '中文')
    resize(760, 520)
    wait_for(lambda: editor() and button('Settings'), 'preferred_layout')
    editor().queryEditableText().setTextContents('')
    wait_for(lambda: has_text('3 items'), 'preferred_all_history')
    screenshot('preferred.png')
    button('Settings').queryAction().doAction(0)
    wait_for(lambda: has_text('Appearance') and editor(), 'general_settings_page')
    draft = editor()
    draft.queryEditableText().setTextContents('321')
    for page, expected in [('Privacy', 'Maximum clipboard item (MiB)'),
                           ('Shortcuts', 'Enable global shortcut'),
                           ('AI', 'Local text models'), ('Data', 'Export history')]:
        navigation = wait_for(lambda page=page: button(page), 'settings_tab_' + page)
        check('settings_tab_' + page + '_fits_preferred_window', fully_visible(navigation, 760, 520))
        navigation.queryAction().doAction(0)
        wait_for(lambda expected=expected: has_text(expected), 'settings_page_' + page)
        screenshot('settings-' + page.lower() + '.png')
    button('General').queryAction().doAction(0)
    wait_for(lambda: has_text('Appearance') and editor(), 'general_return')
    check('settings_navigation_keeps_original_editor_and_unsaved_draft',
          not draft.getState().contains(pyatspi.STATE_DEFUNCT) and editor() == draft and
          draft.queryText().getText(0, draft.queryText().characterCount) == '321')
    check('inactive_settings_pages_leave_accessibility_navigation', not has_text('Export history') and not has_text('Local text models'))
    screenshot('settings-general.png')
    button('Back to history').queryAction().doAction(0)
    wait_for(lambda: has_text('3 items') and button('All types'), 'history_after_settings_pages')
    button('Filters').queryAction().doAction(0)
    wait_for(lambda: button('Hide filters'), 'source_filter_disclosure')
    check('source_filter_remains_available', len([n for n in nodes() if 'EditableText' in n.get_interfaces()]) == 2)
    button('Hide filters').queryAction().doAction(0)
    wait_for(lambda: button('Filters'), 'source_filter_closed')
    check('closing_source_filters_keeps_native_search', editor().queryText().getText(0, editor().queryText().characterCount) == '')
    button('Settings').queryAction().doAction(0)
    wait_for(lambda: button('Language options'), 'language_options').queryAction().doAction(0)
    wait_for(lambda: button('简体中文'), 'chinese_appearance_settings')
    button('简体中文').queryAction().doAction(0)
    wait_for(lambda: button('返回历史'), 'chinese_settings_labels')
    button('返回历史').queryAction().doAction(0)
    wait_for(lambda: button('全部类型') and button('混合内容'), 'chinese_history_labels')
    check('chinese_type_filters_fit_preferred_window', all(
        fully_visible(button(label), 760, 520) for label in ['全部类型', '文本', '图片', '文件', '富文本', '混合内容']))
    screenshot('preferred-zh-Hans.png')
    # A decoded control alone is insufficient: speculative layout can leave
    # GtkPicture at zero height. Use a real tall PNG and inspect its viewport.
    app.terminate()
    app.wait(timeout=5)
    portrait_root = out / ('portrait-' + uuid.uuid4().hex)
    subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('create-preview-fixtures.py')),
                    '--output', str(portrait_root), '--portrait'], check=True, timeout=10)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(portrait_root)],
                           env=env, stdout=log, stderr=log)
    wait_for(lambda: has_text('Ready') and has_text('100 items') and editor(), 'portrait_history')
    editor().queryEditableText().setTextContents('Fixture PNG')
    wait_for(lambda: has_text('1 items') and has_text('Image preview'), 'portrait_preview')
    for width, height in [(760, 520), (640, 480)]:
        resize(width, height)
        picture = wait_for(lambda: next((n for n in nodes() if n.name == 'Image preview'
            and n.getRole() == pyatspi.ROLE_IMAGE), None), 'native_portrait')
        wait_for(lambda: fully_visible(picture, width, height), 'portrait_fits_viewport')
        rect = picture.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        check('portrait_image_is_visible_and_fits_' + str(width), rect.width > 0 and rect.height > rect.width)
        screenshot('portrait-' + str(width) + '.png')
    completed = True
finally:
    if not completed and app and app.poll() is None:
        try:
            screenshot('failure.png')
            (out / 'control-bounds.json').write_text(json.dumps([
                {'name': n.name, 'role': n.getRoleName(),
                 'bounds': list(n.queryComponent().getExtents(pyatspi.WINDOW_COORDS))}
                for n in nodes() if n.name in ['Item actions', 'Item actions ⋯', 'Copy', 'Pin / unpin', 'Delete']]))
        except Exception:
            pass
    for process in [app, wm]:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    log.close()
    (out / 'results.json').write_text(json.dumps({'passed': completed and all(c['passed'] for c in checks),
                                                'scale': args.scale, 'checks': checks,
                                                'limitations': ['Virtual display scaling is covered. Physical multi-monitor DPI and IME remain unverified.']}, indent=2))
