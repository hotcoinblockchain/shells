#!/usr/bin/env python3
"""Offline CVE-2026-98432 inventory and temporary, current-netns MPTCP mitigation.

Python >= 3.6, standard library only. No scanned executable is ever executed.
No socket is created with IPPROTO_MPTCP (which could autoload kernel modules).
"""
import argparse
import base64
import copy
import datetime
import fcntl
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import signal
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

CVE = 'CVE-2026-98432'
BASE = Path(__file__).resolve().parent.parent
LIMIT = 8 * 1024 * 1024
WARNINGS = [
    '临时关闭 MPTCP 不会保证现有 Socket 消失；相关进程可能需要人工滚动重启。',
    '关闭 MPTCP 不等于修复内核；请安装发行版修复内核并按维护流程重启验证。',
    '本脚本不写 sysctl 持久配置；系统重启后该设置可能恢复。',
    '检测和缓解仅覆盖当前网络命名空间；容器的其他网络命名空间需分别巡检。',
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def log(level, message):
    print('{} [{}] {}'.format(now(), level, message), file=sys.stderr)


def text(value, limit=1024):
    # Terminal/control and card markup are not trusted process metadata.
    return ''.join(c if c.isprintable() else '?' for c in str(value))[:limit]


def read(path, binary=False):
    try:
        with open(str(path), 'rb') as stream:
            # proc sysctl handlers may reject oversized reads (ENOMEM/EINVAL).
            value = stream.read(4096 if str(path).startswith('/proc/sys/') else LIMIT + 1)
        if len(value) > LIMIT:
            return None
        return value if binary else value.decode('utf-8', 'replace').strip()
    except OSError:
        return None


def run(args, timeout=10):
    """Never return raw stderr to reports: tools may echo paths or credentials."""
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, env=dict(os.environ, LC_ALL='C',
                                    GOTOOLCHAIN='local', GOENV='off', GOWORK='off'))
        if len(result.stdout) > LIMIT or len(result.stderr) > LIMIT:
            return 125, '', 'OUTPUT_LIMIT'
        return (result.returncode, result.stdout.decode('utf-8', 'replace'),
                'STDERR_PRESENT' if result.stderr else '')
    except FileNotFoundError:
        return 127, '', 'COMMAND_MISSING'
    except subprocess.TimeoutExpired:
        return 124, '', 'TIMEOUT'
    except OSError:
        return 126, '', 'EXECUTION_FAILED'


def secure_directory(path):
    path = Path(path)
    # Every ancestor must be a real directory; reject writable non-sticky parents.
    for ancestor in reversed((path,) + tuple(path.parents)):
        if not ancestor.exists() and ancestor == path:
            try:
                ancestor.mkdir(mode=0o700)
            except FileExistsError:
                pass
        info = ancestor.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ValueError('unsafe state/output directory')
        if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
            raise ValueError('state/output ancestor is writable by other users')
        if info.st_uid not in (0, os.geteuid()):
            raise ValueError('state/output ancestor belongs to an untrusted user')
    info = path.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('state directory must be owned by current user with mode 0700')
    return path


