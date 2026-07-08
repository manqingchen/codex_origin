#!/usr/bin/env bash
# =============================================================================
# gates/_lib.sh — gate 共享函数库
#
# 真跑实验（第三轮 grill）暴露：真实 LLM 产出的 frontmatter 可能是
#   ① 顶层格式：       version: 1 / current_stage: plan
#   ② flow: 嵌套格式： flow:\n  version: 1\n  current_stage: plan
# 本库提供【两种格式都兼容】的字段提取，避免 gate 因格式差异误判。
# =============================================================================

# 提取 frontmatter（--- 到 --- 之间）
fm_extract() {
  local file="$1"
  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null || true
}

# 取某个字段的值，兼容顶层 + 任意缩进嵌套
#   用法: fm_value "$FRONTMATTER" current_stage
#   返回: 字段值（去引号/空格），找不到返回空
fm_value() {
  local frontmatter="$1" field="$2"
  # 匹配 "^field:" 或 "^<空格>field:"，取冒号后的值
  printf '%s\n' "$frontmatter" \
    | grep -E "^[[:space:]]*${field}:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*${field}:[[:space:]]*//; s/^\"//; s/\"$//; s/^'//; s/'$//" \
    | tr -d '\r'
}

# 校验字段存在（两种格式都算存在）
#   用法: fm_has "$FRONTMATTER" version && echo ok
fm_has() {
  local frontmatter="$1" field="$2"
  printf '%s\n' "$frontmatter" | grep -qE "^[[:space:]]*${field}:"
}

# 便捷：校验字段存在并打印结果，不存在则返回 1
check_field() {
  local frontmatter="$1" field="$2"
  if fm_has "$frontmatter" "$field"; then
    echo "  ✅ frontmatter.${field} 存在"
    return 0
  else
    echo "  ❌ frontmatter.${field} 缺失（顶层/flow: 嵌套均未找到）"
    return 1
  fi
}