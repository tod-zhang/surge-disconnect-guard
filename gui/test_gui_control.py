#!/usr/bin/env python3
"""GUI controller tests: all privileged commands and paths are isolated/mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class GuiControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guard gui's test ")
        self.base = Path(self.temp.name)
        self.root = self.base / "installed"
        self.resources = self.base / "Resources"
        self.engine = self.resources / "engine"
        self.engine.mkdir(parents=True)
        self.mock = self.base / "bin"
        self.mock.mkdir()
        self.launch = self.base / "LaunchDaemons"
        self.launch.mkdir()
        self.boot = self.launch / "local.surgedisconnect.guard.plist"
        self.trace = self.base / "trace"
        fake_path = "export PATH='" + str(self.mock).replace("'", "'\\''") + ":/usr/bin:/bin:/usr/sbin:/sbin'"
        source = (HERE / "gui-control.sh").read_text()
        source = source.replace("export PATH=/usr/bin:/bin:/usr/sbin:/sbin", fake_path)
        source = source.replace("ROOT='/Library/Application Support/SurgeDisconnectGuard'", "ROOT=" + self.quote(str(self.root)))
        source = source.replace('BOOT="/Library/LaunchDaemons/$LABEL.plist"', 'BOOT="' + str(self.launch) + '/$LABEL.plist"')
        source = source.replace("STATUS='/var/run/local.surgedisconnect.guard.status.json'", "STATUS=" + self.quote(str(self.base / "status.json")))
        source = source.replace("NEWSYSLOG_CONF='/etc/newsyslog.d/local.surgedisconnect.conf'", "NEWSYSLOG_CONF=" + self.quote(str(self.base / "newsyslog.conf")))
        self.script = self.resources / "gui-control.sh"
        self.script.write_text(source)
        controller = (HERE.parent / "sgctl").read_text()
        controller = controller.replace("export PATH=/usr/bin:/bin:/usr/sbin:/sbin", fake_path)
        controller = controller.replace("ROOT='/Library/Application Support/SurgeDisconnectGuard'", "ROOT=" + self.quote(str(self.root)))
        controller = controller.replace('PLIST="/Library/LaunchDaemons/$LABEL.plist"', 'PLIST="' + str(self.launch) + '/$LABEL.plist"')
        controller = controller.replace("RUN_DIR='/var/run'", "RUN_DIR=" + self.quote(str(self.base)))
        controller = controller.replace("NEWSYSLOG_CONF='/etc/newsyslog.d/local.surgedisconnect.conf'", "NEWSYSLOG_CONF=" + self.quote(str(self.base / "newsyslog.conf")))
        self.write(self.engine / "sgctl", controller)
        self.write(self.mock / "id", "#!/bin/bash\necho 0\n")
        self.write(self.mock / "stat", "#!/bin/bash\necho 0\n")
        self.write(self.mock / "chown", "#!/bin/bash\nexit 0\n")
        self.write(self.mock / "install", """#!/usr/bin/python3
import sys, shutil, os
a=sys.argv[1:]; mode=0o755
while a[0].startswith('-'):
 if a[0]=='-m': mode=int(a[1],8)
 a=a[2:]
shutil.copyfile(a[0],a[1]); os.chmod(a[1],mode)
""")
        self.write(self.mock / "launchctl", """#!/bin/bash
echo "launchctl $*" >> "$TEST_BASE/trace"
case "$1" in
 print) [[ -f "$TEST_BASE/loaded" ]] ;;
 bootstrap) touch "$TEST_BASE/loaded" ;;
 bootout) rm -f "$TEST_BASE/loaded" ;;
 enable|disable) touch "$TEST_BASE/$1" ;;
 *) exit 2 ;;
esac
""")
        self.write(self.engine / "surge-guard", """#!/bin/bash
echo "guard $*" >> "$TEST_BASE/trace"
case "$1" in
 health-check|observer-check|persistent-check) [[ ! -f "$TEST_BASE/preflight-fails" ]] ;;
 restore)
  [[ ! -f "$TEST_BASE/restore-fails" ]] || exit 1
  rm -f "$TEST_BASE/installed/locked.json" "$TEST_BASE/installed/armed.json" ;;
 settings-set)
  [[ "$2" =~ ^[0-9]{2,5}$ ]] && (( 10#$2 >= 10 && 10#$2 <= 10000 )) || exit 2
  printf '%s' "$2" > "$TEST_BASE/config-ms" ;;
 settings-interval)
  [[ "$2" =~ ^[0-9]{1,4}$ ]] && (( 10#$2 >= 5 && 10#$2 <= 1000 )) || exit 2
  printf '%s' "$2" > "$TEST_BASE/config-interval" ;;
 settings-auto-restore)
  [[ "$2" == on || "$2" == off ]] || exit 2
  printf '%s' "$2" > "$TEST_BASE/config-auto" ;;
 ui-state-write) printf '%s' "$2" > "$TEST_BASE/status.json" ;;
 check) exit 0 ;;
 *) exit 2 ;;
