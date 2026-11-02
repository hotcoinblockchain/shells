import unittest
from unittest.mock import patch
from support import audit, RULES, package, report


class KernelTests(unittest.TestCase):
    def test_fixed_debian_vendor_version_comparison(self):
        calls = []
        def compare(left, operation, right):
            calls.append((left, operation, right))
            return True
        result = audit.classify_kernel(dict(ID='debian', VERSION_CODENAME='bookworm'),
                                       [package()], RULES, compare)
        self.assertEqual(result['status'], 'FIXED')
        self.assertEqual(calls, [('6.1.190-1', 'ge', '6.1.190-1')])
        self.assertIn('security-tracker.debian.org', result['sources'][0])

    def test_vulnerable_debian(self):
        result = audit.classify_kernel(dict(ID='debian', VERSION_CODENAME='trixie'),
                                       [package(version='6.12.107-1')], RULES, lambda *_: False)
        self.assertEqual(result['status'], 'VULNERABLE')

    def test_unknown_custom_missing_or_newer_series(self):
        for packages in ([], [package(version='6.18.56-custom')], [package(maintainer='Local Build')]):
            result = audit.classify_kernel(dict(ID='debian', VERSION_CODENAME='bookworm'), packages, RULES)
            self.assertEqual(result['status'], 'UNKNOWN')

    def test_rhel_derivatives_unknown_and_other_os_unsupported(self):
        for os_id in ('rocky', 'almalinux', 'rhel'):
            self.assertEqual(audit.classify_kernel(dict(ID=os_id), [package()], RULES)['status'], 'UNKNOWN')
        self.assertEqual(audit.classify_kernel(dict(ID='other'), [], RULES)['status'], 'UNSUPPORTED')

    def test_ubuntu_esm_18_20_exact_vendor_evidence(self):
        for release, version in [('bionic', '4.15.0-261.273'), ('focal', '5.4.0-244.264')]:
            with self.subTest(release=release):
                result = audit.classify_kernel(dict(ID='ubuntu', VERSION_CODENAME=release),
                    [package(version=version, maintainer='Ubuntu Kernel Team')], RULES)
                self.assertEqual(result['status'], 'VULNERABLE')
                self.assertIn('esm-infra', result['evidence'][0])

    def test_ubuntu_unlisted_newer_version_is_not_assumed_fixed(self):
        result = audit.classify_kernel(dict(ID='ubuntu', VERSION_CODENAME='noble'),
            [package(version='6.8.0-999.999', maintainer='Ubuntu Kernel Team')], RULES)
        self.assertEqual(result['status'], 'UNKNOWN')

    def test_ubuntu_hwe_cloud_and_oem_scoped_rules(self):
        selected = [r for r in RULES['distribution_rules'] if r['os_id'] == 'ubuntu' and
                    any(s in r['source_package'] for s in ('aws', 'azure', 'hwe', 'oem'))]
        self.assertGreater(len(selected), 10)
        for rule in selected:
            result = audit.classify_kernel(dict(ID='ubuntu', VERSION_CODENAME=rule['release']),
                [package(source=rule['source_package'], version=rule['exact_version'], maintainer='Ubuntu')], RULES)
            self.assertEqual(result['status'], 'VULNERABLE', rule['id'])

    def test_running_kernel_queried_even_with_newer_kernel_installed(self):
        names = []
        def command(args, **_):
            names.append(args[-1])
            if args[-1] == 'linux-image-6.8.0-147-generic':
                return 0, 'ii \tlinux-image-6.8.0-147-generic\t6.8.0-147.147\tlinux-signed\t6.8.0-147.147\tUbuntu Kernel Team\t\n', ''
            return 1, '', ''
        with patch.object(audit, 'run', side_effect=command):
            packages = audit.kernel_package('6.8.0-147-generic', 'ubuntu')
        self.assertEqual(packages[0]['source'], 'linux')
        self.assertTrue(all('6.8.0-147' in name for name in names))
        audit.verify_running_build(packages, 'ubuntu', '6.8.0-147-generic',
                                   'Ubuntu 6.8.0-147.147-generic 6.8.12', None)
        result = audit.classify_kernel(dict(ID='ubuntu', VERSION_CODENAME='noble'), packages, RULES)
        self.assertEqual(result['status'], 'VULNERABLE')

    def test_debian_signed_kernel_built_using_source(self):
        value = 'ii \tlinux-image-6.1.0-42-amd64\t6.1.190-1\tlinux-signed-amd64\t6.1.190+1\tDebian Kernel Team\tlinux (= 6.1.190-1)\n'
        with patch.object(audit, 'run', return_value=(0, value, '')):
            packages = audit.kernel_package('6.1.0-42-amd64', 'debian')
        self.assertEqual(packages[0]['source_version'], '6.1.190-1')
        self.assertEqual(packages[0]['source'], 'linux')

    def test_same_uname_updated_on_disk_but_not_rebooted_is_unknown(self):
        packages = [package(version='6.1.190-1')]
        audit.verify_running_build(packages, 'debian', '6.1.0-42-amd64', None,
                                   'Linux 6.1.0-42-amd64 #1 SMP Debian 6.1.189-1 (2026-10-01)')
        result = audit.classify_kernel(dict(ID='debian', VERSION_CODENAME='bookworm'),
                                       packages, RULES, lambda *_: True)
        self.assertEqual(result['status'], 'UNKNOWN')

    def test_running_build_exact_debian_and_ubuntu_esm_signature(self):
        packages = [package()]
        audit.verify_running_build(packages, 'debian', '6.1.0-42-amd64', None,
                                   'Linux version 6.1.0-42-amd64 #1 SMP Debian 6.1.190-1 (date)')
        self.assertTrue(packages[0]['running_build_verified'])
        packages = [package(version='4.15.0-261.273')]
        audit.verify_running_build(packages, 'ubuntu', '4.15.0-261-generic',
                                   'Ubuntu 4.15.0-261.273-generic 4.15.18', None)
        self.assertTrue(packages[0]['running_build_verified'])

    def test_native_dpkg_comparator_errors_remain_unknown(self):
        with patch.object(audit, 'run', return_value=(127, '', 'COMMAND_MISSING')):
            result = audit.classify_kernel(dict(ID='debian', VERSION_CODENAME='bookworm'), [package()], RULES)
        self.assertEqual(result['status'], 'UNKNOWN')

    def test_rules_are_primary_source_and_pinned_by_hash(self):
        self.assertEqual(len(RULES['sha256']), 64)
        self.assertEqual(RULES['upstream']['introduced_version'], '4.4')
        self.assertTrue(all(s['trust'] == 'official-primary' for s in RULES['sources']))

    def test_exit_priority(self):
        r = report('UNKNOWN')
        self.assertEqual(audit.exit_code(r), 3)
        r['kernel_status'] = 'FIXED'
        self.assertEqual(audit.exit_code(r), 0)
        r['mptcp_processes'] = [dict(pid=1)]
        self.assertEqual(audit.exit_code(r), 1)
        r['audit_errors'] = ['failed']
        self.assertEqual(audit.exit_code(r), 2)
        r['remediation_status'] = 'FAILED'
        self.assertEqual(audit.exit_code(r), 4)

    def test_os_release_is_parsed_without_execution(self):
        os_info = audit.parse_os('ID=ubuntu\nNAME="Ubuntu Linux"\nEXTRA="$(touch /tmp/never-execute)"')
        self.assertEqual(os_info['NAME'], 'Ubuntu Linux')
        self.assertEqual(os_info['EXTRA'], '$(touch /tmp/never-execute)')


if __name__ == '__main__':
    unittest.main()
