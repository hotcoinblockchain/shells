# CVE Maintenance Scripts

Scripts in this directory are for urgent security maintenance and CVE patching.

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
