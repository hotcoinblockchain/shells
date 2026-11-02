# CVE Maintenance Scripts

Scripts in this directory are for urgent security maintenance and CVE patching.

## Linux Kernel TCP UAF / MPTCP

For Alibaba Cloud Cloud Assistant batch execution, paste
[`run-kernel-tcp-uaf-audit.sh`](run-kernel-tcp-uaf-audit.sh) into a Bash command.
Set `LARK_WEBHOOK` in that console copy (never commit a real webhook).
The bootstrap downloads three files from a pinned commit into a private `/tmp`
directory, verifies their embedded SHA256 hashes, runs the configured audit and
cleans up downloaded code and temporary credentials. Audit reports are retained.
Default mode temporarily disables MPTCP; choose `MODE='--check-only'` for inventory.
Python 3.6+, curl and sha256sum must already be available. The audit exit code is
preserved, so Cloud Assistant may mark a successful risk detection (exit 1) as failed.

[`linux-kernel-tcp-uaf-audit.sh`](linux-kernel-tcp-uaf-audit.sh) audits
CVE-2026-98432 using bundled offline vendor rules. Its default mode temporarily
disables MPTCP in the current network namespace. Start with a read-only check:

```bash
bash cve/linux-kernel-tcp-uaf-audit.sh --check-only --no-alert
```

Deploy the adjacent `lib/` and `rules/` directories together with the launcher.
See [the usage, verified sources, download verification and test limitations](kernel-tcp-uaf-README.md).

## Nginx Security Patch Update

Update currently installed nginx packages to the latest security patched version
available from the system's configured repositories:

```bash
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/update_nginx_security_patch.sh | bash -s
```

Preview package changes without installing:

```bash
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/update_nginx_security_patch.sh | bash -s -- --dry-run
```

Skip service reload after the package update:

```bash
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/update_nginx_security_patch.sh | bash -s -- --skip-reload
```

Notes:

- Supports Ubuntu/Debian and CentOS/RHEL/Rocky/AlmaLinux style systems.
- Does not add or switch nginx repositories.
- Refuses to install nginx if it is not already installed.
- Backs up `/etc/nginx` to `/var/backups/nginx-cve-update/` before changing packages.
