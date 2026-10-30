#!/usr/bin/env python3
"""Native service checks on isolated credentials, startup entries and loopback HTTP."""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--ocr-fixture', required=True)
args = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 1024 or self.rfile.read(size) != b'synthetic fixture':
            self.send_error(400)
            return
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/must-not-follow')
            body = b''
        else:
            self.send_response(200)
            body = b'x' * 4096 if self.path == '/oversize' else b'fixture response'
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='clipboard-services-fixture-') as folder:
        environment = os.environ.copy()
        environment['CLIPBOARD_PRIVATE_SERVICES_TEST'] = '1'
        daemon = None
        log = None
        try:
            if os.name != 'nt':
                # This wrapper must itself run inside a fresh dbus-run-session.
                owner = subprocess.check_output(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                                                  '--object-path', '/org/freedesktop/DBus', '--method',
                                                  'org.freedesktop.DBus.NameHasOwner', 'org.freedesktop.secrets'], text=True)
                if 'true' in owner:
                    raise RuntimeError('Existing user Secret Service must not be used')
                environment['XDG_DATA_HOME'] = str(Path(folder) / 'data')
                environment['XDG_CONFIG_HOME'] = str(Path(folder) / 'config')
                environment['GNOME_KEYRING_CONTROL'] = str(Path(folder) / 'control')
                log = open(Path(folder) / 'keyring.log', 'wb')
                daemon = subprocess.Popen(['gnome-keyring-daemon', '--foreground', '--components=secrets', '--unlock'],
                                          env=environment, stdin=subprocess.PIPE, stdout=log, stderr=log)
                daemon.stdin.write(b'synthetic-keyring-password\n')
                daemon.stdin.close()
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    owner = subprocess.check_output(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                                                      '--object-path', '/org/freedesktop/DBus', '--method',
                                                      'org.freedesktop.DBus.NameHasOwner', 'org.freedesktop.secrets'], text=True)
                    if 'true' in owner:
                        break
                    if daemon.poll() is not None:
                        raise RuntimeError('Private fixture keyring exited')
                    time.sleep(0.1)
                else:
                    raise RuntimeError('Private fixture keyring did not register')
            if os.name == 'nt':
                # Diagnose only a synthetic fixture and fixed stage codes. Never emit OCR output.
                script = Path(__file__).resolve().parents[2] / 'Core/Sources/DesktopServices/Resources/WindowsOCR.ps1'
                powershell = Path(environment['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
                diagnostic = subprocess.run([str(powershell), '-NoLogo', '-NoProfile', '-NonInteractive',
                                             '-ExecutionPolicy', 'Bypass', '-File', str(script), '-Language', 'en'],
                                            input=base64.b64encode(Path(args.ocr_fixture).read_bytes()),
                                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=50)
                stage = diagnostic.stderr.decode('ascii', errors='ignore').strip()
                allowed = {'ocr_unavailable_' + value for value in
                           ('runtime', 'language', 'input', 'stream', 'decode', 'bitmap', 'recognize')}
                print('Windows OCR fixture: ' + ('passed' if diagnostic.returncode == 0 else
                                                stage if stage in allowed else 'process_failed'), flush=True)
            result = subprocess.run([str(Path(args.executable).resolve()), 'platform-services', '--ocr-fixture',
                                     str(Path(args.ocr_fixture).resolve()), '--http-fixture',
                                     'http://127.0.0.1:' + str(server.server_port)], env=environment, timeout=125)
            code = result.returncode
        finally:
            if daemon and daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=5)
            if log:
                log.close()
finally:
    server.shutdown()
    server.server_close()
raise SystemExit(code)
