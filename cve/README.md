# CVE 应急巡检与补丁维护

本目录用于漏洞巡检、临时缓解和软件包升级。以下说明以仓库中的脚本实现为准；
脚本内的版本阈值是静态规则，不能代替厂商最新安全公告，也不能证明机器未遭入侵。

## 脚本索引

| 脚本 | 用途 | 默认行为 |
| --- | --- | --- |
| [cve_2026_98432_kernel-tcp-uaf-audit.sh](cve_2026_98432_kernel-tcp-uaf-audit.sh) | 内核 TCP UAF / MPTCP 巡检、JSON 报告及可选飞书告警 | 保存证据后临时关闭当前网络命名空间的 MPTCP；依赖相邻 `lib/`、`rules/` |
| [run-kernel-tcp-uaf-audit.sh](run-kernel-tcp-uaf-audit.sh) | 阿里云云助手批量巡检入口 | 下载并校验固定 commit 的巡检组件，再按内置配置执行 |
| [cve_2026_98432_kernel_upgrade.sh](cve_2026_98432_kernel_upgrade.sh) | 检查运行内核并通过现有仓库升级内核包 | **执行升级，不自动重启** |
| [cve_2026_nginx2root_check_and_close_http2.sh](cve_2026_nginx2root_check_and_close_http2.sh) | NGINX HTTP/2 检查与关闭、可选飞书/Lark 告警 | **默认关闭 HTTP/2，校验后 reload；先用 `--dry-run` 预览** |
| [update_nginx_security_patch.sh](update_nginx_security_patch.sh) | 升级已安装的 Nginx 软件包 | 从现有仓库升级，校验配置并尝试重载/重启服务 |

## curl 下载约定

示例在 Bash 中运行，采用“下载成功后再执行”。先阅读下载内容，再执行升级或缓解。
`main` 指向最新分支；需要可复现部署时，将 URL 中的 `main` 换成已审核的 40 位 commit。
文件发布到 GitHub 后对应 URL 才可用。升级操作使用 root；下例以 `sudo bash` 演示，root 用户可省略 `sudo`。

## 1. 内核 TCP UAF / MPTCP 巡检

入口需要 Bash、Python 3.6+，不会自动安装依赖。必须同时下载入口、Python 实现和离线规则，
不能仅下载入口或直接 `curl | bash`。

下载完整运行组件，并先执行只读巡检、不发送告警：

```bash
(
  set -Eeuo pipefail
  umask 077
  bundle=$(mktemp -d /tmp/kernel-tcp-uaf-download.XXXXXX)
  trap 'rm -rf -- "$bundle"' EXIT
  mkdir -p "$bundle/lib" "$bundle/rules"
  base='https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve'
  for file in cve_2026_98432_kernel-tcp-uaf-audit.sh lib/kernel_tcp_uaf_audit.py rules/kernel-tcp-uaf.json; do
    curl -fSL --retry 2 --connect-timeout 10 --max-time 120 \
      "$base/$file" -o "$bundle/$file"
  done
  bash -n "$bundle/cve_2026_98432_kernel-tcp-uaf-audit.sh"
  sudo bash "$bundle/cve_2026_98432_kernel-tcp-uaf-audit.sh" --check-only --no-alert
)
```

