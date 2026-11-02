#!/usr/bin/env python3
"""Keep manual IME environment checks separate from the regular app jobs."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class InputEnvironmentPolicyTests(unittest.TestCase):
    def test_probe_never_runs_a_desktop_build_or_changes_normal_event_scope(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['windows_input_environment']['default'], 'off')
        preview = data['jobs']['preview']
        probe = data['jobs']['input-environment']
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for choice in ['', 'off', 'inspect', 'prepare']:
                expected_probe = event == 'workflow_dispatch' and choice in ['inspect', 'prepare']
                for job, expected in [(probe, expected_probe), (preview, not expected_probe)]:
                    expression = job['if'].replace('github.event_name', repr(event)).replace('inputs.windows_input_environment', repr(choice))
                    selected = eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                    with self.subTest(event=event, choice=choice, job=job.get('name', '')):
                        self.assertEqual(bool(selected), expected)
        self.assertEqual(probe['runs-on'], 'windows-2022')
        self.assertLessEqual(int(probe['timeout-minutes']), 8)
        self.assertNotIn('swift', str(probe['steps']).lower())
        self.assertNotIn('download-test-model', str(probe['steps']))


if __name__ == '__main__':
    unittest.main()