def atomic_json(path, value):
    path = Path(path)
    parent = path.parent
    # Output parents need not be private, but must be trusted (e.g. /var/log).
    for ancestor in (parent,) + tuple(parent.parents):
        info = ancestor.lstat()
        if info.st_uid not in (0, os.geteuid()) or not stat.S_ISDIR(info.st_mode) or (info.st_mode & 0o022 and
                                             not info.st_mode & stat.S_ISVTX):
            raise ValueError('unsafe output directory: {} (mode={:04o}, uid={}, gid={})'.format(
                ancestor, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid))
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('output must be a regular non-symlink file')
    if path.exists() and path.stat().st_uid != os.geteuid():
        raise ValueError('output file belongs to another user')
    fd, candidate = tempfile.mkstemp(prefix='.tcp-uaf-', dir=str(parent))
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(candidate, str(path))
        directory_fd = os.open(str(parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(candidate):
            os.unlink(candidate)


def parse_os(value):
    result = {}
    for line in (value or '').splitlines():
        if '=' not in line or line.startswith('#'):
            continue
        key, raw = line.split('=', 1)
        try:
            fields = shlex.split(raw, comments=False)
            result[key] = fields[0] if len(fields) == 1 else raw
        except ValueError:
            continue
    return result


def kernel_package(release, os_id):
    if os_id in ('ubuntu', 'debian'):
        # Query only files belonging to the RUNNING release, never newest installed.
        candidates = ['linux-image-' + release, 'linux-image-unsigned-' + release,
                      'linux-modules-' + release]
        fmt = '${db:Status-Abbrev}\t${Package}\t${Version}\t${source:Package}\t${source:Version}\t${Maintainer}\t${Built-Using}\n'
        packages = []
        for name in candidates:
            rc, out, _ = run(['dpkg-query', '-W', '-f=' + fmt, name])
            for line in out.splitlines() if rc == 0 else []:
                fields = line.split('\t')
                if len(fields) != 7 or not fields[0].startswith('ii'):
                    continue
                _, package, version, source, source_version, maintainer, built = fields
                underlying = re.search(r'(?:^|,\s*)(linux(?:-6\.12)?)\s*\(=\s*([^ )]+)\)', built)
                if underlying:
                    source, source_version = underlying.groups()
                elif source == 'linux-signed' or source.startswith('linux-signed-'):
                    source = source.replace('linux-signed', 'linux', 1)
                packages.append(dict(name=package, version=version, source=source,
                                     source_version=source_version, maintainer=maintainer))
        return packages
    if os_id in ('rhel', 'rocky', 'almalinux', 'centos', 'amzn'):
        rc, out, _ = run(['rpm', '-qf', '/boot/vmlinuz-' + release,
                         '--qf', '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{SOURCERPM}\n'])
        if rc == 0:
            fields = out.strip().split('\t')
            if len(fields) == 3:
                return [dict(name=fields[0], version=fields[1], source=fields[2])]
    return []


def compare_deb(left, operation, right):
    rc, _, _ = run(['dpkg', '--compare-versions', left, operation, right])
    return True if rc == 0 else (False if rc == 1 else None)


def verify_running_build(packages, os_id, release, signature_value, proc_version):
    """Same uname release can be replaced on disk without rebooting. Fail closed.

    Ubuntu exposes its full build in version_signature; Debian embeds its source
    version after the Debian marker in /proc/version. Never trust dpkg alone.
    """
    for package in packages:
        version = package.get('source_version', '')
        if not version:
            package['running_build_verified'] = False
        elif os_id == 'ubuntu':
            expected = 'Ubuntu {}-{}'.format(version, release.rsplit('-', 1)[-1])
            package['running_build_verified'] = bool(signature_value and
                (signature_value == expected or signature_value.startswith(expected + ' ')))
        elif os_id == 'debian':
            package['running_build_verified'] = bool(proc_version and re.search(
                r'\bDebian ' + re.escape(version) + r'(?=\s|$)', proc_version))
        else:
            package['running_build_verified'] = False
    return packages


def classify_kernel(os_info, packages, rules, comparator=compare_deb):
    os_id = os_info.get('ID', '')
    result = dict(status='UNKNOWN', evidence=[], sources=[], matched_rule=None)
    if os_id not in ('ubuntu', 'debian', 'rhel', 'rocky', 'almalinux', 'centos', 'amzn'):
        result.update(status='UNSUPPORTED', evidence=['No validated rules for this distribution.'])
        return result
    if not packages:
        result['evidence'] = ['Running kernel package unavailable; installed newer kernels are ignored.']
        return result
    matches = []
    for package in packages:
        if not package.get('running_build_verified'):
            continue
        # Local package inventories are evidence, not cryptographic boot attestation.
        if os_id == 'ubuntu' and 'Ubuntu' not in package.get('maintainer', ''):
            continue
        if os_id == 'debian' and 'Debian' not in package.get('maintainer', ''):
            continue
        version = package.get('source_version', '')
        for rule in rules['distribution_rules']:
            if (rule['os_id'] != os_id or
                rule['release'] != os_info.get('VERSION_CODENAME') or
                rule['source_package'] != package.get('source')):
                continue
            if rule.get('exact_version') == version:
                matches.append((rule['status'], rule, package))
            elif rule.get('fixed_version') and version.startswith(rule['version_prefix']):
                fixed = comparator(version, 'ge', rule['fixed_version'])
                if fixed is not None:
                    matches.append(('FIXED' if fixed else 'VULNERABLE', rule, package))
    statuses = {item[0] for item in matches}
    if len(statuses) == 1:
        status, rule, package = matches[0]
        result.update(status=status, matched_rule=rule['id'], sources=[rule['source_url']],
                      evidence=['Running package {} {}, source {} {}; {}'.format(
                          package['name'], package['version'], package['source'],
                          package['source_version'], rule['evidence'])])
    elif statuses:
        result['evidence'] = ['Conflicting package/rule evidence; manual verification required.']
    else:
        result['evidence'] = ['No verified running-build/vendor rule for the package/release/flavour. '
                              'Upstream version numbers do not establish vendor backport status.']
    return result


def mptcp_config(release):
    proc = read('/proc/sys/net/mptcp/enabled')
    rc, sysctl, _ = run(['sysctl', '-n', 'net.mptcp.enabled'])
    sysctl = sysctl.strip() if rc == 0 else None
    state = {'0': 'DISABLED', '1': 'ENABLED'}.get(proc, 'UNKNOWN')
    support = 'SUPPORTED' if proc in ('0', '1') else 'UNKNOWN'
    config = read('/boot/config-' + release)
    if config and re.search(r'^# CONFIG_MPTCP is not set$', config, re.M) and proc is None:
        state, support = 'NOT_SUPPORTED', 'NOT_SUPPORTED'
    return dict(state=state, support=support, proc_value=proc, sysctl_value=sysctl,
                sysctl_available=rc == 0, consistent=sysctl is None or sysctl == proc)


class DiagnosticError(Exception):
    pass


def decode_diag(data):
    if len(data) < 72 or data[0] not in (socket.AF_INET, socket.AF_INET6):
        raise DiagnosticError('Malformed inet_diag record')
    family, state = data[0], data[1]
    sport, dport = struct.unpack_from('!HH', data, 4)
    size = 4 if family == socket.AF_INET else 16
    local = socket.inet_ntop(family, data[8:8 + size])
    remote = socket.inet_ntop(family, data[24:24 + size])
    uid, inode = struct.unpack_from('=II', data, 64)
    return dict(family='IPv4' if family == socket.AF_INET else 'IPv6',
                state='LISTEN' if state == 10 else str(state),
                local_address=local, local_port=sport, remote_address=remote,
                remote_port=dport, uid=uid, inode=inode,
                cookie=list(struct.unpack_from('=II', data, 44)),
                evidence='NETLINK_SOCK_DIAG / INET_DIAG_REQ_PROTOCOL=262')


def diag_dump(family):
    """Verified multipart dump, including explicit NLMSG_DONE and error checks.

    Protocol 262 needs INET_DIAG_REQ_PROTOCOL (u8 protocol field cannot hold it).
    This is the same uAPI used by iproute2 ss. No module is loaded explicitly.
    """
    seq = int.from_bytes(os.urandom(4), 'little') or 1
    request = struct.pack('=BBBBI', family, 0, 0, 0, 0xFFF) + bytes(48)
    request += struct.pack('=HHI', 8, 3, 262)
    header = struct.pack('=IHHII', 16 + len(request), 20, 0x301, seq, 0)
    rows = []
    deadline = time.monotonic() + 8
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 4) as channel:
        channel.bind((0, 0))
        channel.sendto(header + request, (0, 0))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DiagnosticError('Netlink dump deadline exceeded')
            channel.settimeout(remaining)
            packet, _, flags, address = channel.recvmsg(1024 * 1024)
            if flags & socket.MSG_TRUNC or address[0] != 0:
                raise DiagnosticError('Truncated/untrusted netlink response')
            offset = 0
            while offset < len(packet):
                if len(packet) - offset < 16:
                    raise DiagnosticError('Short netlink header')
                length, kind, nlflags, received_seq, _ = struct.unpack_from('=IHHII', packet, offset)
                if length < 16 or offset + length > len(packet) or received_seq != seq:
                    raise DiagnosticError('Invalid netlink framing/sequence')
                data = packet[offset + 16:offset + length]
                if nlflags & 0x10:  # NLM_F_DUMP_INTR, e.g. concurrent socket churn
                    raise DiagnosticError('Interrupted netlink dump')
                if kind == 2:
                    if len(data) < 4:
                        raise DiagnosticError('Short NLMSG_ERROR')
                    error = struct.unpack_from('=i', data)[0]
                    if error:
                        raise OSError(-error, 'MPTCP diagnostic unavailable')
                elif kind == 3:
                    if len(data) >= 4 and struct.unpack_from('=i', data)[0] != 0:
                        raise DiagnosticError('Netlink completion reports error')
                    return rows
                elif kind == 20:
                    rows.append(decode_diag(data))
                    if len(rows) > 100000:
                        raise DiagnosticError('Socket inventory limit exceeded')
                else:
                    raise DiagnosticError('Unexpected netlink response')
                offset += (length + 3) & ~3


def process_identity(pid):
    value = read('/proc/{}/stat'.format(pid))
    if not value or ')' not in value:
        return None
    fields = value[value.rfind(')') + 2:].split()
    return fields[19] if len(fields) > 19 else None  # stat field 22: starttime


def process_metadata(pid, starttime, sockets):
    root = Path('/proc') / str(pid)
    issues = []
    try:
        exe = os.readlink(str(root / 'exe'))
    except OSError:
        exe = None
        issues.append('EXE_UNREADABLE')
    status = read(root / 'status') or ''
    ppid = re.search(r'^PPid:\s+(\d+)', status, re.M)
    uid = re.search(r'^Uid:\s+(\d+)', status, re.M)
    username = None
    if uid:
        try:
            username = pwd.getpwuid(int(uid.group(1))).pw_name
        except KeyError:
            username = uid.group(1)
    comm = read(root / 'comm')
    cgroup = read(root / 'cgroup') or ''
    container = re.search(r'(?:/docker/|docker-|cri-containerd-|crio-)([a-f0-9]{64})(?:\.scope|/|$)', cgroup)
    service = re.findall(r'/([^/\n]+\.service)(?:/|$)', cgroup)
    # Every argument is omitted, including argv[0] which can be forged or secret.
    cmdline = read(root / 'cmdline', binary=True)
    redacted = '[ALL_ARGUMENTS_REDACTED; argc={}]'.format(
        len([part for part in cmdline.split(b'\0') if part])) if cmdline is not None else None
    if cmdline is None:
        issues.append('CMDLINE_UNREADABLE')
    go_version = None
    if exe and shutil.which('go'):
        # Inspect via /proc, never execute target. starttime checked after inspection.
        rc, output, _ = run(['go', 'version', '-m', str(root / 'exe')], timeout=3)
        match = re.search(r':\s+(go\d+\.\d+(?:\.\d+)?)\b', output)
        if rc == 0 and match:
            go_version = match.group(1)
    if process_identity(pid) != starttime:
        return None
    return dict(pid=pid, ppid=int(ppid.group(1)) if ppid else None,
                name=text(comm or 'UNKNOWN', 128), exe=text(exe) if exe else None,
                cmdline_redacted=redacted, user=text(username) if username else None,
                starttime_ticks=starttime, listening=any(s['state'] == 'LISTEN' for s in sockets),
                listen_addresses=[dict(address=s['local_address'], port=s['local_port'])
                                  for s in sockets if s['state'] == 'LISTEN'],
                sockets=sockets, container_status='CONFIRMED' if container else 'UNKNOWN',
                container_id=container.group(1) if container else None,
                systemd_service=text(service[-1]) if service else None,
                go_version=go_version, issues=issues)


def associate_processes(rows):
    by_inode = {s['inode']: s for s in rows if s['inode']}
    processes, attributed, issues = [], set(), set()
    if not rows:
        return processes, [], []
    try:
        entries = list(Path('/proc').iterdir())
    except OSError:
        return [], rows, ['PROC_UNREADABLE']
    for directory in entries:
        if not directory.name.isdigit():
            continue
        pid = int(directory.name)
        start = process_identity(pid)
        if start is None:
            continue
        owned = {}
        try:
            for fd in (directory / 'fd').iterdir():
                try:
                    target = os.readlink(str(fd))
                except OSError:
                    continue
                match = re.fullmatch(r'socket:\[(\d+)\]', target)
                if match and int(match.group(1)) in by_inode:
                    owned[int(match.group(1))] = by_inode[int(match.group(1))]
        except PermissionError:
            issues.add('PROC_FD_PERMISSION_DENIED')
        except OSError:
            continue
        if owned:
            process = process_metadata(pid, start, list(owned.values()))
            if process is not None:
                processes.append(process)
                attributed.update(owned)
            else:
                issues.add('PROCESS_EXITED_OR_PID_REUSED')
    return processes, [s for s in rows if s['inode'] not in attributed], sorted(issues)


def detect_sockets(dumper=diag_dump, release=None, config=None):
    version_rc, version, _ = run(['ss', '-V'])
    ss_rc, _, ss_error = run(['ss', '-M', '-H', '-a', '-n', '-p', '-e', '-O'])
    result = dict(status='DETECTION_UNAVAILABLE', method='NETLINK_SOCK_DIAG',
                  ss_version=text(version.strip()) if version_rc == 0 else None,
                  ss_mptcp_command_ok=ss_rc == 0 and not ss_error,
                  sockets=[], processes=[], unattributed_sockets=[], issues=[],
                  scope='CURRENT_NETWORK_NAMESPACE', listener_coverage='UNVERIFIED')
    try:
        for family in (socket.AF_INET, socket.AF_INET6):
            result['sockets'].extend(dumper(family))
        result['status'] = 'AVAILABLE'
    except (OSError, DiagnosticError) as exc:
        result['issues'].append('MPTCP_DIAG_UNAVAILABLE:' + type(exc).__name__)
    # v6.1's upstream mptcp_diag.c includes listener enumeration. This threshold
    # checks diagnostic capability, never CVE status. Older vendor backports are
    # conservatively unverified. A successful ss exit alone proves nothing.
    baseline = re.match(r'^(\d+)\.(\d+)', release or os.uname().release)
    listener_capable = baseline and tuple(map(int, baseline.groups())) >= (6, 1)
    if result['status'] == 'AVAILABLE' and listener_capable:
        result['listener_coverage'] = 'SUPPORTED_BASELINE'
    elif any(s['state'] == 'LISTEN' for s in result['sockets']):
        result['listener_coverage'] = 'OBSERVED'
    else:
        result['issues'].append('EMPTY_LISTENER_DUMP_DOES_NOT_PROVE_ABSENCE')
        result['status'] = 'DETECTION_UNAVAILABLE'
    if config and config['support'] == 'NOT_SUPPORTED' and not result['sockets']:
        result.update(status='AVAILABLE', listener_coverage='NOT_SUPPORTED', issues=[])
    processes, missing, issues = associate_processes(result['sockets'])
    if processes:
        # Inode numbers can be recycled while scanning /proc. Revalidate kernel
        # cookies after metadata collection, keeping only live identical sockets.
        try:
            live = []
            for family in (socket.AF_INET, socket.AF_INET6):
                live.extend(dumper(family))
            keys = {(s['inode'], tuple(s['cookie'])) for s in live}
            verified = []
            for process in processes:
                owned = [s for s in process['sockets'] if (s['inode'], tuple(s['cookie'])) in keys]
                if owned and process_identity(process['pid']) == process['starttime_ticks']:
                    process['sockets'] = owned
                    process['listening'] = any(s['state'] == 'LISTEN' for s in owned)
                    process['listen_addresses'] = [dict(address=s['local_address'], port=s['local_port'])
                                                   for s in owned if s['state'] == 'LISTEN']
                    verified.append(process)
                else:
                    issues.append('SOCKET_CHANGED_OR_PID_REUSED_DURING_SCAN')
            processes = verified
            attributed = {s['inode'] for p in processes for s in p['sockets']}
            missing = [s for s in result['sockets'] if s['inode'] not in attributed]
        except (OSError, DiagnosticError):
            processes, missing = [], list(result['sockets'])
            issues.append('SOCKET_REVALIDATION_UNAVAILABLE')
    result.update(processes=processes, unattributed_sockets=missing)
    result['issues'].extend(issues)
    if missing:
        result['issues'].append('SOCKET_OWNER_UNAVAILABLE')
    return result


def host_addresses():
    rc, output, _ = run(['ip', '-j', '-4', 'addr', 'show'])
    rr, routes, _ = run(['ip', '-j', '-4', 'route', 'show', 'default'])
    result = dict(private_ips=[], primary_private_ip=None, primary_interface=None,
                  address_source='ip-json', address_scope='HOST_INTERFACE_CANDIDATES', issues=[])
    try:
        if rc != 0:
            raise ValueError()
        interfaces = json.loads(output)
        routes = json.loads(routes) if rr == 0 else []
        candidates = []
        for interface in interfaces:
            name = interface.get('ifname', '')
            kind = interface.get('linkinfo', {}).get('info_kind', '')
            if (name == 'lo' or re.match(r'^(?:docker\d*|br-|veth)', name) or
                    kind in ('veth', 'bridge') or 'LOOPBACK' in interface.get('flags', [])):
                continue
            for address in interface.get('addr_info', []):
                try:
                    ip = ipaddress.IPv4Address(address.get('local', ''))
                except ipaddress.AddressValueError:
                    continue
                if (address.get('scope') != 'global' or ip.is_loopback or ip.is_multicast or
                        ip.is_unspecified or ip.is_link_local or int(ip) == 0xFFFFFFFF):
                    continue
                candidates.append((name, str(ip)))
        result['private_ips'] = sorted({ip for _, ip in candidates})
        devices = {route['dev'] for route in routes if route.get('dev')}
        # Multiple defaults can be policy routing/multipath; do not guess.
        if len(devices) == 1:
            device = next(iter(devices))
            ips = [ip for name, ip in candidates if name == device]
            preferred = {route.get('prefsrc') for route in routes if route.get('dev') == device}
            preferred = set(ips) & preferred
            result['primary_interface'] = device
            if len(preferred) == 1:
                result['primary_private_ip'] = next(iter(preferred))
            elif len(ips) == 1:
                result['primary_private_ip'] = ips[0]
        if not result['primary_private_ip']:
            result['issues'].append('PRIMARY_ADDRESS_UNCONFIRMED')
    except (ValueError, TypeError, KeyError, AttributeError):
        result['issues'].append('IP_JSON_UNAVAILABLE')
    return result


def load_rules(path):
    data = json.loads(Path(path).read_text())
    if data.get('schema_version') != 1 or data.get('cve_id') != CVE:
        raise ValueError('unsupported rule schema/CVE')
    if not isinstance(data.get('distribution_rules'), list) or not data.get('rule_version'):
        raise ValueError('invalid rule document')
    for rule in data['distribution_rules']:
        if (not all(rule.get(k) for k in ('id', 'os_id', 'release', 'source_package', 'source_url', 'evidence')) or
                not rule['source_url'].startswith('https://') or
                not (rule.get('exact_version') or (rule.get('fixed_version') and rule.get('version_prefix'))) or
                rule.get('status', 'FIXED') not in ('FIXED', 'NOT_AFFECTED', 'VULNERABLE')):
            raise ValueError('invalid vendor rule')
    data['sha256'] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    return data


def protected_secret(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.geteuid()) or
                info.st_mode & 0o077 or info.st_size > 8192):
            raise ValueError('credential file requires owner root/current user and mode 0600 or stricter')
        with os.fdopen(fd, 'r') as stream:
            fd = None
            secret = stream.read(8193).strip()
        if not secret or len(secret) > 8192 or '\n' in secret or '\r' in secret:
            raise ValueError('credential file is empty or malformed')
        return secret
    finally:
        if fd is not None:
            os.close(fd)


