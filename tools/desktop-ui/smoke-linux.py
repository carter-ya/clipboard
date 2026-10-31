#!/usr/bin/env python3
"""Exercise accessible GTK controls in an isolated Xvfb/DBus desktop, no key injection."""
import argparse
import ctypes
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
    "No keyboard injection; programmatic accessibility control operations only.",
    "Real Chinese IME composition and global hotkey focus transfer remain untested.",
]
history_root = out / ('history-' + uuid.uuid4().hex)
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
    click('Save behavior')
    settings_file = history_root / 'desktop-settings.json'
    wait_for(lambda: settings_file.exists(), 'saved_settings_file')
    saved = json.loads(settings_file.read_text())
    check('behavior_saved_without_enabling_recording', saved['recordingEnabled'] is False and saved['closeToTray'] is True)
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
    sensitive_probe = True
    history_root = out / ('sensitive-preview-' + uuid.uuid4().hex)
    app = subprocess.Popen([str(Path(args.executable).resolve()), '--smoke-root', str(history_root), '--smoke-sensitive'],
                           stdout=log, stderr=log, start_new_session=True)
    wait_for(lambda: has_text('Ready') and has_text('5 items'), 'sensitive_private_profile')
    click('Image')
    wait_for(lambda: has_text('1 items') and button('Reveal for this session') and has_text('Sensitive content is hidden.'), 'sensitive_image_masked')
    check('sensitive_image_starts_masked', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
    click('Reveal for this session')
    wait_for(lambda: any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()), 'sensitive_image_revealed')
    check('explicit_sensitive_reveal_decodes_native_image', True)
    check('revealed_sensitive_image_still_disables_ocr', not button('Recognize text').getState().contains(pyatspi.STATE_ENABLED))
    click('Hide')
    wait_for(lambda: not window_visible(), 'sensitive_window_hidden')
    wake_existing()
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'sensitive_remasked_after_hide')
    check('hide_reopen_revokes_sensitive_reveal', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
    click('Reveal for this session')
    wait_for(lambda: any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()), 'sensitive_image_revealed_again')
    click('Settings')
    wait_for(lambda: has_text('Preferences'), 'sensitive_settings_handoff')
    click('Back to history')
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'sensitive_remasked_after_settings')
    check('settings_handoff_revokes_sensitive_reveal', True)
    click('Reveal for this session')
    click('Hide')
    wait_for(lambda: not window_visible(), 'rapid_sensitive_hide')
    wake_existing()
    wait_for(lambda: has_text('Sensitive content is hidden.') and button('Reveal for this session'), 'rapid_reveal_remains_revoked')
    check('rapid_reveal_hide_does_not_restore_sensitive_preview', not any(node.getRole() == pyatspi.ROLE_IMAGE for node in nodes()))
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
