#!/usr/bin/env python3
"""Exercise accessible GTK controls in an isolated Xvfb/DBus desktop, no key injection."""
import argparse
import base64
import hashlib
import shutil
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import signal
import select
import subprocess
import time
import traceback
import uuid

import pyatspi

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--launch-command', help='Resolve the installed menu/command entry through PATH')
parser.add_argument('--output', required=True)
parser.add_argument('--clipboard-peer')
parser.add_argument('--ocr-fixture')
parser.add_argument('--lifecycle-cycles', type=int, default=0, help='Bounded private hide/reopen resource regression')
parser.add_argument('--install-package', help='Private package fixture for installation-lock checks')
args = parser.parse_args()
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
limitations = [
    "No keyboard injection; private native pointer or accessibility control operations only.",
    "Real Chinese IME composition and global hotkey focus transfer remain untested.",
]
history_root = out / ('history-' + uuid.uuid4().hex)
primary_history_root = history_root
app = None
wm = None
sensitive_probe = False
log = open(out / 'application.log', 'w')


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    print(name + ': ' + str(bool(condition)), flush=True)
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


def root():
    for candidate in pyatspi.Registry.getDesktop(0):
        try:
            if candidate.get_process_id() == app.pid or 'ClipboardDesktop' in candidate.name:
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
            if 'Text' in node.get_interfaces() and node.queryText().getText(0, node.queryText().characterCount) == text:
                return True
        except Exception:
            continue
    return False


def has_texts(*texts):
    # One live tree snapshot for one checkpoint. Repeated walks can spend the
    # deadline on DBus round trips when a large preview is being updated.
    remaining = set(texts)
    for node in nodes():
        try:
            if node.name in remaining:
                remaining.discard(node.name)
            elif 'Text' in node.get_interfaces():
                remaining.discard(node.queryText().getText(0, node.queryText().characterCount))
            if not remaining:
                return True
        except Exception:
            pass
    return False


def button(label):
    for node in nodes():
        try:
            if node.name == label:
                current = node
                for _ in range(10):
                    if current.getRole() == pyatspi.ROLE_PUSH_BUTTON:
                        return current
                    current = current.parent
                    if current is None:
                        break
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


def editor_with_value(value):
    if sensitive_probe:
        raise RuntimeError('public_editor_lookup_after_sensitive_phase')
    for node in nodes():
        try:
            if ('EditableText' in node.get_interfaces() and
                    node.queryText().getText(0, node.queryText().characterCount) == value):
                return node
        except Exception:
            continue
    return None


def window_id():
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    for line in tree.splitlines():
        if '\"Clipboard\"' in line:
            return int(line.strip().split()[0], 16)
    raise RuntimeError('native_window_missing')


def window_visible():
    state = subprocess.check_output(['xwininfo', '-id', hex(window_id()), '-stats'], text=True)
    return 'Map State: IsViewable' in state


def request_close():
    # A window manager close request, never a synthesized key or paste event.
    class ClientData(ctypes.Union):
        _fields_ = [('b', ctypes.c_char * 20), ('s', ctypes.c_short * 10), ('l', ctypes.c_long * 5)]
    class ClientMessage(ctypes.Structure):
        _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                    ('display', ctypes.c_void_p), ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                    ('format', ctypes.c_int), ('data', ClientData)]
    class Event(ctypes.Union):
        _fields_ = [('client', ClientMessage), ('pad', ctypes.c_long * 24)]
    x11 = ctypes.CDLL('libX11.so.6')
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(Event)]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError('close_display_unavailable')
    try:
        event = Event()
        event.client.type = 33
        event.client.display = display
        event.client.window = window_id()
        event.client.message_type = x11.XInternAtom(display, b'WM_PROTOCOLS', 0)
        event.client.format = 32
        event.client.data.l[0] = x11.XInternAtom(display, b'WM_DELETE_WINDOW', 0)
        if not x11.XSendEvent(display, event.client.window, 0, 0, ctypes.byref(event)):
            raise RuntimeError('close_request_failed')
    finally:
        x11.XCloseDisplay(display)


def wake_existing():
    peer = subprocess.run([str(Path(args.executable).resolve()), '--data-root', str(history_root)],
                          stdout=log, stderr=log, timeout=15)
    check('secondary_launch_exits_without_new_store_owner', peer.returncode == 0 and app.poll() is None)
    wait_for(lambda: window_visible() and has_text('Clipboard') and editor(),
             'existing_window_reopened')



