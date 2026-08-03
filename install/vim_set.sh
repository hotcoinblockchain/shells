#!/usr/bin/env bash

set -Eeuo pipefail

VIMRC="${VIMRC:-${HOME}/.vimrc}"
readonly BEGIN_MARKER='" BEGIN HOTCOIN PASTE SETTINGS'
readonly END_MARKER='" END HOTCOIN PASTE SETTINGS'

TEMP_FILE=""

cleanup() {
    [[ -z ${TEMP_FILE} || ! -f ${TEMP_FILE} ]] || rm -f -- "${TEMP_FILE}"
}

trap cleanup EXIT

mkdir -p "$(dirname "${VIMRC}")"
TEMP_FILE=$(mktemp "${VIMRC}.tmp.XXXXXX")

if [[ -f ${VIMRC} ]]; then
    awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
        BEGIN { in_managed = 0 }
        $0 == begin { in_managed = 1; next }
        $0 == end { in_managed = 0; next }
        in_managed { next }
        # 清理旧脚本写入的散落配置，使历史配置也能收敛。
        $0 == "\" 自动粘贴处理" { next }
        $0 == "autocmd InsertEnter * set paste" { next }
        $0 == "autocmd InsertLeave * set nopaste" { next }
        { print }
    ' "${VIMRC}" > "${TEMP_FILE}"
fi

# 避免托管块前出现越来越多的空行。
awk 'NF { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }' \
    "${TEMP_FILE}" > "${TEMP_FILE}.trimmed"
mv -f "${TEMP_FILE}.trimmed" "${TEMP_FILE}"

if [[ -s ${TEMP_FILE} ]]; then
    printf '\n' >> "${TEMP_FILE}"
fi
cat >> "${TEMP_FILE}" <<EOF
${BEGIN_MARKER}
autocmd InsertEnter * set paste
autocmd InsertLeave * set nopaste
${END_MARKER}
EOF

if [[ -f ${VIMRC} ]] && cmp -s "${VIMRC}" "${TEMP_FILE}"; then
    printf '[vim_set.sh] 配置已经符合要求，无需修改：%s\n' "${VIMRC}"
    exit 0
fi

if [[ -f ${VIMRC} ]]; then
    original_mode=$(stat -c '%a' "${VIMRC}" 2>/dev/null || stat -f '%Lp' "${VIMRC}")
    chmod "${original_mode}" "${TEMP_FILE}"
else
    chmod 0644 "${TEMP_FILE}"
fi

mv -f "${TEMP_FILE}" "${VIMRC}"
TEMP_FILE=""
printf '[vim_set.sh] 配置已更新：%s\n' "${VIMRC}"
