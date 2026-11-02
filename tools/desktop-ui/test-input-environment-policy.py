#!/usr/bin/env python3
"""Keep manual IME environment checks separate from the regular app jobs."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class InputEnvironmentPolicyTests(unittest.TestCase):
    def test_manual_application_adds_package_keyboard_without_optional_models(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        steps = {step.get('name'): step for step in data['jobs']['preview']['steps']}
        release = steps['Build optimized desktop artifacts']
        package = steps['Build and exercise Windows keyboard installer']
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for full in [False, True]:
                for mode in ['', 'off', 'application']:
                    for system in ['Linux', 'Windows']:
                        full_scope = event == 'push' or (event == 'workflow_dispatch' and full)
                        narrow = event == 'workflow_dispatch' and mode == 'application' and system == 'Windows'
                        for step, expected in [(release, full_scope or narrow), (package, narrow and not full_scope)]:
                            expression = step['if'].replace('github.event_name', repr(event)).replace('inputs.windows_input_environment', repr(mode)).replace('env.FULL_VALIDATION', repr(str(full_scope).lower())).replace('runner.os', repr(system))
                            selected = eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                            self.assertEqual(bool(selected), expected)
        self.assertIn('-KeyboardOnly -ChineseIme', package['run'])
        self.assertNotIn('-SummaryModel', package['run'])
        installer = (ROOT / 'tools/desktop-package/check-windows-install.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('keyboard_package_scope_does_not_accept_optional_model_fixtures', installer)
        # Full GUI/model consent calls remain inside the positive full branch;
        # the narrowed report names its actual scope rather than claiming them.
        self.assertIn('if (!$KeyboardOnly)', installer)
        self.assertIn("'keyboard_package'", installer)

    def test_application_ime_requires_explicit_manual_request_or_full_integration(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        expression = data['env']['CHINESE_IME_VALIDATION'].removeprefix('${{').removesuffix('}}').strip()
        steps = data['jobs']['preview']['steps']
        provision = next(step for step in steps if step.get('name') == 'Provision and verify the actual Windows Chinese input method')
        keyboard = next(step for step in steps if step.get('name') == 'Exercise native Windows keyboard focus and explicit paste')
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for full in [False, True]:
                for mode in ['', 'off', 'inspect', 'prepare', 'application']:
                    selected = expression.replace('github.event_name', repr(event)).replace('inputs.full_validation', repr(full)).replace('inputs.windows_input_environment', repr(mode))
                    enabled = eval(selected.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                    expected = event == 'push' or (event == 'workflow_dispatch' and (full or mode == 'application'))
                    self.assertEqual(bool(enabled), expected)
                    for system in ['Linux', 'Windows']:
                        condition = provision['if'].replace('runner.os', repr(system)).replace('env.CHINESE_IME_VALIDATION', repr(str(enabled).lower()))
                        actual = eval(condition.replace('&&', ' and '), {'__builtins__': {}})
                        self.assertEqual(bool(actual), system == 'Windows' and expected)
        self.assertLess(steps.index(provision), steps.index(keyboard))
        self.assertIn('check-native-ime.ps1', provision['run'])
        self.assertIn("$env:CHINESE_IME_VALIDATION -eq 'true'", keyboard['run'])
        self.assertIn("'-ChineseIme'", keyboard['run'])
        self.assertIn('-ChineseIme', next(step for step in steps if 'check-windows-install.ps1' in step.get('run', ''))['run'])

    def test_probe_never_runs_a_desktop_build_or_changes_normal_event_scope(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['windows_input_environment']['default'], 'off')
        preview = data['jobs']['preview']
        probe = data['jobs']['input-environment']
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for choice in ['', 'off', 'inspect', 'prepare', 'application']:
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
