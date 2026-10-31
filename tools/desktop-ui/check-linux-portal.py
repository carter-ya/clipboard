#!/usr/bin/env python3
"""Private portal protocol fixture. This does not simulate or claim keyboard input."""
import argparse
import json
import os
import queue
import subprocess
import threading
import time
import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
if bus.name_has_owner('org.freedesktop.portal.Desktop'):
    raise RuntimeError('Refusing an existing desktop portal; use dbus-run-session')
name = dbus.service.BusName('org.freedesktop.portal.Desktop', bus, do_not_queue=True)
ROOT = '/org/freedesktop/portal/desktop'
SHORTCUTS = 'org.freedesktop.portal.GlobalShortcuts'
requests = []
sessions = []
bindings = []
closed = []
mode = {'deny': False}
registrations = []
checks = []
completed = False


def check(label, condition):
    checks.append({'name': label, 'passed': bool(condition)})
    if not condition:
        raise RuntimeError(label)


class Request(dbus.service.Object):
    def __init__(self, path, result):
        super().__init__(bus, path)
        self.path = path
        self.result = result
        requests.append(self)
        GLib.timeout_add(20, self.respond)

    def respond(self):
        self.Response(*self.result)
        return False

    @dbus.service.signal('org.freedesktop.portal.Request', signature='ua{sv}')
    def Response(self, code, results):
        pass

    @dbus.service.method('org.freedesktop.portal.Request', in_signature='', out_signature='')
    def Close(self):
        closed.append(self.path)


class Session(dbus.service.Object):
    def __init__(self, path):
        super().__init__(bus, path)
        self.path = path
        sessions.append(self)

    @dbus.service.signal('org.freedesktop.portal.Session', signature='')
    def Closed(self):
        pass

    @dbus.service.method('org.freedesktop.portal.Session', in_signature='', out_signature='')
    def Close(self):
        closed.append(self.path)
        self.remove_from_connection()


def request(sender, options, code, results):
    path = ROOT + '/request/' + sender[1:].replace('.', '_') + '/' + str(options['handle_token'])
    # The protocol may reuse a request token after the old response is complete.
    for prior in requests:
        if prior.path == path:
            prior.remove_from_connection()
    Request(path, (code, dbus.Dictionary(results, signature='sv')))
    return dbus.ObjectPath(path)


class Portal(dbus.service.Object):
    @dbus.service.method('org.freedesktop.host.portal.Registry', in_signature='sa{sv}', out_signature='', sender_keyword='sender')
    def Register(self, app_id, options, sender):
        registrations.append((sender, str(app_id)))

    @dbus.service.method(SHORTCUTS, in_signature='a{sv}', out_signature='o', sender_keyword='sender')
    def CreateSession(self, options, sender):
        path = ROOT + '/session/' + sender[1:].replace('.', '_') + '/' + str(options['session_handle_token'])
        Session(path)
        return request(sender, options, 0, {'session_handle': dbus.String(path)})

    @dbus.service.method(SHORTCUTS, in_signature='oa{sv}', out_signature='o', sender_keyword='sender')
    def ListShortcuts(self, session, options, sender):
        return request(sender, options, 0, {'shortcuts': dbus.Array([], signature='(sa{sv})')})

    @dbus.service.method(SHORTCUTS, in_signature='oa(sa{sv})sa{sv}', out_signature='o', sender_keyword='sender')
    def BindShortcuts(self, session, shortcuts, parent, options, sender):
        bindings.append(shortcuts)
        bound = dbus.Array([dbus.Struct(('history', dbus.Dictionary({'trigger_description': 'fixture shortcut'}, signature='sv')))], signature='(sa{sv})')
        return request(sender, options, 1 if mode['deny'] else 0, {} if mode['deny'] else {'shortcuts': bound})

    @dbus.service.signal(SHORTCUTS, signature='osta{sv}')
    def Activated(self, session, identifier, timestamp, options):
        pass

    @dbus.service.signal(SHORTCUTS, signature='oa(sa{sv})')
    def ShortcutsChanged(self, session, shortcuts):
        pass


