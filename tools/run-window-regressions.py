#!/usr/bin/env python3
"""Own one native UI test run, including its subprocesses and disposable bundle."""

import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


class Runner:
    def __init__(self, repo):
        self.repo = repo
        self.cancelled = None
        self.child = None
        self.directory = None
        self.fixture = None

    def on_signal(self, signum, _frame):
        # Never raise between spawning and recording a child. The command
        # and lock wait loops observe this flag within 100 ms.
        self.cancelled = signum

    def check_cancelled(self):
        if self.cancelled is not None:
            raise Interrupted(self.cancelled)

    def stop_child(self):
        child = self.child
        if child is None or child.returncode is not None:
            return
        # Each child starts a private session. Keep its leader unreaped
        # during the grace period so this group ID cannot be reused.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                break
            except PermissionError:
                # Darwin returns EPERM when the group contains only an
                # unreaped zombie. Accept it only after verifying exit;
                # never suppress failure to stop a live child.
                if child.poll() is None:
                    raise
                break
            if sig == signal.SIGTERM:
                time.sleep(0.5)
        child.wait()

    def command(self, args, timeout=None):
        self.check_cancelled()
        self.child = subprocess.Popen(args, cwd=self.repo, start_new_session=True)
        deadline = None if timeout is None else time.monotonic() + timeout
        try:
            while True:
                self.check_cancelled()
                if deadline is not None and time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(args, timeout)
                try:
                    code = self.child.wait(timeout=0.1)
                except subprocess.TimeoutExpired:
                    continue
                self.check_cancelled()
                if code:
                    raise subprocess.CalledProcessError(code, args)
                return
        finally:
            self.stop_child()
            self.child = None

    def acquire(self, lock):
        # Native fixtures share a desktop, even across worktrees. Never
        # unlink this file: waiters must retain the same lock inode.
        while True:
            self.check_cancelled()
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                time.sleep(0.1)

    def cleanup(self):
        self.stop_child()
        if self.fixture is None or not self.fixture.exists():
            return
        register = Path(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            "LaunchServices.framework/Support/lsregister"
        )
        if register.exists():
            try:
                subprocess.run(
                    [str(register), "-u", str(self.fixture)], timeout=5,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except (OSError, subprocess.TimeoutExpired):
                pass
        shutil.rmtree(self.fixture)

    def execute(self):
        output = self.repo / "build/window-regressions"
        output.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="run-", dir=output))
        self.fixture = self.directory / "ClipboardWindowRegressionProbe.app"
        results = self.directory / "results.json"
        print("Native window regression run:", self.directory, flush=True)
        self.command(["just", "build"])
        products = self.repo / "build/Build/Products/Debug"
        binary = self.fixture / "Contents/MacOS/ClipboardWindowRegressionProbe"
        binary.parent.mkdir(parents=True)
        resources = self.fixture / "Contents/Resources"
        resources.mkdir()
        excluded = {"main.swift", "AppDelegate.swift", "SparkleUpdater.swift"}
        sources = sorted(p for p in (self.repo / "App").glob("*.swift") if p.name not in excluded)
        self.command([
            "xcrun", "swiftc", "-parse-as-library", "-module-name", "ClipboardWindowRegression",
            "-target", os.uname().machine + "-apple-macos13.0", "-I", str(products),
            "-F", str(products), *map(str, sources), str(self.repo / "tools/window-regression.swift"),
            str(products / "ClipboardCore.o"), str(products / "KeyboardShortcuts.o"),
            "-o", str(binary),
        ])
        for localization in (self.repo / "App").glob("*.lproj"):
            shutil.copytree(localization, resources / localization.name)
        (self.fixture / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.clipboard.window-regression-probe",
            "CFBundleName": "ClipboardWindowRegressionProbe",
            "CFBundleExecutable": binary.name,
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": True,
            "CFBundleDevelopmentRegion": "en",
        }))
        # Launch the executable directly instead of detaching it through
        # Launch Services, so interruption can terminate/reap our own PID.
        self.command([str(binary), str(results)], timeout=120)
        failures = json.loads(results.read_text())["failures"]
        print("Native window regressions: {} failures ({})".format(failures, results), flush=True)
        return 0 if failures == 0 else 1

    def run(self):
        lock_path = Path(tempfile.gettempdir()) / "clipboard-window-regression.lock"
        # Hold the lock through cleanup, including build failure. A queued
        # run has no bundle or child to clean if it is interrupted.
        with lock_path.open("a+b") as lock:
            try:
                self.acquire(lock)
                return self.execute()
            finally:
                self.cleanup()


def main():
    runner = Runner(Path(__file__).resolve().parent.parent)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, runner.on_signal)
    try:
        return runner.run()
    except Interrupted as error:
        return 128 + error.signum
    except subprocess.TimeoutExpired as error:
        print("Window regression command timed out:", error.cmd, file=sys.stderr)
        return 124
    except subprocess.CalledProcessError as error:
        print("Window regression command failed:", error.cmd, file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, KeyError) as error:
        print("Window regression failed:", error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
