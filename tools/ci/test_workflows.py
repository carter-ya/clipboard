from pathlib import Path
import json
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


def workflow(name):
    # BaseLoader keeps YAML 1.1's ambiguous `on` and boolean strings intact.
    return yaml.load((ROOT / '.github/workflows' / name).read_text(), Loader=yaml.BaseLoader)


def evaluate(expression, event, full_input, system):
    expression = expression.removeprefix('${{').removesuffix('}}').strip()
    for token, value in {'github.event_name': event, 'inputs.full_validation': full_input,
                         'env.FULL_VALIDATION': str(event == 'push' or (event == 'workflow_dispatch' and full_input)).lower(),
                         'runner.os': system}.items():
        expression = expression.replace(token, repr(value))
    return eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}})


class WorkflowPolicyTests(unittest.TestCase):
    def test_windows_keyboard_acceptance_uses_existing_debug_build_on_pr_and_integration(self):
        steps = workflow('swiftcrossui-preview.yml')['jobs']['preview']['steps']
        keyboard = next(step for step in steps if step.get('name') == 'Exercise native Windows keyboard focus and explicit paste')
        self.assertIn('--configuration debug --show-bin-path', keyboard['run'])
        self.assertIn('-KeyboardOnly', keyboard['run'])
        self.assertIn('powershell.exe -NoProfile -MTA', keyboard['run'])
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            self.assertTrue(evaluate(keyboard['if'], event, False, 'Windows'))
            self.assertFalse(evaluate(keyboard['if'], event, True, 'Linux'))
        save = next(step for step in steps if step.get('name') == 'Save compiled debug dependencies before native UI validation')
        self.assertLess(steps.index(save), steps.index(keyboard))
        installer = (ROOT / 'tools/desktop-package/check-windows-install.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('-KeyboardOnly -OutputDirectory', installer)

    def test_manual_ui_runs_can_target_one_platform_without_narrowing_push_or_pr(self):
        data = workflow('swiftcrossui-preview.yml')
        choice = data['on']['workflow_dispatch']['inputs']['platform']
        self.assertEqual(choice['default'], 'all')
        self.assertEqual(choice['options'], ['all', 'windows', 'linux'])
        expression = data['jobs']['preview']['strategy']['matrix']['include']
        expression = expression.removeprefix('${{').removesuffix('}}').strip()
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for platform in ['', 'all', 'windows', 'linux']:
                selected = expression.replace('github.event_name', repr(event)).replace('inputs.platform', repr(platform))
                matrix = eval(selected.replace('&&', ' and ').replace('||', ' or '),
                              {'__builtins__': {}, 'fromJSON': json.loads})
                expected = ['ubuntu-22.04', 'windows-2022']
                if event == 'workflow_dispatch' and platform != 'all' and platform:
                    expected = ['windows-2022' if platform == 'windows' else 'ubuntu-22.04']
                with self.subTest(event=event, platform=platform):
                    self.assertEqual([row['os'] for row in matrix], expected)
                    for row in matrix:
                        self.assertEqual(row['backend'], 'GtkBackend')
                        self.assertEqual(row['display'], 'win32' if row['os'].startswith('windows') else 'x11')
                        self.assertEqual(row['accessibility'], 'accesskit' if row['os'].startswith('windows') else 'atspi')

    def test_new_commits_cancel_only_the_same_workflow_and_pr_or_branch(self):
        for filename in ['swift-portability.yml', 'swiftcrossui-preview.yml', 'desktop-runtime-sources.yml']:
            with self.subTest(workflow=filename):
                data = workflow(filename)
                self.assertEqual(data['concurrency']['cancel-in-progress'], 'true')
                group = data['concurrency']['group']
                for required in ['github.workflow', 'github.event.pull_request.number', 'github.ref']:
                    self.assertIn(required, group)

    def test_full_acceptance_is_selected_only_for_main_push_or_explicit_manual_request(self):
        for filename in ['swift-portability.yml', 'swiftcrossui-preview.yml']:
            data = workflow(filename)
            self.assertEqual(data['on']['push']['branches'], ['main'])
            for event, choice, expected in [('pull_request', False, False), ('pull_request', True, False),
                                             ('workflow_dispatch', False, False), ('workflow_dispatch', True, True),
                                             ('push', False, True)]:
                with self.subTest(workflow=filename, event=event, choice=choice):
                    self.assertEqual(evaluate(data['env']['FULL_VALIDATION'], event, choice, 'Linux'), expected)

    def test_pr_has_no_release_build_model_download_or_installer_execution(self):
        ui = workflow('swiftcrossui-preview.yml')['jobs']['preview']['steps']
        heavy = [step for step in ui if any(marker in step.get('run', '') for marker in [
            '--configuration release', '--download-test-model', 'check-linux-install.py', 'check-windows-install.ps1'])
            or step.get('with', {}).get('configuration') == 'release']
        self.assertGreaterEqual(len(heavy), 10)
        for step in heavy:
            for system in ['Linux', 'Windows']:
                with self.subTest(step=step.get('name'), system=system):
                    self.assertFalse(evaluate(step['if'], 'pull_request', True, system))

    def test_full_native_ui_and_model_gates_are_retained_for_integration(self):
        steps = workflow('swiftcrossui-preview.yml')['jobs']['preview']['steps']
        names = {step.get('name'): step for step in steps}
        required = {
            'Exercise GTK window and capture screenshots': 'Linux',
            'Exercise native Wayland GTK controls in a private compositor': 'Linux',
            'Exercise Windows GTK window and capture screenshots': 'Windows',
            'Exercise actual local models through native Windows controls': 'Windows',
            'Exercise model import cancellation and repair through native Windows controls': 'Windows',
            'Exercise actual file and PDF models through native Windows controls': 'Windows',
            'Package Linux runtime and verify installation without a Swift SDK': 'Linux',
            'Build and exercise Windows user installer': 'Windows',
        }
        for name, system in required.items():
            with self.subTest(step=name):
                self.assertTrue(evaluate(names[name]['if'], 'push', False, system))
                self.assertFalse(evaluate(names[name]['if'], 'pull_request', False, system))
        optimized = next(i for i, step in enumerate(steps) if step.get('name') == 'Build optimized desktop artifacts')
        for name in required:
            self.assertLess(optimized, steps.index(names[name]))
        for name in ['Exercise GTK window and capture screenshots', 'Exercise Windows GTK window and capture screenshots']:
            self.assertIn('--configuration release --show-bin-path', names[name]['run'])

    def test_pr_keeps_native_window_consent_and_complete_core_unit_tests(self):
        ui = workflow('swiftcrossui-preview.yml')['jobs']['preview']['steps']
        quick = [step for step in ui if step.get('name', '').startswith('Check the native ')]
        self.assertEqual(len(quick), 2)
        for step, system, flag in zip(quick, ['Linux', 'Windows'], ['--model-settings-only', '-ModelSettingsOnly']):
            self.assertTrue(evaluate(step['if'], 'pull_request', False, system))
            self.assertIn(flag, step['run'])
            self.assertIn('--configuration debug', step['run'])
        core = workflow('swift-portability.yml')['jobs']['core']['steps']
        unit = next(step for step in core if step.get('name') == 'Test real core sources')
        self.assertNotIn('if', unit)
        self.assertIn('swift test --package-path Core', unit['run'])
        for step in core:
            if '--download-test-model' in step.get('run', ''):
                self.assertFalse(evaluate(step['if'], 'pull_request', False, 'Windows'))
                self.assertTrue(evaluate(step['if'], 'push', False, 'Windows'))

    def test_cache_saves_reuse_frozen_keys_before_any_ui_failure(self):
        ui = workflow('swiftcrossui-preview.yml')['jobs']['preview']['steps']
        for key, build_name, save_name in [
            ('ui-cache', 'Build Desktop UI', 'Save compiled debug dependencies before native UI validation'),
            ('release-cache', 'Build optimized desktop artifacts', 'Save compiled release dependencies before full acceptance')]:
            cache = next(step for step in ui if step.get('id') == key)
            self.assertEqual(cache['uses'], './.github/actions/swift-build-cache')
            save = next(step for step in ui if step.get('name') == save_name)
            self.assertEqual(save['with']['key'], '${{ steps.' + key + '.outputs.key }}')
            self.assertLess(ui.index(next(step for step in ui if step.get('name') == build_name)), ui.index(save))
        first_smoke = next(i for i, step in enumerate(ui) if step.get('name', '').startswith('Check the native '))
        debug_save = next(i for i, step in enumerate(ui) if step.get('name') == 'Save compiled debug dependencies before native UI validation')
        self.assertLess(debug_save, first_smoke)
        self.assertNotIn('hashFiles', '\n'.join(str(step['with']['key']) for step in ui if step.get('uses') == 'actions/cache/save@v4'))

    def test_source_archives_are_collected_once_on_integration_not_every_pr(self):
        events = workflow('desktop-runtime-sources.yml')['on']
        self.assertNotIn('pull_request', events)
        self.assertEqual(events['push']['branches'], ['main'])
        self.assertIn('workflow_dispatch', events)


if __name__ == '__main__':
    unittest.main()
