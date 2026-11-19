#!/usr/bin/env bash
# NGINX2Root HTTP/2 检查与关闭；默认关闭 HTTP/2，--check-only 只读。
# 同时移除 listen 的 http2 参数并将独立 http2 on 改为 off。
# 修改前备份，原子替换，nginx -t 成功后 reload；失败回滚配置。
# 依赖 Bash、Python 3.8+、Nginx；告警需要 curl。修改需要 root。
# 用法：sudo bash cve_2026_nginx2root_check_and_close_http2.sh --dry-run
#       sudo bash cve_2026_nginx2root_check_and_close_http2.sh --check-only
#       sudo bash cve_2026_nginx2root_check_and_close_http2.sh
# 自定义部署需用 --config、--nginx-bin、--prefix 对齐运行实例。
# 退出码：0=关闭流程成功/无命中；1=只读检查命中；2=检查/修改失败；3=告警失败。
# 只覆盖当前命名空间；reload 不保证旧 worker 立即退出，不等同安装漏洞补丁。
# 来源：https://nginx.org/en/docs/http/ngx_http_v2_module.html
set +x
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==================== 可选的内置告警配置 ====================
# 留空：不设置内置凭证。命令行 --webhook / --secret 优先。
# 示例：DEFAULT_LARK_WEBHOOK_URL='https://open.larksuite.com/open-apis/bot/v2/hook/xxx'
#       DEFAULT_LARK_SECRET='你的机器人签名密钥'
readonly DEFAULT_LARK_WEBHOOK_URL=''
readonly DEFAULT_LARK_SECRET=''
# ==========================================================
export NGINX_HTTP2_DEFAULT_WEBHOOK="$DEFAULT_LARK_WEBHOOK_URL"
export NGINX_HTTP2_DEFAULT_SECRET="$DEFAULT_LARK_SECRET"

if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] 缺少 python3（需要 Python 3.8+）。' >&2
    exit 2