def activate_archive_file_with_pointer(filename):
    # GTK 4.6 renders file rows without exposing them through AT-SPI. Locate
    # only our synthetic filename in this private chooser's actual pixels;
    # never synthesize keys or use the clipboard to enter a path.
    if sensitive_probe:
        raise RuntimeError('archive_pointer_outside_private_phase')
    def visible_chooser():
        tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
        for line in tree.splitlines():
            if '"Import history"' not in line: continue
            candidate = int(line.strip().split()[0], 16)
            state = subprocess.check_output(['xwininfo', '-id', hex(candidate), '-stats'], text=True)
            if 'Map State: IsViewable' in state: return candidate
        return None
    chooser = wait_for(visible_chooser, 'archive_chooser_window')
    def rendered_point():
        picture = out / 'archive-open-dialog.png'
        subprocess.run(['import', '-window', hex(chooser), str(picture)], check=True, timeout=10)
        engine = ctypes.CDLL(ctypes.util.find_library('tesseract'))
        lept = ctypes.CDLL(ctypes.util.find_library('lept'))
        engine.TessBaseAPICreate.restype = ctypes.c_void_p
        engine.TessBaseAPIInit3.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        engine.TessBaseAPISetPageSegMode.argtypes = [ctypes.c_void_p, ctypes.c_int]
        engine.TessBaseAPISetImage2.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        engine.TessBaseAPISetSourceResolution.argtypes = [ctypes.c_void_p, ctypes.c_int]
        engine.TessBaseAPIGetTsvText.argtypes = [ctypes.c_void_p, ctypes.c_int]
        engine.TessBaseAPIGetTsvText.restype = ctypes.c_void_p
        engine.TessDeleteText.argtypes = [ctypes.c_void_p]
        engine.TessBaseAPIDelete.argtypes = [ctypes.c_void_p]
        lept.pixRead.argtypes = [ctypes.c_char_p]
        lept.pixRead.restype = ctypes.c_void_p
        lept.pixDestroy.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        api = engine.TessBaseAPICreate()
        pix = ctypes.c_void_p(lept.pixRead(os.fsencode(picture)))
        text = None
        try:
            if not api or not pix.value or engine.TessBaseAPIInit3(api, None, b'eng') != 0:
                raise RuntimeError('archive_filename_locator')
            engine.TessBaseAPISetPageSegMode(api, 6)
            engine.TessBaseAPISetImage2(api, pix)
            engine.TessBaseAPISetSourceResolution(api, 96)
            text = engine.TessBaseAPIGetTsvText(api, 0)
            if not text: raise RuntimeError('archive_filename_locator')
            rows = [line.split('\t') for line in ctypes.string_at(text).decode().splitlines()]
            matches = [row for row in rows if len(row) == 12 and row[11] == filename and float(row[10]) >= 50]
            if len(matches) != 1:
                return None
            row = matches[0]
            return int(row[6]) + int(row[8]) // 2, int(row[7]) + int(row[9]) // 2
        finally:
            if text: engine.TessDeleteText(text)
            if api: engine.TessBaseAPIDelete(api)
            if pix.value: lept.pixDestroy(ctypes.byref(pix))
    x, y = wait_for(rendered_point, 'archive_filename_not_rendered')
    x11 = ctypes.CDLL('libX11.so.6')
    xtest = ctypes.CDLL('libXtst.so.6')
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XTranslateCoordinates.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                                          ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int),
                                          ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong)]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtest.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
    xtest.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    display = x11.XOpenDisplay(None)
    if not display: raise RuntimeError('archive_pointer_display')
    try:
        root_x, root_y, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
        if not x11.XTranslateCoordinates(display, chooser, x11.XDefaultRootWindow(display), x, y,
                                          ctypes.byref(root_x), ctypes.byref(root_y), ctypes.byref(child)):
            raise RuntimeError('archive_pointer_bounds')
        if not (xtest.XTestFakeMotionEvent(display, -1, root_x.value, root_y.value, 0) and
                xtest.XTestFakeButtonEvent(display, 1, 1, 0) and xtest.XTestFakeButtonEvent(display, 1, 0, 0) and
                xtest.XTestFakeButtonEvent(display, 1, 1, 50) and xtest.XTestFakeButtonEvent(display, 1, 0, 0)):
            raise RuntimeError('archive_pointer_selection')
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)


def screenshot(name):
    tree = subprocess.check_output(['xwininfo', '-root', '-tree'], text=True)
    for line in tree.splitlines():
        if '"Clipboard"' in line:
            window = line.strip().split()[0]
            subprocess.run(['import', '-window', window, str(out / name)], check=True, timeout=10)
            return
    raise RuntimeError('window_for_screenshot')


