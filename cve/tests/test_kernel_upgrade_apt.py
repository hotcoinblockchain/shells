"""Exercise the real APT upgrade function with local commands; never install packages."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / 'cve_2026_98432_kernel_upgrade.sh').read_text()
PRELUDE = SOURCE[SOURCE.index('log(){'):SOURCE.index('usage(){')]
FUNCTION = SOURCE[SOURCE.index('upgrade_debian_kernel() {'):SOURCE.index('for arg in "$@";')]
MOCK = r'''#!/usr/bin/env python3
import json, os, signal, sys
name = os.path.basename(sys.argv[0])
with open(os.environ['APT_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, sys.argv[1:], os.environ.get('LC_ALL')]) + '\n')
if name == 'apt-get':
    operation = sys.argv[1]
    if operation == os.environ.get('APT_TEST_FAIL'):
        print('simulated apt-get error', file=sys.stderr)
        sys.exit(100)
elif name == 'dpkg-query':
    if os.environ.get('APT_TEST_INSTALLED') == 'yes':
        print('install ok installed', end='')
    else:
        sys.exit(1)
elif name == 'apt-cache':
    if os.environ.get('APT_TEST_FAIL') == 'policy':
        sys.exit(100)
    candidate = os.environ.get('APT_TEST_CANDIDATE', '6.8.0-151.151')
    policy = 'linux-generic:\n  Installed: (none)\n'
    if candidate != 'missing':
        policy += '  Candidate: ' + candidate + '\n'
    policy += '  Version table:\n     6.8.0-151.151 500\n'
    policy += '        500 http://mirrors.cloud.aliyuncs.com/ubuntu noble-updates/main amd64 Packages\n'
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    os.write(1, policy.encode())
    # More than a pipe buffer, so an early consumer exit reliably breaks writes.
    for _ in range(64):
        os.write(1, b'        500 http://example.test/ubuntu noble-security/main amd64 Packages\n' * 256)
    if os.environ.get('APT_TEST_PROPOSED') == 'yes':
        os.write(1, b'        500 http://example.test/ubuntu noble-proposed/main amd64 Packages\n')
'''


class AptUpgradeTests(unittest.TestCase):
    def run_case(self, *, expression='upgrade_debian_kernel', **settings):
        with tempfile.TemporaryDirectory() as temp:
            calls_file = Path(temp, 'calls.jsonl')
            for name in ('apt-cache', 'apt-get', 'dpkg-query'):
                command = Path(temp, name)
                command.write_text(MOCK)
                command.chmod(0o755)
            script = 'set -Eeuo pipefail\n' + PRELUDE + FUNCTION
            script += '\nPKG=linux-generic\n' + expression + '\n'
            result = subprocess.run(['bash'], input=script, text=True, capture_output=True,
                env={**os.environ, **settings, 'PATH': temp + os.pathsep + os.environ['PATH'],
                     'APT_TEST_CALLS': str(calls_file)}, timeout=20)
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
            return result, calls

    def test_long_policy_and_missing_metapackage_install_normally(self):
        result, calls = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        policies = [call for call in calls if call[0] == 'apt-cache']
        self.assertEqual(len(policies), 1)
        self.assertEqual(policies[0][2], 'C')
        self.assertIn('APT 候选版本=6.8.0-151.151', result.stdout)
        self.assertIn(['install', '-y', 'linux-generic'], [call[1] for call in calls])

    def test_existing_metapackage_uses_only_upgrade(self):
        result, calls = self.run_case(APT_TEST_INSTALLED='yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['install', '-y', '--only-upgrade', 'linux-generic'], [call[1] for call in calls])

    def test_original_early_exit_parser_reproduces_141(self):
        result, _ = self.run_case(expression="cand=\"$(apt-cache policy linux-generic | awk '/Candidate:/{print $2;exit}')\"")
        self.assertEqual(result.returncode, 141)
        self.assertEqual(result.stderr.count('执行失败:'), 1)

    def test_no_candidate_refuses_install(self):
        for candidate in ('(none)', 'missing'):
            result, calls = self.run_case(APT_TEST_CANDIDATE=candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('无可用候选版本', result.stderr)
            self.assertFalse(any(call[0] == 'apt-get' and call[1][0] == 'install' for call in calls))

    def test_proposed_after_long_policy_is_rejected(self):
        result, calls = self.run_case(APT_TEST_PROPOSED='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('拒绝在启用 proposed 的环境升级', result.stderr)
        self.assertFalse(any(call[0] == 'apt-get' and call[1][0] == 'install' for call in calls))

    def test_actual_apt_failures_are_preserved_and_logged_once(self):
        for operation in ('update', 'policy', 'install'):
            result, calls = self.run_case(APT_TEST_FAIL=operation)
            self.assertEqual(result.returncode, 100, operation)
            self.assertEqual(result.stderr.count('执行失败:'), 1, result.stderr)
            if operation != 'install':
                self.assertFalse(any(call[0] == 'apt-get' and call[1][0] == 'install' for call in calls))


if __name__ == '__main__':
    unittest.main()
