#!/usr/bin/env bash
# =============================================================================
# guazi-workflow.sh — 瓜子工作流 · 混合编排器（Shell + Makefile 组合）
#
# 设计哲学：
#   "整体是 Workflow（代码强制），中间由 Agent 接管（完全自治）"
#
# 三层分离：
#   Makefile  ── 声明阶段依赖图 + 增量跳过（flag 时间戳）
#   Shell     ── 门禁校验 + 失败回退 + 重试控制（此脚本）
#   Agent     ── 单阶段内完全自主（通过 run-stage.sh + codex exec 调用）
# =============================================================================
set -euo pipefail

# ─── 配置 ─────────────────────────────────────────────────────────
# SCRIPT_DIR：解析软链接后的真实脚本目录（支持从 /usr/local/bin 软链接调用 gflow）
#   若直接用 dirname，软链接调用时会指向链接所在地（如 /usr/local/bin），
#   导致找不到 gates/ Makefile run-stage.sh。故手动解析软链接链。
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"   # 相对链接转绝对
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
TASK_ID="${1:-}"
PLATFORM="${2:-auto}"
MAX_RETRIES="${3:-3}"
DRY_RUN="${DRY_RUN:-0}"         # 1 = 不真实调用 LLM
FORCE="${FORCE:-0}"             # 1 = 忽略 flag 强制全部重跑
SKIP_INSTALL_CHECK="${SKIP_INSTALL_CHECK:-0}"  # 1 = 跳过插件安装校验

# ⭐ P0 修复：WORKROOT = 业务仓库绝对路径（产物落这里，与脚本目录解耦）
#   默认取当前 CWD 的绝对路径；用户应在业务仓库里启动，或用 WORKROOT=/path 覆盖
#   这样即使 make -C $SCRIPT_DIR 切了 CWD，产物路径仍然正确
WORKROOT="${WORKROOT:-$(pwd)}"
# P1-D 修复：目录不存在时友好报错，而非 set -e 静默崩溃
if [[ ! -d "$WORKROOT" ]]; then
  echo "❌ WORKROOT 目录不存在: $WORKROOT" >&2
  echo "   请传入有效的业务仓库路径：WORKROOT=/path/to/repo bash guazi-workflow.sh ..." >&2
  exit 1
fi
WORKROOT="$(cd "$WORKROOT" && pwd)"   # 归一化为绝对路径

# 阶段定义（顺序 = 强制）
declare -a STAGES=(
  "doctor"      # 0
  "plan"        # 1
  "implement"   # 2
  "test"        # 3
  "review"      # 4
  "complete"    # 5
)

CURRENT_INDEX=0
GATE_RETRY=0        # 门禁失败重试计数（与 make 执行失败计数分离，P1-C）
MAX_STAGE=5

# flag 文件路径（⭐ P0 修复：基于 WORKROOT 绝对路径，不再相对 CWD）
flag_path() { echo "${WORKROOT}/docs/guazi-flow/${TASK_ID}/.orchestrator/.${1}.done"; }

# ─── 工具函数 ──────────────────────────────────────────────────────

# 检测平台
detect_platform() {
  if [[ "$PLATFORM" != "auto" ]]; then echo "$PLATFORM"; return; fi
  if command -v codex &>/dev/null; then echo "codex"
  elif command -v claude &>/dev/null; then echo "claude"
  else echo "unknown"; fi
}

