#!/usr/bin/env python3
"""Keep manual IME environment checks separate from the regular app jobs."""
from pathlib import Path
from fnmatch import fnmatchcase
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class InputEnvironmentPolicyTests(unittest.TestCase):
    def test_client_profile_only_never_changes_server_application_provisioning(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        steps = data['jobs']['input-environment']['steps']
        prepare = next(step for step in steps if step.get('name') == 'Inspect or provision the isolated Windows input environment')
        self.assertEqual(prepare['env']['CLIENT_PROFILE_ONLY'], "${{ inputs.windows_input_runner == 'windows-11-arm' }}")
        self.assertIn("-ProfileOnly:($env:PREPARE_CHINESE_INPUT -eq 'true' -and $env:CLIENT_PROFILE_ONLY -eq 'true')", prepare['run'])
        application = next(step for step in data['jobs']['preview']['steps'] if step.get('name') == 'Provision and verify the actual Windows Chinese input method')
        self.assertNotIn('ProfileOnly', str(application))
        for name in ['Verify private fixture interpreter and pipe encoding', 'Verify private fixture on Windows PowerShell 5.1']:
            step = next(step for step in data['jobs']['preview']['steps'] if step.get('name') == name)
            self.assertIn('test-environment-receipt.ps1', step['run'])

    def test_client_host_is_an_explicit_manual_native_reference_choice(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        choice = data['on']['workflow_dispatch']['inputs']['windows_input_runner']
        self.assertEqual(choice['default'], 'windows-2022')
        self.assertEqual(choice['options'], ['windows-2022', 'windows-11-arm'])
        probe = data['jobs']['input-environment']
        expression = probe['runs-on'].removeprefix('${{').removesuffix('}}').strip()
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for host in ['', 'windows-2022', 'windows-11-arm', 'self-hosted', 'windows-2025']:
                selected = expression.replace('github.event_name', repr(event)).replace('inputs.windows_input_runner', repr(host))
                actual = eval(selected.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                self.assertEqual(actual, 'windows-11-arm' if event == 'workflow_dispatch' and host == 'windows-11-arm' else 'windows-2022')
        # The existing build matrix is independent of this reference-only choice.
        self.assertNotIn('windows_input_runner', str(data['jobs']['preview']))
        self.assertEqual(probe['timeout-minutes'], '8')
        self.assertNotIn('swift', str(probe['steps']).lower())

    def test_acceptance_notes_alone_do_not_build_but_mixed_code_changes_do(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        for event in ['push', 'pull_request']:
            paths = data['on'][event]['paths']
            self.assertLess(paths.index('Desktop/**'), paths.index('!Desktop/TESTING.md'))

            def selected(files):
                for path in files:
                    included = False
                    for pattern in paths:
                        negative = pattern.startswith('!')
                        if fnmatchcase(path, pattern[1:] if negative else pattern):
                            included = not negative
                    if included:
                        return True
                return False

            self.assertFalse(selected(['Desktop/TESTING.md', 'harness.json']))
            for changed in ['Desktop/Sources/ClipboardDesktop/DesktopUI.swift',
                            'Desktop/Tests/FixtureTests.swift', 'Desktop/Package.swift',
                            'Desktop/Sources/ClipboardDesktop/Resources/version.txt',
                            'Core/Sources/ClipboardCore/Clip.swift',
                            'tools/desktop-ui/windows-keyboard-acceptance.ps1',
                            'tools/desktop-package/check-windows-install.ps1',
                            '.github/workflows/swiftcrossui-preview.yml']:
                with self.subTest(event=event, changed=changed):
                    self.assertTrue(selected([changed]))
                    self.assertTrue(selected(['Desktop/TESTING.md', changed]))

    def test_native_input_receipts_are_available_before_package_builds(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        steps = data['jobs']['preview']['steps']
        receipt = next(step for step in steps if step.get('name') == 'Retain Windows input diagnostics before package builds')
        self.assertEqual(receipt['if'], "always() && runner.os == 'Windows' && env.CHINESE_IME_VALIDATION == 'true'")
        self.assertIn('github.run_attempt', receipt['with']['name'])
        paths = receipt['with']['path'].split()
        self.assertEqual(set(paths), {
            'ui-artifacts/input/environment.json', 'ui-artifacts/input/native-ime.json',
            'ui-artifacts/keyboard/ime-target-state.jsonl', 'ui-artifacts/keyboard/keyboard-capabilities.json',
            'ui-artifacts/keyboard/keyboard-peer-state.json', 'ui-artifacts/keyboard/results.json',
        })
        self.assertLess(next(i for i, step in enumerate(steps) if step.get('name') == 'Exercise native Windows keyboard focus and explicit paste'), steps.index(receipt))
        self.assertLess(steps.index(receipt), next(i for i, step in enumerate(steps) if step.get('name') == 'Restore compiled release dependencies'))

    def test_notepad_readiness_fails_before_expensive_builds(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        steps = data['jobs']['preview']['steps']
        probe = next(step for step in steps if step.get('name') == 'Verify spawned Notepad readiness before application builds')
        self.assertEqual(probe['if'], "runner.os == 'Windows'")
        self.assertEqual(probe['shell'], 'powershell')
        self.assertIn('test-windows-notepad-process.ps1', probe['run'])
        self.assertLess(steps.index(probe), next(i for i, step in enumerate(steps) if step.get('name') == 'Install Swift 6.3.3 on Windows'))
        for name in ['Verify private fixture interpreter and pipe encoding', 'Verify private fixture on Windows PowerShell 5.1']:
            step = next(step for step in steps if step.get('name') == name)
            self.assertIn('test-windows-notepad-readiness.ps1', step['run'])

    def test_manual_application_adds_package_keyboard_without_optional_models(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        steps = {step.get('name'): step for step in data['jobs']['preview']['steps']}
        release = steps['Build optimized desktop artifacts']
        package = steps['Build and exercise Windows keyboard installer']
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for full in [False, True]:
                for mode in ['', 'off', 'browser', 'richtext', 'images', 'application']:
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
        browser = next(step for step in steps if step.get('name') == 'Verify native browser formats before application builds')
        rtf = next(step for step in steps if step.get('name') == 'Verify native RTF formats before application builds')
        keyboard = next(step for step in steps if step.get('name') == 'Exercise native Windows keyboard focus and explicit paste')
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for full in [False, True]:
                for mode in ['', 'off', 'inspect', 'prepare', 'browser', 'richtext', 'images', 'application']:
                    selected = expression.replace('github.event_name', repr(event)).replace('inputs.full_validation', repr(full)).replace('inputs.windows_input_environment', repr(mode))
                    enabled = eval(selected.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                    expected = event == 'push' or (event == 'workflow_dispatch' and (full or mode == 'application'))
                    self.assertEqual(bool(enabled), expected)
                    for system in ['Linux', 'Windows']:
                        condition = provision['if'].replace('runner.os', repr(system)).replace('env.CHINESE_IME_VALIDATION', repr(str(enabled).lower()))
                        actual = eval(condition.replace('&&', ' and '), {'__builtins__': {}})
                        self.assertEqual(bool(actual), system == 'Windows' and expected)
                        browser_condition = browser['if'].replace('runner.os', repr(system)).replace('env.CHINESE_IME_VALIDATION', repr(str(enabled).lower()))
                        self.assertEqual(bool(eval(browser_condition.replace('&&', ' and '), {'__builtins__': {}})), system == 'Windows' and expected)
        self.assertLess(steps.index(provision), steps.index(keyboard))
        self.assertIn('check-native-ime.ps1', provision['run'])
        self.assertIn("$env:CHINESE_IME_VALIDATION -eq 'true'", keyboard['run'])
        self.assertIn("'-ChineseIme'", keyboard['run'])
        self.assertIn("'-BrowserPaste'", keyboard['run'])
        self.assertIn("'-RtfPaste'", keyboard['run'])
        self.assertEqual(rtf['if'], browser['if'])
        self.assertIn('check-windows-richtext.ps1', rtf['run'])
        self.assertLess(steps.index(rtf), next(index for index, step in enumerate(steps) if step.get('name') == 'Install Swift 6.3.3 on Windows'))
        self.assertLess(steps.index(browser), next(index for index, step in enumerate(steps) if step.get('name') == 'Install Swift 6.3.3 on Windows'))
        self.assertIn('check-windows-browser.ps1', browser['run'])
        for step in steps:
            if 'check-windows-install.ps1' in step.get('run', ''):
                self.assertIn('-BrowserPaste', step['run'])
                self.assertIn('-RtfPaste', step['run'])
        self.assertIn('-ChineseIme', next(step for step in steps if 'check-windows-install.ps1' in step.get('run', ''))['run'])

    def test_probe_never_runs_a_desktop_build_or_changes_normal_event_scope(self):
        data = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['windows_input_environment']['default'], 'off')
        preview = data['jobs']['preview']
        probe = data['jobs']['input-environment']
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for choice in ['', 'off', 'inspect', 'prepare', 'browser', 'richtext', 'images', 'application']:
                for candidate in [False, True]:
                    normal = event != 'workflow_dispatch' or not candidate
                    expected_probe = normal and event == 'workflow_dispatch' and choice in ['inspect', 'prepare', 'browser', 'richtext', 'images']
                    for job, expected in [(probe, expected_probe), (preview, normal and not expected_probe)]:
                        expression = job['if'].replace('github.event_name', repr(event)).replace('inputs.windows_input_environment', repr(choice))
                        expression = expression.replace('!inputs.windows_capture_candidate', repr(not candidate))
                        selected = eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})
                        with self.subTest(event=event, choice=choice, candidate=candidate, job=job.get('name', '')):
                            self.assertEqual(bool(selected), expected)
        self.assertIn("'windows-11-arm' || 'windows-2022'", probe['runs-on'])
        self.assertLessEqual(int(probe['timeout-minutes']), 8)
        self.assertNotIn('swift', str(probe['steps']).lower())
        self.assertNotIn('download-test-model', str(probe['steps']))
        browser = next(step for step in probe['steps'] if step.get('name') == 'Exercise native browser input without an application build')
        self.assertEqual(browser['if'], "inputs.windows_input_environment == 'browser'")
        self.assertIn('check-windows-browser.ps1', browser['run'])
        richtext = next(step for step in probe['steps'] if step.get('name') == 'Exercise native RTF paste without an application build')
        self.assertEqual(richtext['if'], "inputs.windows_input_environment == 'richtext'")
        self.assertIn('check-windows-richtext.ps1', richtext['run'])
        inspect = next(step for step in probe['steps'] if step.get('name') == 'Inspect or provision the isolated Windows input environment')
        self.assertEqual(inspect['if'], "inputs.windows_input_environment == 'inspect' || inputs.windows_input_environment == 'prepare'")
        images = next(step for step in probe['steps'] if step.get('name') == 'Verify valid JPEG and TIFF native clipboard interoperability')
        self.assertEqual(images['if'], "inputs.windows_input_environment == 'images'")
        self.assertIn('check-windows-valid-images.ps1', images['run'])
        compiler = next(step for step in probe['steps'] if step.get('name') == 'Configure the native Windows compiler for valid image checks')
        self.assertEqual(compiler['if'], images['if'])
        self.assertLess(probe['steps'].index(compiler), probe['steps'].index(images))


if __name__ == '__main__':
    unittest.main()
