# =============================================================================
# Makefile — 瓜子工作流 · 阶段依赖图（声明式）
#
# 职责：声明"阶段之间的依赖关系" + "增量跳过"（flag 时间戳）
#   - 每个阶段完成后 touch 一个 flag 文件
#   - make 通过 flag 时间戳判断哪些阶段需要重跑
#   - 门禁失败时，主编排器删掉对应 flag，make 会自动从那里重建
#
# 不管：门禁、回退、重试 —— 那些交给 guazi-workflow.sh
#
# 用法（一般由 guazi-workflow.sh 调用，也可单独用）：
#   make deliver TASK_ID=ABC-123 PLATFORM=codex
#   make plan    TASK_ID=ABC-123            # 只跑到 plan
#   make clean   TASK_ID=ABC-123            # 清所有 flag
# =============================================================================

SHELL := /usr/bin/env bash

# ── 参数（可被命令行覆盖）──────────────────────────────────────────
TASK_ID  ?= UNSET
PLATFORM ?= auto
WORKROOT ?= $(CURDIR)

# ── 状态目录：flag 放在 WORKROOT 下的任务目录（P0 修复：绝对路径，与脚本目录解耦）
STATE_DIR := $(WORKROOT)/docs/guazi-flow/$(TASK_ID)/.orchestrator
# run-stage.sh 就在脚本目录（= make -C 的 CURDIR），但产物写到 WORKROOT
RUN       := DRY_RUN=$(DRY_RUN) WORKROOT="$(WORKROOT)" bash $(CURDIR)/run-stage.sh

# ── 各阶段的 flag 文件（"完成标记"）──────────────────────────────
DOCTOR    := $(STATE_DIR)/.doctor.done
PLAN      := $(STATE_DIR)/.plan.done
IMPLEMENT := $(STATE_DIR)/.implement.done
TEST      := $(STATE_DIR)/.test.done
REVIEW    := $(STATE_DIR)/.review.done
COMPLETE  := $(STATE_DIR)/.complete.done

.PHONY: doctor plan implement test review complete deliver clean check-task

# ── 顶层目标 ──────────────────────────────────────────────────────
deliver: $(COMPLETE)     ## 跑完整交付流程

doctor:    check-task $(DOCTOR)
plan:      check-task $(PLAN)
implement: check-task $(IMPLEMENT)
test:      check-task $(TEST)
review:    check-task $(REVIEW)
complete:  check-task $(COMPLETE)

# ── 依赖链（声明式：谁依赖谁一目了然）────────────────────────────
# doctor 是起点，无前置
$(DOCTOR): | $(STATE_DIR)
	@echo "═══ 📌 make: doctor ═══"
	$(RUN) doctor "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# plan 依赖 doctor
$(PLAN): $(DOCTOR)
	@echo "═══ 📌 make: plan ═══"
	$(RUN) plan "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# implement 依赖 plan
$(IMPLEMENT): $(PLAN)
	@echo "═══ 📌 make: implement ═══"
	$(RUN) implement "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# test 依赖 implement
$(TEST): $(IMPLEMENT)
	@echo "═══ 📌 make: test ═══"
	$(RUN) test "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# review 依赖 test
$(REVIEW): $(TEST)
	@echo "═══ 📌 make: review ═══"
	$(RUN) review "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# complete 依赖 review
$(COMPLETE): $(REVIEW)
	@echo "═══ 📌 make: complete ═══"
	$(RUN) complete "$(TASK_ID)" "$(PLATFORM)"
	@touch $@

# ── 辅助目标 ──────────────────────────────────────────────────────
$(STATE_DIR):
	@mkdir -p $@

check-task:
	@if [ "$(TASK_ID)" = "UNSET" ]; then \
		echo "❌ 请指定 TASK_ID，例如: make deliver TASK_ID=ABC-123"; \
		exit 1; \
	fi

clean: check-task    ## 清除所有阶段 flag（强制全部重跑）
	@rm -rf $(STATE_DIR)
	@echo "🧹 已清除 $(TASK_ID) 的所有阶段 flag"