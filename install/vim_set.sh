#!/bin/bash

VIMRC="$HOME/.vimrc"
AUTOCMD_PASTE='autocmd InsertEnter * set paste'
AUTOCMD_NOPASTE='autocmd InsertLeave * set nopaste'

# 如果不存在 .vimrc 文件，创建
if [ ! -f "$VIMRC" ]; then
    echo "创建 ~/.vimrc 并添加粘贴自动处理配置..."
    {
        echo "\" 自动粘贴处理"
        echo "$AUTOCMD_PASTE"
        echo "$AUTOCMD_NOPASTE"
    } >> "$VIMRC"
    echo "已创建 ~/.vimrc 并添加配置。"
else
    # 检查是否已经配置过
    if grep -q "$AUTOCMD_PASTE" "$VIMRC"; then
        echo "已存在配置，无需修改。"
    else
        echo "添加自动粘贴处理配置到 ~/.vimrc..."
        {
            echo ""
            echo "\" 自动粘贴处理"
            echo "$AUTOCMD_PASTE"
            echo "$AUTOCMD_NOPASTE"
        } >> "$VIMRC"
        echo "已添加自动粘贴配置。"
    fi
fi
