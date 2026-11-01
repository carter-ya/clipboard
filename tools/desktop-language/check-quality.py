#!/usr/bin/env python3
"""A reproducible synthetic quality gate, separate from process self-checks.

Required concepts detect known omissions/wrong-language regressions. Review the
saved synthetic sentences for unsupported facts too: keyword matches alone do
not establish factual accuracy, translation quality or general model quality.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    executable, model = Path(args.executable).resolve(), Path(args.model).resolve()
    fixtures = json.loads(Path(__file__).with_name('quality-fixtures.json').read_text(encoding='utf-8'))
    output = Path(args.output)
    reports = []
    try:
        for fixture in fixtures:
            request = {'model': str(model), 'text': fixture['text'], 'task': 'summary',
                       'language': fixture['language']}
            start = time.monotonic()
            result = subprocess.run([str(executable)], input=json.dumps(request).encode(),
                                    capture_output=True, timeout=90)
            summary, valid = '', False
            if not result.returncode and not result.stderr and 0 < len(result.stdout) <= 4096:
                value = json.loads(result.stdout)
                summary = value.get('summary', '')
                valid = (value.get('task') == 'summary' and isinstance(summary, str) and
                         value.get('inputTruncated') is False and 0 < len(summary.encode()) <= 2048)
            folded = summary.casefold()
            concepts = [any(term.casefold() in folded for term in alternatives)
                        for alternatives in fixture['requiredConcepts']]
            forbidden = any(term.casefold() in folded for term in fixture.get('forbidden', []))
            reports.append({'id': fixture['id'], 'language': fixture['language'],
                            'seconds': round(time.monotonic() - start, 2),
                            'protocolPassed': valid, 'conceptsPassed': concepts,
                            'knownFabricationAbsent': not forbidden,
                            'passed': valid and all(concepts) and not forbidden,
                            'syntheticSummary': summary})
            print(json.dumps({key: value for key, value in reports[-1].items()
                              if key != 'syntheticSummary'}), flush=True)
    finally:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({'syntheticOnly': True, 'humanReviewRequired': True,
                                      'results': reports}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if len(reports) != len(fixtures) or not all(value['passed'] for value in reports):
        raise RuntimeError('Synthetic summary quality gate failed')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Summary quality gate failed; inspect synthetic-only results')