def webhook_target(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.netloc not in ('open.feishu.cn', 'open.larksuite.com') or
            parsed.query or parsed.fragment or not re.fullmatch(r'/open-apis/bot/v2/hook/[A-Za-z0-9-]+', parsed.path)):
        raise ValueError('webhook must be an official Feishu/Lark HTTPS custom-bot URL')
    return parsed.hostname, parsed.path


def should_alert(report, options):
    if options.alert_mode == 'none':
        return False
    uncertain = unresolved(report)
    return (options.alert_mode == 'always' or report['kernel_status'] == 'VULNERABLE' or
            bool(report['mptcp_processes']) or (options.alert_unknown and uncertain))


def unresolved(report):
    before = report['socket_detection_before']
    return (report['kernel_status'] in ('UNKNOWN', 'UNSUPPORTED') or
            report['mptcp_before'] == 'UNKNOWN' or before['status'] != 'AVAILABLE' or
            before['listener_coverage'] == 'UNVERIFIED' or bool(before['unattributed_sockets']) or
            bool(before['issues'] and before['processes']))


def exit_code(report):
    # Priority: remediation failure > audit failure > confirmed risk > uncertainty > clear.
    if report['remediation_status'] in ('FAILED', 'PERMISSION_DENIED', 'INTERRUPTED'):
        return 4
    if report.get('audit_errors'):
        return 2
    if report['kernel_status'] == 'VULNERABLE' or report['mptcp_processes']:
        return 1
    return 3 if unresolved(report) else 0