以上为分支下载示例，不提供独立摘要校验。固定版本的可信摘要校验流程见
[完整巡检说明](kernel-tcp-uaf-README.md#固定-github-commit-与-sha256-下载)。

已有完整仓库时，可在仓库根目录执行：

```bash
# 只读巡检；仍生成本地审计记录
sudo bash cve/cve_2026_98432_kernel-tcp-uaf-audit.sh --check-only --no-alert

# 预览缓解计划，输出 JSON，不修改 sysctl、不发送告警
sudo bash cve/cve_2026_98432_kernel-tcp-uaf-audit.sh --dry-run --json --no-alert

# 临时关闭当前网络命名空间的 MPTCP，并按风险策略告警
sudo bash cve/cve_2026_98432_kernel-tcp-uaf-audit.sh --disable-mptcp \
  --lark-webhook-file /etc/security/lark-webhook \
  --lark-secret-file /etc/security/lark-secret
```

- `--check-only`：只读巡检；`--no-alert`：禁用告警；`--help`：完整参数。
- 临时缓解不写 `/etc/sysctl.d/`，不升级内核，不重启业务；不等同修复普通 TCP 路径的漏洞。
- 仅覆盖当前网络命名空间，不自动进入容器。
- 退出码：`0` 明确安全且检测完整；`1` 发现风险（缓解成功仍保留）；`2` 检查错误；`3` 无法确认；`4` 缓解失败。
- 发行版规则、报告位置、凭证权限及恢复方式见[完整说明](kernel-tcp-uaf-README.md)。

### 阿里云云助手批量入口

```bash
curl -fSL --retry 2 \
  https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/run-kernel-tcp-uaf-audit.sh \
  -o run-kernel-tcp-uaf-audit.sh
```

阅读下载文件，修改顶部配置，再将完整内容粘贴至云助手 Bash 命令：

| 配置 | 默认值与说明 |
| --- | --- |
| `MODE` | `--disable-mptcp`；只读盘点改为 `--check-only` |
| `ALERT_MODE` | `risk`；无需告警时设为 `none` |
| `LARK_WEBHOOK` / `LARK_SECRET` | 在云助手副本中填写，不提交真实凭证；`risk` 模式要求填写 Webhook |
| `ALERT_UNKNOWN` | `true`，将不确定结果也纳入告警 |
| `DRY_RUN` | `false`；设为 `true` 时不执行缓解或发送告警 |

依赖 Python 3.6+、curl、sha256sum。该入口仍绑定历史 commit，下载的是历史文件名
`linux-kernel-tcp-uaf-audit.sh`，并验证内嵌 SHA256；不会自动切换到当前改名后的脚本。
不要仅修改文件名或 commit 而保留旧摘要。巡检退出码会原样返回，云助手可能将风险退出码 `1` 标为任务失败。

## 2. 内核检查与升级

先下载并检查当前内核及仓库信息：

```bash
curl -fSL --retry 2 \
  https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/cve_2026_98432_kernel_upgrade.sh \
  -o cve_2026_98432_kernel_upgrade.sh && \
  bash cve_2026_98432_kernel_upgrade.sh --check
```

维护窗口执行升级：

```bash
sudo bash cve_2026_98432_kernel_upgrade.sh --upgrade

# 仅在允许机器重启时使用：升级完成后等待 5 秒并重启
sudo bash cve_2026_98432_kernel_upgrade.sh --upgrade --reboot
```

| 参数 / 环境变量 | 说明 |
| --- | --- |
| `--check` / `MODE=check` | 查询运行内核、包及仓库信息，不安装包；可能访问软件源或刷新查询缓存 |
| `--upgrade` / `MODE=upgrade` | 默认模式，刷新软件包索引并升级映射的内核包，需要 root |
| `--reboot` / `REBOOT=yes` | 仅升级模式下请求自动重启；默认 `REBOOT=no` |
| `--help` | 显示帮助 |

- Ubuntu 仅为脚本中明确映射的发行版、generic/HWE 分支选择元包；未知内核类型拒绝自动选包。
- Alibaba Cloud Linux 3/4 仅对匹配的内核分支设置静态阈值，不能据此宣称所有阿里云内核均受支持。
- RHEL/CentOS/Rocky/AlmaLinux/Oracle Linux/Fedora 映射到 `kernel`，优先 dnf、其次 yum；
  Debian 当前映射到 `linux-image-amd64`，不能用于其他架构的自动选包。
- 无匹配修复门槛时状态为 `UNKNOWN`；能更新包不代表已确认修复。检查模式退出 `0` 也不等于安全。
- 不添加或切换软件源，不删除旧内核；包升级没有自动回滚。默认不重启，重启后须核对 `uname -r`、启动项及厂商公告。

## 3. NGINX HTTP/2 检查、关闭与告警

**默认会关闭 HTTP/2 并平滑重载 Nginx，需要 root。**
修改前备份，按文件原子替换，失败时回滚配置。
依赖 Linux、Bash、Python 3.8+、运行中的 Nginx；发送告警时还需要 curl。扫描默认主配置 `/etc/nginx/nginx.conf`、
解析到的 include 及 `/etc/nginx/conf.d` 中的补充文件，查找 `http2 on` 和 `listen ... http2`。

下载并预览关闭计划（不修改、不重载、不发送告警）：

```bash
curl -fSL --retry 2 \
  https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/cve_2026_nginx2root_check_and_close_http2.sh \
  -o cve_2026_nginx2root_check_and_close_http2.sh && \
  sudo bash cve_2026_nginx2root_check_and_close_http2.sh --dry-run
```

确认后关闭 HTTP/2；可选使用已有凭证文件发送执行结果告警
（文件仅存原始值、权限 `0600`，由执行用户读取）：

```bash
# 不配置 Webhook 时仍会关闭 HTTP/2，只是不发送告警
sudo bash cve_2026_nginx2root_check_and_close_http2.sh

# 关闭并按结果发送告警
sudo bash cve_2026_nginx2root_check_and_close_http2.sh \
  --webhook-file /etc/security/lark-webhook \
  --secret-file /etc/security/lark-secret
```

自定义安装路径：

```bash
sudo bash cve_2026_nginx2root_check_and_close_http2.sh --dry-run \
  --config /usr/local/nginx/conf/nginx.conf \
  --conf-dir /usr/local/nginx/conf/conf.d \
  --nginx-bin /usr/local/nginx/sbin/nginx
```

| 参数 | 说明 |
| --- | --- |
| 无模式参数 | 关闭 HTTP/2，备份、校验后 reload |
| `--check-only` | 只读检查，不修改、不 reload；配置 Webhook 时可告警 |
| `--dry-run` | 预览关闭计划，不修改、不 reload、不读取发送凭证或发送告警 |
| `--config` / `--conf-dir` | 主配置与补充目录的绝对路径；显式指定时强制检查 |
| `--nginx-bin` | 对应运行实例的 Nginx 可执行文件绝对路径，用于校验与 reload |
| `--prefix` | 对应运行实例的 `nginx -p` 绝对路径；自定义部署需与原启动参数一致 |
| `--webhook-file` / `--secret-file` | Webhook 与可选签名密钥文件；推荐使用 |
| `--webhook`（或 `--webhook-url`）/ `--secret` | 直接传值，可能进入历史记录或进程列表 |
| `--help` | 显示帮助 |

凭证逐项优先级：命令行或文件 > 脚本内默认值 > `LARK_WEBHOOK_URL` / `LARK_SECRET` 环境变量。
未配置 Webhook 时不发送告警；`--webhook ''` 可显式禁用发送，不影响关闭操作。

命中 HTTP/2 配置就报告线索，版本号仅供参考；不验证可利用性、厂商回补补丁或当前 worker 的实际配置。
无 Nginx 安装/运行证据时默认跳过；不自动进入 Docker/Kubernetes 容器。
关闭时同时处理两类指令：

```nginx
# 修改前
listen 443 ssl http2 default_server;
http2 on;

# 修改后（ssl、default_server 等参数保持原样）
listen 443 ssl  default_server;
http2 off;
```

已有 `http2 off;` 保持不变，注释不修改；支持 IPv6、多行指令、引号和 include。
扫描涉及的补充目录配置也纳入关闭计划；检查不完整则拒绝自动修改。
通过真实目标文件修改 `sites-enabled` 符号链接指向的配置，不替换链接本身。
配置文件及所在目录须由 root 控制，拒绝可被其他用户写入或带硬链接的文件。

执行流程：获取全局锁，检查原配置和运行 master，备份至
`/var/backups/nginx-http2-disable/run-*`（保留 `manifest.json` 路径映射），
逐文件原子替换，再执行完整的 `nginx -t`，通过后才执行 `nginx -s reload`。
校验或重载失败会恢复本次修改的文件；重载尝试过时会尽力重新加载原配置。
不会 restart，不自动安装软件。重复执行无变更时不新增备份、不 reload。
源码/发行版 Nginx 均通过对应二进制操作，不依赖 APT/DNF/YUM；需有可识别的 Linux `/proc`、pid 文件及 worker。
修改与回滚受 INT/TERM 保护；SIGKILL/断电及外部配置工具并发写入仍需人工核查。

自定义部署请明确指定 `--config`、`--nginx-bin`、必要时 `--prefix`，确保对应同一运行实例。
原生校验在配置原子替换后、reload 前执行；多个文件不构成单次文件系统事务，期间勿由外部工具 reload。
reload 后核对 master，并等待最多 10 秒确认新 worker 出现；超时视为失败并回滚。
平滑重载不保证旧 worker 或已有 HTTP/2 连接立即退出，需另行确认。

退出码：`0` 关闭流程成功、未发现 Nginx 或完整检查无变更；`1` 只读/预览命中；
`2` 检查不完整或修改失败；`3` 告警发送失败（配置关闭可能已完成）。

## 4. Nginx 软件包安全更新

下载后预览当前仓库中的更新：

```bash
curl -fSL --retry 2 \
  https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/update_nginx_security_patch.sh \
  -o update_nginx_security_patch.sh && \
  sudo bash update_nginx_security_patch.sh --dry-run
```

确认后升级：

```bash
sudo bash update_nginx_security_patch.sh

# 升级后由运维另行处理服务重载
sudo bash update_nginx_security_patch.sh --skip-reload
```

- 支持 Ubuntu/Debian 与 CentOS/RHEL/Rocky/AlmaLinux 风格系统，使用现有 APT/DNF/YUM 仓库。
- 拒绝为未安装 Nginx 的机器首次安装；不添加或切换仓库，也不维护源码/容器内的 Nginx。
- 修改包前将 `/etc/nginx` 备份到 `/var/backups/nginx-cve-update/`；配置备份不等于软件包自动降级回滚。
- `--dry-run` 预览包更新；`--skip-reload` 跳过脚本显式执行的重载/重启，不保证包安装脚本不会操作服务。
- 仓库候选版本是否修复目标 CVE 需对照厂商公告，升级完成不等于目标漏洞已确认修复。