# ⭐ P0 修复：启动前校验 guazi-flow 插件是否已安装
#   没装 → skill 调不到 → 整个流程跑不动，必须提前 fail-fast
check_guazi_flow_installed() {
  local platform="$1"
  [[ "$DRY_RUN" == "1" || "$SKIP_INSTALL_CHECK" == "1" ]] && return 0

  echo "[编排器] 🔍 校验 guazi-flow 插件是否已安装 (platform=${platform})..."
  local found=0
  case "$platform" in
    codex)
      # codex skill 目录：~/.codex/skills 或 plugins 缓存
      if find "${HOME}/.codex/skills" "${HOME}/.codex/plugins" -maxdepth 4 -iname "*guazi-flow*" 2>/dev/null | grep -q .; then
        found=1
      fi
      ;;
    claude)
      if find "${HOME}/.claude/skills" "${HOME}/.claude/plugins" -maxdepth 4 -iname "*guazi-flow*" 2>/dev/null | grep -q .; then
        found=1
      fi
      ;;
  esac

  if (( found == 1 )); then
    echo "  ✅ 检测到 guazi-flow 插件"
    return 0
  fi

  echo "  ❌ 未检测到 guazi-flow 插件（${platform}）"
  echo ""
  echo "  ⚠️  这套编排器【依赖 guazi-flow skill】才能工作。"
  echo "     每个阶段会通过 prompt 点名调用 guazi-flow-<stage> skill。"
  echo "     插件未安装 → skill 调不到 → 产物不合规 → 门禁必然失败。"
  echo ""
  echo "  请先安装 guazi-flow 插件后再运行；或（仅调试编排逻辑时）："
  echo "     SKIP_INSTALL_CHECK=1 bash guazi-workflow.sh ${TASK_ID} ${platform}"
  echo "     DRY_RUN=1 bash test-run.sh   # 纯 mock 干跑"
  return 1
}

# 运行阶段门禁
run_gate() {
  local stage="$1"
  local gate_script="${SCRIPT_DIR}/gates/${stage}-gate.sh"
  if [[ ! -f "$gate_script" ]]; then
    echo "  [编排器] 无门禁脚本 → 默认放行"
    return 0
  fi
  echo "  [编排器] 🛂 运行 ${stage} 门禁..."
  # ⭐ P0 修复：传 WORKROOT 给 gate，让 gate 在正确目录校验产物
  WORKROOT="$WORKROOT" bash "$gate_script" "$TASK_ID"
}

# 门禁失败处理：删掉【失败阶段】的 flag，让 make 下轮重建它
#   P0-B 修复：语义明确 —— 只删失败阶段自己的 flag。
#   是否连带回退上一阶段，由调用方(main)根据 rollback 策略决定并显式删 flag。
#   本函数不再"删2个flag却只退1格"，职责单一。
invalidate_stage_flag() {
  local stage="$1"
  rm -f "$(flag_path "$stage")"
}

# 收口：写编排器终态（缺陷修复①：complete 后记录流程真正跑完）
# 注意：只写编排器自己的状态文件，绝不改 skill 拥有的 index.md
finalize_state() {
  local status_file="${WORKROOT}/docs/guazi-flow/${TASK_ID}/.orchestrator/.workflow-status"
  mkdir -p "$(dirname "$status_file")" 2>/dev/null || true
  {
    echo "workflow=complete"
    echo "all_stages_passed=true"
    echo "final_stage=${STAGES[$MAX_STAGE]}"
    echo "updated_by=guazi-workflow.sh"
  } > "$status_file"
  return 0
}

# ─── 主循环 ────────────────────────────────────────────────────────