def alert_card(report):
    high = report['kernel_status'] == 'VULNERABLE'
    risk = high or bool(report['mptcp_processes'])
    uncertain = unresolved(report)
    colour = 'red' if high else ('orange' if risk or uncertain else 'green')
    severity = '已确认内核受影响' if high else ('需要人工确认' if risk or uncertain else '检查完成')
    body = [
        severity,
        '主机: {} / 实例: {}'.format(report['hostname'], report['instance_id']),
        '系统: {} {}'.format(report['os_name'], report['os_version']),
        '运行内核: {}'.format(report['kernel_version']),
        'IP: {}'.format(', '.join(report['private_ips']) or 'UNKNOWN'),
        '{}: {}'.format(CVE, report['kernel_status']),
        '依据: ' + '; '.join(report['kernel_detection']['evidence']),
        'MPTCP: {} → {}'.format(report['mptcp_before'], report['mptcp_after']),
        '缓解结果: ' + report['remediation_status'],
        '确认 MPTCP 进程: {}'.format(len(report['mptcp_processes'])),
        'Socket 检测: {}; 监听覆盖: {}; 未归属 Socket: {}'.format(
            report['socket_detection_before']['status'],
            report['socket_detection_before']['listener_coverage'],
            len(report['socket_detection_before']['unattributed_sockets'])),
    ]
    for process in report['mptcp_processes'][:10]:
        ports = ','.join('{}:{}'.format(x['address'], x['port']) for x in process['listen_addresses'])
        body.append('{} PID={} exe={} 监听={}'.format(process['name'], process['pid'],
                    process['exe'] or 'UNKNOWN', ports or '未观察到'))
    if len(report['mptcp_processes']) > 10:
        body.append('另有 {} 个进程，详见本地报告。'.format(len(report['mptcp_processes']) - 10))
    body.extend(['时间: ' + report['audit_time'], '规则: ' + report['rule_version']] + WARNINGS)
    # Plain-text div avoids interpreting process metadata as Lark markdown/mentions.
    return dict(msg_type='interactive', card=dict(
        header=dict(template=colour, title=dict(tag='plain_text', text='Linux Kernel TCP UAF 安全风险告警')),
        elements=[dict(tag='div', text=dict(tag='plain_text', content='\n'.join(body)[:20000]))]))


