# Linux Kernel TCP UAF 巡检与 MPTCP 临时缓解

入口：`linux-kernel-tcp-uaf-audit.sh`。目标漏洞为 **CVE-2026-98432**。
默认行为等同 `--disable-mptcp`：先采集和保存证据，再临时关闭**当前网络命名空间**的 MPTCP。
首次部署建议使用 `--check-only --no-alert` 核对结果。

## 文件与依赖

```text
cve/
  linux-kernel-tcp-uaf-audit.sh
  lib/kernel_tcp_uaf_audit.py
  rules/kernel-tcp-uaf.json
  SHA256SUMS
  kernel-tcp-uaf-README.md
  tests/test-*-detection.sh
  tests/test-lark-alert.sh
  tests/test_*.py
  examples/report.json
  examples/lark-alert.json
```

必须一起部署入口、`lib/`、`rules/`；只下载 Bash 文件无法完成巡检。
需要 Bash、Python **3.6+**（仅标准库）。Python 负责结构化 JSON、签名、受限权限文件、
`fcntl.flock` 和 MPTCP netlink uAPI，避免依赖 jq、第三方 Python 包或不可信二进制。
辅助程序源码随包提供，无需编译。入口使用 `python3 -I -B` 隔离 Python 导入环境并禁止生成字节码。

`dpkg-query`/`dpkg` 用于 Debian/Ubuntu 软件包判定；`rpm` 用于 RHEL 系清单采集；
`sysctl` 用于双重读取及缓解；`ip` 用于地址；`ss` 用于能力采集。
命令缺失时保留能力不足信息，不能推断安全。不会自动安装软件包。
可选 `go version -m /proc/PID/exe` 只读取已确认 MPTCP 进程的编译信息，不执行目标程序，
并设置 `GOTOOLCHAIN=local`、`GOENV=off`、`GOWORK=off` 防止自动下载工具链。

## 漏洞资料与离线规则

