import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch
from support import audit, config, report


def socket_row(state=10, inode=123):
    return dict(state='LISTEN' if state == 10 else str(state), inode=inode,
                cookie=[1, 2], local_address='0.0.0.0', local_port=30303)


class MptcpTests(unittest.TestCase):
    def test_disabled_config(self):
        with patch.object(audit, 'read', side_effect=lambda path: '0' if str(path).startswith('/proc/sys') else None), \
                patch.object(audit, 'run', return_value=(0, '0\n', '')):
            self.assertEqual(audit.mptcp_config('6.1.0')['state'], 'DISABLED')

    def test_kernel_not_compiled_for_mptcp(self):
        with patch.object(audit, 'read', side_effect=lambda path: '# CONFIG_MPTCP is not set' if str(path).startswith('/boot') else None), \
                patch.object(audit, 'run', return_value=(1, '', '')):
            c = audit.mptcp_config('4.15.0')
        self.assertEqual(c['state'], 'NOT_SUPPORTED')
        with patch.object(audit, 'run', return_value=(127, '', '')):
            result = audit.detect_sockets(dumper=lambda _: (_ for _ in ()).throw(OSError()), release='4.15', config=c)
        self.assertEqual(result['listener_coverage'], 'NOT_SUPPORTED')

    def test_missing_ss_and_empty_dump_do_not_imply_no_listeners_on_old_kernel(self):
        with patch.object(audit, 'run', return_value=(127, '', 'COMMAND_MISSING')):
            result = audit.detect_sockets(dumper=lambda _: [], release='5.10.0')
        self.assertEqual(result['status'], 'DETECTION_UNAVAILABLE')
        self.assertEqual(result['listener_coverage'], 'UNVERIFIED')

    def test_ss_unsupported_but_native_diag_can_complete_on_supported_kernel(self):
        with patch.object(audit, 'run', return_value=(1, '', 'STDERR_PRESENT')):
            result = audit.detect_sockets(dumper=lambda _: [], release='6.1.0')
        self.assertEqual(result['status'], 'AVAILABLE')
        self.assertEqual(result['processes'], [])
        self.assertFalse(result['ss_mptcp_command_ok'])

    def test_ss_success_empty_output_and_netlink_failure_is_unavailable(self):
        with patch.object(audit, 'run', return_value=(0, '', '')):
            result = audit.detect_sockets(dumper=lambda _: (_ for _ in ()).throw(OSError()), release='6.8.0')
        self.assertEqual(result['status'], 'DETECTION_UNAVAILABLE')

    def test_decode_confirmed_mptcp_listener(self):
        raw = bytearray(72)
        raw[0], raw[1] = socket.AF_INET, 10
        struct.pack_into('!HH', raw, 4, 30303, 0)
        raw[8:12] = socket.inet_pton(socket.AF_INET, '10.2.3.4')
        struct.pack_into('=II', raw, 64, 1000, 12345)
        row = audit.decode_diag(raw)
        self.assertEqual((row['state'], row['local_port'], row['inode']), ('LISTEN', 30303, 12345))
        self.assertIn('262', row['evidence'])

    def test_invalid_diag_packet_rejected(self):
        with self.assertRaises(audit.DiagnosticError):
            audit.decode_diag(bytes(71))

    def test_confirmed_listener_process_is_detected(self):
        proc = dict(pid=123, sockets=[socket_row()], starttime_ticks='42')
        with patch.object(audit, 'run', return_value=(0, 'ss utility', '')), \
                patch.object(audit, 'process_identity', return_value='42'), \
                patch.object(audit, 'associate_processes', return_value=([proc], [], [])):
            result = audit.detect_sockets(dumper=lambda family: [socket_row()] if family == socket.AF_INET else [], release='6.8.0')
        self.assertEqual(result['processes'][0]['pid'], 123)
        self.assertEqual(len(result['sockets']), 1)

    def test_no_generic_go_process_scanning(self):
        with patch.object(audit, 'process_metadata') as metadata:
            self.assertEqual(audit.associate_processes([]), ([], [], []))
            metadata.assert_not_called()

    def test_process_sensitive_cmdline_container_and_service(self):
        values = dict(status='PPid:\t1\nUid:\t1000\n', comm='geth',
                      cgroup='0::/system.slice/geth.service/docker-' + 'a' * 64 + '.scope',
                      cmdline=b'geth\0--password\0secret-password\0TOKEN=super-secret\0mnemonic words\0')
        def reader(path, binary=False):
            return values.get(Path(path).name)
        with patch.object(audit, 'read', side_effect=reader), \
                patch.object(audit.os, 'readlink', return_value='/usr/bin/geth'), \
                patch.object(audit, 'process_identity', return_value='42'), \
                patch.object(audit.shutil, 'which', return_value=None):
            proc = audit.process_metadata(123, '42', [socket_row()])
        serialized = json.dumps(proc)
        for secret in ('secret-password', 'super-secret', 'mnemonic words'):
            self.assertNotIn(secret, serialized)
        self.assertEqual(proc['container_id'], 'a' * 64)
        self.assertEqual(proc['systemd_service'], 'geth.service')
        self.assertEqual(proc['ppid'], 1)

    def test_pid_reused_is_not_reported(self):
        with patch.object(audit, 'read', return_value=None), \
                patch.object(audit.os, 'readlink', side_effect=PermissionError), \
                patch.object(audit, 'process_identity', return_value='new-pid-starttime'):
            self.assertIsNone(audit.process_metadata(123, 'old-pid-starttime', []))

    def test_permission_denied_exe_is_explicit(self):
        with patch.object(audit, 'read', return_value=None), \
                patch.object(audit.os, 'readlink', side_effect=PermissionError), \
                patch.object(audit, 'process_identity', return_value='42'):
            proc = audit.process_metadata(123, '42', [])
        self.assertIsNone(proc['exe'])
        self.assertIn('EXE_UNREADABLE', proc['issues'])

    def test_success_saves_before_change_and_verifies_sysctl(self):
        r = report()
        o = audit.parser().parse_args(['--disable-mptcp'])
        events = []
        def checkpoint():
            events.append('checkpoint:' + r['remediation_status'])
        def command(args):
            events.append(args)
            return 0, '', ''
        audit.remediate(r, o, checkpoint, lambda _: config('DISABLED'), command, lambda: 0)
        self.assertEqual(events[0], 'checkpoint:IN_PROGRESS')
        self.assertEqual(events[1], ['sysctl', '-w', 'net.mptcp.enabled=0'])
        self.assertEqual(r['remediation_status'], 'SUCCESS')
        self.assertFalse(r['rollback']['automatic'])

    def test_failure_is_exit_4_and_never_reenables(self):
        for command_rc, after in ((1, 'ENABLED'), (0, 'ENABLED'), (1, 'DISABLED')):
            r = report()
            with patch.object(audit, 'run') as runner:
                runner.return_value = command_rc, '', ''
                audit.remediate(r, audit.parser().parse_args([]), lambda: None,
                                 lambda _: config(after), runner, lambda: 0)
                self.assertEqual(r['remediation_status'], 'FAILED')
                self.assertEqual(audit.exit_code(r), 4)
                runner.assert_called_once_with(['sysctl', '-w', 'net.mptcp.enabled=0'])

    def test_nonroot_dryrun_checkonly_and_idempotent_rerun(self):
        for flags, state, uid, expected in [([], 'ENABLED', 1000, 'PERMISSION_DENIED'),
            (['--dry-run'], 'ENABLED', 0, 'DRY_RUN'), (['--check-only'], 'ENABLED', 0, 'CHECK_ONLY'),
            (['--no-remediation'], 'ENABLED', 0, 'CHECK_ONLY'), ([], 'DISABLED', 0, 'ALREADY_DISABLED')]:
            r = report()
            r['mptcp_before'] = state
            with patch.object(audit, 'run') as runner:
                audit.remediate(r, audit.parser().parse_args(flags), lambda: None, runner=runner, uid=lambda: uid)
                runner.assert_not_called()
            self.assertEqual(r['remediation_status'], expected)

    def test_docker_bridge_filter_and_non_rfc1918_vpc_ip(self):
        interfaces = [dict(ifname=name, flags=['UP'], addr_info=[dict(local=ip, scope='global')])
                      for name, ip in [('docker0', '172.17.0.1'), ('br-abc', '172.18.0.1'),
                                       ('veth123', '10.1.0.3'), ('eth0', '100.64.1.2'), ('eth1', '198.19.0.2')]]
        with patch.object(audit, 'run', side_effect=[(0, json.dumps(interfaces), ''),
                         (0, json.dumps([dict(dev='eth0')]), '')]):
            result = audit.host_addresses()
        self.assertEqual(result['private_ips'], ['100.64.1.2', '198.19.0.2'])
        self.assertEqual(result['primary_private_ip'], '100.64.1.2')

    def test_no_default_route_does_not_guess_primary(self):
        with patch.object(audit, 'run', side_effect=[(0, '[]', ''), (0, '[]', '')]):
            result = audit.host_addresses()
        self.assertIsNone(result['primary_private_ip'])

    def test_atomic_output_private_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            path = root / 'result.json'
            audit.atomic_json(path, dict(before='ENABLED'))
            self.assertEqual(os.stat(str(path)).st_mode & 0o777, 0o600)
            audit.atomic_json(path, dict(after='DISABLED'))
            self.assertEqual(json.loads(path.read_text()), dict(after='DISABLED'))
            link = root / 'link'
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                audit.atomic_json(link, {})


    def test_sysctl_proc_read_uses_small_request(self):
        from unittest.mock import mock_open
        stream = mock_open(read_data=b'1\n')
        with patch('builtins.open', stream):
            self.assertEqual(audit.read('/proc/sys/net/mptcp/enabled'), '1')
        stream().read.assert_called_once_with(4096)


if __name__ == '__main__':
    unittest.main()
