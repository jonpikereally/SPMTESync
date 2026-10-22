#!/usr/bin/env python3
"""Exercise the production install helper in disposable directories.

Copies used for swap tests replace absolute command paths with mocks, so no
test can launch an app or reset the user's microphone permission. Preparation
validation tests additionally use real macOS signing tools, without launching.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Resources/InstallBundle.sh"
BUNDLE_ID = "com.jonpike.ltcbridge"

MOCK = r'''#!/usr/bin/python3
import json, os, pathlib, plistlib, shutil, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["LTC_INSTALL_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([tool, args, (root / "support/update-failed.txt").exists()]) + "\n")
def flagged(name): return (root / name).exists()
if tool == "PlistBuddy":
    try:
        with open(args[-1], "rb") as f: info = plistlib.load(f)
        print(info[args[1].split(":", 1)[1]])
    except Exception: sys.exit(1)
elif tool == "sw_vers": print("15.0.1")
elif tool == "uname": print("arm64")
elif tool == "file": print("Mach-O 64-bit executable arm64")
elif tool == "codesign":
    if "--force" in args and flagged("fail-sign"): sys.exit(1)
    if "--verify" in args:
        if flagged("fail-verify"): sys.exit(1)
        if "--arch" in args and flagged("fail-arch"): sys.exit(1)
        if pathlib.Path(args[-1]).joinpath("damaged").exists(): sys.exit(1)
elif tool == "ditto":
    if flagged("fail-copy"): sys.exit(1)
    shutil.copytree(args[-2], args[-1])
elif tool == "mv":
    src, dst = map(pathlib.Path, args)
    if flagged("fail-swap") and src.name == "LTC Bridge.app" and src.parent.name == "stage": sys.exit(1)
    if flagged("fail-restore") and "Previous." in src.name: sys.exit(1)
    src.rename(dst)
elif tool == "open":
    dest = pathlib.Path(args[-1])
    if flagged("fail-open") and dest.joinpath("Contents/Resources/identity").read_text() == "new": sys.exit(1)
elif tool in ("xattr", "tccutil", "sleep"): pass
else: raise RuntimeError("unexpected mocked tool: " + tool)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ltc-installer-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.make_app(self.root / "source/LTC Bridge.app", "new")
        self.destination = self.make_app(self.root / "Applications/LTC Bridge.app", "old")
        self.stage_root = self.root / "Applications/stage"
        self.stage_root.mkdir()
        self.staged = self.stage_root / "LTC Bridge.app"
        self.marker = self.root / "support/update-failed.txt"
        self.previous = self.destination.with_name("LTC Bridge Previous.app")
        tools = self.root / "tools"
        tools.mkdir()
        text = HELPER.read_text()
        for path in ("/usr/bin/ditto", "/usr/bin/xattr", "/usr/bin/codesign",
                     "/usr/bin/uname", "/usr/bin/sw_vers", "/usr/bin/tccutil",
                     "/usr/bin/open", "/usr/bin/file", "/bin/mv", "/bin/sleep", "/usr/libexec/PlistBuddy"):
            mock = tools / Path(path).name
            mock.write_text("#!/bin/sh\nexit 0\n" if mock.name == "sleep" else MOCK)
            mock.chmod(0o755)
            self.assertIn(path, text)
            text = text.replace(path, str(mock))
        self.mock_helper = self.root / "helper.sh"
        self.mock_helper.write_text(text)
        self.env = dict(os.environ, LTC_INSTALL_TEST_ROOT=str(self.root))

    def make_app(self, path, identity, minimum="13.0"):
        executable = path / "Contents/MacOS/LTCBridge"
        executable.parent.mkdir(parents=True)
        executable.write_text("invalid executable\n")
        executable.chmod(0o755)
        with (path / "Contents/Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleIdentifier": BUNDLE_ID,
                          "CFBundleExecutable": "LTCBridge",
                          "CFBundlePackageType": "APPL",
                          "CFBundleShortVersionString": "1.3",
                          "LSMinimumSystemVersion": minimum}, f)
        (path / "Contents/Resources").mkdir()
        (path / "Contents/Resources/identity").write_text(identity)
        return path

    def call(self, operation, real=False, version="1.3", pid="0"):
        helper = HELPER if real else self.mock_helper
        if operation == "prepare":
            args = [operation, self.source, self.staged, BUNDLE_ID, version]
        else:
            args = [operation, pid, self.staged, self.destination,
                    BUNDLE_ID, self.marker, version]
        return subprocess.run(["/bin/bash", str(helper)] + list(map(str, args)),
                              env=self.env, capture_output=True, text=True)

    def assert_old_kept(self):
        self.assertEqual((self.destination / "Contents/Resources/identity").read_text(), "old")

    def calls(self):
        log = self.root / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_copy_failure_keeps_old_app_and_never_resets_permission(self):
        (self.root / "fail-copy").touch()
        self.assertNotEqual(self.call("prepare").returncode, 0)
        self.assert_old_kept()
        self.assertFalse(any(c[0] in ("tccutil", "open") for c in self.calls()))

    def test_sign_failure_keeps_old_app(self):
        (self.root / "fail-sign").touch()
        self.assertNotEqual(self.call("prepare").returncode, 0)
        self.assert_old_kept()

    def test_wrong_version_rejected_before_copy(self):
        self.assertNotEqual(self.call("prepare", version="1.4").returncode, 0)
        self.assertFalse(self.staged.exists())
        self.assert_old_kept()

    def test_wrong_architecture_rejected_before_copy(self):
        (self.root / "fail-arch").touch()
        self.assertNotEqual(self.call("prepare").returncode, 0)
        self.assertFalse(self.staged.exists())
        self.assert_old_kept()

    def test_open_failure_restores_and_reopens_old_app(self):
        self.assertEqual(self.call("prepare").returncode, 0)
        (self.root / "fail-open").touch()
        self.assertNotEqual(self.call("swap").returncode, 0)
        self.assert_old_kept()
        self.assertIn("LB-112", self.marker.read_text())
        opens = [c for c in self.calls() if c[0] == "open"]
        self.assertEqual(len(opens), 2)
        self.assertEqual([c[2] for c in opens], [False, True])

    def test_swap_failure_restores_old_app(self):
        self.assertEqual(self.call("prepare").returncode, 0)
        (self.root / "fail-swap").touch()
        self.assertNotEqual(self.call("swap").returncode, 0)
        self.assert_old_kept()

    def test_failed_rollback_preserves_recovery_copy(self):
        self.assertEqual(self.call("prepare").returncode, 0)
        (self.root / "fail-open").touch()
        (self.root / "fail-restore").touch()
        self.assertNotEqual(self.call("swap").returncode, 0)
        recovery = list(self.destination.parent.glob("LTC Bridge Previous.*.app"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual((recovery[0] / "Contents/Resources/identity").read_text(), "old")
        self.assertIn(str(recovery[0]), self.marker.read_text())

    def test_success_keeps_one_working_predecessor(self):
        self.make_app(self.previous, "older")
        self.assertEqual(self.call("prepare").returncode, 0)
        self.assert_old_kept()
        self.assertEqual(self.call("swap").returncode, 0)
        self.assertEqual((self.destination / "Contents/Resources/identity").read_text(), "new")
        self.assertEqual((self.previous / "Contents/Resources/identity").read_text(), "old")
        self.assertFalse(self.stage_root.exists())
        self.assertFalse(self.marker.exists())

    def test_changed_staging_bundle_rejected_without_touching_old_app(self):
        self.assertEqual(self.call("prepare").returncode, 0)
        (self.staged / "damaged").touch()
        self.assertNotEqual(self.call("swap").returncode, 0)
        self.assert_old_kept()

    def test_shutdown_timeout_never_replaces_running_app(self):
        self.assertEqual(self.call("prepare").returncode, 0)
        self.assertNotEqual(self.call("swap", pid=str(os.getpid())).returncode, 0)
        self.assert_old_kept()
        self.assertFalse(any(c[0] in ("tccutil", "open") for c in self.calls()))

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS signing tools")
    def test_real_validation_rejects_broken_executable(self):
        result = self.call("prepare", real=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LB-110", result.stderr)
        self.assertFalse(self.staged.exists())
        self.assert_old_kept()

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS signing tools")
    def test_real_validation_rejects_even_signed_text_executable(self):
        signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(self.source)],
                                capture_output=True, text=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        result = self.call("prepare", real=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Mach-O executable", result.stderr)
        self.assertFalse(self.staged.exists())
        self.assert_old_kept()

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS signing tools")
    def test_real_signed_compatible_app_can_be_prepared_without_launching(self):
        shutil.copyfile("/usr/bin/true", self.source / "Contents/MacOS/LTCBridge")
        signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(self.source)],
                                capture_output=True, text=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        result = self.call("prepare", real=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.staged)],
                       check=True, capture_output=True)
        self.assert_old_kept()
        self.assertFalse(self.calls())  # No mocked launch or permission calls, either.


if __name__ == "__main__":
    unittest.main(verbosity=2)