本次规则快照为 **2026-11-02.1**，更新时间按 Asia/Singapore 记录。
IPv4 TCP 握手中 IP options 的对象释放与并发读取之间存在竞态。上游修复使用 RCU 延迟释放。
普通 TCP 路径也在影响范围内；没有 MPTCP 进程不代表内核安全。
依据：[Linux CNA 记录](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/98xxx/CVE-2026-98432.json)、
[Ubuntu 公告](https://ubuntu.com/security/CVE-2026-98432)。

规则记录上游引入提交 `079096f103faca2dd87342cca6f23d4b34da8871`（4.4）和
[修复提交](https://git.kernel.org/linus/e3f33b0a1d89d738e2b913dab519226eaf76e15b)
`e3f33b0a1d89d738e2b913dab519226eaf76e15b`。
CNA 列出的修复版本为 5.10.272、5.15.223、6.1.190、6.6.159、6.12.113、6.18.56、7.2.10 和 7.3。
这些数字只作参考，不用于直接判定发行版内核，因为发行版可能回移补丁。

规则有独立 schema、版本、来源 URL、来源内容 SHA256、可信级别和发行版条目：

- Ubuntu 18.04/20.04/22.04/24.04：从
  [Canonical OpenVEX v14](https://raw.githubusercontent.com/canonical/ubuntu-security-notices/main/vex/cve/2026/CVE-2026-98432.json)
  提取 229 个明确标为 `affected` 的源包/发行版/渠道/精确版本条目，覆盖 Generic、HWE、AWS、Azure、OEM 等。
  当前快照没有据此声明任何 Ubuntu 修复包。未列出的旧版、新版、ignored、退役分支均为 `UNKNOWN`。
- Debian 12 bookworm：`linux` 修复源包为 `6.1.190-1`；`linux-6.12` 为 `6.12.113-1~deb12u1`。
  Debian 13 trixie：`linux` 为 `6.12.113-1`。使用 `dpkg --compare-versions`，严格限定发行版、源包和内核系列。
  依据：[Debian Security Tracker](https://security-tracker.debian.org/tracker/CVE-2026-98432)。
- Rocky、AlmaLinux、RHEL、Amazon Linux：采集内核包和执行当前命名空间缓解，
  当前不复用其他发行版的修复阈值，内核判定为 `UNKNOWN`。
  [Red Hat 官方公告](https://access.redhat.com/security/cve/cve-2026-98432) 作为人工核查入口。
- 其他发行版：`UNSUPPORTED`；自编译、第三方或无法证明运行构建与软件包一致的内核：`UNKNOWN`。

运行时完全离线加载规则，不刷新网络数据。使用 `--rules /绝对路径/固定规则.json` 指定审阅后的规则。
更新规则时必须重新核验官方资料、记录内容摘要、提升 `rule_version`、更新 `updated_at`，
并重新生成 `SHA256SUMS`。不要把网页中的 “work in progress” 当作已发布修复。
规则是审计时点的证据快照，不会自动覆盖之后发布的版本。

## 运行内核判定

采集 `/etc/os-release`、`uname`、`/proc/version`、`/proc/version_signature`、当前发行版内核包和 Pro 状态。
只查询 `linux-image-$(uname -r)`、unsigned image、对应 modules 包；不会选择“最新已安装内核”。
Ubuntu 签名包映射到对应源包；Debian 签名包优先解析 `Built-Using` 中的 linux 源版本。
随后核对 Ubuntu `version_signature` 的完整构建号或 Debian `/proc/version` 的源版本。
相同 `uname -r` 的内核在磁盘上被替换但尚未重启时，也不能仅凭 dpkg 判为 `FIXED`。

| 状态 | 含义 |
| --- | --- |
| VULNERABLE | 运行构建和厂商规则明确匹配受影响版本 |
| FIXED | 运行构建匹配且达到该发行版、源包、系列的官方修复版本 |
| NOT_AFFECTED | 规则对精确运行版本明确标为不受影响；当前快照未包含此类发行版条目 |
| UNKNOWN | 包、运行构建、厂商证据不足或不一致 |
| UNSUPPORTED | 没有支持该发行版的判定流程 |

包数据库与 `/proc` 用于运维证据核对，不构成对已遭入侵主机的密码学启动证明。
Ubuntu 18/20 的 ESM 条目单独保留渠道；`pro` 或 `ua` 可用时仅记录 attached 和 esm 服务状态，
不记录账户、订阅凭证。Pro 已订阅不代表补丁已安装或正在运行。
Livepatch 不被自动视为该 CVE 的修复证明；需要人工根据厂商信息核查。

## MPTCP 与进程识别

同时读取 `/proc/sys/net/mptcp/enabled` 和 `sysctl -n net.mptcp.enabled`。
值 1/0 分别为 `ENABLED`/`DISABLED`；明确的内核配置不支持时为 `NOT_SUPPORTED`；其余为 `UNKNOWN`。
两个读取结果冲突时拒绝修改。

首先采集 `ss -V`、尝试 `ss -M -H -a -n -p -e -O`。部分 `ss` 即使 netlink 失败仍退出 0，
因此它的空输出与退出状态不能证明没有 MPTCP。随后使用标准库直接发送
`NETLINK_SOCK_DIAG`、`INET_DIAG_REQ_PROTOCOL=262` 的 IPv4/IPv6 全状态 dump，
校验内核发送者、序列号、分帧、错误、截断、dump 中断和最终 `NLMSG_DONE`。
诊断请求可能由内核自动加载其诊断模块；脚本不调用 modprobe，不创建 MPTCP 测试监听端口。

老内核的 MPTCP diagnostic 可能仅列出已建立连接而不列监听。
正常完成 dump 且运行版本达到 **6.1 诊断功能基线**时，标记监听覆盖为 `SUPPORTED_BASELINE`；
这是诊断能力判断，不参与 CVE 版本判断。依据为
[Linux v6.1 的监听枚举源码](https://raw.githubusercontent.com/torvalds/linux/v6.1/net/mptcp/mptcp_diag.c)，
对比 [v5.10 源码](https://raw.githubusercontent.com/torvalds/linux/v5.10/net/mptcp/mptcp_diag.c)。
旧内核只有实际观察到监听时才标记 `OBSERVED`；否则返回 `DETECTION_UNAVAILABLE`，不能宣称“无 MPTCP 进程”。
自定义内核如果删改了诊断实现，应人工核查该功能基线的适用性。

通过**已确认 MPTCP Socket 的 inode**与 `/proc/PID/fd` 关联进程，读取 PID、PPID、名称、exe、用户、
监听端口、cgroup 服务和可可靠解析的容器 ID；不调用 Docker daemon。
读取前后核对进程 starttime，随后再次 dump 并核对 Socket inode/cookie，避免 PID/inode 重用导致误报。
退出、权限不足、无主 Socket 和验证失败均保留能力不足证据。
不会按 Go 版本、进程名或普通 TCP 监听把进程认定为 MPTCP。

**所有 argv，包括 argv[0]，一律省略**；JSON 只记录脱敏占位符和参数数量。
飞书卡片不包含命令行。Go 版本仅为辅助信息，识别失败不能推断安全。
空的 `mptcp_processes` 只有结合 `socket_detection_before.status`、`listener_coverage`、
`unattributed_sockets` 和 `issues` 才有意义。

检测仅覆盖调用者当前网络命名空间。Docker/容器的独立 netns 不被自动进入或修改。
请在每个需要覆盖的命名空间按授权分别执行；宿主机的一次成功不代表所有容器完成缓解。
`SUCCESS` 仅表示当前 netns 的 sysctl 已验证为 0，不能保证现有 Socket 消失。

## 使用与参数

在仓库根目录执行：

```bash
bash cve/linux-kernel-tcp-uaf-audit.sh --check-only --no-alert

sudo bash cve/linux-kernel-tcp-uaf-audit.sh \
  --disable-mptcp \
  --lark-webhook-file /etc/security/lark-webhook \
  --lark-secret-file /etc/security/lark-secret \
  --output /var/log/kernel-tcp-uaf-audit.json

sudo bash cve/linux-kernel-tcp-uaf-audit.sh --dry-run --json --no-alert
```

| 参数 | 行为 |
| --- | --- |
| 无模式参数 / `--disable-mptcp` | 默认，保存原状态后执行临时关闭 |
| `--check-only` | 只读巡检系统配置，仍写安全审计文件，按告警策略可发送卡片 |
| `--no-remediation` | 禁止修改配置，与 check-only 等效 |
| `--dry-run` | 展示 sysctl 计划，不执行配置修改或 Webhook POST；仍记录审计文件 |
| `--json` | stdout 只输出 JSON，运行日志送 stderr |
| `--output FILE` | 额外原子写入 0600 JSON 文件；父目录须已存在且可信 |
| `--rules FILE` | 固定的离线规则文件 |
| `--state-dir DIR` | 指定 0700 锁目录，父目录须存在；并发调用须使用同一目录 |
| `--instance-id ID` | 明确配置实例 ID，也支持 `KERNEL_AUDIT_INSTANCE_ID` |
| `--lark-webhook` / `--lark-webhook-file` | 机器人 URL 或受限权限文件；优先文件 |
| `--lark-secret` / `--lark-secret-file` | 可选签名密钥或受限权限文件；优先文件 |
| `--alert-mode risk\|always\|none` | 默认 risk，分别为风险告警、每次报告、禁用告警 |
| `--no-alert` | 禁用告警，不读取或校验凭证 |
| `--alert-unknown` | 将 UNKNOWN/UNSUPPORTED、Socket 检测不完整也纳入告警 |
| `--help` | 参数帮助 |

模式参数互斥；`--no-alert` 与 `--alert-mode` 互斥；同种凭证的直接值和文件参数互斥。
`--dry-run` 可以与任意模式结合。非 root 允许巡检；需要缓解已启用的 MPTCP 时返回 4，
不会自动 sudo。MPTCP 原本已关闭时跳过 sysctl 写入，重复执行不会改动业务配置。

IP 使用 `ip -j -4 addr show`，过滤 loopback、Docker bridge、veth、bridge 类型及无效地址。
`private_ips` 表示宿主机接口候选地址，**不保证一定是私有地址**；保留云 VPC、自定义网段及全球地址，
避免只按 RFC1918 过滤。只在默认路由设备及地址选择明确时输出主 IP；多默认路由或多地址不明确时不猜测。
未指定实例 ID 时使用 hostname，并记录 `hostname_fallback`，不访问任何云元数据接口。

## 飞书配置与可靠性

支持环境变量 `LARK_WEBHOOK`、`LARK_SECRET`。优先使用 root 或当前用户拥有的普通文件，
权限必须 0600 或更严，拒绝 symlink、FIFO、其他用户可读文件和多行凭证。
文件可通过已有密钥管理工具写入，再执行：

```bash
sudo chmod 600 /etc/security/lark-webhook /etc/security/lark-secret
sudo chown root:root /etc/security/lark-webhook /etc/security/lark-secret
```

不要在 shell history、命令行、日志中粘贴实际 Webhook 或密钥。
文件参数优先于环境变量；直接参数同样优先，但会提示其可能暴露于进程列表。
只允许 `https://open.feishu.cn/open-apis/bot/v2/hook/...` 与 Lark 的
`https://open.larksuite.com/open-apis/bot/v2/hook/...`，拒绝额外 query/fragment、其他主机或协议。
直接 TLS 连接，不采用代理环境变量、不跟随重定向、不关闭证书验证。

签名遵循[飞书官方指南](https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot)：
以 `timestamp + "\n" + secret` 为 HMAC-SHA256 key，对空消息求摘要，再 Base64，
将 timestamp/sign 放入请求顶层。测试含独立 OpenSSL 计算的固定向量。

风险条件为 **kernel_status=VULNERABLE OR 至少一个已确认的 MPTCP 进程**。
`--alert-unknown` 额外覆盖不确定结果。只有已确认内核受影响时使用红卡；
未知、MPTCP 风险需人工确认时橙卡；always 模式证据明确安全时绿卡。
卡片最多列出 10 个进程，其余汇总计数，不发送 cmdline、Webhook、签名密钥或订阅账户信息。

每次请求设置 5 秒 socket 超时，最多 3 次请求；网络、HTTP 429/5xx 和特定暂时性业务错误有限重试。
同时校验 HTTP 状态与 `code`/`StatusCode`；缺失业务码、重定向、签名等业务失败不算成功。
不记录可能包含凭证的服务端正文和异常详情。
`alert.status` 区分 `SENT`、`FAILED`、`FAILED_CONFIGURATION`、`NOT_CONFIGURED`、`SKIPPED`、`DRY_RUN`。
告警失败不改变本地风险退出码；需要单独监控 JSON 的告警状态。
核心离线巡检不需要外网；只有显式配置并满足告警条件时才访问飞书。

## 状态、文件、锁与回滚

唯一系统配置写入为 `sysctl -w net.mptcp.enabled=0`，不写 `/etc/sysctl.conf` 或 `/etc/sysctl.d/`。
不升级内核、不修改防火墙、不关闭业务端口、不重启 Geth/Docker/SSH/任何业务服务。
关闭 MPTCP 可能改变应用后续建立连接的行为，应根据进程清单安排人工验证。

root 默认锁目录 `/run/lock/kernel-tcp-uaf-audit`；普通用户为 `/tmp/kernel-tcp-uaf-audit-UID`，目录权限 0700。
使用 `fcntl.flock(LOCK_EX|LOCK_NB)`，锁冲突立即退出 2；不删除锁文件，避免不同 inode 绕过互斥。
root 的每次审计原子保存到 `/var/tmp/kernel-tcp-uaf-audit/audit-*.json`，普通用户保存到其锁目录。
文件均 0600，原状态在 sysctl 写入前 fsync；保存失败就不会开始修改。
每次生成独立审计记录便于追溯，应通过现有日志保留策略定期归档，脚本不自动删历史记录。
`--output` 用同目录临时文件、fsync、rename 更新，拒绝不可信目录、symlink 和覆盖自身运行文件/凭证/锁。

收到 INT/TERM 或后续失败时尽力保存原状态和当前读取结果。
不会自动重新开启 MPTCP，以免撤销已生效的应急缓解。SIGKILL/断电无法处理，
但写入前的原状态与 `IN_PROGRESS` 日志仍可用于恢复审计。
关闭前为 1 且运维确认可以恢复时，人工执行：

```bash
sudo sysctl -w net.mptcp.enabled=1
```

只恢复当前命名空间的开关，不能重建已经消失的 Socket；重新开启也会恢复相应暴露面。
原值为 0 时无需恢复。系统重启后临时值可能按既有系统配置恢复。

退出码优先级固定为 **4 > 2 > 1 > 3 > 0**：

| 退出码 | 含义 |
| --- | --- |
| 0 | 检查完成，内核有明确安全证据，且 Socket 检测完整、未观察到风险 |
| 1 | 内核明确受影响，或确认存在 MPTCP 进程；成功缓解后仍保留该风险结果 |
| 2 | 参数、规则、审计文件、锁或检查流程失败 |
| 3 | 未确认风险，但无法完成安全判定，包括不支持或 Socket 检测不足 |
| 4 | 请求的缓解失败、权限不足或缓解过程被中断 |

## 固定 GitHub Commit 与 SHA256 下载

禁止 `curl | bash`，不要未经校验执行最新分支。
从可信发布渠道取得 **40 位 commit** 与该版本 **SHA256SUMS 自身的预期 SHA256**，替换下列占位值。
清单覆盖全部三个运行文件，核验入口本身不够。

```bash
set -Eeuo pipefail
umask 077
COMMIT='替换为40位Git提交哈希'
EXPECTED_MANIFEST_SHA256='替换为64位SHA256SUMS文件的可信摘要'
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]]
[[ $EXPECTED_MANIFEST_SHA256 =~ ^[0-9a-f]{64}$ ]]
bundle=$(mktemp -d /tmp/kernel-tcp-uaf-download.XXXXXX)
trap 'if [[ -n ${bundle:-} && $bundle == /tmp/kernel-tcp-uaf-download.* ]]; then rm -rf -- "$bundle"; fi' EXIT
mkdir -m 700 "$bundle/lib" "$bundle/rules"
base="https://raw.githubusercontent.com/hotcoinblockchain/shells/$COMMIT/cve"
for file in linux-kernel-tcp-uaf-audit.sh lib/kernel_tcp_uaf_audit.py rules/kernel-tcp-uaf.json SHA256SUMS; do
  curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 5 --max-time 30 --retry 2 \
    -o "$bundle/$file" "$base/$file"
done
(
  cd "$bundle"
  printf '%s  SHA256SUMS\n' "$EXPECTED_MANIFEST_SHA256" | sha256sum --check --strict -
  sha256sum --check --strict SHA256SUMS
  bash -n linux-kernel-tcp-uaf-audit.sh
)
sudo bash "$bundle/linux-kernel-tcp-uaf-audit.sh" \
  --disable-mptcp --lark-webhook-file /etc/security/lark-webhook
```

校验失败则停止，不执行脚本。预期摘要不能临时从同一未验证下载地址取得。
也可在可信 checkout 中按固定 commit 安装完整目录后本地执行。

## 验证与限制

```bash
bash -n cve/linux-kernel-tcp-uaf-audit.sh
bash cve/tests/test-kernel-detection.sh
bash cve/tests/test-mptcp-detection.sh
bash cve/tests/test-lark-alert.sh
python3 -B -m unittest discover -s cve/tests -p 'test_*.py' -v
shellcheck cve/linux-kernel-tcp-uaf-audit.sh cve/tests/test-*.sh
```

开发环境实际验证：macOS、Python 3.11；51 个离线单元/模拟流程测试通过，Bash 语法检查通过。
覆盖已修复/受影响/未知内核、Ubuntu 18/20 ESM、HWE/云/OEM、同名包替换未重启、
MPTCP 开/关/监听进程、缓解成功/失败/非 root/重复运行、旧 ss/空输出、
容器 cgroup 与桥接过滤、敏感参数脱敏、PID/inode 重用、写前日志失败、
netlink 错误/中断/完成消息、并发锁冲突，以及签名/非签名飞书、发送失败、参数冲突。
没有向真实飞书机器人发送测试消息。

**ShellCheck 当前不可用，未执行，不能视为通过。**
当前机器没有可用 Docker daemon，未进行 Linux 实机的 sysctl、netlink、发行版包数据库和容器 netns 集成验证。
Ubuntu 18/20/22/24、Debian 的支持是基于官方规则和模拟测试，尚未完成这些版本的实机验收。
投产前在目标发行版测试机先执行 check-only，再在授权的维护窗口验证缓解和残留 Socket。
