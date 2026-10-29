"""Exercise runner ownership with real subprocesses, without opening GUI apps."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("window_runner", HERE / "run-window-regressions.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

BUILD = """
import os
from pathlib import Path
import time
marker = Path(os.environ['CASE_MARKER'])
marker.mkdir(parents=True, exist_ok=True)
(marker / 'build.pid').write_text(str(os.getpid()))
while os.environ.get('BLOCK_BUILD') and not (marker / 'release').exists():
    time.sleep(0.02)
raise SystemExit(int(os.environ.get('BUILD_EXIT', '0')))
"""

PROBE = """
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
marker = Path(os.environ['CASE_MARKER'])
child = None
if os.environ.get('PROBE_CHILD'):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    (marker / 'probe-child.pid').write_text(str(child.pid))
def terminate(signum, frame):
    if child is not None:
        child.wait(timeout=2)
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, terminate)
(marker / 'probe.pid').write_text(str(os.getpid()))
while os.environ.get('BLOCK_PROBE') and not (marker / 'release').exists():
    time.sleep(0.02)
Path(sys.argv[1]).write_text(json.dumps({'failures': int(os.environ.get('FAILURES', '0'))}))
"""


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="clipboard-runner-review-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with spaces"
        (self.repo / "tools").mkdir(parents=True)
        (self.repo / "App/en.lproj").mkdir(parents=True)
        for name in ("check-window-regressions.sh", "run-window-regressions.py"):
            shutil.copyfile(HERE / name, self.repo / "tools" / name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.script(self.commands / "just", BUILD)
        self.script(self.commands / "xcrun", """
import os
from pathlib import Path
import sys
code = int(os.environ.get('COMPILE_EXIT', '0'))
if code:
    raise SystemExit(code)
binary = Path(sys.argv[sys.argv.index('-o') + 1])
binary.write_text({!r})
binary.chmod(0o755)
""".format("#!" + sys.executable + "\n" + PROBE))
        self.legacy = self.repo / "build/window-regressions/ClipboardWindowRegressionProbe.app"
        self.legacy.mkdir(parents=True)
        (self.legacy / "keep.txt").write_text("another run")
        self.unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.processes = []
        self.logs = []

    def script(self, path, source):
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o755)

    def start(self, name, **options):
        marker = self.root / name
        env = dict(os.environ, CASE_MARKER=str(marker), TMPDIR=str(self.root))
        env["PATH"] = str(self.commands) + os.pathsep + env["PATH"]
        env.update({key: str(value) for key, value in options.items()})
        log = (self.root / (name + ".log")).open("w+")
        self.logs.append(log)
        process = subprocess.Popen(
            ["bash", str(self.repo / "tools/check-window-regressions.sh")],
            env=env, stdout=log, stderr=subprocess.STDOUT,
        )
        self.processes.append(process)
        return process, marker

    def await_file(self, path):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(0.02)
        self.fail("No marker: " + str(path))

    def assert_dead(self, pid):
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def runs(self):
        return sorted((self.repo / "build/window-regressions").glob("run-*"))

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        self.assertIsNone(self.unrelated.poll(), "an unrelated process was terminated")
        self.assertEqual((self.legacy / "keep.txt").read_text(), "another run")
        self.unrelated.terminate()
        self.unrelated.wait(timeout=5)
        for log in self.logs:
            log.close()
        self.temp.cleanup()

    def test_concurrent_waiter_can_be_interrupted_without_touching_active_run(self):
        first, one = self.start("one", BLOCK_PROBE=1)
        self.await_file(one / "probe.pid")
        directory = self.runs()[0]
        second, two = self.start("two", BUILD_EXIT=23)
        time.sleep(0.25)
        self.assertFalse((two / "build.pid").exists())
        second.send_signal(signal.SIGTERM)
        self.assertEqual(second.wait(timeout=5), 143)
        self.assertIsNone(first.poll())
        self.assertTrue((directory / "ClipboardWindowRegressionProbe.app").exists())
        self.assertEqual(len(self.runs()), 1)
        (one / "release").touch()
        self.assertEqual(first.wait(timeout=5), 0)

    def test_queued_build_failure_preserves_previous_results(self):
        first, one = self.start("one", BLOCK_PROBE=1)
        self.await_file(one / "probe.pid")
        first_directory = self.runs()[0]
        second, two = self.start("two", BUILD_EXIT=23)
        time.sleep(0.2)
        self.assertFalse((two / "build.pid").exists())
        (one / "release").touch()
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertEqual(second.wait(timeout=5), 23)
        self.assertEqual(json.loads((first_directory / "results.json").read_text())["failures"], 0)
        self.assertEqual(len(self.runs()), 2)
        self.assertFalse(list(self.repo.rglob("run-*/*.app")))

    def test_signals_during_build_and_probe_terminate_only_owned_processes(self):
        for stage in ("BUILD", "PROBE"):
            for sig in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(stage=stage, signal=sig):
                    process, marker = self.start(
                        "{}-{}".format(stage, sig), **{"BLOCK_" + stage: 1, "PROBE_CHILD": 1})
                    self.await_file(marker / (stage.lower() + ".pid"))
                    pid = int((marker / (stage.lower() + ".pid")).read_text())
                    process.send_signal(sig)
                    self.assertEqual(process.wait(timeout=5), 128 + sig)
                    self.assert_dead(pid)
                    if stage == "PROBE":
                        self.assert_dead(int((marker / "probe-child.pid").read_text()))
                    self.assertFalse(list(self.repo.rglob("run-*/*.app")))

    def test_compile_failure_cleans_partial_bundle(self):
        process, _ = self.start("compile", COMPILE_EXIT=19)
        self.assertEqual(process.wait(timeout=5), 19)
        self.assertFalse(list(self.repo.rglob("run-*/*.app")))

    def test_failed_assertions_preserve_report_and_remove_bundle(self):
        process, _ = self.start("failed-check", FAILURES=1)
        self.assertEqual(process.wait(timeout=5), 1)
        self.assertEqual(json.loads((self.runs()[0] / "results.json").read_text())["failures"], 1)
        self.assertFalse(list(self.repo.rglob("run-*/*.app")))

    def test_timeout_terminates_owned_child(self):
        marker = self.root / "timeout.pid"
        runner = MODULE.Runner(self.repo)
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.command([
                sys.executable, "-c",
                "import os,time,pathlib;pathlib.Path({!r}).write_text(str(os.getpid()));time.sleep(60)"
                .format(str(marker)),
            ], timeout=0.25)
        self.assert_dead(int(marker.read_text()))
        self.assertIsNone(runner.child)


if __name__ == "__main__":
    unittest.main()