try:
    wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=log, stderr=log)
    app = subprocess.Popen([args.launch_command or str(Path(args.executable).resolve()), '--smoke-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('3 items'), 'initial_history')
    check('native_window_and_history_visible', True)
    if args.install_package:
        package = Path(args.install_package).resolve()
        installation = Path(args.executable).resolve().parent.parent
        metadata = json.loads((installation / 'installation.json').read_text())
        upgrade = subprocess.run(['/usr/bin/python3', str(package / 'install.py'), '--prefix', str(installation),
                                  '--applications-dir', str(Path(metadata['desktopEntry']).parent),
                                  '--bin-dir', str(Path(metadata['shortcut']).parent),
                                  '--config-home', str(Path(metadata['autostart']).parent.parent)], capture_output=True, text=True)
        check('running_installed_app_blocks_upgrade', upgrade.returncode != 0 and 'Quit Clipboard' in upgrade.stderr)
        uninstall = subprocess.run(['/usr/bin/python3', str(installation / 'uninstall.py')], capture_output=True, text=True)
        check('running_installed_app_blocks_uninstall', uninstall.returncode != 0 and 'Quit Clipboard' in uninstall.stderr)

    screenshot('history.png')
    edit = wait_for(editor, 'search_editable_control')
    try:
        if not edit.getState().contains(pyatspi.STATE_FOCUSED):
            edit.queryComponent().grabFocus()
        wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'programmatic_search_focus', seconds=5)
        check('native_search_control_focus', True)
    except Exception as error:
        # GTK 4.6's AT-SPI implementation may reject Component.GrabFocus.
        # Keep this explicit as unverified while exercising the independent controls.
        limitations.append('Search focus could not be verified through AT-SPI: ' + str(error)[:120])
    click('Copy')
    wait_for(lambda: has_text('Copied to clipboard'), 'copy_status')
    clipboard = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=10)
    check('copy_button_writes_native_clipboard', clipboard.decode('utf-8') == 'Release checklist · build, test, publish')
    wait_for(editor, 'search_editable_control').queryEditableText().setTextContents('Welcome')
    wait_for(lambda: has_text('1 items') and has_text('Welcome to Clipboard Preview'), 'older_item_selected')
    click('Copy')
    wait_for(lambda: json.loads((history_root / 'history.json').read_text())['items'][0]['preview'] ==
             'Welcome to Clipboard Preview', 'copied_item_promoted_while_capture_paused')
    copied_older = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=10)
    check('copy_promotes_older_item_with_capture_paused', copied_older.decode('utf-8') == 'Welcome to Clipboard Preview')
    wait_for(editor, 'search_editable_control').queryEditableText().setTextContents('中文')
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
    wait_for(lambda: editor().queryText().getText(0, editor().queryText().characterCount) == '中文', 'restored_search_value')
    check('settings_round_trip_preserves_search', True)
    wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'settings_return_focus')
    check('settings_return_focuses_native_search', True)
    click('Hide')
    wait_for(lambda: not window_visible(), 'window_hidden')
    wake_existing()
    wait_for(lambda: editor().queryText().getText(0, editor().queryText().characterCount) == '中文', 'wake_search_value')
    wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'wake_native_search_focus')
    check('hide_and_secondary_launch_preserve_search_and_focus', True)
    request_close()
    wait_for(lambda: not window_visible(), 'close_hides_window')
    check('native_close_keeps_existing_process_alive', app.poll() is None)
    wake_existing()
    check('native_close_reopen_preserves_query', editor().queryText().getText(0, editor().queryText().characterCount) == '中文')
    if args.lifecycle_cycles:
        if not 5 <= args.lifecycle_cycles <= 100:
            raise RuntimeError('lifecycle_cycles_out_of_range')
        def resources():
            status = Path('/proc/' + str(app.pid) + '/status').read_text()
            rss = int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:')))
            return {'rssKiB': rss, 'fds': len(list(Path('/proc/' + str(app.pid) + '/fd').iterdir()))}
        baseline = None
        for cycle in range(args.lifecycle_cycles + 5):
            click('Hide')
            wait_for(lambda: not window_visible(), 'cycle_window_hidden')
            wake_existing()
            wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'cycle_search_focus')
            if editor().queryText().getText(0, editor().queryText().characterCount) != '中文':
                raise RuntimeError('cycle_lost_search')
            if cycle == 4:
                baseline = resources()
        final = resources()
        (out / 'lifecycle-resources.json').write_text(json.dumps({'cycles': args.lifecycle_cycles,
                                                                 'baseline': baseline, 'final': final}, indent=2))
        check('repeated_hide_reopen_preserves_query_and_focus', True)
        check('repeated_window_lifecycle_keeps_fds_bounded', final['fds'] <= baseline['fds'] + 4)
        check('repeated_window_lifecycle_keeps_memory_bounded', final['rssKiB'] <= baseline['rssKiB'] + 32768)
    click('Delete')
    wait_for(lambda: has_text('Item deleted') and has_text('0 items'), 'delete_in_pinned_list')
    check('delete_updates_real_store', True)
    click('All')
    wait_for(editor, 'search_after_delete').queryEditableText().setTextContents('')
    wait_for(lambda: has_text('2 items'), 'remaining_history')
    history = json.loads((history_root / 'history.json').read_text())
    check('store_persistence_matches_ui', len(history['items']) == 2)
    if args.clipboard_peer:
        click('Start recording')
        wait_for(lambda: has_text('Recording clipboard'), 'rich_recording_enabled')
        for fixture, kind, count in [('rich', 'Image', '1 items'), ('files', 'File', '1 items')]:
            peer = subprocess.Popen([str(Path(args.clipboard_peer).resolve()), 'rich-clipboard-peer', fixture],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
            try:
                if not select.select([peer.stdout], [], [], 10)[0] or peer.stdout.readline() != b'ready\n':
                    raise RuntimeError('rich_peer_startup')
                click(kind)
                wait_for(lambda: has_text(count) and has_text('Source: linux:ClipboardDesktop'), 'capture_native_' + fixture)
                check('native_' + fixture + '_capture_reaches_type_filter_and_preview', True)
                if fixture == 'rich':
                    check('image_preview_has_native_picture', any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
                    screenshot('image-preview.png')
                    click('Copy')
                    wait_for(lambda: has_text('Copied to clipboard'), 'copy_image_status')
                    image = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'image/png'], timeout=10)
                    check('image_copy_keeps_original_native_png', image.startswith(b'\x89PNG\r\n\x1a\n'))
                else:
                    wait_for(lambda: has_text('fixture 中文.txt') or any('fixture 中文.txt' in getattr(node, 'name', '') for node in nodes()), 'file_paths_preview')
                    click('Copy')
                    wait_for(lambda: has_text('Copied to clipboard'), 'copy_files_status')
                    uris = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'text/uri-list'], timeout=10)
                    check('file_copy_keeps_both_native_uris', len(uris.decode('utf-8').splitlines()) == 2)
            finally:
                peer.stdin.close()
                try:
                    peer.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    peer.kill()
                    peer.wait(timeout=5)
        click('Pause recording')
        wait_for(lambda: has_text('Recording paused'), 'rich_recording_paused')
        check('recording_can_pause_after_native_rich_capture', True)
        click('Text')
        wait_for(editor, 'long_preview_search').queryEditableText().setTextContents('Long preview fixture')
        click('Start recording')
        wait_for(lambda: has_text('Recording clipboard'), 'long_preview_recording')
        peer = subprocess.Popen([str(Path(args.clipboard_peer).resolve()), 'rich-clipboard-peer', 'preview-long'],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            if not select.select([peer.stdout], [], [], 10)[0] or peer.stdout.readline() != b'ready\n':
                raise RuntimeError('long_preview_peer_startup')
            wait_for(lambda: has_text('1 items') and has_text('Preview truncated. Copy keeps the full text.'), 'long_preview_truncation_notice')
            check('long_text_preview_reports_truncation', True)
            screenshot('long-text-preview.png')
            click('Pause recording')
            wait_for(lambda: has_text('Recording paused'), 'long_preview_pause_before_copy')
            click('Copy')
            wait_for(lambda: has_text('Copied to clipboard'), 'long_preview_copied')
            copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=10)
            expected = ('Long preview fixture 中文😀\n' * 4096 + 'end-of-full-preview-fixture').encode('utf-8')
            check('truncated_preview_copy_keeps_full_unicode_payload', copied == expected)
        finally:
            peer.stdin.close()
            try:
                peer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                peer.kill()
                peer.wait(timeout=5)
        click('Delete')
        wait_for(lambda: has_text('0 items'), 'long_preview_fixture_removed')
        wait_for(editor, 'search_after_long_preview').queryEditableText().setTextContents('')
        if args.ocr_fixture:
            click('Image')
            wait_for(lambda: has_text('1 items'), 'image_for_ocr_replacement')
            click('Delete')
            wait_for(lambda: has_text('0 items'), 'previous_image_removed')
            click('Start recording')
            wait_for(lambda: has_text('Recording clipboard'), 'ocr_capture_enabled')
            peer = subprocess.Popen([str(Path(args.clipboard_peer).resolve()), 'rich-clipboard-peer', 'ocr', str(Path(args.ocr_fixture).resolve())],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
            try:
                if not select.select([peer.stdout], [], [], 10)[0] or peer.stdout.readline() != b'ready\n':
                    raise RuntimeError('ocr_peer_startup')
                wait_for(lambda: has_text('1 items') and button('Recognize text'), 'ocr_image_captured')
                click('Recognize text')
                wait_for(lambda: has_text('OCR text ready') and has_text('OCR / AI result'), 'ocr_result_visible', seconds=60)
                check('native_ocr_result_reaches_real_preview', any('CLIPBOARD' in getattr(node, 'name', '').upper() for node in nodes()))
                click('Pause recording')
                wait_for(lambda: has_text('Recording paused'), 'pause_before_copying_ocr')
                click('Copy result')
                wait_for(lambda: has_text('Copied to clipboard'), 'ocr_result_copy_status')
                text = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=10).decode('utf-8')
                check('ocr_result_can_be_copied_without_replacing_original_item', 'CLIPBOARD' in text.upper() and '123' in text)
            finally:
                peer.stdin.close()
                try:
                    peer.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    peer.kill()
                    peer.wait(timeout=5)
        click('All types')
        wait_for(lambda: has_text('4 items'), 'all_content_restored')
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'preferences_for_save')
    click('Dark')
    wait_for(lambda: has_text('Appearance saved'), 'dark_appearance_saved')
    screenshot('settings-dark.png')
    mean = float(subprocess.check_output(['convert', str(out / 'settings-dark.png'), '-format', '%[fx:mean]', 'info:'], text=True))
    check('native_dark_appearance_changes_rendered_window', mean < 0.6)
    click('Light')
    wait_for(lambda: has_text('Appearance saved'), 'light_appearance_saved')
    click('简体中文')
    wait_for(lambda: has_text('偏好设置') and has_text('语言已保存'), 'localized_settings')
    check('language_switch_updates_native_controls', bool(button('返回历史')) and bool(button('保存行为设置')))
    check('localized_service_privacy_and_capability_notes',
          has_text('本地 OCR 使用已安装的语言包，此平台不提供 Apple 专属模型。') and
          has_text('远程 AI 默认关闭。启用后，符合条件的内容会发送到指定服务。'))
    screenshot('settings-chinese.png')
    click('返回历史')
    wait_for(lambda: editor() and has_text('设置'), 'localized_history')
    wait_for(lambda: editor().getState().contains(pyatspi.STATE_FOCUSED), 'localized_history_focus')
    check('language_change_preserves_history_focus', True)
    click('设置')
    wait_for(lambda: has_text('偏好设置'), 'localized_settings_return')
    click('English')
    wait_for(lambda: has_text('Preferences') and has_text('Language saved'), 'english_restored')
    def public_endpoint_editor(value):
        for candidate in nodes():
            try:
                if candidate.getRole() == pyatspi.ROLE_TEXT and 'EditableText' in candidate.get_interfaces() and candidate.queryText().getText(0, candidate.queryText().characterCount) == value:
                    return candidate
            except Exception:
                pass
        return None
    draft_value = 'https://fixture.invalid/localized-draft'
    draft_editor = wait_for(lambda: public_endpoint_editor('https://api.openai.com/v1'), 'public_endpoint_editor')
    draft_editor.queryEditableText().setTextContents(draft_value)
    language_cases = [('zh-Hant', '繁體中文', '偏好設定', '語言已保存', '保存行為設定', '本地 OCR 使用已安裝的語言包，此平台不提供 Apple 專屬模型。', '遠端 AI 預設關閉。啓用後，符合條件的內容會發送到指定服務。'), ('ja', '日本語', '環境設定', '言語を保存しました', '動作設定を保存', 'ローカル OCR はインストール済みのシステム言語パックを使用します。Apple 専用モデルは利用できません。', 'リモート AI は初期状態で無効です。有効にすると、対象の内容が指定した接続先に送信されます。'), ('ko', '한국어', '환경설정', '언어를 저장했습니다', '동작 설정 저장', '로컬 OCR은 설치된 시스템 언어 팩을 사용합니다. Apple 전용 모델은 사용할 수 없습니다.', '원격 AI는 기본적으로 꺼져 있습니다. 켜면 조건에 맞는 콘텐츠가 지정한 엔드포인트로 전송됩니다.'), ('de', 'Deutsch', 'Einstellungen', 'Sprache gespeichert', 'Verhalten speichern', 'Lokale OCR nutzt installierte Systemsprachpakete. Apple-exklusive Modelle sind hier nicht verfügbar.', 'Remote-KI ist standardmäßig deaktiviert. Bei Aktivierung werden geeignete Inhalte an deinen gewählten Endpunkt gesendet.'), ('es', 'Español', 'Preferencias', 'Idioma guardado', 'Guardar comportamiento', 'El OCR local usa los paquetes de idioma del sistema instalados. Los modelos exclusivos de Apple no están disponibles aquí.', 'La IA remota está desactivada por defecto. Al activarla, el contenido permitido se envía al destino elegido.')]
    for tag, label, preferences, saved_label, behavior, ocr_note, ai_note in language_cases:
        click(label)
        wait_for(lambda: has_texts(preferences, saved_label, behavior), 'localized_controls_' + tag)
        check('language_' + tag + '_updates_controls_and_privacy_notes', has_texts(ocr_note, ai_note))
        check('language_' + tag + '_preserves_editor_draft', not draft_editor.getState().contains(pyatspi.STATE_DEFUNCT) and
              draft_editor.queryText().getText(0, draft_editor.queryText().characterCount) == draft_value and
              public_endpoint_editor(draft_value) == draft_editor)
        screenshot('settings-' + tag + '.png')
    click('English')
    wait_for(lambda: has_texts('Preferences', 'Language saved'), 'english_after_all_languages')
    click('Save behavior')
    settings_file = history_root / 'desktop-settings.json'
    wait_for(lambda: settings_file.exists(), 'saved_settings_file')
    saved = json.loads(settings_file.read_text())
    check('behavior_saved_without_enabling_recording', saved['recordingEnabled'] is False and saved['closeToTray'] is True)
    check('language_switches_keep_remote_AI_disabled_and_endpoint_draft_unsaved', saved['ai']['enabled'] is False and saved['ai']['endpoint'] == 'https://api.openai.com/v1' and saved['languageOverride'] == 'en')
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('explicit_quit_flushes_and_exits', app.returncode == 0)
    history_root = out / ('production-empty-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('0 items'), 'fresh_production_history')
    check('normal_launch_has_no_sample_history_and_starts_paused', bool(button('Start recording')))
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'fresh_settings')
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('normal_launch_quits_cleanly', app.returncode == 0)
    history_root = out / ('background-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(history_root), '--background'],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: (history_root / 'blobs').exists(), 'background_profile_claimed')
    wait_for(lambda: not window_visible(), 'background_launch_stays_hidden')
    check('startup_background_argument_keeps_window_hidden', app.poll() is None)
    wake_existing()
    wait_for(lambda: has_text('Ready') and has_text('0 items'), 'background_launch_reopened')
    check('startup_background_instance_can_be_reopened', True)
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'background_settings')
    click('Quit Clipboard')
    app.wait(timeout=10)
    history_root = out / ('history-counts-' + uuid.uuid4().hex)
    history_root.mkdir()
    snapshot = json.loads((primary_history_root / 'history.json').read_text())
    shutil.copytree(primary_history_root / 'blobs', history_root / 'blobs')
    mixed_text = b'Legacy mixed fixture'
    mixed = dict(snapshot['items'][0])
    mixed.update(id=str(uuid.uuid4()), kind='mixed', preview=mixed_text.decode(), pinned=False,
                 sensitive=False, sha256=hashlib.sha256(mixed_text).hexdigest(), sizeBytes=len(mixed_text),
                 payloads=[{'pasteboardType': 'public.utf8-plain-text',
                            'inlineData': base64.b64encode(mixed_text).decode()}])
    for key in ['summary', 'summarySource', 'sensitivityReason']:
        mixed.pop(key, None)
    snapshot['items'].insert(0, mixed)
    expected_all = len(snapshot['items'])
    (history_root / 'history.json').write_text(json.dumps(snapshot))
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text(str(expected_all) + ' items') and button('Mixed'), 'counted_history_ready')
    check('query_wide_tab_and_type_counts_are_visible', has_text('(' + str(expected_all) + ')') and has_text('(2)'))
    screenshot('history-counts.png')
    click('Mixed')
    wait_for(lambda: has_text('1 items') and has_text('Legacy mixed fixture'), 'legacy_mixed_filter')
    check('legacy_mixed_kind_can_be_filtered', has_text('(' + str(expected_all) + ')'))
    click('Pin / unpin')
    wait_for(lambda: has_text('Item pinned'), 'pin_legacy_mixed')
    click('Pinned')
    wait_for(lambda: has_text('1 items') and not has_text('(2)'), 'pinned_kind_counts')
    click('Text')
    wait_for(lambda: has_text('0 items'), 'empty_pinned_kind')
    check('kind_counts_follow_pinned_tab_without_collapsing_library_total',
          has_text('(' + str(expected_all) + ')') and has_text('(1)') and not has_text('(2)'))
    click('All')
    wait_for(lambda: has_text('2 items') and has_text('(2)'), 'all_tab_restores_text_count')
    wait_for(editor, 'counted_query_editor').queryEditableText().setTextContents('Legacy mixed fixture')
    wait_for(lambda: has_text('0 items') and not has_text('(' + str(expected_all) + ')'), 'query_updates_cross_kind_counts')
    click('Mixed')
    wait_for(lambda: has_text('1 items') and has_text('Legacy mixed fixture'), 'matched_mixed_kind')
    check('tab_and_type_counts_follow_the_active_query', has_text('(1)') and not has_text('(' + str(expected_all) + ')'))
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'counted_history_quit_settings')
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('counted_history_quits_cleanly', app.returncode == 0)

    # Persist only synthetic rich payloads; the preview may be short, Copy must not be.
    history_root = out / ('rich-preview-' + uuid.uuid4().hex)
    history_root.mkdir()
    (history_root / 'blobs').mkdir()
    template = json.loads((primary_history_root / 'history.json').read_text())
    fixtures = [
        ('HTML budget fixture', 'public.html', '<p>' + '中😀' * 12000 + ' HTML_COPY_TAIL</p>', 'text/html'),
        ('RTF budget fixture', 'public.rtf', '{\\rtf1 ' + 'x' * 70000 + ' RTF_COPY_TAIL}', 'text/rtf'),
    ]
    template['items'] = [dict(id=str(uuid.uuid4()), createdAt=template['items'][0]['createdAt'],
                            kind='rtf', preview=name, pinned=False, sensitive=False,
                            sha256=hashlib.sha256(body.encode()).hexdigest(), sizeBytes=len(body.encode()),
                            payloads=[dict(pasteboardType=kind, inlineData=base64.b64encode(body.encode()).decode())])
                         for name, kind, body, target in fixtures]
    (history_root / 'history.json').write_text(json.dumps(template))
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--data-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('2 items'), 'rich_budget_profile')
    for name, kind, body, target in fixtures:
        wait_for(editor, 'rich_budget_editor').queryEditableText().setTextContents(name)
        expected_preview = (('中😀' * 12000 + ' HTML_COPY_TAIL').encode()[:64 * 1024].decode('utf-8', errors='ignore')
                            if target == 'text/html' else 'x' * (64 * 1024))
        wait_for(lambda: has_texts('1 items', name, expected_preview, 'Preview truncated. Copy keeps the full text.'), 'rich_budget_notice')
        check('rich_' + target.split('/')[1] + '_reports_truncation',
              not has_text('HTML_COPY_TAIL') and not has_text('RTF_COPY_TAIL'))
        click('Pin / unpin')
        wait_for(lambda: has_text('Item pinned'), 'rich_budget_copy_transition')
        click('Copy')
        wait_for(lambda: has_text('Copied to clipboard'), 'rich_budget_copied')
        copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-t', target, '-o'], timeout=10)
        check('rich_' + target.split('/')[1] + '_copy_preserves_complete_payload', copied == body.encode())
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'rich_budget_quit_settings')
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('rich_budget_profile_quits_cleanly', app.returncode == 0)

    history_root = out / ('archive-state-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(history_root)],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_texts('Ready', '3 items'), 'archive_private_profile')
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'archive_preferences')
    click('Export history')
    name_entry = wait_for(lambda: next((n for n in nodes() if n.name == 'Name:' and 'EditableText' in n.get_interfaces()), None), 'archive_save_filename')
    check('native_archive_save_dialog_defaults_to_zip', name_entry.queryText().getText(0, name_entry.queryText().characterCount) == 'clipboard-history.zip')
    archive_path = history_root / 'native-export.zip'
    name_entry.queryEditableText().setTextContents(str(archive_path))
    click('Save')
    wait_for(lambda: archive_path.exists() and has_text('History exported. Sensitive items excluded.'), 'archive_export_finished')
    import zipfile
    with zipfile.ZipFile(archive_path) as archive:
        exported = json.loads(archive.read('history.json'))
    check('native_archive_export_contains_mac_history', len(exported['items']) == 3 and not any(i['sensitive'] for i in exported['items']))
    click('Clear history')
    click('Delete all history')
    wait_for(lambda: has_text('History cleared'), 'archive_source_cleared')
    click('Import history')
    wait_for(lambda: has_text('Open'), 'archive_open_dialog')
    activate_archive_file_with_pointer('native-export.zip')
    wait_for(lambda: has_text('Imported 3 items; 0 skipped; 0 missing blobs.'), 'archive_native_round_trip')
    restored = json.loads((history_root / 'history.json').read_text())
    check('native_archive_import_preserves_original_order_and_content', [i['sha256'] for i in restored['items']] == [i['sha256'] for i in exported['items']])
    click('Import history')
    wait_for(lambda: has_text('Open'), 'archive_duplicate_dialog')
    activate_archive_file_with_pointer('native-export.zip')
    wait_for(lambda: has_text('Imported 0 items; 3 skipped; 0 missing blobs.'), 'archive_duplicate_result')
    check('native_archive_duplicate_import_is_counted', len(json.loads((history_root / 'history.json').read_text())['items']) == 3)
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('archive_state_profile_quits_cleanly', app.returncode == 0)

    history_root = out / ('startup-state-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(history_root), '--smoke-startup'],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('3 items'), 'startup_private_profile')
    click('Settings')
    wait_for(lambda: has_texts('Preferences', 'Enable launch at login'), 'startup_initial_disabled')
    settings_editor = wait_for(editor, 'startup_settings_editor')
    settings_editor.queryEditableText().setTextContents('321')
    click('Enable launch at login')
    wait_for(lambda: button('Disable launch at login'), 'startup_explicit_enable')
    startup_entries = list((history_root / '.startup-config/autostart').glob('com.clipboard.test.*.desktop'))
    check('private_startup_toggle_uses_only_synthetic_registration', len(startup_entries) == 1 and
          b'.startup-no-launch' in startup_entries[0].read_bytes())
    startup_entry = startup_entries[0]
    startup_content = startup_entry.read_bytes()
    startup_entry.unlink()
    driver_x11 = ctypes.CDLL('libX11.so.6')
    driver_x11.XOpenDisplay.restype = ctypes.c_void_p
    driver_x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
    driver_x11.XDefaultScreen.restype = ctypes.c_int
    driver_x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    driver_x11.XDefaultRootWindow.restype = ctypes.c_ulong
    driver_x11.XIconifyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]
    driver_x11.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    driver_x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    driver_x11.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
    driver_x11.XFlush.argtypes = [ctypes.c_void_p]
    driver_x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = driver_x11.XOpenDisplay(None)
    try:
        target_window = window_id()
        driver_x11.XIconifyWindow(display, target_window, driver_x11.XDefaultScreen(display))
        driver_x11.XFlush(display)
        wait_for(lambda: not window_visible(), 'startup_settings_minimized')
        driver_x11.XMapRaised(display, target_window)
        driver_x11.XFlush(display)
        wait_for(window_visible, 'startup_settings_mapped')
        driver_x11.XSetInputFocus(display, target_window, 2, 0)
        driver_x11.XFlush(display)
        wait_for(lambda: window_visible() and has_texts('Preferences', 'Enable launch at login'), 'startup_state_after_restore')
        check('settings_restore_reconciles_external_startup_disable', not startup_entry.exists())
        check('startup_restore_preserves_native_editor_draft', not settings_editor.getState().contains(pyatspi.STATE_DEFUNCT) and
              settings_editor.queryText().getText(0, settings_editor.queryText().characterCount) == '321' and editor() == settings_editor)
        root_window = driver_x11.XDefaultRootWindow(display)
        driver_x11.XSetInputFocus(display, root_window, 2, 0)
        driver_x11.XFlush(display)
        def focus_is_root():
            focused, revert = ctypes.c_ulong(), ctypes.c_int()
            driver_x11.XGetInputFocus(display, ctypes.byref(focused), ctypes.byref(revert))
            return focused.value == root_window
        wait_for(focus_is_root, 'startup_settings_deactivated_without_unmap')
        startup_entry.write_bytes(startup_content)
        driver_x11.XSetInputFocus(display, target_window, 2, 0)
        driver_x11.XFlush(display)
        wait_for(lambda: has_texts('Preferences', 'Disable launch at login'), 'startup_state_after_reactivation')
        check('settings_reactivation_reads_external_startup_state_without_writing', startup_entry.read_bytes() == startup_content)
    finally:
        driver_x11.XCloseDisplay(display)
    click('Disable launch at login')
    wait_for(lambda: button('Enable launch at login') and not startup_entry.exists(), 'startup_explicit_disable')
    check('explicit_startup_disable_removes_the_owned_registration', True)
    foreign_startup = startup_content.replace(b'.startup-no-launch', b'.startup-other-no-launch')
    startup_entry.write_bytes(foreign_startup)
    try:
        click('Enable launch at login')
        wait_for(lambda: has_text('Startup entry conflicts with this installation. Check system startup settings before retrying.'), 'startup_conflict_guidance')
        check('startup_conflict_preserves_other_installation_entry', startup_entry.read_bytes() == foreign_startup)
        check('startup_conflict_preserves_native_editor_draft', editor() == settings_editor and
              settings_editor.queryText().getText(0, settings_editor.queryText().characterCount) == '321')
    finally:
        if startup_entry.exists() and startup_entry.read_bytes() == foreign_startup:
            startup_entry.unlink()

    saved_file = history_root / 'desktop-settings.json'
    saved_settings = json.loads(saved_file.read_text()) if saved_file.exists() else {}
    check('startup_reconciliation_does_not_save_content_drafts', saved_settings.get('historyCapacity', 100) == 100)
    size_editor = wait_for(lambda: editor_with_value('10'), 'size_preference_editor')
    size_editor.queryEditableText().setTextContents('0')
    click('Save content settings')
    wait_for(lambda: has_text('Content settings saved') and
             json.loads(saved_file.read_text()).get('maxClipSizeBytes') == 0, 'disabled_size_preference_saved')
    check('native_settings_can_disable_size_filtering',
          has_text('0 disables size filtering. Clipboard transfers remain limited to 16 MiB.'))
    wait_for(lambda: editor_with_value('0'), 'disabled_size_editor').queryEditableText().setTextContents('-1')
    click('Save content settings')
    wait_for(lambda: has_text('Enter a capacity of 1–5000 and a size of 0–16 MiB.'), 'negative_size_preference_rejected')
    check('invalid_size_does_not_replace_disabled_preference',
          json.loads(saved_file.read_text()).get('maxClipSizeBytes') == 0)
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('startup_state_profile_quits_cleanly', app.returncode == 0)

    sensitive_probe = True
    history_root = out / ('sensitive-preview-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(history_root), '--smoke-sensitive'],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('5 items'), 'sensitive_private_profile')
    click('Image')
    wait_for(lambda: has_text('1 items') and button('Reveal for this session') and has_text('Sensitive content is hidden.'), 'sensitive_image_masked')
    check('sensitive_image_starts_masked', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
    sensitive_type_control = button('Text')
    click('Reveal for this session')
    wait_for(lambda: any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()), 'sensitive_image_revealed')
    check('explicit_sensitive_reveal_decodes_native_image', True)
    check('revealed_sensitive_image_still_disables_ocr', not button('Recognize text').getState().contains(pyatspi.STATE_ENABLED))
    click('Hide')
    wait_for(lambda: not window_visible(), 'sensitive_window_hidden')
    wake_existing()
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'sensitive_remasked_after_hide')
    check('hide_reopen_revokes_sensitive_reveal', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
    check('sensitive_filter_identity_survives_one_hide', sensitive_type_control == button('Text') and
          not sensitive_type_control.getState().contains(pyatspi.STATE_DEFUNCT))
    click('Reveal for this session')
    wait_for(lambda: any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()), 'sensitive_image_revealed_again')
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'sensitive_settings_handoff')
    click('Back to history')
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'sensitive_remasked_after_settings')
    check('settings_handoff_revokes_sensitive_reveal', True)
    sensitive_type_control = button('Text')  # Settings may legitimately rebuild history controls.
    click('Reveal for this session')
    click('Hide')
    wait_for(lambda: not window_visible(), 'rapid_sensitive_hide')
    wake_existing()
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'rapid_reveal_remains_revoked')
    check('rapid_reveal_hide_does_not_restore_sensitive_preview', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
    check('sensitive_filter_controls_keep_native_identity', sensitive_type_control == button('Text') and
          not sensitive_type_control.getState().contains(pyatspi.STATE_DEFUNCT))
    click('Text')
    wait_for(lambda: has_text('4 items') and button('Reveal for this session'), 'sensitive_text_masked')
    secret = 'Sensitive synthetic preview fixture · 中文'
    check('sensitive_text_starts_masked', not has_text(secret))
    click('Reveal for this session')
    wait_for(lambda: has_text(secret), 'sensitive_text_explicitly_revealed')
    check('explicit_sensitive_reveal_displays_text', True)
    wait_for(editor, 'sensitive_selection_change').queryEditableText().setTextContents('Welcome')
    wait_for(lambda: has_text('1 items') and not has_text(secret), 'public_selection_after_reveal')
    click('Image')
    wait_for(lambda: has_text('0 items'), 'different_kind_after_reveal')
    wait_for(editor, 'clear_sensitive_selection_search').queryEditableText().setTextContents('')
    wait_for(lambda: has_text('1 items') and button('Reveal for this session'), 'selection_change_revoked_reveal')
    check('selection_change_revokes_sensitive_reveal', not has_text(secret))
    persisted = json.loads((history_root / 'history.json').read_text())
    check('sensitive_reveal_keeps_history_memory_only', len(persisted['items']) == 3 and
          all(not item['sensitive'] for item in persisted['items']) and not list((history_root / 'blobs').iterdir()))
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'sensitive_quit_settings')
    click('Quit Clipboard')
    app.wait(timeout=10)
    check('sensitive_preview_quits_cleanly', app.returncode == 0)

except Exception as error:
    if sensitive_probe:
        checks.append({'name': 'sensitive_ui_probe', 'passed': False, 'detail': type(error).__name__})
        (out / 'probe-error.log').write_text('Sensitive preview probe failed; content diagnostics suppressed.\n')
    else:
        (out / 'probe-error.log').write_text(traceback.format_exc())
        (out / 'x11-tree.txt').write_text(subprocess.check_output(['xwininfo', '-root', '-tree'], text=True))
        diagnostic = []
        for node in nodes():
            try:
                diagnostic.append({'name': node.name, 'role': node.getRoleName(), 'interfaces': node.get_interfaces()})
            except Exception:
                pass
        (out / 'accessibility-tree.json').write_text(json.dumps(diagnostic, ensure_ascii=False, indent=2))
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
              'checks': checks, 'limitations': limitations}
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
