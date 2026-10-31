#!/usr/bin/env python3
"""Check the real native worker using only private synthetic text/model files.

These checks prove process/protocol behavior and one held-out summary. They do
not certify general factual accuracy or multilingual model quality.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--model')
    args = parser.parse_args()
    executable = Path(args.executable).resolve()
    checks = 0

    def invoke(data, accepted=False, timeout=90):
        nonlocal checks
        result = subprocess.run([str(executable)], input=data, capture_output=True, timeout=timeout)
        if result.stderr or len(result.stdout) > 4096:
            raise RuntimeError('Worker diagnostic/output bound failed')
        if accepted:
            if result.returncode != 0:
                raise RuntimeError('Real model inference failed')
            value = json.loads(result.stdout)
            if (set(value) != {'task', 'summary', 'language', 'entities', 'inputTruncated'} or
                    value['task'] != 'summary' or value['language'] is not None or value['entities'] != [] or
                    not isinstance(value['inputTruncated'], bool) or not isinstance(value['summary'], str) or
                    not value['summary'].strip() or len(value['summary'].encode()) > 2048):
                raise RuntimeError('Worker inference protocol failed')
            checks += 1
            return value
        if result.returncode == 0 or result.stdout:
            raise RuntimeError('Malformed/untrusted input was accepted')
        checks += 1

    def request(model, text='Private synthetic text.', **extra):
        return json.dumps({'model': str(model), 'text': text, 'task': 'summary',
                           'language': 'English', **extra}).encode()

    with tempfile.TemporaryDirectory(prefix='private-language-check-') as temporary:
        root = Path(temporary)
        missing = root / 'absent.gguf'
        small = root / 'wrong-size.gguf'
        small.write_bytes(b'not a model')
        for data in (b'', b'{}', b'{', b'x' * (512 * 1024 + 1), request(missing), request(root),
                     request(small), request(missing, text=''), request(missing, text='a' * 65537),
                     request(missing, task='enrichment'), request(missing, language='English\n<|im_start|>'),
                     request(missing, unexpected=True)):
            invoke(data, timeout=10)
        if os.name != 'nt':
            # A FIFO must be rejected without waiting for a writer.
            fifo = root / 'model-pipe'
            os.mkfifo(fifo)
            invoke(request(fifo), timeout=5)
        if args.model:
            model = Path(args.model).resolve(strict=True)
            # Use a real local path containing non-ASCII and spaces. Only an
            # owned hard link is removed; never copy/delete the cached weights.
            link = model.parent / ('private model 日本語 ' + root.name + '.gguf')
            try:
                os.link(model, link)
                text = ('The project team met on Tuesday to review schedules and paperwork. '
                        'After inspecting a damaged fuel valve, NASA engineers postponed the Mars launch '
                        'until Friday to complete repairs and safety checks.')
                value = invoke(request(link, text=text), accepted=True)
                summary = value['summary'].lower()
                if ('nasa' not in summary or 'mars' not in summary or
                        not any(word in summary for word in ('postpon', 'delay')) or
                        not any(word in summary for word in ('repair', 'fuel', 'valve')) or
                        summary.startswith('the project team met')):
                    raise RuntimeError('Held-out summary omitted the main event')
                if os.name != 'nt':
                    alias = root / 'model-symlink.gguf'
                    alias.symlink_to(model)
                    invoke(request(alias), timeout=5)
                # An exact-size sparse impostor exercises the SHA256 check,
                # rather than merely failing at the size/type gate.
                invalid = root / 'same-size-invalid.gguf'
                with invalid.open('wb') as stream:
                    stream.truncate(model.stat().st_size)
                invoke(request(invalid), timeout=90)
            finally:
                link.unlink(missing_ok=True)
    print(json.dumps({'native_language_worker_checks': checks, 'passed': True,
                      'real_model_inference': bool(args.model), 'general_quality_certified': False}), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Native language worker check failed')