main() {
  if [[ -z "$TASK_ID" ]]; then
    echo "用法: bash guazi-workflow.sh <task-id> [platform] [max-retries]"
    echo ""
    echo "示例: bash guazi-workflow.sh ABC-123 codex"
    exit 1
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║     🚀 Guazi Workflow · 瓜子工程交付流水线               ║"
  echo "║     任务: ${TASK_ID}                                     "
  echo "║     平台: $(detect_platform)                              "
  echo "║     引擎: Makefile + Shell 双层编排                       "
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "  工作根目录(WORKROOT): ${WORKROOT}"

  # ⭐ P0 修复：启动前校验插件已安装，没装直接 fail-fast（避免白跑一场）
  if ! check_guazi_flow_installed "$(detect_platform)"; then
    exit 1
  fi

  mkdir -p "${WORKROOT}/docs/guazi-flow/${TASK_ID}" 2>/dev/null || true

  # ── 可选：强制全部重跑 ─────────────────────────────────────
  if [[ "$FORCE" == "1" ]]; then
    echo "[编排器] FORCE=1 → 清除所有阶段 flag，强制全部重跑"
    make -C "$SCRIPT_DIR" clean TASK_ID="$TASK_ID" WORKROOT="$WORKROOT"
  fi

  # ── 主循环 ────────────────────────────────────────────────
  #   P0-A 修复：增量判断【完全交给 make】的时间戳机制，Shell 不再自己判 flag。
  #     - make <stage> 会自动跑齐所有未完成的前置依赖（已完成的靠时间戳跳过）
  #     - Shell 只负责：触发 make、跑门禁、门禁失败时删 flag 回退
  #   P1-C 修复：make 执行失败(exec_retry) 与 门禁失败(gate 回退) 用【独立计数器】
  local exec_retry=0        # 同一阶段 make 执行失败的重试次数
  while (( CURRENT_INDEX <= MAX_STAGE )); do
    local stage="${STAGES[$CURRENT_INDEX]}"

    echo ""
    echo "═══ 📌 阶段 $((CURRENT_INDEX + 1))/${#STAGES[@]}：${stage} ═══"

    # ── Step 1: 交给 make 执行（make 自己决定跑哪些前置，已完成的跳过）
    echo "  [编排器] → make ${stage}（前置依赖由 make 按时间戳自动补齐）"
    if ! make -C "$SCRIPT_DIR" "$stage" \
      TASK_ID="$TASK_ID" \
      PLATFORM="$PLATFORM" \
      WORKROOT="$WORKROOT" \
      DRY_RUN="$DRY_RUN" 2>&1; then
      echo "  [编排器] ⚠️ make ${stage} 执行失败"
      if (( exec_retry >= MAX_RETRIES )); then
        echo "❌ 阶段 ${stage} 执行重试已达上限（${MAX_RETRIES}），流程中止"
        exit 1
      fi
      exec_retry=$((exec_retry + 1))
      echo "  [编排器] 执行重试第 ${exec_retry}/${MAX_RETRIES} 次"
      # make 失败没 touch flag，下轮 make 会重跑同一阶段
      continue
    fi
    exec_retry=0   # 执行成功，重置执行重试计数

    # ── Step 2: 门禁校验（Shell 的核心职责）
    if run_gate "$stage"; then
      echo "  ✅ [编排器] 阶段 ${stage} 通过门禁"
      GATE_RETRY=0
      CURRENT_INDEX=$((CURRENT_INDEX + 1))
      continue
    fi

    # ── Step 3: 门禁失败 → 回退策略（删 flag 让 make 重建）
    echo ""
    echo "⚠️  ${stage} 阶段门禁未通过 ⚠️"
    if (( GATE_RETRY >= MAX_RETRIES )); then
      echo "❌ 阶段 ${stage} 门禁重试已达上限（${MAX_RETRIES}），流程中止"
      echo "   请检查产物: ${WORKROOT}/docs/guazi-flow/${TASK_ID}/"
      exit 1
    fi
    GATE_RETRY=$((GATE_RETRY + 1))

    # 删失败阶段的 flag（必删）
    invalidate_stage_flag "$stage"
    # 回退策略：若有上一阶段，连带删上一阶段 flag 并退一格，让上一阶段也重做
    if (( CURRENT_INDEX > 0 )); then
      local prev="${STAGES[$((CURRENT_INDEX - 1))]}"
      invalidate_stage_flag "$prev"
      CURRENT_INDEX=$((CURRENT_INDEX - 1))
      echo "  [编排器] 回退到 ${prev}（删除 ${prev}.done + ${stage}.done），门禁重试 ${GATE_RETRY}/${MAX_RETRIES}"
    else
      echo "  [编排器] 已在首阶段，仅重做 ${stage}（删除 ${stage}.done），门禁重试 ${GATE_RETRY}/${MAX_RETRIES}"
    fi
    continue
  done

  # ── 收口：记录流程完成状态到编排器独立状态文件（不污染 skill 的 index.md）
  #    缺陷修复①：complete 后主动写终态，便于外部查询"流程是否真正跑完"
  finalize_state

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  ✅  ✅  ✅  交付流程全部完成！  ✅  ✅  ✅             ║"
  echo "║  任务: ${TASK_ID}                                       "
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "  编排器终态: ${WORKROOT}/docs/guazi-flow/${TASK_ID}/.orchestrator/.workflow-status"
}

main "$@"