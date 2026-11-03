"""Keep the focused candidate distinct from complete desktop acceptance."""
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
DATA = yaml.load((ROOT / '.github/workflows/swiftcrossui-preview.yml').read_text(), Loader=yaml.BaseLoader)


class CandidatePolicyTests(unittest.TestCase):
    def test_candidate_never_cancels_complete_acceptance_for_the_same_ref(self):
        def group(event, candidate, number=None):
            def render(match):
                expression = match[1]
                values = {'github.workflow': 'Desktop UI', 'github.event_name': event,
                          'github.event.pull_request.number': number, 'github.ref': 'refs/heads/main',
                          'inputs.windows_capture_candidate': candidate}
                for key, value in values.items():
                    expression = expression.replace(key, repr(value))
                return str(eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__': {}}))
            return re.sub(r'\$\{\{(.*?)\}\}', render, DATA['concurrency']['group'])
        full = group('push', False)
        self.assertEqual(full, 'Desktop UI-refs/heads/main')
        self.assertEqual(group('workflow_dispatch', False), full)
        self.assertEqual(group('workflow_dispatch', True), full + '-capture-candidate')
        self.assertEqual(group('pull_request', False, 74), 'Desktop UI-74')
        self.assertEqual(DATA['concurrency']['cancel-in-progress'], 'true')

    def test_candidate_requires_explicit_manual_scope(self):
        choice = DATA['on']['workflow_dispatch']['inputs']['windows_capture_candidate']
        self.assertEqual(choice, {'description': choice['description'], 'type': 'boolean', 'default': 'false'})
        job = DATA['jobs']['capture-candidate']
        self.assertEqual(job['if'], "github.event_name == 'workflow_dispatch' && inputs.windows_capture_candidate")
        self.assertEqual(job['runs-on'], 'windows-2022')
        guard = job['steps'][0]['run']
        for token in ('inputs.full_validation', "'false'", 'inputs.platform', "'windows'", 'inputs.windows_input_environment', "'off'", 'throw'):
            self.assertIn(token, guard)
        self.assertIn('!inputs.windows_capture_candidate', DATA['jobs']['preview']['if'])
        self.assertIn('!inputs.windows_capture_candidate', DATA['jobs']['input-environment']['if'])

    def test_candidate_reuses_release_cache_and_never_downloads_optional_weights(self):
        steps = DATA['jobs']['capture-candidate']['steps']
        restore = next(s for s in steps if s.get('id') == 'candidate-release')
        self.assertEqual(restore['uses'], './.github/actions/swift-build-cache')
        self.assertEqual(restore['with'], {'package': 'Desktop', 'configuration': 'release'})
        commands = '\n'.join(s.get('run', '') for s in steps)
        self.assertIn('--configuration release', commands)
        for forbidden in ('--configuration debug', '--download-test-model', 'check-windows-browser.ps1', 'check-native-ime.ps1'):
            self.assertNotIn(forbidden, commands)

    def test_installed_regression_precedes_a_clearly_scoped_artifact(self):
        steps = DATA['jobs']['capture-candidate']['steps']
        verify = next(s for s in steps if s.get('name') == 'Build and verify the installed capture fix candidate')
        upload = next(s for s in steps if s.get('name') == 'Upload the checked capture fix candidate')
        self.assertLess(steps.index(verify), steps.index(upload))
        self.assertNotIn('if', upload)  # Requires all preceding checks to succeed.
        self.assertIn('check-windows-capture-launch.ps1', verify['run'])
        self.assertIn('fullPlatformAcceptance = $false', verify['run'])
        self.assertIn('dist/CANDIDATE.json', upload['with']['path'])
        self.assertIn('candidate-checks/*.json', upload['with']['path'])

    def test_complete_acceptance_gates_remain_present(self):
        steps = DATA['jobs']['preview']['steps']
        for name in ('Exercise actual local models through native Windows controls',
                     'Exercise model import cancellation and repair through native Windows controls',
                     'Exercise actual file and PDF models through native Windows controls',
                     'Build and exercise Windows user installer'):
            step = next(s for s in steps if s.get('name') == name)
            self.assertIn("env.FULL_VALIDATION == 'true'", step['if'])
        source = (ROOT / 'tools/desktop-package/check-windows-capture-launch.ps1').read_text()
        for token in ("$env:GITHUB_ACTIONS -ne 'true'", 'recordingEnabled', 'shortcutEnabled', 'fullPlatformAcceptance=$false',
                      'three_public_text_items_persist', 'sensitive_text_and_png_remain_memory_only'):
            self.assertIn(token, source)
        native = (ROOT / 'tools/desktop-package/windows-no-console-process.cs').read_text()
        for forbidden in ('SendInput', 'OpenClipboard', 'EnumWindows', 'GetForegroundWindow'):
            self.assertNotIn(forbidden, native)


if __name__ == '__main__':
    unittest.main()