def signature(secret, timestamp):
    key = '{}\n{}'.format(timestamp, secret).encode('utf-8')
    return base64.b64encode(hmac.new(key, b'', hashlib.sha256).digest()).decode('ascii')


def send_alert(report, webhook, secret, attempts=3):
    host, path = webhook_target(webhook)
    result = dict(status='FAILED', attempts=0, http_status=None, business_code=None)
    for attempt in range(attempts):
        payload = alert_card(report)
        if secret:
            stamp = str(int(time.time()))
            payload.update(timestamp=stamp, sign=signature(secret, stamp))
        connection = None
        result['attempts'] = attempt + 1
        retry = True
        try:
            # Direct TLS, no proxy/env redirects and no credential in subprocess argv.
            connection = http.client.HTTPSConnection(host, timeout=5, context=ssl.create_default_context())
            connection.request('POST', path, json.dumps(payload, ensure_ascii=False).encode('utf-8'),
                               {'Content-Type': 'application/json; charset=utf-8'})
            response = connection.getresponse()
            result['http_status'] = response.status
            raw = response.read(65537)
            data = json.loads(raw) if len(raw) <= 65536 else {}
            code = data.get('code', data.get('StatusCode')) if isinstance(data, dict) else None
            result['business_code'] = code if type(code) is int else None
            if 200 <= response.status < 300 and type(code) is int and code == 0:
                result['status'] = 'SENT'
                break
            retry = response.status == 429 or response.status >= 500 or code in (9499, 99991400)
        except (OSError, ValueError, http.client.HTTPException):
            # Never log exception strings: they can contain the complete webhook.
            pass
        finally:
            if connection:
                connection.close()
        if not retry:
            break
        if attempt + 1 < attempts:
            time.sleep(1 + attempt)
    return result


