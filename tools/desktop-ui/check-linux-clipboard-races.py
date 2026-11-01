#!/usr/bin/env python3
"""Cancel native X11 requests on an explicitly isolated display."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
if os.environ.get('CLIPBOARD_PRIVATE_X11_TEST') != '1':
    parser.error('Run only in an owned Xvfb with CLIPBOARD_PRIVATE_X11_TEST=1')
out = Path(args.output)
out.mkdir(parents=True, exist_ok=True)
checks = []
completed = False
peer = None
display = None
log = (out / 'peer.log').open('w')


def check(name, passed):
    checks.append({'name': name, 'passed': bool(passed)})
    print(name + ': ' + str(bool(passed)), flush=True)
    if not passed:
        raise RuntimeError(name)


x11 = ctypes.CDLL('libX11.so.6')
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x11.XDefaultRootWindow.restype = ctypes.c_ulong
x11.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
x11.XCreateSimpleWindow.restype = ctypes.c_ulong
x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x11.XInternAtom.restype = ctypes.c_ulong
x11.XConvertSelection.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong,
                                 ctypes.c_ulong, ctypes.c_ulong]
x11.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
try:
    fixture = 'Clipboard cancellation fixture 😀 中文'
    peer = subprocess.Popen([str(Path(args.executable).resolve()), 'clipboard-peer'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    peer.stdin.write((json.dumps({'operation': 'write', 'text': fixture}) + '\n').encode())
    peer.stdin.flush()
    if not select.select([peer.stdout], [], [], 10)[0]:
        raise RuntimeError('peer_write_timeout')
    check('native_owner_ready', json.loads(peer.stdout.readline()).get('ok'))
    display = x11.XOpenDisplay(None)
    check('private_requestor_connected', bool(display))
    clipboard = x11.XInternAtom(display, b'CLIPBOARD', 0)
    result = x11.XInternAtom(display, b'CLIPBOARD_CANCELLED_RESULT', 0)
    for name in [b'UTF8_STRING', b'TARGETS']:
        os.kill(peer.pid, signal.SIGSTOP)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if '\nState:\tT' in Path('/proc/' + str(peer.pid) + '/status').read_text():
                break
            time.sleep(.01)
        else:
            raise RuntimeError('owned_peer_stop_timeout')
        window = x11.XCreateSimpleWindow(display, x11.XDefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0)
        x11.XConvertSelection(display, clipboard, x11.XInternAtom(display, name, 0), result, window, 0)
        x11.XSync(display, 0)
        x11.XDestroyWindow(display, window)
        x11.XSync(display, 0)
        os.kill(peer.pid, signal.SIGCONT)
        deadline = time.monotonic() + 1
        while peer.poll() is None and time.monotonic() < deadline:
            time.sleep(.01)
        check('owner_survives_cancelled_' + name.decode(), peer.poll() is None)
        copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-out', '-target', 'UTF8_STRING'], timeout=5)
        check('fresh_reader_succeeds_after_cancelled_' + name.decode(), copied.decode() == fixture)
    peer.stdin.close()
    check('owner_exits_cleanly', peer.wait(timeout=5) == 0)
    completed = True
finally:
    if display:
        x11.XCloseDisplay(display)
    if peer and peer.poll() is None:
        os.kill(peer.pid, signal.SIGCONT)
        peer.terminate()
        try:
            peer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait(timeout=5)
    log.close()
    (out / 'results.json').write_text(json.dumps({'passed': completed, 'checks': checks}, indent=2))
