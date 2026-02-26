#!/usr/bin/env bash
set -euo pipefail

OUT="/coins/firewalld.rules.sh"
ZONE="public"

if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "[ERROR] firewall-cmd not installed"
    exit 1
fi

echo "[INFO] Exporting firewalld rules (zone=$ZONE)..."

PORTS=$(firewall-cmd --permanent --zone=$ZONE --list-ports || true)
SERVICES=$(firewall-cmd --permanent --zone=$ZONE --list-services || true)
RICH=$(firewall-cmd --permanent --zone=$ZONE --list-rich-rules || true)

cat > "$OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ZONE="$ZONE"

echo "[INFO] Restoring firewalld rules..."

# 确保 firewalld 运行
systemctl enable --now firewalld >/dev/null 2>&1 || true

EOF

# 导出 ports
for p in $PORTS; do
    echo "firewall-cmd --permanent --zone=\$ZONE --add-port=$p" >> "$OUT"
done

# 导出 services
for s in $SERVICES; do
    echo "firewall-cmd --permanent --zone=\$ZONE --add-service=$s" >> "$OUT"
done

# 导出 rich rules（必须逐行）
if [[ -n "${RICH// /}" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        SAFE=$(printf "%s" "$line" | sed "s/'/'\\\\''/g")
        echo "firewall-cmd --permanent --zone=\$ZONE --add-rich-rule='$SAFE'" >> "$OUT"
    done <<< "$RICH"
fi

cat >> "$OUT" <<EOF

firewall-cmd --reload
echo "[OK] firewalld rules restored."
EOF

chmod +x "$OUT"

echo "[OK] Rules exported to: $OUT"