def remediate(report, options, checkpoint, config_reader=mptcp_config, runner=run, uid=os.geteuid):
    if options.mode != 'disable':
        report['remediation_status'] = 'CHECK_ONLY'
        return
    if report['mptcp_before'] != 'ENABLED':
        report['remediation_status'] = ('ALREADY_DISABLED' if report['mptcp_before'] == 'DISABLED'
                                        else 'SKIPPED_' + report['mptcp_before'])
        return
    if options.dry_run:
        report['remediation_status'] = 'DRY_RUN'
        report['planned_action'] = 'sysctl -w net.mptcp.enabled=0 (current network namespace only)'
        return
    if uid() != 0:
        report['remediation_status'] = 'PERMISSION_DENIED'
        return
    if not report['mptcp_config_before']['consistent']:
        report['remediation_status'] = 'FAILED'
        report['audit_errors'].append('MPTCP sysctl/proc evidence inconsistent; mutation refused.')
        return
    # Journal original evidence BEFORE mutation. Never auto-reenable after failure:
    # that would undo a successful emergency mitigation. Operator rollback is explicit.
    report['remediation_status'] = 'IN_PROGRESS'
    report['rollback'] = dict(original_value=1, command='sysctl -w net.mptcp.enabled=1',
                              automatic=False, reason='Re-enabling restores exposure; operator decision required.')
    checkpoint()
    report['mutation_attempted'] = True
    rc, _, _ = runner(['sysctl', '-w', 'net.mptcp.enabled=0'])
    after = config_reader(report['kernel_version'])
    report['mptcp_config_after'] = after
    report['mptcp_after'] = after['state']
    report['remediation_status'] = 'SUCCESS' if rc == 0 and after['state'] == 'DISABLED' and after['consistent'] else 'FAILED'
    checkpoint()


