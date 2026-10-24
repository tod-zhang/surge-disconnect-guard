#!/usr/bin/env python3
"""Exercise controller sequencing in a disposable tree, never the real system."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="surgeguard-test-")
        self.base = Path(self.temp.name)
        self.root = self.base / "install"
        self.root.mkdir()
        self.mock = self.base / "bin"
        self.mock.mkdir()
        self.trace = self.base / "trace"
        source = (Path(__file__).parent / "sgctl").read_text()
        old_root = "ROOT='/Library/Application Support/SurgeDisconnectGuard'"
        old_path = "export PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        old_plist = 'PLIST="/Library/LaunchDaemons/$LABEL.plist"'
        assert old_root in source and old_path in source and old_plist in source
        source = source.replace(old_root, "ROOT='" + str(self.root) + "'")
        source = source.replace(old_path, "export PATH='" + str(self.mock) + ":/usr/bin:/bin:/usr/sbin:/sbin'")
        source = source.replace(old_plist, 'PLIST="' + str(self.base) + '/$LABEL.plist"')
        self.script = self.base / "controller"
        self.script.write_text(source)
        (self.root / "sgctl").write_text("test copy")
        self.write(self.mock / "id", "#!/bin/bash\necho 0\n")
        self.write(self.mock / "launchctl", """#!/bin/bash
echo "launchctl $*" >> "$TEST_BASE/trace"
case "$1" in
 print) [[ -f "$TEST_BASE/loaded" ]] ;;
 bootout)
  [[ ! -f "$TEST_BASE/bootout-fails" ]] || exit 1
  rm -f "$TEST_BASE/loaded" ;;
 bootstrap) touch "$TEST_BASE/loaded" ;;
 enable|disable) touch "$TEST_BASE/$1" ;;
 *) exit 2 ;;
esac
""")
        self.write(self.root / "surge-guard", """#!/bin/bash
echo "guard $*" >> "$TEST_BASE/trace"
case "$1" in
 restore)
  [[ ! -f "$TEST_BASE/restore-fails" ]] || exit 1
  rm -f "$TEST_BASE/install/locked.json" ;;
 health-check)
  [[ ! -f "$TEST_BASE/surge-absent" && ! -f "$TEST_BASE/modes-off" ]] ;;
 observer-check) [[ ! -f "$TEST_BASE/observer-fails" ]] ;;
 persistent-check) [[ ! -f "$TEST_BASE/persistent-fails" ]] ;;
 lock) touch "$TEST_BASE/install/locked.json" ;;
 check) exit 0 ;;
 *) exit 2 ;;
esac
""")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_control(self, command):
        env = dict(os.environ, TEST_BASE=str(self.base))
        result = subprocess.run(["/bin/bash", str(self.script), command],
                                env=env, capture_output=True, text=True, timeout=5)
        trace = self.trace.read_text().splitlines() if self.trace.exists() else []
        return result, trace

    def test_recover_stops_before_restore_and_persists_pause(self):
        (self.base / "loaded").touch()
        (self.root / "locked.json").touch()
        result, trace = self.run_control("recover")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / "disable").exists())
        self.assertFalse((self.base / "loaded").exists())
        self.assertFalse((self.root / "locked.json").exists())
        self.assertLess(trace.index("launchctl bootout system/local.surgedisconnect.guard"),
                        trace.index("guard restore"))

    def test_stop_failure_never_restores(self):
        (self.base / "loaded").touch()
        (self.base / "bootout-fails").touch()
        result, trace = self.run_control("recover")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("guard restore", trace)

    def test_failed_restore_preserves_uninstall_files(self):
        (self.base / "restore-fails").touch()
        (self.root / "locked.json").touch()
        result, _ = self.run_control("uninstall")
        self.assertNotEqual(result.returncode, 0)
        for name in ["surge-guard", "sgctl", "locked.json"]:
            self.assertTrue((self.root / name).exists())

    def test_enable_refuses_existing_lock(self):
        (self.root / "locked.json").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(trace)

    def test_enable_refuses_absent_surge(self):
        (self.base / "surge-absent").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["guard health-check"])

    def test_enable_refuses_modes_off(self):
        (self.base / "modes-off").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["guard health-check"])

    def test_enable_bootstraps_after_surge_check(self):
        result, trace = self.run_control("enable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / "loaded").exists())
        self.assertEqual(trace[0], "guard health-check")

    def test_enable_refuses_interrupted_armed_run(self):
        (self.root / "armed.json").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("guard health-check", trace)

    def test_enable_refuses_unavailable_proxy_observer(self):
        (self.base / "observer-fails").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["guard health-check", "guard observer-check"])

    def test_enable_refuses_unavailable_persistent_connection(self):
        (self.base / "persistent-fails").touch()
        result, trace = self.run_control("enable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["guard health-check", "guard observer-check", "guard persistent-check"])

    def test_lock_stops_then_locks_then_restarts(self):
        (self.base / "loaded").touch()
        result, trace = self.run_control("lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "locked.json").exists())
        self.assertTrue((self.base / "loaded").exists())
        self.assertLess(trace.index("guard lock"),
                        next(i for i, line in enumerate(trace) if line.startswith("launchctl bootstrap")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
