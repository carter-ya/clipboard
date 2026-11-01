#!/usr/bin/env python3
"""Owned public-metadata fixture. Reports only counts and validation booleans."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if os.environ.get('CLIPBOARD_PRIVATE_UPDATE_TEST') != '1':
    raise SystemExit(2)
release = threading.Event()
lock = threading.Lock()
report = dict(requests=0, fixedTestsOnly=True, noAuthorization=True, noCookies=True)


class Server(ThreadingHTTPServer):
    daemon_threads = False

    def handle_error(self, request, client_address):
        with lock:
            report['fixedTestsOnly'] = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.connection.settimeout(5)
        with lock:
            report['requests'] += 1
            index = report['requests']
            report['fixedTestsOnly'] &= self.path == '/releases?per_page=20' and self.headers.get('Content-Length', '0') == '0'
            report['noAuthorization'] &= self.headers.get('Authorization') is None
            report['noCookies'] &= self.headers.get('Cookie') is None
        if index >= 3:
            print('blocked', flush=True)
            release.wait(20)
        assets = [{'name': 'ClipboardDesktop-0.2.0-' + target + suffix, 'state': 'uploaded', 'size': 100}
                  for target, suffix in [('linux-arm64', '.tar.gz'), ('linux-x64', '.tar.gz'), ('windows-x64', '-setup.exe')]]
        assets.append({'name': 'SHA256SUMS', 'state': 'uploaded', 'size': 100})
        body = json.dumps([dict(tag_name='desktop-v0.2.0', draft=False, prerelease=False, assets=assets)]).encode()
        try:
            self.send_response(503 if index == 1 else 200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', 'synthetic=ignored; Path=/')
            self.end_headers()
            self.wfile.write(body)
        except ConnectionError:
            pass


server = Server(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.05})
thread.start()
print('ready:' + str(server.server_address[1]), flush=True)
try:
    sys.stdin.buffer.read()
finally:
    release.set()
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
print(json.dumps(report), flush=True)