esac
""")
        (self.engine / "local.surgedisconnect.guard.plist").write_text("mock plist")
        (self.engine / "local.surgedisconnect.newsyslog.conf").write_text("mock newsyslog")
        (self.engine / "VERSION").write_text("9.8.7\n")

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def quote(value):
        return "'" + value.replace("'", "'\\''") + "'"

    @staticmethod
    def write(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def call(self, action, boot="on", success=True):
        result = subprocess.run(["/bin/bash", str(self.script), action, boot],
                                env=dict(os.environ, TEST_BASE=str(self.base)),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_enable_with_boot(self):
        self.call("enable")
        self.assertTrue((self.base / "loaded").exists())
        self.assertTrue(self.boot.exists())
        self.assertTrue((self.root / "daemon.plist").exists())

    def test_enable_without_boot(self):
        self.call("enable", "off")
        self.assertTrue((self.base / "loaded").exists())
        self.assertFalse(self.boot.exists())
        self.assertTrue((self.root / "daemon.plist").exists())

    def test_disable_restores_but_preserves_selected_boot(self):
        self.call("enable")
        (self.root / "locked.json").touch()
        self.call("disable")
        self.assertFalse((self.base / "loaded").exists())
        self.assertFalse((self.root / "locked.json").exists())
        self.assertTrue(self.boot.exists())
        self.assertEqual((self.base / "status.json").read_text(), "disabled")

    def test_disable_without_boot_stays_paused(self):
        self.call("enable")
        self.call("disable", "off")
        self.assertFalse(self.boot.exists())
        self.assertFalse((self.base / "loaded").exists())

    def test_boot_change_does_not_stop_running_guard(self):
        self.call("enable")
        self.call("boot", "off")
        self.assertTrue((self.base / "loaded").exists())
        self.assertFalse(self.boot.exists())

    def test_boot_enable_does_not_start_paused_guard(self):
        self.call("enable")
        self.call("disable", "off")
        self.call("boot", "on")
        self.assertTrue(self.boot.exists())
        self.assertFalse((self.base / "loaded").exists())

    def test_failed_restore_preserves_backup_and_files(self):
        self.call("enable")
        (self.root / "locked.json").touch()
        (self.base / "restore-fails").touch()
        self.call("disable", success=False)
        self.assertTrue((self.root / "locked.json").exists())
        self.assertTrue((self.root / "surge-guard").exists())

    def test_failed_preflight_never_installs(self):
        (self.base / "preflight-fails").touch()
        self.call("enable", success=False)
        self.assertFalse(self.root.exists())

    def test_upgrade_refuses_to_overwrite_running_old_engine(self):
        self.call("enable")
        (self.root / "engine-version").write_text("2.0\n")
        old_engine = (self.root / "surge-guard").read_bytes() + b"\n# old engine marker\n"
        (self.root / "surge-guard").write_bytes(old_engine)
        (self.root / "armed.json").touch()
        self.call("enable", success=False)
        self.assertEqual((self.root / "engine-version").read_text(), "2.0\n")
        self.assertEqual((self.root / "surge-guard").read_bytes(), old_engine)
        self.assertTrue((self.root / "armed.json").exists())
        self.assertTrue((self.base / "loaded").exists())

    def test_upgrade_after_disable_restores_then_replaces_old_engine(self):
        self.call("enable")
        (self.root / "engine-version").write_text("2.0\n")
        (self.root / "surge-guard").write_bytes(
            (self.root / "surge-guard").read_bytes() + b"\n# old engine marker\n")
        (self.root / "armed.json").touch()
        self.call("disable")
        self.assertFalse((self.base / "loaded").exists())
        self.assertFalse((self.root / "armed.json").exists())
        self.assertEqual((self.root / "engine-version").read_text().strip(), "9.8.7")
        self.assertEqual((self.root / "surge-guard").read_bytes(),
                         (self.engine / "surge-guard").read_bytes())
        self.assertTrue(self.boot.exists())

    def test_enable_installs_log_rotation(self):
        self.call("enable")
        self.assertEqual((self.base / "newsyslog.conf").read_text(), "mock newsyslog")

    def test_uninstall_removes_autostart(self):
        self.call("enable")
        self.assertTrue((self.base / "newsyslog.conf").exists())
        self.call("uninstall")
        self.assertFalse((self.base / "newsyslog.conf").exists())
        self.assertFalse(self.root.exists())
        self.assertFalse(self.boot.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
