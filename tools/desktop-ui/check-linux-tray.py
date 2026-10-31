#!/usr/bin/env python3
"""Private-session SNI/dbusmenu integration fixture; never run on a user bus."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import threading
import time

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
if os.environ.get('CLIPBOARD_PRIVATE_SHELL_TEST') != '1':
    raise SystemExit('Use the private-session shell-test wrapper')
dbus.mainloop.glib.threads_init()
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
if bus.name_has_owner('org.kde.StatusNotifierWatcher'):
    raise SystemExit('An existing tray watcher must not be replaced')


class Watcher(dbus.service.Object):
    def __init__(self):
        self.name = dbus.service.BusName('org.kde.StatusNotifierWatcher', bus, do_not_queue=True)
        super().__init__(bus, '/StatusNotifierWatcher')
        self.owner = None
        self.path = None

    @dbus.service.method('org.kde.StatusNotifierWatcher', in_signature='s', out_signature='', sender_keyword='sender')
    def RegisterStatusNotifierItem(self, service, sender=None):
        self.owner = sender if service.startswith('/') else service
        self.path = service if service.startswith('/') else '/StatusNotifierItem'

    @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='ss', out_signature='v')
    def Get(self, interface, name):
        if interface == 'org.kde.StatusNotifierWatcher' and name == 'IsStatusNotifierHostRegistered':
            return dbus.Boolean(True, variant_level=1)
        raise dbus.exceptions.DBusException('Unknown fixture property')


watcher = Watcher()
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True)
thread.start()
checks = []
peer = None
selector = selectors.DefaultSelector()
out = Path(args.output)
out.parent.mkdir(parents=True, exist_ok=True)


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    if not value:
        raise RuntimeError(name)


def wait_line(expected):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if peer.poll() is not None:
            raise RuntimeError('tray_peer_exited')
        if selector.select(timeout=0.2):
            line = peer.stdout.readline().decode('ascii').strip()
            if line == expected:
                return
    raise RuntimeError('tray_peer_checkpoint_' + expected)


try:
    peer = subprocess.Popen([str(Path(args.executable).resolve()), 'tray-peer'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    selector.register(peer.stdout, selectors.EVENT_READ)
    wait_line('ready')
    check('tray_registers_on_private_watcher', watcher.owner is not None and watcher.path == '/StatusNotifierItem')
    item = bus.get_object(watcher.owner, watcher.path, introspect=False)
    props = dbus.Interface(item, 'org.freedesktop.DBus.Properties')
    values = props.GetAll('org.kde.StatusNotifierItem')
    check('tray_native_properties_and_menu_path', values['Status'] == 'Active' and values['Menu'] == '/MenuBar'
          and values['Title'] == 'Clipboard - paused' and values['IconName'] == 'edit-paste')
    menu_object = bus.get_object(watcher.owner, '/MenuBar', introspect=False)
    menu = dbus.Interface(menu_object, 'com.canonical.dbusmenu')
    menu_props = dbus.Interface(menu_object, 'org.freedesktop.DBus.Properties')
    check('menu_protocol_version', menu_props.Get('com.canonical.dbusmenu', 'Version') == 3)
    layout = menu.GetLayout(dbus.Int32(0), dbus.Int32(-1), dbus.Array([], signature='s'))
    labels = [str(child[1]['label']) for child in layout[1][2]]
    check('menu_contains_real_native_actions', labels == ['Show history', 'Start recording', 'Settings', 'Quit'])
    peer.stdin.write(b'language:zh\n')
    peer.stdin.flush()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - 已暂停':
        time.sleep(0.05)
    layout = menu.GetLayout(dbus.Int32(0), dbus.Int32(-1), dbus.Array([], signature='s'))
    check('native_tray_menu_localizes_without_restart', [str(child[1]['label']) for child in layout[1][2]] == ['显示历史', '开始录制', '设置', '退出'])
    check('native_tray_tooltip_localizes_without_restart', props.Get('org.kde.StatusNotifierItem', 'ToolTip')[3] == '已暂停')
    localized = [
        ('zh-Hant', ['顯示歷程', '開始錄製', '設定', '退出'], '已暫停', '正在錄製', '暫停錄製'),
        ('ja', ['履歴を表示', '記録を開始', '設定', '終了'], '一時停止中', '記録中', '記録を一時停止'),
        ('ko', ['기록 표시', '기록 시작', '설정', '종료'], '일시 정지됨', '기록 중', '기록 일시 정지'),
        ('de', ['Verlauf anzeigen', 'Aufzeichnung starten', 'Einstellungen', 'Beenden'], 'Pausiert', 'Aufzeichnung läuft', 'Aufzeichnung pausieren'),
        ('es', ['Mostrar historial', 'Iniciar registro', 'Ajustes', 'Salir'], 'Pausado', 'Registrando', 'Pausar registro'),
    ]
    for tag, expected, paused, recording, pause_action in localized:
        peer.stdin.write(('language:' + tag + '\n').encode())
        peer.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - ' + paused:
            time.sleep(0.05)
        layout = menu.GetLayout(dbus.Int32(0), dbus.Int32(-1), dbus.Array([], signature='s'))
        check('native_menu_' + tag + '_updates_without_restart', [str(child[1]['label']) for child in layout[1][2]] == expected)
        check('native_tooltip_' + tag + '_matches_language', props.Get('org.kde.StatusNotifierItem', 'ToolTip')[3] == paused)
        peer.stdin.write(b'recording:on\n')
        peer.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - ' + recording:
            time.sleep(0.05)
        layout = menu.GetLayout(dbus.Int32(0), dbus.Int32(-1), dbus.Array([], signature='s'))
        check('native_recording_action_' + tag + '_matches_state', str(layout[1][2][1][1]['label']) == pause_action and
              props.Get('org.kde.StatusNotifierItem', 'ToolTip')[3] == recording)
        peer.stdin.write(b'recording:off\n')
        peer.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - ' + paused:
            time.sleep(0.05)
    peer.stdin.write(b'language:en\n')
    peer.stdin.flush()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - paused':
        time.sleep(0.05)
    dbus.Interface(item, 'org.kde.StatusNotifierItem').Activate(dbus.Int32(0), dbus.Int32(0))
    wait_line('action:2')
    check('native_tray_activation_reaches_action_stream', True)
    menu.Event(dbus.Int32(3), 'clicked', dbus.Int32(0, variant_level=1), dbus.UInt32(0))
    wait_line('action:3')
    check('native_settings_menu_reaches_action_stream', True)
    peer.stdin.write(b'recording:on\n')
    peer.stdin.flush()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and props.Get('org.kde.StatusNotifierItem', 'Title') != 'Clipboard - recording':
        time.sleep(0.05)
    layout = menu.GetLayout(dbus.Int32(0), dbus.Int32(-1), dbus.Array([], signature='s'))
    check('recording_updates_native_menu_and_tooltip', str(layout[1][2][1][1]['label']) == 'Pause recording'
          and props.Get('org.kde.StatusNotifierItem', 'ToolTip')[3] == 'Recording')
    menu.Event(dbus.Int32(2), 'clicked', dbus.Int32(0, variant_level=1), dbus.UInt32(0))
    wait_line('action:4')
    check('native_recording_menu_reaches_action_stream', True)
    menu.Event(dbus.Int32(4), 'clicked', dbus.Int32(0, variant_level=1), dbus.UInt32(0))
    wait_line('action:5')
    check('native_quit_menu_reaches_action_stream', True)
    owner = watcher.owner
    peer.stdin.write(b'quit\n')
    peer.stdin.flush()
    peer.wait(timeout=10)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and bus.name_has_owner(owner):
        time.sleep(0.05)
    check('stopping_removes_tray_service', not bus.name_has_owner(owner))
except Exception as error:
    checks.append({'name': 'native_tray_probe', 'passed': False, 'detail': str(error)[:160]})
finally:
    if peer and peer.poll() is None:
        peer.terminate()
        try:
            peer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait(timeout=5)
    selector.close()
    loop.quit()
    thread.join(timeout=2)
    report = {'passed': bool(checks) and all(c['passed'] for c in checks), 'checks': checks}
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
