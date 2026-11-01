#!/usr/bin/env python3
"""Verify the actual isolated PDF decoder with synthetic documents only."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop-ui'))
from pdf_fixture import text_pdf

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
args = parser.parse_args()
checks = []


def verify(name, data, status, expected=b''):
    result = subprocess.run([str(Path(args.executable).resolve())], input=data,
                            capture_output=True, timeout=15)
    valid = result.returncode == status and result.stdout.strip() == expected
    checks.append({'name': name, 'passed': valid})
    if not valid:
        print(json.dumps({'checks': checks, 'passed': False}), flush=True)
        raise SystemExit(1)


verify('native_pdf_text_roundtrip', text_pdf('Synthetic private PDF text.'), 0, b'Synthetic private PDF text.')
verify('native_pdf_unicode_and_astral_mapping', text_pdf('AB', unicode_mapping=True), 0, '中😀'.encode())
verify('native_pdf_rejects_malformed_data', b'%PDF-synthetic-invalid', 4)
verify('native_pdf_rejects_empty_text', text_pdf(''), 4)
verify('native_pdf_input_budget', b'x' * (1024 * 1024 + 1), 3)
verify('native_pdf_page_budget', text_pdf('Synthetic page bound.', pages=257), 3)
print(json.dumps({'checks': checks, 'passed': True}), flush=True)