def parser():
    p = argparse.ArgumentParser(description='CVE-2026-98432 audit; DEFAULT: temporarily disable MPTCP.',
                                epilog='Offline checks use bundled rules. Python >=3.6 required. Exit priority: 4 > 2 > 1 > 3 > 0.')
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--check-only', dest='mode', action='store_const', const='check')
    mode.add_argument('--disable-mptcp', dest='mode', action='store_const', const='disable')
    mode.add_argument('--no-remediation', dest='mode', action='store_const', const='check')
    p.set_defaults(mode='disable')
    p.add_argument('--dry-run', action='store_true', help='no sysctl mutation and no webhook POST')
    p.add_argument('--json', action='store_true', help='JSON to stdout; operational logs go to stderr')
    p.add_argument('--output', help='atomic private JSON output; parent must already exist')
    p.add_argument('--rules', default=str(BASE / 'rules/kernel-tcp-uaf.json'))
    p.add_argument('--state-dir', help='private journal/lock directory (0700); parent must exist')
    p.add_argument('--instance-id', default=os.environ.get('KERNEL_AUDIT_INSTANCE_ID'))
    web = p.add_mutually_exclusive_group()
    web.add_argument('--lark-webhook')
    web.add_argument('--lark-webhook-file')
    secret = p.add_mutually_exclusive_group()
    secret.add_argument('--lark-secret')
    secret.add_argument('--lark-secret-file')
    alerts = p.add_mutually_exclusive_group()
    alerts.add_argument('--alert-mode', choices=('risk', 'always', 'none'), default='risk')
    alerts.add_argument('--no-alert', action='store_true')
    p.add_argument('--alert-unknown', action='store_true')
    return p


def print_report(report, json_mode):
    if json_mode:
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
        return
    print('{} | {} | {}'.format(CVE, report['hostname'], report['audit_time']))
    print('OS: {} {} | Kernel: {} ({})'.format(report['os_name'], report['os_version'],
                                             report['kernel_version'], report['kernel_status']))
    for item in report['kernel_detection']['evidence']:
        print('Evidence: ' + item)
    print('IPs: ' + ', '.join(report['private_ips']))
    print('MPTCP: {} -> {} | remediation: {}'.format(report['mptcp_before'], report['mptcp_after'],
                                                   report['remediation_status']))
    print('Socket detection: {} | listener coverage: {} | confirmed processes: {}'.format(
        report['socket_detection_before']['status'], report['socket_detection_before']['listener_coverage'],
        len(report['mptcp_processes'])))
    for process in report['mptcp_processes']:
        print('  {} PID={} exe={} listen={}'.format(process['name'], process['pid'], process['exe'],
                                                  process['listen_addresses']))
    print('Alert: {} | Exit: {} | Journal: {}'.format(report['alert']['status'], report['exit_code'],
                                                    report['journal_path']))
    for warning in WARNINGS:
        print(warning)


