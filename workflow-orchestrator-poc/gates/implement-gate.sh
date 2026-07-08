#!/usr/bin/env bash
# =============================================================================
# gates/implement-gate.sh — implement 阶段门禁（对接真实 guazi-flow 契约）
#
# 对齐 guazi-flow-implement 完成门禁：
#   - current_stage = implement
#   - index.md 存在且 frontmatter 合法
#   - （可选）候选 diff 在 write_set 内 —— 需 git，PoC 里做软校验
#
# 退出码：0 = 通过，非0 = 回退上一阶段
# =============================================================================
set -euo pipefail

TASK_ID="${1:-}"
WORKROOT="${WORKROOT:-$(pwd)}"
TASK_DIR="${WORKROOT}/docs/guazi-flow/${TASK_ID}"
INDEX_FILE="${TASK_DIR}/index.md"

# 引入共享库（兼容顶层 + flow: 嵌套两种 frontmatter 格式）
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${GATE_LIB_DIR}/_lib.sh"

echo "  [门禁:implement] 校验 implement 阶段产出物（任务: ${TASK_ID}）..."

# ─── 1. index.md 必须存在 ────────────────────────────────
if [[ ! -f "$INDEX_FILE" ]]; then
  echo "  ❌ 未找到任务文档: $INDEX_FILE"
  exit 1
fi
echo "  ✅ index.md 存在"

# ─── 2. current_stage 必须是 implement（兼容顶层/嵌套）────
FRONTMATTER=$(fm_extract "$INDEX_FILE")
CURRENT_STAGE=$(fm_value "$FRONTMATTER" current_stage)

case "$CURRENT_STAGE" in
  implement)
    echo "  ✅ current_stage = implement"
    ;;
  blocked)
    echo "  ❌ current_stage = blocked（任务被阻塞）"
    exit 1
    ;;
  *)
    echo "  ❌ current_stage = '${CURRENT_STAGE}'，预期 implement"
    echo "     implement 完成门禁要求 current_stage=implement"
    exit 1
    ;;
esac

# ─── 3. 候选 diff 在 write_set 内（软校验，需 git）────────
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
  CHANGED=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  echo "  ℹ️  检测到 ${CHANGED} 个变更文件（write_set 越界校验需接入真实脚本）"
else
  echo "  ⚙️  非 git 环境，跳过 write_set 校验"
fi

echo "  ✅ [门禁:implement] 校验通过"
exit 0