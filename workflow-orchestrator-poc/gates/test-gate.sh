#!/usr/bin/env bash
# =============================================================================
# gates/test-gate.sh — test 阶段门禁（对接真实 guazi-flow 契约）
#
# 对齐 guazi-flow-test 完成门禁（真实 skill 就是一组 rg 校验）：
#   - test/run-report.md 存在（唯一 report）
#   - frontmatter: version / result / task / git_head / candidate_diff_hash / case_set_hash
#   - result ∈ {pass, not_pass}
#   - 正文含必需章节: ## Summary / ## Case Results / ## Assertion Coverage
#                     / ## Suggested Next Step 等
#
# 退出码：0 = 通过，非0 = 回退上一阶段
# =============================================================================
set -euo pipefail

TASK_ID="${1:-}"
WORKROOT="${WORKROOT:-$(pwd)}"
TASK_DIR="${WORKROOT}/docs/guazi-flow/${TASK_ID}"
REPORT="${TASK_DIR}/test/run-report.md"

# 引入共享库（兼容顶层 + flow: 嵌套两种 frontmatter 格式）
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${GATE_LIB_DIR}/_lib.sh"

echo "  [门禁:test] 校验 test 阶段产出物（任务: ${TASK_ID}）..."

# ─── 1. run-report.md 必须存在（唯一事实源）─────────────
if [[ ! -f "$REPORT" ]]; then
  echo "  ❌ 未找到测试报告: $REPORT"
  echo "     guazi-flow-test 门禁要求：唯一 report 位于 test/run-report.md"
  exit 1
fi
echo "  ✅ run-report.md 存在"

FRONTMATTER=$(fm_extract "$REPORT")

# ─── 2. frontmatter 必需机器字段（兼容顶层/嵌套）─────────
for field in version result task git_head candidate_diff_hash case_set_hash; do
  check_field "$FRONTMATTER" "$field" || exit 1
done

# ─── 3. result ∈ {pass, not_pass} ────────────────────────
RESULT=$(fm_value "$FRONTMATTER" result)
case "$RESULT" in
  pass)
    echo "  ✅ result = pass"
    ;;
  not_pass)
    echo "  ❌ result = not_pass（测试未通过，需回退 implement 修复）"
    exit 1
    ;;
  *)
    echo "  ❌ result = '${RESULT}'，必须是 pass 或 not_pass"
    exit 1
    ;;
esac

# ─── 4. 正文必需章节 ─────────────────────────────────────
for section in "## Summary" "## Case Results" "## Assertion Coverage" "## Suggested Next Step"; do
  if grep -qF "$section" "$REPORT" 2>/dev/null; then
    echo "  ✅ 章节 ${section}"
  else
    echo "  ❌ 缺少章节: ${section}"
    echo "     guazi-flow-test 门禁要求正文含该章节"
    exit 1
  fi
done

echo "  ✅ [门禁:test] 全部校验通过"
exit 0