def main(argv=None):
    options = parser().parse_args(argv)
    os.umask(0o077)
    if options.no_alert:
        options.alert_mode = 'none'
    report, journal, lock_fd, output_path = None, None, None, None
    def interrupted(_number, _frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if sys.platform != 'linux':
            raise ValueError('Linux is required; no host settings have been changed')
        rules = load_rules(options.rules)
        webhook, secret, alert_config_error = None, None, False
        if options.alert_mode != 'none':
            try:
                webhook = options.lark_webhook or (protected_secret(options.lark_webhook_file)
                           if options.lark_webhook_file else os.environ.get('LARK_WEBHOOK'))
                secret = options.lark_secret or (protected_secret(options.lark_secret_file)
                          if options.lark_secret_file else os.environ.get('LARK_SECRET'))
                if webhook:
                    webhook_target(webhook)
                if secret and not webhook:
                    raise ValueError('Lark secret requires a webhook')
            except (OSError, ValueError):
                webhook, secret, alert_config_error = None, None, True
                log('ERROR', 'Lark credential configuration is invalid; local audit will continue.')
        if options.lark_webhook or options.lark_secret:
            log('WARN', 'Command-line credentials may be visible in process listings; prefer protected files.')
        state_path = options.state_dir or ('/run/lock/kernel-tcp-uaf-audit' if os.geteuid() == 0
                                          else '/tmp/kernel-tcp-uaf-audit-{}'.format(os.geteuid()))
        state = secure_directory(Path(os.path.abspath(state_path)))
        lock_fd = os.open(str(state / 'audit.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.geteuid() or lock_info.st_mode & 0o077:
            raise ValueError('unsafe lock file')
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Root journal survives reboot; check-only journals use the private lock dir.
        journal_dir = secure_directory('/var/tmp/kernel-tcp-uaf-audit') if os.geteuid() == 0 else state
        fd, name = tempfile.mkstemp(prefix='audit-', suffix='.json', dir=str(journal_dir))
        os.close(fd)
        journal = Path(name)
        os_info = parse_os(read('/etc/os-release'))
        release = os.uname().release
        hostname = text(socket.gethostname(), 255)
        proc_version = read('/proc/version')
        version_signature = read('/proc/version_signature')
        packages = verify_running_build(kernel_package(release, os_info.get('ID')),
            os_info.get('ID'), release, version_signature, proc_version)
        kernel = classify_kernel(os_info, packages, rules)
        config = mptcp_config(release)
        before = detect_sockets(release=release, config=config)
        pro_tool = shutil.which('pro') or shutil.which('ua')
        pro_rc, pro, _ = run([pro_tool, 'status', '--format', 'json'], timeout=5) if pro_tool else (127, '', '')
        # Only booleans/service status are retained, never account/token information.
        pro_summary = dict(available=pro_rc == 0, attached=None, esm_services=[])
        if pro_rc == 0:
            try:
                pro_data = json.loads(pro)
                pro_summary['attached'] = pro_data.get('attached') is True
                pro_summary['esm_services'] = [dict(name=s.get('name'), status=s.get('status'))
                    for s in pro_data.get('services', []) if s.get('name', '').startswith('esm-')]
            except (ValueError, AttributeError, TypeError):
                pro_summary['available'] = False
        report = dict(schema_version=1, cve_id=CVE, audit_time=now(), hostname=hostname,
                      instance_id=text(options.instance_id or hostname, 255),
                      instance_id_source='explicit_configuration' if options.instance_id else 'hostname_fallback',
                      os_name=text(os_info.get('NAME', 'UNKNOWN')), os_version=text(os_info.get('VERSION_ID', 'UNKNOWN')),
                      os_release=os_info, kernel_version=release, architecture=os.uname().machine,
                      proc_version=proc_version, version_signature=version_signature,
                      kernel_packages=packages, kernel_flavour=release.rsplit('-', 1)[-1],
                      kernel_status=kernel['status'], kernel_detection=kernel, ubuntu_pro=pro_summary,
                      reboot_required=Path('/var/run/reboot-required').exists(),
                      rule_version=rules['rule_version'], rules_sha256=rules['sha256'],
                      rule_updated_at=rules['updated_at'], warnings=list(WARNINGS), audit_errors=[],
                      mptcp_before=config['state'], mptcp_after=config['state'],
                      mptcp_config_before=config, mptcp_config_after=copy.deepcopy(config),
                      socket_detection_before=before, socket_detection_after=copy.deepcopy(before),
                      socket_diff=None,
                      mptcp_processes=before['processes'], remediation_status='NOT_ATTEMPTED',
                      mutation_attempted=False, journal_path=str(journal),
                      network_namespace=os.readlink('/proc/self/ns/net'),
                      alert=dict(status='NOT_EVALUATED', attempts=0), exit_code=None)
        report['alert_configuration_valid'] = not alert_config_error
        report.update(host_addresses())
        def checkpoint():
            atomic_json(journal, report)
        checkpoint()
        # Validate output now, so path errors cannot first appear after mutation.
        if options.output:
            output = Path(os.path.abspath(options.output))
            protected_paths = [Path(os.path.abspath(p)) for p in (options.lark_webhook_file, options.lark_secret_file) if p]
            if (output in protected_paths or output == Path(os.path.abspath(options.rules)) or
                    str(output).startswith(str(BASE) + '/') or str(output).startswith(str(state) + '/') or
                    str(output).startswith(str(journal_dir) + '/')):
                raise ValueError('output must not overwrite bundle, credentials, journal or lock files')
            atomic_json(output, report)
            output_path = output  # Only validated destinations may be reused after an error.
        log('INFO', 'Original evidence saved: ' + str(journal))
        remediate(report, options, checkpoint)
        if report['mutation_attempted']:
            after = detect_sockets(release=release, config=report['mptcp_config_after'])
            report['socket_detection_after'] = after
            old = {json.dumps(s, sort_keys=True) for s in before['sockets']}
            new = {json.dumps(s, sort_keys=True) for s in after['sockets']}
            report['socket_diff'] = dict(before_count=len(old), after_count=len(new),
                                       disappeared_count=len(old - new), appeared_count=len(new - old),
                                       comparable=before['status'] == after['status'] == 'AVAILABLE')
        report['exit_code'] = exit_code(report)
        checkpoint()
        if should_alert(report, options):
            if options.dry_run:
                report['alert'] = dict(status='DRY_RUN', attempts=0)
            elif alert_config_error:
                report['alert'] = dict(status='FAILED_CONFIGURATION', attempts=0)
            elif not webhook:
                report['alert'] = dict(status='NOT_CONFIGURED', attempts=0)
            else:
                report['alert'] = send_alert(report, webhook, secret)
        else:
            report['alert'] = dict(status='SKIPPED', attempts=0)
        log('ERROR' if report['alert']['status'].startswith('FAILED') else 'INFO',
            'Alert status: ' + report['alert']['status'])
        checkpoint()
        if output_path:
            atomic_json(output_path, report)
        print_report(report, options.json)
        return report['exit_code']
    except (KeyboardInterrupt, Exception) as exc:
        # Never include raw exception messages or argv in output (secrets).
        if report is not None:
            if report['remediation_status'] == 'IN_PROGRESS':
                report['remediation_status'] = 'INTERRUPTED'
                report['mptcp_config_after'] = mptcp_config(report['kernel_version'])
                report['mptcp_after'] = report['mptcp_config_after']['state']
            report['audit_errors'].append(type(exc).__name__ + ': audit interrupted or failed; consult local evidence.')
            report['exit_code'] = exit_code(report)
            try:
                atomic_json(journal, report)
                if output_path:
                    atomic_json(output_path, report)
            except Exception:
                log('ERROR', 'Could not update report; original journal may remain available.')
            # A local write failure must not suppress already confirmed risk.
            if report['alert']['status'] == 'NOT_EVALUATED' and should_alert(report, options):
                try:
                    if options.dry_run:
                        report['alert'] = dict(status='DRY_RUN', attempts=0)
                    elif alert_config_error:
                        report['alert'] = dict(status='FAILED_CONFIGURATION', attempts=0)
                    elif webhook:
                        report['alert'] = send_alert(report, webhook, secret)
                    else:
                        report['alert'] = dict(status='NOT_CONFIGURED', attempts=0)
                    atomic_json(journal, report)
                except Exception:
                    log('ERROR', 'Could not send or persist the failure-path alert.')
            print_report(report, options.json)
        detail = str(exc) if type(exc) is ValueError else type(exc).__name__
        log('ERROR', 'Audit failed ({}); no automatic re-enable is performed.'.format(detail))
        return report['exit_code'] if report else 2
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


if __name__ == '__main__':
    sys.exit(main())
