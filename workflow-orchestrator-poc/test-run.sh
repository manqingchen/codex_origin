#!/usr/bin/env bash
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"
# =============================================================================
# test-run.sh — 本地干跑验证（不调真实 LLM，DRY_RUN 模式）
#
# 目的：不烧 token 验证完整调用链
#   guazi-workflow.sh → make → run-stage.sh → codex exec (mock)
#   专注验证：增量跳过 + 门禁拦截 + 强制回退 是否正确工作。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🧪 Shell + Makefile 组合编排 · 干跑测试（不烧 token）       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ─── 准备 Mock Agent（产出真实 guazi-flow 契约格式）───────────────
MOCK_BIN="$(mktemp -d)"
cat > "$MOCK_BIN/codex" <<'MOCK'
#!/usr/bin/env bash
prompt="$*"
stage="$(printf '%s' "$prompt" | sed -n 's/.*\[STAGE:\([a-z]*\)\].*/\1/p' | head -1)"
stage="${stage:-unknown}"
# 从 prompt 的 [TASK:xxx] 解析 task_id（不依赖环境变量）
task_id="$(printf '%s' "$prompt" | sed -n 's/.*\[TASK:\([A-Za-z0-9_-]*\)\].*/\1/p' | head -1)"
task_id="${task_id:-UNKNOWN}"
# WORKROOT 从 build_prompt 注入的"工作目录: xxx"里取（真实 codex 用 --cd，mock 靠这个）
workroot="$(printf '%s' "$prompt" | sed -n 's/.*工作目录: \([^。]*\)。.*/\1/p' | head -1)"
workroot="${workroot:-$(pwd)}"
echo "  [Mock:codex] stage=${stage} task=${task_id} (autonomous execution)"

task_dir="${workroot}/docs/guazi-flow/${task_id}"
mkdir -p "$task_dir"

case "$stage" in
  plan)
    if [[ -f "$task_dir/.plan_attempt" ]]; then
      # 第二次：产出符合真实 guazi-flow 契约的完整 index.md
      cat > "$task_dir/index.md" <<'EOF'
---
version: 1
current_stage: plan
profile: h5
profile_detail: h5-web
---
# 任务方案
## 目标
实现登录功能
## 方案
使用 JWT + Redis
## 验收与验证矩阵
| Case ID | 验收项 |
| --- | --- |
| C-001 | 登录成功跳转 |
EOF
      echo '{"units":[],"readall":"ok"}' > "$task_dir/plan-readall.json"
      echo "  [Mock:codex] plan 完整产出（frontmatter + readall）✓"
    else
      # 第一次：故意产出 blocked 状态（触发门禁失败）
      touch "$task_dir/.plan_attempt"
      cat > "$task_dir/index.md" <<'EOF'
---
version: 1
current_stage: blocked
profile: h5
---
# 任务方案
JIRA_ID 未确认，暂时 blocked
EOF
      echo "  [Mock:codex] plan 产出 blocked（故意触发门禁失败）✗"
    fi
    ;;
  doctor)    echo "  [Mock:codex] doctor 通过（mock）" ;;
  implement)
    # 产出符合 implement gate 的 index.md（current_stage=implement）
    cat > "$task_dir/index.md" <<'EOF'
---
version: 1
current_stage: implement
profile: h5
profile_detail: h5-web
---
# 任务方案
## 目标
实现登录功能
EOF
    echo "  [Mock:codex] implement 完成（current_stage=implement）✓"
    ;;
  test)
    # 产出符合 test gate 的 run-report.md（全部机器字段 + 章节）
    mkdir -p "$task_dir/test"
    cat > "$task_dir/test/run-report.md" <<'EOF'
---
version: 1
result: pass
task: TEST-001
git_head: abc123
candidate_diff_hash: def456
case_set_hash: ghi789
case_results: []
adapters: [playwright]
updated_at: 2026-06-29
---
## Summary
全部用例通过
## Case Results
| Case | Result |
| --- | --- |
| C-001 | pass |
## Assertion Coverage
covered
## Suggested Next Step
guazi-flow-review
EOF
    echo "  [Mock:codex] test 通过（run-report.md result=pass）✓"
    ;;
  review)
    # 产出符合 review gate 的 evidence/review.md（全部 hash 字段）
    mkdir -p "$task_dir/evidence"
    cat > "$task_dir/evidence/review.md" <<'EOF'
---
result: pass
trigger: manual
review_mode: full
git_head: abc123
candidate_diff_hash: def456
write_set: [src/login.ts]
review_subject_hash: sub123
flow_runtime_hash: rt456
---
## 评审范围
登录功能
## 结论
通过
EOF
    echo "  [Mock:codex] review 通过（evidence/review.md result=pass）✓"
    ;;
  complete)  echo "  [Mock:codex] complete 完成（mock）" ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/codex"

# ─── 准备独立 WORKROOT ───────────────────────────────────────────
# ⭐ 用独立临时目录当 WORKROOT，验证"产物落对地方"（而非 PoC 目录）
TEST_WORKROOT="$(mktemp -d)"
TEST_TASK="TEST-001"

echo ""
echo "▶ 预期行为："
echo "    1. doctor → make 第一次跑 → flag 创建"
echo "    2. plan 第一次 → make 跑 → current_stage=blocked → 门禁拦截"
echo "    3. 强制回退 → 删 doctor+plan flag → 重跑 doctor → 重跑 plan"
echo "    4. plan 第二次 → 完整产物 → 门禁通过"
echo "    5. implement → test → review → complete（增量跳过生效）"
echo "    6. ⭐ 产物落在 WORKROOT=${TEST_WORKROOT}，而非 PoC 目录"
echo ""
echo "────────────────────────────────────────────────────────────────"

# 跑测试：PATH 指向 mock，DRY_RUN=1，WORKROOT 指向独立临时目录
export PATH="$MOCK_BIN:$PATH"
DRY_RUN=1 FORCE=1 WORKROOT="$TEST_WORKROOT" \
  bash "$SCRIPT_DIR/guazi-workflow.sh" "$TEST_TASK" codex 3 || true

echo "────────────────────────────────────────────────────────────────"
echo ""
echo "📄 最终 index.md 内容（来自 WORKROOT）："
cat "${TEST_WORKROOT}/docs/guazi-flow/${TEST_TASK}/index.md" 2>/dev/null | sed 's/^/    /' || echo "    (无)"

echo ""
echo "📦 make flag + 终态（来自 WORKROOT）："
ls -la "${TEST_WORKROOT}/docs/guazi-flow/${TEST_TASK}/.orchestrator/" 2>/dev/null | sed 's/^/    /' || echo "    (无)"

echo ""
echo "🔍 验证 PoC 目录【没有】被污染（不应有 docs/）："
if [[ -d "${SCRIPT_DIR}/docs" ]]; then
  echo "    ❌ PoC 目录出现了 docs/ —— WORKROOT 隔离失败！"
else
  echo "    ✅ PoC 目录干净，产物正确落在 WORKROOT"
fi

echo ""
echo "🧹 清理..."
rm -rf "$MOCK_BIN" "$TEST_WORKROOT" 2>/dev/null || true
echo "✅ 干跑测试完成"