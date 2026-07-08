#!/usr/bin/env bash
# =============================================================================
# gates/plan-gate.sh — plan 阶段门禁（对接真实 guazi-flow 契约）
#
# 校验内容（完全对齐 guazi-flow-plan 的完成门禁 + core 机器字段规范）：
#   1. index.md 存在
#   2. index.md frontmatter 包含 version / current_stage / profile
#   3. current_stage = plan（不能是 blocked 或空）
#   4. plan-readall.json 存在（核心约束）
#   5. 可选：调用 plan-readall-validator.py（真实门禁脚本）
#
# 退出码：0 = 通过，非0 = 不通过 → 编排器强制回退上一阶段
# =============================================================================
set -euo pipefail

# 引入共享库（兼容顶层 + flow: 嵌套两种 frontmatter 格式）
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${GATE_LIB_DIR}/_lib.sh"

TASK_ID="${1:-}"
WORKROOT="${WORKROOT:-$(pwd)}"
TASK_DIR="${WORKROOT}/docs/guazi-flow/${TASK_ID}"
INDEX_FILE="${TASK_DIR}/index.md"
PLAN_READALL="${TASK_DIR}/plan-readall.json"
CORE_SKILL_DIR="plugins/guazi-flow/skills/guazi-flow-core"

echo "  [门禁:plan] 校验 plan 阶段产出物（任务: ${TASK_ID}）..."

# ─── 0. 前置：core skill 必须可读 ──────────────────────────
if [[ -d "$CORE_SKILL_DIR/references" ]]; then
  echo "  [门禁:plan] core_skill_dir 可读 ✅"
else
  echo "  [门禁:plan] core_skill_dir 不可读，跳过引用文件校验"
fi

# ─── 1. index.md 必须存在 ────────────────────────────────
if [[ ! -f "$INDEX_FILE" ]]; then
  echo "  ❌ 未找到任务文档: $INDEX_FILE"
  echo "     plan 阶段必须产出 index.md（参见 guazi-flow-plan 完成门禁）"
  exit 1
fi
echo "  ✅ index.md 存在"

# ─── 2. Frontmatter 机器字段校验（兼容顶层 + flow: 嵌套）──────
FRONTMATTER=$(fm_extract "$INDEX_FILE")

# guazi-flow-core/SKILL.md:44 规定 frontmatter 必需字段
check_field "$FRONTMATTER" version || exit 1
check_field "$FRONTMATTER" current_stage || exit 1
check_field "$FRONTMATTER" profile || exit 1

# ─── 3. current_stage 必须是 plan（不能是 blocked） ───────
CURRENT_STAGE=$(fm_value "$FRONTMATTER" current_stage)

case "$CURRENT_STAGE" in
  plan)
    echo "  ✅ current_stage = plan"
    ;;
  blocked)
    echo "  ❌ current_stage = blocked（任务被阻塞，无法继续）"
    echo "     阻塞原因请查 index.md 的 blockers 字段"
    exit 1
    ;;
  "")
    echo "  ❌ current_stage 为空"
    exit 1
    ;;
  *)
    echo "  ⚠️ current_stage = ${CURRENT_STAGE}，预期为 plan"
    echo "     如果这是回退重做，请确保 index.md 正确"
    # 允许其他值存在，但不拦截，让后续门禁自行判断
    ;;
esac

# ─── 4. plan-readall.json 必须存在（core 完成门禁） ─────
if [[ -f "$PLAN_READALL" ]]; then
  echo "  ✅ plan-readall.json 存在"
  # 可选：校验 JSON 是否合法
  if python3 -c "import json; json.load(open('$PLAN_READALL'))" 2>/dev/null; then
    echo "  ✅ plan-readall.json JSON 格式合法"
  else
    echo "  ⚠️ plan-readall.json JSON 格式异常（跳过）"
  fi
else
  echo "  ❌ plan-readall.json 缺失"
  echo "     guazi-flow-plan 完成门禁要求：已生成并通过 plan-readall-validator.py"
  exit 1
fi

# ─── 5. 可选：调用真实 plan-readall-validator.py ────────
VALIDATOR="plugins/guazi-flow/scripts/plan-readall-validator.py"
if [[ -f "$VALIDATOR" ]]; then
  # 尝试找 source-root，适配不同的任务目录位置
  SOURCE_ROOT=$(find "$(pwd)/docs/guazi-flow" -maxdepth 2 -name "plan-readall.json" -exec dirname {} \; 2>/dev/null | head -1 || echo ".")
  echo "  ⚙️  运行 plan-readall-validator.py（source-root: $SOURCE_ROOT）..."
  if python3 "$VALIDATOR" "$PLAN_READALL" --source-root "$SOURCE_ROOT" 2>&1; then
    echo "  ✅ plan-readall-validator.py 通过"
  else
    echo "  ❌ plan-readall-validator.py 未通过（详见上方输出）"
    echo "     script 退出码非零，编排器将回退上一阶段"
    exit 1
  fi
else
  echo "  ⚙️  plan-readall-validator.py 未找到，跳过真实门禁"
fi

# ─── 全部通过 ──────────────────────────────────────────────
echo "  ✅ [门禁:plan] 全部校验通过"
exit 0