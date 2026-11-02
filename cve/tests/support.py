import copy
import importlib.util
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('kernel_audit', str(BASE / 'lib/kernel_tcp_uaf_audit.py'))
audit = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = audit
spec.loader.exec_module(audit)
RULES = audit.load_rules(BASE / 'rules/kernel-tcp-uaf.json')


def package(source='linux', version='6.1.190-1', maintainer='Debian Kernel Team'):
    return dict(name='linux-image-6.1.0-42-amd64', version=version, source=source,
                source_version=version, maintainer=maintainer, running_build_verified=True)


def detection():
    return dict(status='AVAILABLE', method='NETLINK_SOCK_DIAG', processes=[], sockets=[],
                unattributed_sockets=[], listener_coverage='SUPPORTED_BASELINE', issues=[])


def config(state='ENABLED'):
    return dict(state=state, support='SUPPORTED', proc_value='1' if state == 'ENABLED' else '0',
                sysctl_value='1' if state == 'ENABLED' else '0', consistent=True)


def report(status='FIXED'):
    return dict(hostname='node-1', instance_id='instance-1', os_name='Debian GNU/Linux',
                os_version='12', kernel_version='6.1.0-42-amd64', kernel_status=status,
                kernel_detection=dict(status=status, evidence=['Vendor package comparison.']),
                private_ips=['100.64.0.5'], mptcp_before='ENABLED', mptcp_after='ENABLED',
                mptcp_config_before=config(), mptcp_config_after=config(),
                mptcp_processes=[], remediation_status='NOT_ATTEMPTED', audit_time='2026-11-02T00:00:00Z',
                rule_version='2026-11-02.1', mutation_attempted=False, audit_errors=[],
                socket_detection_before=detection(), socket_detection_after=detection())


def process(pid=123):
    return dict(pid=pid, name='geth', exe='/usr/bin/geth',
                listen_addresses=[dict(address='0.0.0.0', port=30303)],
                cmdline_redacted='[ALL_ARGUMENTS_REDACTED; argc=3]')


def clone(value):
    return copy.deepcopy(value)
