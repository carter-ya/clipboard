#!/usr/bin/env python3
"""Response disconnects must not masquerade as invalid synthetic request bodies."""
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
import http.client
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class FailingOutput(io.BytesIO):
    def __init__(self, error, body_only):
        super().__init__()
        self.error = error
        self.body_only = body_only
        self.writes = 0

    def write(self, value):
        self.writes += 1
        if not self.body_only or self.writes > 1:
            raise self.error
        return super().write(value)


class ProbeDisconnectTests(unittest.TestCase):
    def handler(self, error, body_only=False, valid=True):
        source = Path(__file__).with_name('ai-probe-server.py')
        spec = importlib.util.spec_from_file_location('private_ai_fixture', source)
        fixture = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {'CLIPBOARD_PRIVATE_AI_TEST': '1', 'CLIPBOARD_PRIVATE_AI_MODE': ''}):
            spec.loader.exec_module(fixture)
        body = json.dumps({'model': 'fixture-model' if valid else 'other-synthetic-model',
                           'max_tokens': 4, 'temperature': 0, 'messages': [
                               {'role': 'system', 'content': 'Synthetic instructions'},
                               {'role': 'user', 'content': 'Synthetic input\n\nreply OK'}]}).encode()
        handler = fixture.Handler.__new__(fixture.Handler)
        handler.connection = SimpleNamespace(settimeout=lambda _: None)
        handler.headers = Message()
        handler.headers['Content-Length'] = str(len(body))
        handler.path = '/v1/chat/completions'
        handler.rfile = io.BytesIO(body)
        handler.wfile = FailingOutput(error, body_only)
        handler.request_version = 'HTTP/1.1'
        handler.requestline = 'POST /v1/chat/completions HTTP/1.1'
        handler.command = 'POST'
        return fixture, handler

    def test_valid_request_remains_valid_when_cancelled_response_disconnects(self):
        for error in [BrokenPipeError(), ConnectionResetError(), ConnectionAbortedError()]:
            for body_only in [False, True]:
                with self.subTest(error=type(error).__name__, body_only=body_only):
                    fixture, handler = self.handler(error, body_only)
                    handler.do_POST()
                    self.assertEqual(fixture.report['requests'], 1)
                    self.assertTrue(fixture.report['fixedTestsOnly'])
                    self.assertEqual(fixture.report['invalidRequests'], 0)
                    self.assertEqual(fixture.report['handlerFailures'], 0)
                    self.assertEqual(fixture.report['responseDisconnects'], 1)
                    self.assertTrue(fixture.report['noAuthorization'] and fixture.report['noCookies'])

    def test_disconnect_never_hides_invalid_requests_or_unknown_failures(self):
        fixture, handler = self.handler(ConnectionAbortedError(), valid=False)
        handler.do_POST()
        self.assertFalse(fixture.report['fixedTestsOnly'])
        self.assertEqual(fixture.report['invalidRequests'], 1)
        self.assertEqual(fixture.report['modelMismatches'], 1)
        fixture, handler = self.handler(RuntimeError('synthetic internal failure'))
        handler.do_POST()
        self.assertFalse(fixture.report['fixedTestsOnly'])
        self.assertEqual(fixture.report['handlerFailures'], 1)


    def test_real_four_request_server_exits_after_owned_cancellation(self):
        environment = os.environ.copy()
        environment.update(CLIPBOARD_PRIVATE_AI_TEST='1', CLIPBOARD_PRIVATE_AI_MODE='')
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('ai-probe-server.py'))],
                                   env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        pool = ThreadPoolExecutor(max_workers=1)
        connection = None
        try:
            ready = pool.submit(process.stdout.readline).result(timeout=5).decode('ascii').strip()
            self.assertTrue(ready.startswith('ready:'))
            port = int(ready[6:])
            body = json.dumps({'model': 'fixture-model', 'max_tokens': 4, 'temperature': 0, 'messages': [
                {'role': 'system', 'content': 'Synthetic instructions'},
                {'role': 'user', 'content': 'Synthetic input\n\nreply OK'}]}).encode()
            for expected in [200, 401, 200]:
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                connection.request('POST', '/v1/chat/completions', body, {'Content-Type': 'application/json'})
                response = connection.getresponse()
                self.assertEqual(response.status, expected)
                response.read()
                connection.close()
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            connection.request('POST', '/v1/chat/completions', body, {'Content-Type': 'application/json'})
            blocked = pool.submit(process.stdout.readline).result(timeout=5)
            self.assertEqual(blocked.strip(), b'blocked')
            connection.close()
            process.stdin.close()
            process.wait(timeout=5)
            report = json.loads(pool.submit(process.stdout.readline).result(timeout=5))
            self.assertEqual(process.returncode, 0)
            self.assertEqual(report['requests'], 4)
            self.assertEqual(report['invalidRequests'], 0)
            self.assertEqual(report['handlerFailures'], 0)
            self.assertTrue(report['fixedTestsOnly'] and report['noAuthorization'] and report['noCookies'])
        finally:
            if connection:
                connection.close()
            if not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            pool.shutdown(wait=True, cancel_futures=True)
            process.stdout.close()


if __name__ == '__main__':
    unittest.main()
