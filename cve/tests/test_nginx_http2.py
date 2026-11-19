"""Offline regression tests for the self-contained HTTP/2 shell/Python script."""
import argparse
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'cve_2026_nginx2root_check_and_close_http2.sh'
audit = types.ModuleType('nginx_http2')
exec(compile(SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0], str(SCRIPT), 'exec'), audit.__dict__)


class RewriteTests(unittest.TestCase):
    def test_listen_and_standalone(self):
        source = 'http { http2 on; server { listen 443 ssl http2 default_server; http2 off; } }'
        result, count = audit.disable_http2(source)
        self.assertEqual(count, 2)
        self.assertEqual(result, 'http { http2 off; server { listen 443 ssl  default_server; http2 off; } }')
        self.assertEqual(audit.disable_http2(result), (result, 0))

    def test_multiline_ipv6_quotes_and_comments(self):
        source = '''# listen 443 http2; http2 on;
http { http2 "on"; server {
  listen [::]:443\n    ssl # keep comment http2
    'http2' reuseport;
  set $note "listen 443 http2; http2 on;";
  server_name http2.example.com;
} }
'''
        expected = source.replace('http2 "on";', 'http2 off;').replace("'http2' reuseport", ' reuseport')
        self.assertEqual(audit.disable_http2(source), (expected, 2))

    def test_unrelated_names_and_values(self):
        source = 'server { listen unix:/run/http2; http2 off; set $http2 on; proxy_pass http://http2; }'
        self.assertEqual(audit.disable_http2(source), (source, 0))

    def test_bad_setting_refused(self):
        with self.assertRaises(audit.AuditError):
            audit.disable_http2('http2 invalid;')

    def test_include_and_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            target = base / 'site'
            target.write_text('server { listen 443 ssl http2; http2 on; }')
            (base / 'enabled').symlink_to(target)
            main = base / 'nginx.conf'
            main.write_text('events {} http { include enabled; }')
            scanner = audit.Scanner(str(main))
            found = audit.detect(scanner.read(str(main)), scanner.errors)
            self.assertEqual(scanner.errors, [])
            self.assertEqual(len(found), 2)
            self.assertIn(str(target.resolve()), scanner.contents)


class ReloadTests(unittest.TestCase):
    def test_waits_for_new_generation(self):
        old = {(1, '100')}
        with patch.object(audit, 'worker_generation', side_effect=[old, {(2, '200')}]), \
             patch.object(audit.os, 'kill'), patch.object(audit.time, 'sleep') as sleep:
            audit.wait_for_reload(123, old)
            sleep.assert_called_once_with(0.1)

    def test_reload_timeout(self):
        with patch.object(audit.time, 'monotonic', side_effect=[0, 11]):
            with self.assertRaises(audit.AuditError):
                audit.wait_for_reload(123, {(1, '100')})


class TransactionTests(unittest.TestCase):
    def setup_transaction(self, root):
        main = Path(root) / 'nginx.conf'
        site = Path(root) / 'site.conf'
        main.write_text('events {} http { http2 on; include site.conf; }')
        site.write_text('server { listen 443 ssl http2; }')
        main.chmod(0o640)
        site.chmod(0o644)
        scanner = audit.Scanner(str(main))
        nodes = scanner.read(str(main))
        a = argparse.Namespace(check_only=False, dry_run=False, nginx_bin='/mock/nginx', config=str(main), prefix=None)
        return main, site, scanner, nodes, a

    def execute(self, root, fail_at=None, dry=False, broken=False, write_failure=False, interrupted=False):
        main, site, scanner, nodes, a = self.setup_transaction(root)
        original = {p: p.read_bytes() for p in (main, site)}
        metadata = {p: p.stat().st_mode for p in (main, site)}
        a.dry_run = dry
        if broken:
            scanner.errors.append('include missing')
        calls = []
        def nginx(argv):
            calls.append(argv)
            if len(calls) == fail_at:
                raise audit.AuditError('injected failure')
            if interrupted and len(calls) == 2:
                raise KeyboardInterrupt()
        writes = []
        real_atomic = audit.atomic_config
        def atomic(path, content, metadata_source):
            writes.append(path)
            if write_failure and len(writes) == 2:
                raise OSError('injected second replacement failure')
            return real_atomic(path, content, metadata_source)
        # Keep all mutation inside the fixture, even the persistent backup.
        real_mkdtemp = tempfile.mkdtemp
        def backup_dir(*args, **kwargs):
            kwargs['dir'] = root
            return real_mkdtemp(*args, **kwargs)
        with patch.object(audit, 'trusted_directory'), patch.object(audit, 'trusted_config'), patch.object(audit.os, 'geteuid', return_value=0), \
             patch.object(audit, 'master_pid', return_value=123), patch.object(audit, 'worker_generation', return_value={(1, '1')}), patch.object(audit, 'wait_for_reload'), patch.object(audit, 'atomic_config', side_effect=atomic), patch.object(audit, 'run_nginx', side_effect=nginx), \
             patch.object(audit.os, 'makedirs'), patch.object(audit.os, 'chown'), \
             patch.object(audit.tempfile, 'mkdtemp', side_effect=backup_dir):
            if fail_at or broken or write_failure or interrupted:
                with self.assertRaises(KeyboardInterrupt if interrupted else (OSError if write_failure else audit.AuditError)):
                    audit.close_http2(a, scanner, {'binaries': ['/mock/nginx']}, nodes)
            else:
                changed = audit.close_http2(a, scanner, {'binaries': ['/mock/nginx']}, nodes)
                self.assertEqual(changed, not dry)
        for path in (main, site):
            self.assertEqual(path.stat().st_mode, metadata[path])
            if fail_at or dry or broken or write_failure or interrupted:
                self.assertEqual(path.read_bytes(), original[path])
            else:
                self.assertEqual(audit.disable_http2(path.read_text())[1], 0)
        return calls

    def test_success_and_noop(self):
        with tempfile.TemporaryDirectory() as root:
            calls = self.execute(root)
            self.assertEqual([c[-1] for c in calls], ['-t', '-t', 'reload'])
            main = Path(root) / 'nginx.conf'
            scanner = audit.Scanner(str(main))
            nodes = scanner.read(str(main))
            a = argparse.Namespace(check_only=False, dry_run=False)
            with patch.object(audit, 'run_nginx') as nginx:
                self.assertFalse(audit.close_http2(a, scanner, {}, nodes))
                nginx.assert_not_called()

    def test_validation_failure_rolls_back_without_reload(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(len(self.execute(root, fail_at=2)), 2)

    def test_reload_failure_restores_and_reloads_original(self):
        with tempfile.TemporaryDirectory() as root:
            calls = self.execute(root, fail_at=3)
            self.assertEqual([c[-1] for c in calls], ['-t', '-t', 'reload', '-t', 'reload'])

    def test_partial_write_failure_restores_all_files(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(len(self.execute(root, write_failure=True)), 1)

    def test_interrupt_restores_without_reload(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(len(self.execute(root, interrupted=True)), 2)

    def test_precheck_failure_does_not_write(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(len(self.execute(root, fail_at=1)), 1)

    def test_dry_run_does_not_write_or_call_nginx(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(self.execute(root, dry=True), [])

    def test_incomplete_scan_does_not_write(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(self.execute(root, broken=True), [])


if __name__ == '__main__':
    unittest.main()
