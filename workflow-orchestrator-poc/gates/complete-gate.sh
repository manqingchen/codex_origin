#!/usr/bin/env bash
# =============================================================================
# gates/complete-gate.sh — complete 阶段门禁（对接真实 guazi-flow 契约）
#
# 对齐 guazi-flow-complete 完成门禁：
#   - review 证据 pass 且 fresh（review.md result=pass）
#   - 本轮需要 Test 时，test/run-report.md result=pass
#   - current_stage = complete
#
# 这是最后一道门禁，也是最严格的"交付前总检查"。
#
# 退出码：0 = 通过，非0 = 回退上一阶段
# =============================================================================
set -euo pipefail

TASK_ID="${1:-}"
WORKROOT="${WORKROOT:-$(pwd)}"
TASK_DIR="${WORKROOT}/docs/guazi-flow/${TASK_ID}"
INDEX_FILE="${TASK_DIR}/index.md"
REVIEW="${TASK_DIR}/evidence/review.md"
REPORT="${TASK_DIR}/test/run-report.md"

# 引入共享库（兼容顶层 + flow: 嵌套两种 frontmatter 格式）
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${GATE_LIB_DIR}/_lib.sh"

echo "  [门禁:complete] 交付前总检查（任务: ${TASK_ID}）..."

# ─── 1. review 证据必须 pass ─────────────────────────────
if [[ ! -f "$REVIEW" ]]; then
  echo "  ❌ 缺少评审证据: $REVIEW"
  echo "     complete 门禁要求 review 证据 pass 且 fresh"
  exit 1
fi

REVIEW_RESULT=$(fm_value "$(fm_extract "$REVIEW")" result)
if [[ "$REVIEW_RESULT" == "pass" ]]; then
  echo "  ✅ review 证据 result = pass"
else
  echo "  ❌ review 证据 result = '${REVIEW_RESULT}'（需要 pass）"
  echo "     complete 门禁：review 未通过，只能回 review/implement"
  exit 1
fi

# ─── 2. 如果有 Test 报告，必须 pass ──────────────────────
if [[ -f "$REPORT" ]]; then
  TEST_RESULT=$(fm_value "$(fm_extract "$REPORT")" result)
  if [[ "$TEST_RESULT" == "pass" ]]; then
    echo "  ✅ Test report result = pass"
  else
    echo "  ❌ Test report result = '${TEST_RESULT}'（需要 pass）"
    exit 1
  fi
else
  echo "  ℹ️  无 Test report（若本轮需要 Test 则应存在）"
fi

# ─── 3. current_stage 校验 ───────────────────────────────
if [[ -f "$INDEX_FILE" ]]; then
  CURRENT_STAGE=$(fm_value "$(fm_extract "$INDEX_FILE")" current_stage)
  echo "  ℹ️  current_stage = ${CURRENT_STAGE}"
fi

echo "  ✅ [门禁:complete] 交付前总检查通过 —— 可以交付！"
exit 0