#!/usr/bin/env bash
# =============================================================================
# gates/review-gate.sh — review 阶段门禁（对接真实 guazi-flow 契约）
#
# 对齐 guazi-flow-review 完成门禁：
#   - evidence/review.md 存在
#   - frontmatter: result / git_head / candidate_diff_hash / write_set
#                  / review_subject_hash / flow_runtime_hash
#   - result ∈ {pass, not_pass}
#   - review 失败不得推进 complete
#
# 退出码：0 = 通过，非0 = 回退上一阶段
# =============================================================================
set -euo pipefail

TASK_ID="${1:-}"
WORKROOT="${WORKROOT:-$(pwd)}"
TASK_DIR="${WORKROOT}/docs/guazi-flow/${TASK_ID}"
REVIEW="${TASK_DIR}/evidence/review.md"

# 引入共享库（兼容顶层 + flow: 嵌套两种 frontmatter 格式）
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${GATE_LIB_DIR}/_lib.sh"

echo "  [门禁:review] 校验 review 阶段产出物（任务: ${TASK_ID}）..."

# ─── 1. evidence/review.md 必须存在 ──────────────────────
if [[ ! -f "$REVIEW" ]]; then
  echo "  ❌ 未找到评审证据: $REVIEW"
  echo "     guazi-flow-review 门禁要求：evidence/review.md 存在"
  exit 1
fi
echo "  ✅ evidence/review.md 存在"

FRONTMATTER=$(fm_extract "$REVIEW")

# ─── 2. frontmatter 必需字段（兼容顶层/嵌套）─────────────
for field in result git_head candidate_diff_hash write_set review_subject_hash flow_runtime_hash; do
  check_field "$FRONTMATTER" "$field" || exit 1
done

# ─── 3. result ∈ {pass, not_pass} ────────────────────────
RESULT=$(fm_value "$FRONTMATTER" result)
case "$RESULT" in
  pass)
    echo "  ✅ result = pass"
    ;;
  not_pass)
    echo "  ❌ result = not_pass（评审未通过，不得推进 complete）"
    exit 1
    ;;
  *)
    echo "  ❌ result = '${RESULT}'，必须是 pass 或 not_pass"
    exit 1
    ;;
esac

echo "  ✅ [门禁:review] 全部校验通过"
exit 0