#!/usr/bin/env bash
# =============================================================================
# run-stage.sh — 单阶段执行器（被 Makefile recipe 调用）
#
# 职责单一：只负责"让 Agent 接管某一个阶段"。
#   - 构建该阶段的 prompt（点名调用对应 skill）
#   - headless 调用 LLM（codex / claude / cursor）
#
# 不管：顺序、依赖、门禁、回退、重试 —— 那些是 Makefile 和主编排的事。
#
# 用法: run-stage.sh <stage> <task-id> [platform]
# =============================================================================
set -euo pipefail

STAGE="${1:?需要 stage 参数}"
TASK_ID="${2:?需要 task-id 参数}"
PLATFORM="${3:-auto}"
DRY_RUN="${DRY_RUN:-0}"
# ⭐ P0 修复：WORKROOT = 业务仓库绝对路径（产物基准），默认当前 CWD
WORKROOT="${WORKROOT:-$(pwd)}"

# 阶段 → 真实 skill 名
skill_name_for_stage() { echo "guazi-flow-$1"; }

# 平台检测
detect_platform() {
  if [[ "$PLATFORM" != "auto" ]]; then echo "$PLATFORM"; return; fi
  if command -v codex &>/dev/null; then echo "codex"
  elif command -v claude &>/dev/null; then echo "claude"
  else echo "unknown"; fi
}

# 构建 prompt（编排器只点名 skill，不复制 skill 规则）
build_prompt() {
  local stage_name="$1" task_id="$2" cwd="${3:-$WORKROOT}"
  local skill; skill="$(skill_name_for_stage "$stage_name")"
  # ⭐ P0 修复：产物路径基于 WORKROOT 绝对路径
  local status_file="${WORKROOT}/docs/guazi-flow/${task_id}/index.md"
  local context=""
  if [[ -f "$status_file" ]]; then
    context="已有任务文档 ${status_file}，请读取其 current_stage 和已有内容后继续。"
  else
    context="尚无任务文档，这是流程起点。"
  fi
  # [STAGE:xxx] 和 [TASK:xxx] 是 ASCII 标记，便于 mock/日志稳定解析（不依赖环境变量）
  echo "[STAGE:${stage_name}] [TASK:${task_id}] 请通过 guazi-flow 插件执行 ${stage_name} 阶段，调用 skill: ${skill}。任务标识: ${task_id}。工作目录: ${cwd}。${context} 严格遵循该 skill 自身的规则与完成门禁，不要跨阶段执行其他阶段的工作。完成后输出中文摘要，说明产出物及其路径，并确保 index.md 的 current_stage 已更新。"
}

# headless 调用 Agent
call_agent() {
  local stage="$1" prompt="$2"
  local platform; platform="$(detect_platform)"
  echo "  [run-stage] 阶段 ${stage} → Agent 接管 (platform=${platform})"

  if [[ "$DRY_RUN" == "1" ]]; then
    codex exec "$prompt"   # PATH 里是 mock
    return $?
  fi

  case "$platform" in
    codex)
      # ⭐ P0 修复：--cd 指定业务仓库；--skip-git-repo-check 允许非 git 目录（冒烟测试实证必需）
      codex exec --cd "$WORKROOT" --skip-git-repo-check --sandbox workspace-write "$prompt" 2>&1
      ;;
    claude)
      # Claude 用 --add-dir 指定工作目录（或调用前 cd）
      ( cd "$WORKROOT" && claude -p "$prompt" --permission-mode acceptEdits ) 2>&1
      ;;
    cursor)
      echo "  [run-stage] ⚠️ Cursor 暂不支持 headless，请手动执行以下 prompt："
      echo "─── PROMPT ───"; echo "$prompt"; echo "──────────────"
      read -r -p "完成后按 Enter 继续..." _
      return 0
      ;;
    *)
      echo "❌ 无法检测到支持的 AI 平台（codex / claude）"; exit 1
      ;;
  esac
}

# ─── 执行 ─────────────────────────────────────────────────────────
PROMPT="$(build_prompt "$STAGE" "$TASK_ID")"
call_agent "$STAGE" "$PROMPT"