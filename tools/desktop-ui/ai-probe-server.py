#!/usr/bin/env python3
"""Owned loopback fixture for explicit UI diagnostics; never logs request data."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if os.environ.get('CLIPBOARD_PRIVATE_AI_TEST') != '1':
    raise SystemExit(2)

analysis_mode = os.environ.get("CLIPBOARD_PRIVATE_AI_MODE") == "analysis"
file_mode = os.environ.get("CLIPBOARD_PRIVATE_AI_MODE") == "file"

lock = threading.Lock()
release = threading.Event()
report = dict(requests=0, fixedTestsOnly=True, noAuthorization=True, noCookies=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        with lock:
            report['fixedTestsOnly'] = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.connection.settimeout(5)
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 8192:
                raise ValueError()
            body = json.loads(self.rfile.read(length))
            messages = body.get('messages', [])
            fixed = (self.path == '/v1/chat/completions' and
                     body.get('model') == 'fixture-model' and body.get('max_tokens') == 4 and
                     body.get('temperature') == 0 and len(messages) == 2 and
                     messages[-1].get('role') == 'user' and
                     isinstance(messages[-1].get('content'), str) and
                     messages[-1]['content'].endswith('\n\nreply OK'))
            if analysis_mode:
                fixed = (self.path == '/v1/chat/completions' and
                         body.get('model') == 'fixture-model' and 'max_tokens' not in body and
                         len(messages) == 2 and messages[-1].get('role') == 'user' and
                         isinstance(messages[-1].get('content'), str) and
                         messages[-1]['content'].endswith('\n\nRelease checklist · build, test, publish'))
            if file_mode:
                expected = 'This synthetic remote file summary uses the current body. ' + 'Private file body context. ' * 10
                fixed = (self.path == '/v1/chat/completions' and body.get('model') == 'fixture-model' and
                         'max_tokens' not in body and len(messages) == 2 and
                         messages[-1].get('role') == 'user' and
                         isinstance(messages[-1].get('content'), str) and
                         messages[-1]['content'].endswith('\n\n' + expected.strip()) and
                         'private-upload-name' not in messages[-1]['content'])
            with lock:
                report['requests'] += 1
                index = report['requests']
                report['fixedTestsOnly'] &= fixed
                report['noAuthorization'] &= self.headers.get('Authorization') is None
                report['noCookies'] &= self.headers.get('Cookie') is None
            if (analysis_mode and index == 1) or (file_mode and index == 2) or (not analysis_mode and not file_mode and index >= 4):
                print('blocked', flush=True)
                release.wait(45 if analysis_mode or file_mode else 10)
            status = 200 if file_mode else ((503 if index == 1 else 200) if analysis_mode else (401 if index == 2 else 200))
            response = ({'error': 'synthetic authentication failure'} if status == 401 else
                        {'choices': [{'message': {'content': 'Private file summary fixture' if file_mode else ('Private summary fixture' if analysis_mode else 'OK')}}]})
            data = json.dumps(response).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Set-Cookie', 'synthetic=ignored; Path=/')
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            with lock:
                report['fixedTestsOnly'] = False


server = Server(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
thread.start()
print('ready:' + str(server.server_address[1]), flush=True)
try:
    # EOF releases any slow request and shuts down only this fixture.
    for line in sys.stdin.buffer:
        if line in (b'release\n', b'release\r\n'):
            release.set()
finally:
    release.set()
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
print(json.dumps(report), flush=True)
