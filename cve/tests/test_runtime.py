import contextlib
import io
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch
from support import audit, config, detection, package, report, clone


class FakeNetlink:
    mode = 'done'
    last_request = None

    def __init__(self, *_args):
        self.seq = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def bind(self, _address):
        pass

    def sendto(self, data, _address):
        self.seq = struct.unpack_from('=I', data, 8)[0]
        FakeNetlink.last_request = data

    def settimeout(self, _timeout):
        pass

    def recvmsg(self, _size):
        if self.mode == 'error':
            kind, flags, payload = 2, 0, struct.pack('=i', -95)
        elif self.mode == 'incomplete':
            raise socket.timeout()
        elif self.mode == 'interrupted':
            kind, flags, payload = 3, 0x10, struct.pack('=i', 0)
        elif self.mode == 'done_error':
            kind, flags, payload = 3, 0, struct.pack('=i', -4)
        else:
            kind, flags, payload = 3, 0, struct.pack('=i', 0)
        header = struct.pack('=IHHII', 16 + len(payload), kind, flags, self.seq, 0)
        return header + payload, [], 0, (0, 0)


class RuntimeTests(unittest.TestCase):
    def test_native_netlink_request_and_verified_empty_completion(self):
        FakeNetlink.mode = 'done'
        with patch.object(audit.socket, 'AF_NETLINK', 16, create=True), \
                patch.object(audit.socket, 'socket', FakeNetlink):
            self.assertEqual(audit.diag_dump(socket.AF_INET), [])
        data = FakeNetlink.last_request
        self.assertEqual(struct.unpack_from('=IHH', data), (80, 20, 0x301))
        self.assertEqual(struct.unpack_from('=HHI', data, 72), (8, 3, 262))

    def test_native_netlink_errors_never_become_empty_success(self):
        for mode in ('error', 'incomplete', 'interrupted', 'done_error'):
            FakeNetlink.mode = mode
            with patch.object(audit.socket, 'AF_NETLINK', 16, create=True), \
                    patch.object(audit.socket, 'socket', FakeNetlink):
                with self.assertRaises((OSError, audit.DiagnosticError)):
                    audit.diag_dump(socket.AF_INET)

    def test_journal_failure_prevents_mutation(self):
        def failed_checkpoint():
            raise OSError('disk full')
        with patch.object(audit, 'run') as command:
            with self.assertRaises(OSError):
                audit.remediate(report(), audit.parser().parse_args([]), failed_checkpoint,
                                 runner=command, uid=lambda: 0)
            command.assert_not_called()

    def test_inode_reuse_between_dumps_is_not_attributed(self):
        original = dict(inode=123, cookie=[1, 2], state='LISTEN', local_address='0.0.0.0', local_port=1)
        recycled = dict(original, cookie=[3, 4])
        proc = dict(pid=123, starttime_ticks='42', sockets=[original])
        with patch.object(audit, 'run', return_value=(0, '', '')), \
                patch.object(audit, 'associate_processes', return_value=([proc], [], [])), \
                patch.object(audit, 'process_identity', return_value='42'):
            dumps = iter([[original], [], [recycled], []])
            result = audit.detect_sockets(dumper=lambda _: next(dumps), release='6.8.0')
        self.assertEqual(result['processes'], [])
        self.assertEqual(len(result['unattributed_sockets']), 1)

    def test_main_check_only_writes_final_json_without_sysctl_or_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            output = root / 'report.json'
            before = detection()
            os_release = 'ID=ubuntu\nNAME=Ubuntu\nVERSION_ID=24.04\nVERSION_CODENAME=noble'
            def reader(path, binary=False):
                return {'/etc/os-release': os_release,
                        '/proc/version': 'Linux version 6.8.0-147-generic',
                        '/proc/version_signature': 'Ubuntu 6.8.0-147.147-generic 6.8.12'}.get(str(path))
            class Uname:
                release, machine = '6.8.0-147-generic', 'x86_64'
            # Actual OS root uid is not changed. All host data/commands are mocked;
            # only temporary private files and the real advisory lock are exercised.
            original_secure = audit.secure_directory
            def directory(path):
                if str(path) == '/var/tmp/kernel-tcp-uaf-audit':
                    return original_secure(root / 'journals')
                return original_secure(path)
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(audit.sys, 'platform', 'linux'))
                stack.enter_context(patch.object(audit.os, 'uname', return_value=Uname()))
                stack.enter_context(patch.object(audit.os, 'readlink', return_value='net:[123]'))
                stack.enter_context(patch.object(audit.socket, 'gethostname', return_value='test-node'))
                stack.enter_context(patch.object(audit, 'read', side_effect=reader))
                stack.enter_context(patch.object(audit, 'kernel_package', return_value=[
                    package(version='6.8.0-147.147', maintainer='Ubuntu Kernel Team')]))
                stack.enter_context(patch.object(audit, 'mptcp_config', return_value=config('DISABLED')))
                stack.enter_context(patch.object(audit, 'detect_sockets', return_value=before))
                stack.enter_context(patch.object(audit, 'host_addresses', return_value=dict(
                    private_ips=['100.64.0.5'], primary_private_ip='100.64.0.5', primary_interface='eth0')))
                stack.enter_context(patch.object(audit.shutil, 'which', return_value=None))
                stack.enter_context(patch.object(audit, 'secure_directory', side_effect=directory))
                command = stack.enter_context(patch.object(audit, 'run'))
                send = stack.enter_context(patch.object(audit, 'send_alert'))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                code = audit.main(['--check-only', '--no-alert', '--json', '--state-dir', str(root / 'state'),
                                   '--output', str(output)])
                command.assert_not_called()
                send.assert_not_called()
                result = json.loads(stdout.getvalue())
                self.assertEqual(code, 1)
                self.assertEqual(result['kernel_status'], 'VULNERABLE')
                self.assertEqual(result['remediation_status'], 'CHECK_ONLY')
                self.assertEqual(result, json.loads(output.read_text()))
                self.assertEqual(result, json.loads(Path(result['journal_path']).read_text()))
                stdout.seek(0)
                stdout.truncate(0)
                code = audit.main(['--check-only', '--json', '--state-dir', str(root / 'state'),
                                   '--lark-webhook', 'https://untrusted.invalid/never-contact', '--alert-mode', 'always'])
                self.assertEqual(code, 1)
                self.assertEqual(json.loads(stdout.getvalue())['alert']['status'], 'FAILED_CONFIGURATION')
                send.assert_not_called()
                # A rejected output must never be retried by the error handler.
                output.write_text('KEEP_CREDENTIAL_FILE')
                code = audit.main(['--check-only', '--no-alert', '--json', '--state-dir', str(root / 'state'),
                                   '--output', str(output), '--lark-secret-file', str(output)])
                self.assertEqual(code, 2)
                self.assertEqual(output.read_text(), 'KEEP_CREDENTIAL_FILE')
                send.assert_not_called()

    def test_concurrent_lock_conflict_stops_before_detection(self):
        with tempfile.TemporaryDirectory() as temp:
            state = audit.secure_directory(Path(temp).resolve() / 'state')
            fd = os.open(str(state / 'audit.lock'), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                audit.fcntl.flock(fd, audit.fcntl.LOCK_EX | audit.fcntl.LOCK_NB)
                with patch.object(audit.sys, 'platform', 'linux'), patch.object(audit, 'read') as reader, \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(audit.main(['--check-only', '--no-alert', '--state-dir', str(state)]), 2)
                    reader.assert_not_called()
            finally:
                os.close(fd)

    def test_interrupted_remediation_retains_original_state(self):
        r = report()
        saved = []
        def interrupt(_args):
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            audit.remediate(r, audit.parser().parse_args([]), lambda: saved.append(clone(r)),
                             runner=interrupt, uid=lambda: 0)
        self.assertEqual(saved[0]['mptcp_before'], 'ENABLED')
        self.assertEqual(saved[0]['remediation_status'], 'IN_PROGRESS')
        self.assertTrue(r['mutation_attempted'])


if __name__ == '__main__':
    unittest.main()
