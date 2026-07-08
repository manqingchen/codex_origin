#!/usr/bin/env bash
# =============================================================================
# install.sh — 把 gflow 软链接到 /usr/local/bin
#
# 用法：
#   bash install.sh            # 安装（软链接到 /usr/local/bin/gflow）
#   bash install.sh uninstall  # 卸载
#
# 安装后可在任意业务仓库里运行：
#   cd /path/to/业务仓库
#   gflow <任务ID> codex
# =============================================================================
set -euo pipefail

# 本脚本所在目录 = PoC 目录（install.sh 不会被软链接，直接 dirname 即可）
POC_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${POC_DIR}/guazi-workflow.sh"
LINK_NAME="gflow"
BIN_DIR="/usr/local/bin"
LINK_PATH="${BIN_DIR}/${LINK_NAME}"

ACTION="${1:-install}"

# ── 卸载 ──────────────────────────────────────────────────────────
if [[ "$ACTION" == "uninstall" ]]; then
  if [[ -L "$LINK_PATH" ]]; then
    if rm -f "$LINK_PATH" 2>/dev/null; then
      echo "✅ 已移除软链接: $LINK_PATH"
    else
      echo "⚠️  权限不足，请手动执行: sudo rm -f $LINK_PATH"
      exit 1
    fi
  else
    echo "ℹ️  $LINK_PATH 不存在，无需卸载"
  fi
  exit 0
fi

# ── 安装 ──────────────────────────────────────────────────────────
echo "═══ 安装 gflow ═══"
echo "  主脚本: $MAIN_SCRIPT"
echo "  软链接: $LINK_PATH"

# 前置检查
if [[ ! -f "$MAIN_SCRIPT" ]]; then
  echo "❌ 找不到主脚本: $MAIN_SCRIPT"
  exit 1
fi
chmod +x "$MAIN_SCRIPT" "$POC_DIR"/gates/*.sh "$POC_DIR"/run-stage.sh 2>/dev/null || true

# /usr/local/bin 可能不存在（新版 mac / Apple Silicon 有时用 /opt/homebrew/bin）
if [[ ! -d "$BIN_DIR" ]]; then
  echo "⚠️  $BIN_DIR 不存在。"
  echo "   可改用其它在 PATH 里的目录，例如："
  echo "   ln -sf \"$MAIN_SCRIPT\" ~/bin/${LINK_NAME}"
  exit 1
fi

# 建软链接（-f 覆盖旧的）
if ln -sf "$MAIN_SCRIPT" "$LINK_PATH" 2>/dev/null; then
  echo "✅ 软链接创建成功"
else
  echo "⚠️  权限不足，尝试 sudo..."
  if sudo ln -sf "$MAIN_SCRIPT" "$LINK_PATH"; then
    echo "✅ 软链接创建成功（sudo）"
  else
    echo "❌ 创建失败。请手动执行："
    echo "   sudo ln -sf \"$MAIN_SCRIPT\" \"$LINK_PATH\""
    exit 1
  fi
fi

# 验证
echo ""
echo "═══ 验证 ═══"
if command -v "$LINK_NAME" >/dev/null 2>&1; then
  echo "✅ gflow 已在 PATH 中: $(command -v $LINK_NAME)"
else
  echo "⚠️  gflow 不在 PATH 中，请确认 $BIN_DIR 在你的 \$PATH 里"
fi

echo ""
echo "🎉 安装完成！用法："
echo "   cd /path/to/业务仓库"
echo "   gflow <任务ID> codex        # 或 claude / auto"
echo ""
echo "   卸载: bash $POC_DIR/install.sh uninstall"