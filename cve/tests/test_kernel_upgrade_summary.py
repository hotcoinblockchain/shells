"""Mocked package version comparisons and final kernel-upgrade state reporting."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'cve_2026_98432_kernel_upgrade.sh'
SOURCE = SCRIPT.read_text()
FUNCTIONS = SOURCE[SOURCE.index('kernel_status() {'):SOURCE.index('for arg in "$@";')]
MOCK = '''#!/usr/bin/env python3
import os, re, sys
def key(v):
    return tuple(int(x) for x in re.findall(r'[0-9]+', v))
if os.path.basename(sys.argv[0]) == 'rpm':
    a,b = re.findall(r'"([^\"]+)"', sys.argv[2])
    print((key(a)>key(b))-(key(a)<key(b)))
else:
    sys.exit(0 if key(sys.argv[2]) >= key(sys.argv[4]) else 1)
'''


class SummaryTests(unittest.TestCase):
    def run_case(self, running, installed='', next_kernel='', fix='5.10.134-19.10.al8', os_id='alinux', expression='print_summary'):
        with tempfile.TemporaryDirectory() as temp:
            for name in ('rpm', 'dpkg'):
                executable = Path(temp, name)
                executable.write_text(MOCK)
                executable.chmod(0o755)
            variables = dict(RUNNING=running, INSTALLED_KERNELS=installed, NEXT_KERNEL=next_kernel,
                             FIX=fix, OS_ID=os_id, NEXT_CONFIDENCE='grubby 默认启动项')
            script = 'set -Eeuo pipefail\nlog() { shift; printf "%s\\n" "$*"; }\n' + FUNCTIONS
            script += '\n' + '\n'.join(k+'='+shlex.quote(v) for k,v in variables.items())
            script += '\n' + expression
            result = subprocess.run(['bash'], input=script, text=True, capture_output=True,
                                    env={**os.environ, 'PATH': temp + os.pathsep + os.environ['PATH']})
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_user_log_already_running_fixed(self):
        kernel = '5.10.134-19.10.al8.x86_64'
        output = self.run_case(kernel, '5.10.134-16.1.al8.x86_64\n'+kernel, kernel)
        self.assertIn('[RUNNING_FIXED]', output)
        self.assertIn('无需为本 CVE 再次重启', output)
        self.assertNotIn('[FIX_INSTALLED_REBOOT_REQUIRED]', output)

    def test_patch_installed_but_old_kernel_running(self):
        output = self.run_case('5.10.134-19.9.al8.x86_64', '5.10.134-19.10.al8.x86_64', '5.10.134-19.10.al8.x86_64')
        self.assertIn('[FIX_INSTALLED_REBOOT_REQUIRED]', output)
        self.assertIn('尚未运行', output)

    def test_installed_patch_not_default(self):
        output = self.run_case('5.10.134-19.9.al8.x86_64', '5.10.134-19.10.al8.x86_64', '5.10.134-19.9.al8.x86_64')
        self.assertIn('不能直接认为重启即可修复', output)

    def test_vulnerable_without_fixed_package(self):
        output = self.run_case('5.10.134-19.9.al8.x86_64', '5.10.134-19.9.al8.x86_64')
        self.assertIn('[VULNERABLE_NO_FIX_INSTALLED]', output)

    def test_unknown_threshold(self):
        output = self.run_case('6.1.0-custom', fix='')
        self.assertIn('[UNKNOWN]', output)

    def test_fixed_running_but_boot_would_regress(self):
        output = self.run_case('5.10.134-19.10.al8.x86_64', next_kernel='5.10.134-19.9.al8.x86_64')
        self.assertIn('下次重启可能回退', output)

    def test_newer_same_branch_is_fixed(self):
        self.assertEqual(self.run_case('5.10.134-19.11.al8.aarch64', expression='kernel_status "$RUNNING"'), 'FIXED')

    def test_different_base_and_pro_not_mixed(self):
        for kernel in ('6.6.102-8.0.2.alnx4.x86_64', '5.10.134-014.8.ali5000.pro.al8.x86_64'):
            self.assertEqual(self.run_case(kernel, expression='kernel_status "$RUNNING"'), 'UNKNOWN')

    def test_pro_has_separate_threshold(self):
        fix = '5.10.134-014.8.ali5000.pro.al8'
        self.assertEqual(self.run_case(fix+'.x86_64', fix=fix, expression='kernel_status "$RUNNING"'), 'FIXED')
        self.assertEqual(self.run_case('5.10.134-014.7.ali5000.pro.al8.x86_64', fix=fix, expression='kernel_status "$RUNNING"'), 'VULNERABLE')

    def test_ubuntu_same_branch_only(self):
        for kernel, expected in (('6.8.0-149-generic', 'FIXED'), ('6.8.0-148-generic', 'VULNERABLE'),
                                 ('6.8.0-150-aws', 'UNKNOWN'), ('7.0.0-43-generic', 'UNKNOWN')):
            self.assertEqual(self.run_case(kernel, os_id='ubuntu', fix='6.8.0-149-generic', expression='kernel_status "$RUNNING"'), expected)


if __name__ == '__main__':
    unittest.main()
