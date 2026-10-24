#!/usr/bin/env python3
"""All privileged commands and paths run in temporary mock trees."""
import os
from pathlib import Path
import subprocess
import unittest
import test_gui_control as fixtures
HERE = Path(__file__).resolve().parent

class PermissionControlTests(unittest.TestCase):
    setUp = fixtures.GuiControlTests.setUp
    tearDown = fixtures.GuiControlTests.tearDown
    quote = staticmethod(fixtures.GuiControlTests.quote)
    write = staticmethod(fixtures.GuiControlTests.write)
    call = fixtures.GuiControlTests.call

    def prepare(self):
        for name in ['install-control.sh', 'control-actions.sh']:
            text = (HERE / name).read_text()
            text = text.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin',
                                'export PATH=' + self.quote(str(self.mock) + ':/usr/bin:/bin:/usr/sbin:/sbin'))
            text = text.replace("ROOT='/Library/Application Support/SurgeDisconnectGuard'", 'ROOT=' + self.quote(str(self.root)))
            text = text.replace('"/Library/LaunchDaemons/$LABEL.plist"', '"' + str(self.launch) + '/$LABEL.plist"')
            text = text.replace('/var/run/local.surgedisconnect.guard.status.json', self.quote(str(self.base / 'status.json')))
            text = text.replace('/var/run/local.surgedisconnect.settings.json', self.quote(str(self.base / 'public-settings.json')))
            self.write(self.resources / name, text)
        self.write(self.engine / 'sg-control', '''#!/bin/bash
echo "helper $*" >> "$TEST_BASE/trace"
case "$1" in
 authorize) [[ ! -f "$TEST_BASE/authorize-fails" ]] ;;
 stop) [[ ! -f "$TEST_BASE/helper-busy" ]] ;;
 *) exit 2 ;;
esac
''')
        (self.resources / 'local.surgedisconnect.control.plist').write_text('mock helper plist')
        self.write(self.mock / 'launchctl', '''#!/bin/bash
echo "launchctl $*" >> "$TEST_BASE/trace"
marker="$TEST_BASE/loaded"
[[ "${2:-}${3:-}" == *local.surgedisconnect.control* ]] && marker="$TEST_BASE/loaded-control"
case "$1" in
 print) [[ -f "$marker" ]] ;;
 bootstrap) touch "$marker" ;;
 bootout) rm -f "$marker" ;;
 enable|disable) touch "$TEST_BASE/$1" ;;
 *) exit 2 ;;
esac
''')

    def command(self, name, args, success=True):
        result = subprocess.run(['/bin/bash', str(self.resources / name)] + args,
                                env=dict(os.environ, TEST_BASE=str(self.base)),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_install_does_not_toggle_existing_guard(self):
        self.prepare(); self.call('enable'); self.trace.write_text('')
        self.command('install-control.sh', ['12345'])
        trace = self.trace.read_text()
        self.assertTrue((self.base / 'loaded').exists())
        self.assertTrue((self.base / 'loaded-control').exists())
        self.assertTrue(self.boot.exists())
        self.assertNotIn('guard restore', trace)
        self.assertNotIn('guard health-check', trace)
        self.assertIn('helper authorize 12345', trace)

    def test_install_does_not_enable_guard(self):
        self.prepare(); self.command('install-control.sh', ['12345'])
        self.assertFalse((self.base / 'loaded').exists())
        self.assertFalse(self.boot.exists())
        self.assertTrue((self.base / 'loaded-control').exists())

    def test_busy_helper_not_overwritten(self):
        self.prepare(); self.command('install-control.sh', ['12345'])
        old = (self.root / 'sg-control').read_bytes() + b'\n# old marker\n'
        (self.root / 'sg-control').write_bytes(old)
        (self.base / 'helper-busy').touch()
        self.command('install-control.sh', ['12345'], success=False)
        self.assertEqual((self.root / 'sg-control').read_bytes(), old)
        self.assertTrue((self.base / 'loaded-control').exists())

    def test_reinstall_clears_exited_job_registration(self):
        self.prepare(); (self.base / 'loaded-control').touch()
        self.command('install-control.sh', ['12345'])
        self.assertTrue((self.root / 'sg-control').exists())
        self.assertTrue((self.base / 'loaded-control').exists())
        self.assertIn('launchctl bootout system/local.surgedisconnect.control', self.trace.read_text())

    def test_invalid_pid_never_installs(self):
        self.prepare(); self.command('install-control.sh', ['1; touch bad'], success=False)
        self.assertFalse(self.root.exists())

    def test_disable_preserves_boot(self):
        self.prepare(); self.call('enable'); (self.root / 'armed.json').touch()
        self.command('control-actions.sh', ['disable', 'on'])
        self.assertFalse((self.base / 'loaded').exists())
        self.assertFalse((self.root / 'armed.json').exists())
        self.assertTrue(self.boot.exists())
        self.assertEqual((self.base / 'status.json').read_text(), 'disabled')

    def test_failed_restore_preserves_backup_and_boot(self):
        self.prepare(); self.call('enable')
        (self.root / 'locked.json').touch(); (self.base / 'restore-fails').touch()
        self.command('control-actions.sh', ['disable', 'off'], success=False)
        self.assertTrue((self.root / 'locked.json').exists())
        self.assertTrue(self.boot.exists())

    def test_boot_change_does_not_stop_guard(self):
        self.prepare(); self.call('enable')
        self.command('control-actions.sh', ['boot', 'off'])
        self.assertTrue((self.base / 'loaded').exists())
        self.assertFalse(self.boot.exists())

    def test_rejects_unknown_action_and_preference(self):
        self.prepare()
        self.command('control-actions.sh', ['shell', 'on'], success=False)
        self.command('control-actions.sh', ['enable', '$(touch bad)'], success=False)
        self.assertFalse((self.base / 'loaded').exists())

    def test_save_timeout_keeps_running_guard_and_boot(self):
        self.prepare(); self.call('enable'); self.trace.write_text('')
        self.command('control-actions.sh', ['setTimeout', 'off', '750'])
        self.assertTrue((self.base / 'loaded').exists())
        self.assertTrue(self.boot.exists())
        self.assertEqual((self.base / 'config-ms').read_text(), '750')
        self.assertNotIn('bootout', self.trace.read_text())
        self.assertNotIn('guard restore', self.trace.read_text())

    def test_enable_applies_custom_timeout_before_preflight(self):
        self.prepare(); self.command('install-control.sh', ['12345']); self.trace.write_text('')
        self.command('control-actions.sh', ['enable', 'off', '850'])
        trace = self.trace.read_text()
        self.assertLess(trace.index('guard settings-set 850'), trace.index('guard health-check'))
        self.assertTrue((self.base / 'loaded').exists())
        self.assertEqual((self.base / 'config-ms').read_text(), '850')

    def test_invalid_timeout_does_not_stop_running_guard(self):
        self.prepare(); self.call('enable')
        self.command('control-actions.sh', ['setTimeout', 'on', '0'], success=False)
        self.assertTrue((self.base / 'loaded').exists())
        self.assertFalse((self.base / 'config-ms').exists())

    def test_enable_still_checks_health(self):
        self.prepare(); self.command('install-control.sh', ['12345'])
        (self.base / 'preflight-fails').touch()
        self.command('control-actions.sh', ['enable', 'on'], success=False)
        self.assertFalse((self.base / 'loaded').exists())

    def test_idle_publishes_disabled_after_reboot(self):
        self.prepare(); self.call('enable'); self.call('disable', 'off')
        (self.base / 'status.json').unlink()
        self.command('control-actions.sh', ['idle', 'off'])
        self.assertEqual((self.base / 'status.json').read_text(), 'disabled')

    def test_idle_reports_leftover_backup(self):
        self.prepare(); self.call('enable'); self.call('disable', 'off')
        (self.base / 'status.json').unlink(); (self.root / 'locked.json').touch()
        self.command('control-actions.sh', ['idle', 'off'])
        self.assertEqual((self.base / 'status.json').read_text(), 'error')

    def test_idle_leaves_running_guard_alone(self):
        self.prepare(); self.call('enable')
        self.command('control-actions.sh', ['idle', 'off'])
        self.assertFalse((self.base / 'status.json').exists())
        self.assertTrue((self.base / 'loaded').exists())

    def test_helper_uninstall_leaves_helper_for_self_removal(self):
        self.prepare(); self.command('install-control.sh', ['12345']); self.call('enable')
        self.command('control-actions.sh', ['uninstall', 'off'])
        self.assertFalse((self.root / 'surge-guard').exists())
        self.assertTrue((self.root / 'sg-control').exists())

if __name__ == '__main__': unittest.main(verbosity=2)