portal = Portal(bus, ROOT)
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True)
thread.start()
env = os.environ.copy()
env.pop('DISPLAY', None)
env['WAYLAND_DISPLAY'] = 'private-portal-fixture'
env['CLIPBOARD_PRIVATE_PORTAL_TEST'] = '1'
peer = subprocess.Popen([os.path.abspath(args.executable), 'portal-peer'], env=env, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
lines = queue.Queue()
reader = threading.Thread(target=lambda: [lines.put(line.strip()) for line in peer.stdout], daemon=True)
reader.start()


def command(value):
    peer.stdin.write(value + '\n')
    peer.stdin.flush()


def status(expected):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        command('status')
        try:
            line = lines.get(timeout=.5)
        except queue.Empty:
            continue
        if line == expected:
            return True
        time.sleep(.03)
    return False


def emit(function):
    event = threading.Event()
    def call():
        function()
        event.set()
        return False
    GLib.idle_add(call)
    if not event.wait(3):
        raise RuntimeError('Fixture dispatch timed out')


try:
    check('first_start_requires_explicit_portal_permission', status('status:2:false'))
    check('startup_does_not_prompt_for_new_shortcut', not bindings)
    check('host_connection_registers_stable_application_identity', registrations[0][1] == 'com.clipboard.desktop')
    command('request')
    check('portal_binding_success_enables_capability', status('status:3:true'))
    check('preferred_trigger_uses_xdg_shortcut_syntax', bindings[0][0][1]['preferred_trigger'] == 'CTRL+ALT+F12')
    session = sessions[-1]
    emit(lambda: portal.Activated(session.path, 'other-action', 1, {}))
    time.sleep(.15)
    check('unregistered_action_is_ignored', lines.empty())
    spoof = dbus.bus.BusConnection(os.environ['DBUS_SESSION_BUS_ADDRESS'])
    message = dbus.lowlevel.SignalMessage(ROOT, SHORTCUTS, 'Activated')
    message.append(dbus.ObjectPath(session.path), 'history', dbus.UInt64(1),
                   dbus.Dictionary({'activation_token': 'synthetic-activation-token'}, signature='sv'), signature='osta{sv}')
    spoof.send_message(message)
    spoof.flush()
    time.sleep(.15)
    check('activation_from_untrusted_bus_peer_is_ignored', lines.empty())
    spoof.close()

    emit(lambda: portal.Activated(session.path, 'history', 1, {'activation_token': 'synthetic-activation-token'}))
    emit(lambda: portal.Activated(session.path, 'history', 2, {'activation_token': 'synthetic-second-token'}))
    command('consume')
    check('queued_activation_keeps_first_token', lines.get(timeout=3) == 'activated:true')
    check('queued_activation_keeps_second_token', lines.get(timeout=3) == 'activated:true')
    emit(lambda: session.Closed())
    check('closed_portal_session_loses_shortcut_capability', status('status:5:false'))
    mode['deny'] = True
    command('request')
    check('denied_portal_binding_is_not_reported_active', status('status:4:false'))
    mode['deny'] = False
    command('request')
    check('explicit_retry_creates_fresh_session', status('status:3:true') and len(sessions) == 3)
    emit(lambda: portal.ShortcutsChanged(sessions[-1].path, dbus.Array([], signature='(sa{sv})')))
    check('removed_shortcut_loses_active_capability', status('status:4:false'))
    command('quit')
    peer.wait(timeout=8)
    check('stop_closes_owned_portal_session', sessions[-1].path in closed)
    completed = True
finally:
    if peer.poll() is None:
        peer.terminate()
        try:
            peer.wait(timeout=3)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait()
    loop.quit()
    thread.join(timeout=3)
    with open(args.output, 'w') as output:
        json.dump({'passed': completed and bool(checks) and all(x['passed'] for x in checks), 'checks': checks}, output, indent=2)
print(json.dumps({'passed': all(x['passed'] for x in checks), 'checks': checks}, indent=2))
