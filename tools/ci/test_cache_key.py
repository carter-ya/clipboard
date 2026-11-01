import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cache_key', Path(__file__).with_name('cache-key.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='clipboard-ci-key-')
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git('init', '-q')
        for name in ['Core/Package.swift', 'Core/Package.resolved', 'Desktop/Package.swift',
                     'Desktop/Package.resolved', 'Desktop/Patches/gtk.patch',
                     'tools/desktop-language/upstream.json', 'tools/desktop-language/language-worker.cpp',
                     'Desktop/Sources/ClipboardDesktop/App.swift']:
            self.write(name, 'original\n')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'user.name=CI Cache Test',
                                        '-c', 'user.email=ci-cache@example.invalid',
                                        '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false',
                                        '-c', 'core.hooksPath=/dev/null', *args], cwd=self.repo)

    def write(self, name, value):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value.encode('utf-8'))

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'Synthetic cache identity fixture')

    def key(self, **kwargs):
        values = dict(repo=self.repo, package='Desktop', configuration='debug',
                      operating_system='Windows', architecture='X64', compiler='Swift version 6.3.3\nTarget: x86_64-unknown-windows-msvc')
        values.update(kwargs)
        return module.cache_key(**values)

    def test_resolution_rewrite_and_checkout_line_endings_do_not_change_identity(self):
        before = self.key()
        self.write('Core/Package.resolved', 'rewritten by SwiftPM\n')
        self.write('Desktop/Package.resolved', 'original\r\n')
        self.assertEqual(self.key(), before)

    def test_committed_dependency_update_invalidates_cache(self):
        before = self.key()
        self.write('Desktop/Package.resolved', 'new pinned dependency\n')
        self.commit()
        self.assertNotEqual(self.key(), before)

    def test_native_worker_recipe_update_invalidates_cache(self):
        before = self.key()
        self.write('tools/desktop-language/language-worker.cpp', 'new native implementation\n')
        self.commit()
        self.assertNotEqual(self.key(), before)

    def test_application_edit_reuses_dependency_identity(self):
        before = self.key()
        self.write('Desktop/Sources/ClipboardDesktop/App.swift', 'updated application\n')
        self.commit()
        self.assertEqual(self.key(), before)

    def test_model_acceptance_fixture_edit_reuses_dependency_identity(self):
        before = self.key()
        self.write('tools/desktop-language/check-quality.py', 'updated acceptance fixture\n')
        self.commit()
        self.assertEqual(self.key(), before)

    def test_compiler_os_architecture_configuration_and_package_are_isolated(self):
        before = self.key()
        for changes in [dict(compiler='Swift version 6.1.3'), dict(operating_system='Linux'),
                        dict(architecture='ARM64'), dict(configuration='release'), dict(package='Core')]:
            with self.subTest(changes=changes):
                self.assertNotEqual(self.key(**changes), before)

    def test_missing_committed_pins_fail_instead_of_using_an_empty_key(self):
        self.git('rm', 'Core/Package.resolved')
        self.commit()
        with self.assertRaises(ValueError):
            self.key()


if __name__ == '__main__':
    unittest.main()
