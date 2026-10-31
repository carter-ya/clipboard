#!/usr/bin/env python3
"""Exercise both native pipe line endings against an owned loopback fixture."""
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


class ProbeReleaseTests(unittest.TestCase):
    def test_lf_and_crlf_release_an_active_request_without_waiting_for_fallback(self):
        for ending in (b'\n', b'\r\n'):
            with self.subTest(ending=repr(ending)):
                environment = os.environ.copy()
                environment.update(CLIPBOARD_PRIVATE_AI_TEST='1', CLIPBOARD_PRIVATE_AI_MODE='analysis')
                server = subprocess.Popen([sys.executable, str(Path(__file__).with_name('ai-probe-server.py'))],
                                          env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL)
                pool = ThreadPoolExecutor(max_workers=2)
                try:
                    ready = pool.submit(server.stdout.readline).result(timeout=5).decode('ascii').strip()
                    self.assertTrue(ready.startswith('ready:'))
                    port = int(ready[6:])

                    def request():
                        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=12)
                        try:
                            body = json.dumps({'model': 'fixture-model', 'messages': [
                                {'role': 'system', 'content': 'Synthetic system'},
                                {'role': 'user', 'content': 'Synthetic input\n\nRelease checklist · build, test, publish'}]})
                            connection.request('POST', '/v1/chat/completions', body.encode(),
                                               {'Content-Type': 'application/json'})
                            response = connection.getresponse()
                            response.read()
                            return response.status
                        finally:
                            connection.close()

                    pending = pool.submit(request)
                    blocked = pool.submit(server.stdout.readline).result(timeout=5)
                    self.assertEqual(blocked.strip(), b'blocked')
                    server.stdin.write(b'release' + ending)
                    server.stdin.flush()
                    self.assertEqual(pending.result(timeout=10), 503)
                finally:
                    server.stdin.close()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                    pool.shutdown(wait=True, cancel_futures=True)
                report = json.loads(server.stdout.readline())
                server.stdout.close()
                self.assertEqual(report['requests'], 1)
                self.assertTrue(report['fixedTestsOnly'] and report['noAuthorization'] and report['noCookies'])
                self.assertEqual(server.returncode, 0)


if __name__ == '__main__':
    unittest.main()