fi
# 经私有管道传递参数，不再把 Webhook/secret 复制到 Python/curl 的命令行。
# 脚本自身的命令行参数仍可能被 ps/历史记录看到，可使用环境变量或凭证文件。
exec python3 - 3< <(if (($#)); then printf '%s\0' "$@"; fi) <<'PY'
import argparse
import base64
import datetime
import fnmatch
import fcntl
import glob
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import socket
import stat
import tempfile
import subprocess
import sys
import time
from urllib.parse import urlsplit

DEFAULT_WEBHOOK = os.environ.pop("NGINX_HTTP2_DEFAULT_WEBHOOK", "")
DEFAULT_SECRET = os.environ.pop("NGINX_HTTP2_DEFAULT_SECRET", "")
NGINX_NAMES = ("nginx", "openresty", "tengine")
NGINX_BINARY_PATHS = (
    "/usr/sbin/nginx", "/sbin/nginx", "/usr/local/sbin/nginx",
    "/usr/local/nginx/sbin/nginx", "/www/server/nginx/sbin/nginx",
    "/usr/local/openresty/nginx/sbin/nginx", "/usr/local/openresty/bin/openresty",
    "/opt/openresty/nginx/sbin/nginx", "/usr/local/tengine/sbin/nginx",
    "/opt/nginx/sbin/nginx",
)
NGINX_PACKAGES = {"nginx", "nginx-core", "nginx-full", "nginx-light", "nginx-extras",
                  "nginx-plus", "openresty", "tengine"}


def log(level, message):
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    print("{} [{}] {}".format(stamp, level, message), file=sys.stderr)


class AuditError(Exception):
    pass


class QuietParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse 默认错误可能回显误放位置的 secret。
        self.print_usage(sys.stderr)
        self.exit(2, "参数无效；请使用 --help 查看，检查参数名称和值是否齐全。\n")


def arguments(argv):
    p = QuietParser(prog="cve_2026_nginx2root_check_and_close_http2.sh", description="NGINX HTTP/2 检查与关闭（默认修改配置并 reload）")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--webhook", "--webhook-url", help="Lark/飞书 Webhook URL")
    g.add_argument("--webhook-file", help="仅当前用户可读的 Webhook 文件")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--secret", help="机器人签名密钥；未启用签名时可省略")
    g.add_argument("--secret-file", help="仅当前用户可读的签名密钥文件")
    p.add_argument("--config", help="主配置绝对路径，默认 /etc/nginx/nginx.conf；显式指定时强制检查")
    p.add_argument("--conf-dir", help="补充扫描目录绝对路径，默认 /etc/nginx/conf.d")
    p.add_argument("--nginx-bin", help="对应实例的 nginx 可执行文件绝对路径")
    p.add_argument("--check-only", action="store_true", help="只读检查，不修改配置、不 reload")
    p.add_argument("--prefix", help="Nginx -p 前缀绝对路径；自定义部署须与运行实例一致")
    p.add_argument("--dry-run", action="store_true", help="展示关闭计划，不修改、不 reload、不发送告警")
    p.epilog = ("逐项优先级：命令行/凭证文件 > 内置默认值 > LARK_WEBHOOK_URL、LARK_SECRET 环境变量。"
                "未配置 Webhook：不发送告警；--webhook '' 可显式关闭发送。"
                "退出码：0 关闭流程成功/未命中，1 只读或预览命中，2 检查/修改失败，3 发送失败。")
    a = p.parse_args(argv)
    a.config_explicit = a.config is not None
    a.conf_dir_explicit = a.conf_dir is not None
    a.config = a.config if a.config_explicit else "/etc/nginx/nginx.conf"
    a.conf_dir = a.conf_dir if a.conf_dir_explicit else "/etc/nginx/conf.d"
    # 凭证文件和发送依赖均延后到确实需要发送时再读取/校验。
    env_webhook = os.environ.pop("LARK_WEBHOOK_URL", "")
    env_secret = os.environ.pop("LARK_SECRET", "")
    a.webhook_default = DEFAULT_WEBHOOK or env_webhook
    a.secret_default = DEFAULT_SECRET or env_secret
    for path in (a.config, a.conf_dir, *([a.prefix] if a.prefix else [])):
        if not os.path.isabs(path):
            raise AuditError("--config 和 --conf-dir 必须为绝对路径。")
    if a.nginx_bin and not os.path.isabs(a.nginx_bin):
        raise AuditError("--nginx-bin 必须为绝对路径。")
    return a


def credential(value, filename, fallback):
    if filename is not None:
        try:
            fd = os.open(filename, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(fd, "rb") as f:
                s = os.fstat(f.fileno())
                if not stat.S_ISREG(s.st_mode) or s.st_mode & 0o077 or s.st_size > 4096:
                    raise AuditError("凭证文件必须是普通文件、权限 600/400，且不超过 4 KiB。")
                return f.read(4097).decode("utf-8").rstrip("\r\n")
        except (OSError, UnicodeError):
            raise AuditError("无法读取凭证文件。")
    return value if value is not None else fallback


def process_presence(proc_root="/proc"):
    """只按进程名称识别，不使用可能匹配到脚本自身的 ps | grep。"""
    pids, errors, denied = [], [], 0
    try:
        with os.scandir(proc_root) as entries:
            for entry in entries:
                if not entry.name.isdigit():
                    continue
                try:
                    with open(os.path.join(entry.path, "comm"), encoding="utf-8", errors="replace") as f:
                        name = f.read(256).strip()
                    if name in NGINX_NAMES or any(name.startswith(n + ":") for n in NGINX_NAMES):
                        pids.append(int(entry.name))
                except (FileNotFoundError, ProcessLookupError):
                    continue  # 扫描期间进程退出，不属于检查失败。
                except OSError:
                    denied += 1
    except OSError:
        errors.append("无法读取 /proc 进程列表，不能确认 Nginx 是否运行")
    if denied:
        errors.append("{} 个进程名称无法读取，不能完整确认运行状态（建议 root 执行）".format(denied))
    # hidepid 可以直接隐藏其他用户的 PID，此时枚举成功也不代表可见全部进程。
    if proc_root == "/proc" and os.geteuid() != 0:
        try:
            with open("/proc/mounts", encoding="utf-8") as f:
                for row in f:
                    fields = row.split()
                    if len(fields) >= 4 and fields[1:3] == ["/proc", "proc"]:
                        if any(x.startswith("hidepid=") and x != "hidepid=0" for x in fields[3].split(",")):
                            errors.append("/proc 启用了 hidepid，当前用户无法据此确认全部运行进程")
        except OSError:
            errors.append("无法确认 /proc 可见性，建议 root 执行")
    return sorted(pids), errors


def installed_packages():
    """只认实际安装的运行包；不把 nginx-common、模块或 dpkg rc 残留当作 Nginx。"""
    packages, errors = [], []
    checks = []
    if shutil.which("dpkg-query"):
        checks.append(("dpkg", ["dpkg-query", "-W", "-f=${Package}\t${db:Status-Status}\n"]))
    if shutil.which("rpm"):
        checks.append(("rpm", ["rpm", "-qa", "--qf", "%{NAME}\n"]))
    for kind, argv in checks:
        try:
            r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            if r.returncode != 0:
                errors.append("{} 软件包查询失败，无法确认安装状态".format(kind))
                continue
            for row in r.stdout.decode("utf-8", "replace").splitlines():
                fields = row.split("\t")
                name = fields[0].split(":")[0]
                if name in NGINX_PACKAGES and (kind == "rpm" or fields[1:] == ["installed"]):
                    packages.append(name)
        except (OSError, subprocess.TimeoutExpired):
            errors.append("{} 软件包查询失败或超时，无法确认安装状态".format(kind))
    return sorted(set(packages)), errors


def detect_presence(a):
    pids, errors = process_presence()
    candidates = ([a.nginx_bin] if a.nginx_bin else [])
    candidates += [p for name in NGINX_NAMES for p in [shutil.which(name)] if p]
    candidates += list(NGINX_BINARY_PATHS)
    binaries, evidence = [], []
    for path in dict.fromkeys(candidates):
        try:
            s = os.stat(path)
            evidence.append(path)
            if stat.S_ISREG(s.st_mode) and os.access(path, os.X_OK):
                binaries.append(path)
            else:
                errors.append("{}: 找到 Nginx 路径，但不是可执行普通文件".format(path))
        except (FileNotFoundError, NotADirectoryError):
            if path == a.nginx_bin or os.path.lexists(path):
                errors.append("{}: 指定的 Nginx 程序不存在或符号链接失效".format(path))
        except OSError:
            errors.append("{}: 无法读取 Nginx 程序状态".format(path))
    packages = []
    if not evidence and not pids:
        packages, package_errors = installed_packages()
        errors.extend(package_errors)
    installed = bool(evidence or packages)
    running = bool(pids)
    return {"installed": installed, "running": running, "pids": pids,
            "binaries": list(dict.fromkeys(binaries)), "packages": packages,
            "errors": list(dict.fromkeys(errors)),
            "absent": not installed and not running and not errors}


def presence_text(presence):
    installation = "已检测到安装" if presence["installed"] else "未检测到当前环境的安装证据"
    if presence["running"]:
        runtime = "已运行，PID=" + ",".join(map(str, presence["pids"]))
    elif presence["errors"]:
        runtime = "运行/安装状态检查不完整"
    else:
        runtime = "当前未发现运行进程"
    return installation + "；" + runtime


def lex(text, spans=False):
    """生成 (词, 行号, 是否分隔符)，保留引号边界并跳过注释。"""
    i, line, start = 0, 1, 1
    word, active, quote = [], False, None
    offset = 0
    while i < len(text):
        c = text[i]
        if c == "\\":
            if i + 1 == len(text):
                raise AuditError("末尾转义未完成")
            if not active:
                start, active, offset = line, True, i
            n = text[i + 1]
            word.append({"n": "\n", "r": "\r", "t": "\t"}.get(n, n))
            line += int(n == "\n")
            i += 2
            continue
        if quote:
            if c == quote:
                quote = None
            else:
                word.append(c)
            line += int(c == "\n")
            i += 1
            continue
        if c == "#" and not active:
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        if c in "\"'":
            if not active:
                start, active, offset = line, True, i
            quote = c
        elif text.startswith("${", i):
            end = text.find("}", i + 2)
            if end < 0:
                raise AuditError("变量括号未闭合")
            if not active:
                start, active, offset = line, True, i
            word.append(text[i:end + 1])
            i = end + 1
            continue
        elif c.isspace() or c in ";{}":
            if active:
                yield (("".join(word), start, False, offset, i) if spans else ("".join(word), start, False))
                word, active = [], False
            if c in ";{}":
                yield ((c, line, True, i, i + 1) if spans else (c, line, True))
            line += int(c == "\n")
        else:
            if not active:
                start, active, offset = line, True, i
            word.append(c)
        i += 1
    if quote:
        raise AuditError("引号未闭合")
    if active:
        yield (("".join(word), start, False, offset, i) if spans else ("".join(word), start, False))


class Scanner:
    def __init__(self, main):
        # nginx 的相对 include 路径以主配置所在目录为基准。
        self.base = os.path.dirname(os.path.abspath(main))
        self.files, self.errors, self.calls, self.bytes_read = set(), [], 0, 0
        self.contents = {}

    def expand(self, pattern):
        # glob.glob 会吞掉目录权限错误；逐级枚举，避免把“不可读”判作无匹配。
        if not glob.has_magic(pattern):
            return [pattern]
        paths = [os.path.sep]
        for part in Path(pattern).parts[1:]:
            matches = []
            for parent in paths:
                try:
                    if glob.has_magic(part):
                        with os.scandir(parent) as entries:
                            for entry in entries:
                                if entry.name.startswith(".") and not part.startswith("."):
                                    continue
                                if fnmatch.fnmatchcase(entry.name, part):
                                    matches.append(os.path.join(parent, entry.name))
                    else:
                        child = os.path.join(parent, part)
                        os.lstat(child)
                        matches.append(child)
                except (FileNotFoundError, NotADirectoryError):
                    continue
                except OSError:
                    self.errors.append("{}: include 通配路径无法读取".format(parent))
            if len(matches) > 4096:
                self.errors.append("{}: include 通配匹配超过 4096 项".format(pattern))
                return []
            paths = matches
        return sorted(paths)

    def read(self, filename, stack=()):
        path = os.path.abspath(filename)
        real = os.path.realpath(path)
        self.calls += 1
        if self.calls > 4096 or len(stack) >= 32 or real in stack:
            self.errors.append("{}: include 循环或数量/深度超过检查上限".format(path))
            return []
        self.files.add(real)
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(fd, "rb") as f:
                s = os.fstat(f.fileno())
                if not stat.S_ISREG(s.st_mode) or s.st_size > 4 * 1024 * 1024:
                    raise AuditError("不是普通文件或文件超过 4 MiB")
                raw = f.read(4 * 1024 * 1024 + 1)
            self.bytes_read += len(raw)
            if len(raw) > 4 * 1024 * 1024 or self.bytes_read > 32 * 1024 * 1024:
                raise AuditError("文件大小或总读取量超过检查上限（单文件 4 MiB、总计 32 MiB）")
            if real in self.contents and self.contents[real] != raw:
                raise AuditError("扫描期间配置发生变化")
            self.contents[real] = raw
            data = raw.decode("utf-8", "strict")
            tokens = iter(lex(data))

            def block(nested=False):
                nodes, words, first = [], [], 1
                for token, lineno, symbol in tokens:
                    if not symbol:
                        if not words:
                            first = lineno
                        words.append(token)
                        continue
                    if token == "}":
                        if words or not nested:
                            raise AuditError("第 {} 行：括号或分号异常".format(lineno))
                        return nodes
                    if not words:
                        raise AuditError("第 {} 行：空指令/块".format(lineno))
                    children = block(True) if token == "{" else None
                    node = {"args": words, "path": path, "line": first, "children": children}
                    if words[0] == "include" and children is None:
                        if len(words) != 2 or "$" in words[1]:
                            raise AuditError("第 {} 行：无法处理 include 路径".format(first))
                        target = words[1] if os.path.isabs(words[1]) else os.path.join(self.base, words[1])
                        targets = self.expand(target)
                        for item in targets:
                            nodes.extend(self.read(item, stack + (real,)))
                    else:
                        nodes.append(node)
                    words = []
                if words or nested:
                    raise AuditError("文件末尾缺少分号或右括号")
                return nodes

            return block()
        except (OSError, UnicodeError, AuditError, RecursionError) as e:
            if isinstance(e, FileNotFoundError):
                detail = "配置文件不存在；自定义部署请用 --config 指定主配置，容器实例请在容器内检查"
            elif isinstance(e, PermissionError):
                detail = "无读取权限，建议以 root 执行"
            else:
                detail = str(e) if isinstance(e, AuditError) else type(e).__name__
            self.errors.append("{}: {}".format(path, detail))
            return []


def detect(nodes, errors, orphan=False):
    found = []
    scope = "目录补充项，未确认被主配置引用" if orphan else "主配置 include 树"

    def add(n, reason):
        found.append((n["path"], n["line"], " ".join(n["args"]) + ";", scope + "；" + reason))

    def setting(items):
        flags = [n for n in items if n["args"][0] == "http2" and n["children"] is None]
        if len(flags) > 1:
            errors.append("{}:{}: 同一上下文存在重复 http2 指令".format(flags[0]["path"], flags[0]["line"]))
        for n in flags:
            if n["args"] not in (["http2", "on"], ["http2", "off"]):
                errors.append("{}:{}: http2 指令参数无效".format(n["path"], n["line"]))
        return flags[-1] if flags else None

    def server(items, parent=None):
        own = setting(items)
        flag = own if own is not None else parent
        if flag and flag["args"] == ["http2", "on"]:
            add(flag, "server 开启 HTTP/2" if own else "server 继承 http 层 HTTP/2 开启项")
        for n in items:
            if n["children"] is None and n["args"][0] == "listen" and "http2" in n["args"][2:]:
                add(n, "listen 开启 HTTP/2（不受 http2 off 抵消）")

    def http(items):
        parent = setting(items)
        for n in items:
            if n["args"] == ["server"] and n["children"] is not None:
                server(n["children"], parent)

    for n in nodes:
        if n["args"] == ["http"] and n["children"] is not None:
            http(n["children"])
        elif orphan and n["args"] == ["server"] and n["children"] is not None:
            server(n["children"])
    if orphan:
        # 单独的片段可能原本用于 http/server 上下文，作为未确认加载的线索。
        server([n for n in nodes if n["children"] is None])
    return found


def disable_http2(text):
    """精确修改指令 token，其他字节（注释、引号、换行）保持不变。"""
    edits, words = [], []
    for token in lex(text, spans=True):
        value, line, symbol, begin, end = token
        if not symbol:
            words.append(token)
            continue
        if value == ";" and words:
            args = [w[0] for w in words]
            if args[0] == "listen":
                # args[1] 是监听地址；仅移除后面的独立 http2 选项。
                edits.extend((w[3], w[4], "") for w in words[2:] if w[0] == "http2")
            elif args[0] == "http2":
                if args not in (["http2", "on"], ["http2", "off"]):
                    raise AuditError("第 {} 行 http2 指令无效，拒绝修改".format(line))
                if args[1] == "on":
                    edits.append((words[1][3], words[1][4], "off"))
        words = []
    for begin, end, value in reversed(edits):
        text = text[:begin] + value + text[end:]
    return text, len(edits)


def trusted_directory(path):
    """修改/备份目录必须由 root 控制；允许 root 管理的 sites-enabled 链接。"""
    current = os.path.realpath(path)
    while True:
        st = os.stat(current)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            raise AuditError("目录必须由 root 拥有且不能由组或其他用户写入：" + current)
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent


def trusted_config(path):
    trusted_directory(os.path.dirname(path))
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022 or st.st_nlink != 1:
        raise AuditError("配置必须是 root 控制、无硬链接的普通文件：" + path)


def nginx_command(a, binary, *options):
    argv = [binary, "-c", a.config]
    if a.prefix:
        argv.extend(["-p", a.prefix])
    return argv + list(options)


def run_nginx(argv):
    # nginx -t 可能输出配置相关信息；不将原始输出写入飞书或日志。
    try:
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise AuditError("Nginx 命令失败或超时，请在机器本地手动检查")
    if result.returncode:
        raise AuditError("Nginx 校验/重载失败（退出码 {}），请在本机检查错误日志".format(result.returncode))


def atomic_config(path, content, metadata_source):
    """在目标目录临时写入并替换，保留权限/属主及 copy2 支持的扩展属性。"""
    fd, temporary = tempfile.mkstemp(prefix=".hotcoin-http2-", dir=os.path.dirname(path))
    os.close(fd)
    try:
        shutil.copy2(metadata_source, temporary)
        st = os.stat(metadata_source)
        os.chown(temporary, st.st_uid, st.st_gid)
        os.chmod(temporary, stat.S_IMODE(st.st_mode))
        with open(temporary, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def master_pid(a, binary, nodes):
    compiled = command([binary, "-V"])
    options = {}
    try:
        for item in shlex.split(compiled.split("configure arguments:", 1)[-1]):
            if item.startswith("--") and "=" in item:
                key, value = item.split("=", 1)
                options[key] = value
    except ValueError:
        raise AuditError("无法解析 Nginx 编译参数，请核对运行实例")
    prefix = a.prefix or options.get("--prefix", "/usr/local/nginx/")
    pid_nodes = [n for n in nodes if n["args"][0] == "pid" and n["children"] is None]
    if len(pid_nodes) > 1 or any(len(n["args"]) != 2 for n in pid_nodes):
        raise AuditError("无法唯一确定 Nginx pid 配置")
    pid_path = pid_nodes[0]["args"][1] if pid_nodes else options.get("--pid-path", "logs/nginx.pid")
    if not os.path.isabs(pid_path):
        pid_path = os.path.join(prefix, pid_path)
    try:
        pid = int(Path(pid_path).read_text().strip())
        if pid <= 1:
            raise ValueError()
        # 自动修改只支持 Linux；验证 pid 确实属于选定 Nginx，避免误发信号。
        if not os.path.samefile("/proc/{}/exe".format(pid), binary):
            raise ValueError()
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        raise AuditError("无法确认 pid 文件对应的运行 Nginx，请检查 --config/--nginx-bin/--prefix")


def worker_generation(pid):
    try:
        children = Path("/proc/{0}/task/{0}/children".format(pid)).read_text().split()
        workers = set()
        for child in children:
            try:
                title = Path("/proc/{}/cmdline".format(child)).read_bytes().split(b"\0", 1)[0]
                if title.startswith(b"nginx: worker process") and b"shutting down" not in title:
                    fields = Path("/proc/{}/stat".format(child)).read_text().rsplit(")", 1)[1].split()
                    workers.add((int(child), fields[19]))  # PID + starttime 防止 PID 重用。
            except FileNotFoundError:
                continue
        return workers
    except (OSError, ValueError, IndexError):
        raise AuditError("无法确认 Nginx worker 代际，请检查 /proc 权限")


def wait_for_reload(pid, old_workers):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            raise AuditError("重载后 Nginx master 已退出")
        if worker_generation(pid) - old_workers:
            return
        time.sleep(0.1)
    raise AuditError("10 秒内未观察到新 Nginx worker，无法确认 reload 生效")


def close_http2(a, scanner, presence, nodes):
    if scanner.errors:
        raise AuditError("检查不完整，拒绝自动修改；请先处理检查错误")
    changes = {}
    for path, original in scanner.contents.items():
        updated, count = disable_http2(original.decode("utf-8"))
        if count:
            changes[path] = (original, updated.encode("utf-8"))
            log("PLAN", "{}：修改 {} 处 HTTP/2 开启项".format(path, count))
    a.planned_changes = len(changes)
    if not changes or a.check_only or a.dry_run:
        return False
    if os.geteuid() != 0:
        raise AuditError("关闭 HTTP/2 需要 root；只读使用 --check-only 或 --dry-run")
    binaries = list(dict.fromkeys(os.path.realpath(p) for p in presence["binaries"]))
    binary = a.nginx_bin or (binaries[0] if len(binaries) == 1 else None)
    if not binary:
        raise AuditError("无法唯一确定 Nginx 程序，请用 --nginx-bin 指定对应运行实例")
    for path in scanner.contents:
        trusted_config(path)
    # 校验原配置，避免在已有故障的实例上叠加修改。
    run_nginx(nginx_command(a, binary, "-t"))
    pid = master_pid(a, binary, nodes)
    old_workers = worker_generation(pid)
    if not old_workers:
        raise AuditError("未发现运行中的 Nginx worker，拒绝自动重载")
    for path, content in scanner.contents.items():
        if Path(path).read_bytes() != content:
            raise AuditError("配置在扫描后发生变化，拒绝覆盖：" + path)
    backup_root = "/var/backups/nginx-http2-disable"
    trusted_directory("/var")
    os.makedirs("/var/backups", mode=0o755, exist_ok=True)
    trusted_directory("/var/backups")
    if os.path.lexists(backup_root) and os.path.islink(backup_root):
        raise AuditError("备份目录不能是符号链接")
    os.makedirs(backup_root, mode=0o700, exist_ok=True)
    trusted_directory(backup_root)
    backup = tempfile.mkdtemp(prefix="run-", dir=backup_root)
    backups, applied = {}, []
    # 在任何配置修改之前完成全部备份。
    for index, path in enumerate(sorted(changes)):
        target = os.path.join(backup, str(index) + ".conf")
        shutil.copy2(path, target)
        os.chmod(target, 0o600)
        backups[path] = target
    Path(backup, "manifest.json").write_text(json.dumps(backups, ensure_ascii=False, indent=2))
    log("INFO", "原配置备份：" + backup)
    reload_attempted = False
    try:
        for path, (original, updated) in changes.items():
            if Path(path).read_bytes() != original:
                raise AuditError("配置发生变化，拒绝覆盖：" + path)
            applied.append(path)  # 在替换前登记回滚状态。
            atomic_config(path, updated, path)
        # 完整配置落盘后原生校验；通过之前不向运行实例发送 reload。
        run_nginx(nginx_command(a, binary, "-t"))
        for path in scanner.contents:
            _, remaining = disable_http2(Path(path).read_text())
            if remaining:
                raise AuditError("修改后仍存在 HTTP/2 开启项：" + path)
        reload_attempted = True
        run_nginx(nginx_command(a, binary, "-s", "reload"))
        wait_for_reload(pid, old_workers)
        if master_pid(a, binary, nodes) != pid:
            raise AuditError("重载后 master PID 改变，请检查运行实例")
    except BaseException:
        # SIGINT/SIGTERM 同样走回滚，回滚期间避免再次中断。
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        failed = []
        try:
            for path in reversed(applied):
                try:
                    # 用原配置的元数据恢复，备份自身的权限固定为 0600。
                    atomic_config(path, changes[path][0], path)
                except (OSError, AuditError):
                    failed.append(path)
            if reload_attempted and not failed:
                try:
                    run_nginx(nginx_command(a, binary, "-t"))
                    run_nginx(nginx_command(a, binary, "-s", "reload"))
                except AuditError:
                    failed.append("恢复配置后的 reload")
            log("ERROR", "关闭失败，已尝试恢复原配置；备份保留：" + backup)
            if failed:
                log("ERROR", "需人工恢复：" + ", ".join(failed))
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        raise
    log("OK", "已移除 listen http2、关闭独立 http2 指令，配置校验通过且已观察到 reload 后的新 worker")
    log("WARN", "平滑重载不保证旧 worker/已有 HTTP/2 连接立即退出，请核实运行实例及连接")
    return True


def command(argv):
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        return (r.stdout + r.stderr).decode("utf-8", "replace") if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def internal_ips():
    ranges = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7")]
    items, primary = [], ""
    if shutil.which("ip"):
        try:
            routes = json.loads(command(["ip", "-j", "route", "show", "default"]) or "[]")
            primary = next((r.get("dev", "") for r in routes if r.get("dev")), "")
            for dev in json.loads(command(["ip", "-j", "address", "show"]) or "[]"):
                if dev.get("ifname") != "lo":
                    items.extend((dev.get("ifname", "?"), a.get("local", "")) for a in dev.get("addr_info", []))
        except (ValueError, TypeError, AttributeError):
            items = []
    if not items and shutil.which("hostname"):
        items = [("host", a) for a in command(["hostname", "-I"]).split()]
    result = []
    for interface, value in sorted(items, key=lambda x: (x[0] != primary, x[0], x[1])):
        try:
            ip = ipaddress.ip_address(value.split("%")[0])
        except ValueError:
            continue
        if any(ip.version == net.version and ip in net for net in ranges):
            entry = "{}={}".format(interface, ip)
            if entry not in result:
                result.append(entry)
    return ", ".join(result) if result else "未识别到私网地址（请核对网卡及 ip 命令）"


def version_info(binary):
    binary = binary or shutil.which("nginx")
    if not binary:
        binary = next((p for p in ("/usr/sbin/nginx", "/usr/local/nginx/sbin/nginx") if os.access(p, os.X_OK)), None)
    raw = command([binary, "-v"]) if binary else ""
    m = re.search(r"nginx/(\d+)\.(\d+)\.(\d+)", raw)
    if not m:
        return "无法读取标准 NGINX 版本；分支/容器实例需单独核实"
    v = tuple(map(int, m.groups()))
    fixed = (v[:2] == (1, 30) and v[2] >= 7) or v >= (1, 31, 9)
    vendor = any(x in raw.lower() for x in ("openresty", "tengine", "nginx-plus"))
    if vendor:
        status = "供应商分支，需核实供应商补丁"
    elif fixed:
        status = "磁盘二进制版本已进入上游修复范围，仍须核对运行进程/旧 worker"
    elif v >= (1, 9, 5):
        status = "上游受影响范围；发行版是否回补补丁需核实"
    else:
        status = "早于上游 HTTP/2 引入版本，与命中配置/实际运行实例需交叉核实"
    return "nginx/{}（{}）".format(".".join(m.groups()), status)


def make_payload(text, secret, timestamp=None):
    # 留出 JSON 字段和签名余量，控制在官方 20 KB 限制内。
    raw = text.encode("utf-8")
    if len(raw) > 14000:
        text = raw[:14000].decode("utf-8", "ignore") + "\n……内容已截断，请查看机器本地输出。"
    body = {"msg_type": "text", "content": {"text": text}}
    if secret:
        ts = str(int(time.time()) if timestamp is None else timestamp)
        body["timestamp"] = ts
        key = (ts + "\n" + secret).encode("utf-8")
        body["sign"] = base64.b64encode(hmac.new(key, b"", hashlib.sha256).digest()).decode("ascii")
    encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 19000:
        # 极端文件名/转义字符使 JSON 膨胀时继续缩减正文。
        return make_payload(text[:len(text) // 2] + "\n……内容已截断。", secret, timestamp)
    return encoded


def response_ok(data):
    if not isinstance(data, dict):
        return False
    code = data.get("code", data.get("StatusCode"))
    return type(code) is int and code == 0


def send(webhook, secret, text):
    def quote(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'

    payload = make_payload(text, secret).decode("utf-8")
    config = "url = {}\nheader = {}\ndata-binary = {}\n".format(
        quote(webhook), quote("Content-Type: application/json; charset=utf-8"), quote(payload))
    try:
        r = subprocess.run(["curl", "-q", "--silent", "--show-error", "--request", "POST",
                            "--connect-timeout", "5", "--max-time", "15", "--proto", "=https",
                            "--write-out", "\n%{http_code}", "--config", "-"],
                           input=config.encode("utf-8"), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=20)
        if r.returncode != 0:
            log("ERROR", "Lark 请求失败，curl 退出码 {}（详情已隐藏以保护凭证）。".format(r.returncode))
            return False
        body, status = r.stdout.rsplit(b"\n", 1)
        if not 200 <= int(status) < 300:
            log("ERROR", "Lark 返回 HTTP {}。".format(int(status)))
            return False
        data = json.loads(body)
        if not response_ok(data):
            code = data.get("code", data.get("StatusCode")) if isinstance(data, dict) else None
            code = code if type(code) is int else "缺失/无效"
            log("ERROR", "Lark 业务状态失败，code={}；检查签名、时间、关键词及出口 IP 白名单。".format(code))
            return False
        return True
    except (OSError, subprocess.TimeoutExpired, ValueError):
        log("ERROR", "Lark 发送超时或响应格式异常；不会自动重试，以免重复发送。")
        return False


def notify(a, text):
    """True=已发送/按配置跳过；False=需要发送但失败。"""
    if a.dry_run:
        log("INFO", "dry-run：仅输出本地结果，不读取发送凭证、不发送消息。")
        return True
    try:
        webhook = credential(a.webhook, a.webhook_file, a.webhook_default).strip()
        if not webhook:
            log("INFO", "未配置 Webhook：仅输出本地结果，不发送 Lark 告警。")
            return True
        secret = credential(a.secret, a.secret_file, a.secret_default)
        try:
            u = urlsplit(webhook)
            valid = (u.scheme == "https" and u.hostname in ("open.larksuite.com", "open.feishu.cn")
                     and u.port in (None, 443) and not u.username and not u.password
                     and re.fullmatch(r"/open-apis/bot/v2/hook/[A-Za-z0-9_-]+", u.path)
                     and not u.query and not u.fragment
                     and not any(ord(c) < 33 or ord(c) == 127 for c in webhook))
        except ValueError:
            valid = False
        if not valid:
            raise AuditError("Webhook 必须是有效的官方 Lark/飞书 HTTPS 机器人地址。")
        if not shutil.which("curl"):
            raise AuditError("需要发送告警，但未安装 curl。")
        if not send(webhook, secret, text):
            return False
        log("INFO", "Lark 告警发送成功。")
        return True
    except AuditError as e:
        log("ERROR", "告警未发送：" + str(e))
        return False


def audit(a):
    presence = detect_presence(a)
    forced = a.config_explicit or a.conf_dir_explicit or a.nginx_bin is not None
    if presence["absent"] and not forced:
        log("OK", "未发现本检查范围内的 Nginx 安装或运行实例；本次 HTTP/2 检查无风险，跳过配置扫描，不告警。")
        return 0
    log("INFO", "Nginx 状态：" + presence_text(presence))
    if presence["absent"] and forced:
        log("INFO", "已显式指定检查对象，继续检查指定的磁盘配置。")
    scanner = Scanner(a.config)
    scanner.errors.extend(presence["errors"])
    nodes = scanner.read(a.config)
    found = detect(nodes, scanner.errors)
    referenced = set(scanner.files)
    try:
        directory = Path(a.conf_dir)
        if directory.exists():
            entries = sorted(directory.iterdir())
        else:
            entries = []
            if a.conf_dir_explicit:
                scanner.errors.append("{}: 显式指定的配置目录不存在".format(a.conf_dir))
        for entry in entries:
            if entry.name.startswith(".") or entry.is_dir():
                continue
            if os.path.realpath(str(entry)) not in referenced:
                found.extend(detect(scanner.read(str(entry)), scanner.errors, orphan=True))
    except OSError:
        scanner.errors.append("{}: 无法枚举目录".format(a.conf_dir))
    found = list(dict.fromkeys(found))
    scanner.errors = list(dict.fromkeys(scanner.errors))
    changed = False
    if not a.check_only:
        try:
            changed = close_http2(a, scanner, presence, nodes)
        except (AuditError, OSError) as error:
            remediation_error = str(error) if isinstance(error, AuditError) else type(error).__name__
            scanner.errors.append("关闭 HTTP/2 失败：" + remediation_error)
            log("ERROR", scanner.errors[-1])
    if not found and not scanner.errors and not changed and not getattr(a, "planned_changes", 0):
        log("OK", "已检查 {} 个文件；当前磁盘配置未发现 HTTP/2 开启项。".format(len(scanner.files)))
        log("INFO", "此结果不代表运行中的旧配置已关闭 HTTP/2，也不检查其他 nginx2root 入口。")
        return 0
    title = "NGINX HTTP/2 已执行关闭" if changed else ("NGINX HTTP/2 风险配置告警" if found or getattr(a, "planned_changes", 0) else "NGINX HTTP/2 检查不完整告警")
    lines = ["【{}】".format(title), "hostname: " + socket.gethostname(),
             "内网 IP: " + internal_ips(), "时间: " + datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
             "Nginx 状态: " + presence_text(presence),
             "版本参考: " + version_info(a.nginx_bin or next(iter(presence["binaries"]), None)),
             "范围: {}、{}/*，以及解析到的 include".format(a.config, a.conf_dir),
             "检查文件: {}；命中项: {}；检查错误: {}".format(len(scanner.files), len(found), len(scanner.errors)),
             "相关漏洞: CVE-2026-123007 / CVE-2026-123633（具体条件不同）",
             "判定: 静态配置风险/线索；未验证当前 worker、可达性、漏洞可利用性或供应商回补补丁。"]
    if found:
        lines.append("\n命中依据:")
        for path, lineno, directive, scope in found:
            lines.extend(["{}:{} [{}]".format(path, lineno, scope), "  " + directive])
    if scanner.errors:
        lines.append("\n检查不完整，不能据此认定安全:")
        lines.extend(scanner.errors)
    lines.extend(["\n建议: 核实运行实例及供应商补丁；上游修复版本为 1.30.7 / 1.31.9。",
                  "临时缓解: 关闭相关 http2 on，并移除 listen 中的 http2；验证配置、reload 后确认旧 worker 已退出。",
                  ("执行结果: 已备份并关闭配置中的 HTTP/2，通过 nginx -t 并观察到新 worker；需确认旧 worker 退出。" if changed
                   else "执行结果: 仅检查/预览，或关闭未完成；请查看检查错误。")])
    text = "\n".join(lines)
    print(text, flush=True)
    if not notify(a, text):
        return 3
    return 2 if scanner.errors else (0 if changed else 1)


def main(argv):
    a = arguments(argv)
    if a.check_only or a.dry_run:
        return audit(a)
    if os.geteuid() != 0:
        raise AuditError("默认关闭 HTTP/2 需要 root；只读使用 --check-only 或 --dry-run")
    # 所有实例共用稳定锁，避免相交 include 树的脚本并发修改。
    lock_root = "/run/hotcoin-nginx-http2-disable"
    trusted_directory("/run")
    if os.path.islink(lock_root):
        raise AuditError("锁目录不能是符号链接")
    os.makedirs(lock_root, mode=0o700, exist_ok=True)
    trusted_directory(lock_root)
    fd = os.open(os.path.join(lock_root, "hotcoin-nginx-http2-disable.lock"),
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "a+") as lock:
        st = os.fstat(lock.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_nlink != 1:
            raise AuditError("关闭 HTTP/2 的锁文件不安全")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise AuditError("已有 HTTP/2 关闭任务正在执行")
        return audit(a)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        if sys.version_info < (3, 8):
            raise AuditError("需要 Python 3.8 或更高版本。")
        with os.fdopen(3, "rb") as stream:
            raw_args = stream.read()
        cli_args = [os.fsdecode(v) for v in raw_args[:-1].split(b"\0")] if raw_args else []
        sys.exit(main(cli_args))
    except AuditError as e:
        log("ERROR", str(e))
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        # 不打印 traceback/外部原始输出，防止泄露凭证或完整配置。
        log("ERROR", "检查异常：{}；不能认定安全。".format(type(e).__name__))
        sys.exit(2)
PY
