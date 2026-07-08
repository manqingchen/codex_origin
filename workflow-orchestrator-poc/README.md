# Guazi Workflow · 混合编排器（Shell + Makefile）

> 一个**架在 guazi-flow skill 之上**的强制编排层。
> skill 负责"每阶段怎么做"（可独立升级），编排器负责"强制顺序 + 门禁 + 回退"。

---

## 🎯 它解决什么问题

原生 skill / slash command 的痛点：**控制流在 LLM 手里，无法强制**。
你 `/guazi-flow-auto`，LLM 可能跳步、可能在 plan 阶段就偷偷写代码。

本编排器把**控制流从 LLM 手里夺回来**，交给确定性代码：

```
整体是 Workflow（代码强制顺序）
  ↓
中间由 Agent 接管（每阶段 headless 调用，Agent 在单阶段内完全自治）
  ↓
每阶段后有门禁（代码校验产物，不过则强制回退）
```

---

## 🏗️ 三层架构

```
guazi-workflow.sh   ← 控制平面（Shell）：门禁校验 · 失败回退 · 重试
      │ make <stage>
      ▼
Makefile            ← 依赖平面（Make）：声明阶段依赖图 · flag 增量跳过
      │ run-stage.sh <stage> <task> <platform>
      ▼
run-stage.sh        ← 执行平面：构建 prompt · headless 调 Agent
      │ codex exec / claude -p
      ▼
gates/*.sh          ← 门禁：校验产物是否符合 skill 完成门禁
```

| 文件 | 职责 |
|------|------|
| `guazi-workflow.sh` | 主编排：触发 make + 门禁 + 回退 + 终态收口（**不管增量**） |
| `Makefile` | 阶段依赖图 + **增量跳过的唯一负责人**（flag 时间戳） |
| `run-stage.sh` | 单阶段执行器：构建 prompt + headless 调 LLM |
| `gates/*.sh` | 6 道门禁 + `_lib.sh` 共享库（兼容两种 frontmatter 格式） |
| `commands/guazi-workflow.md` | slash command 入口 |
| `test-run.sh` | 干跑测试（0 token 验证全链路） |

---

## ⭐ Skill 是怎么被"使用"的？（核心设计，务必理解）

**这是最容易误解的地方。本编排器【不是】在 shell/Makefile 里硬调用 skill。**

### 为什么不能硬调用？

查证过两个事实：
1. guazi-flow 的 skill 目录里**只有 `SKILL.md`**，没有可执行 CLI 入口
   → 无法 `bash guazi-flow-plan.sh` 硬调
2. `codex exec --help` 里**没有 `--skill` / `--activate-skill` 参数**
   → CLI 层面无法指名激活某个 skill

### 实际做法：prompt 软声明 + gate 硬校验

```
① 软声明（run-stage.sh 的 build_prompt）：
   prompt 文本里写 "请调用 skill: guazi-flow-plan..."
   → codex exec 把 prompt 喂给 LLM
   → LLM 自行决定是否调用该 skill

② 硬校验（gates/plan-gate.sh）：
   校验产物是否符合 skill 的完成门禁
   → 产物格式对 → 放行
   → 产物不对 → 回退重做
```

### 本质：这是「检测性强制」，不是「声明性强制」

| | 强制的对象 | 强制力 |
|--|----------|:-----:|
| 控制流（走哪个阶段） | Makefile 依赖链 | ✅ 硬 |
| 门禁（过不过） | Shell gate 脚本 | ✅ 硬 |
| **skill 调用** | **prompt 文本点名** | ⚠️ **软** |
| **skill 产出结果** | **gate 校验产物契约** | ✅ **硬** |

> **编排器强制的是【结果必须符合 skill 契约】，而不是【必须调用某 skill 的行为】。**
>
> 这反而是更健壮的设计：
> - skill 团队升级 skill 内部逻辑 → 编排器不用改（只要产物契约不变）
> - 就算 LLM 用别的方式产出了正确结果 → 也放行（结果导向）
> - 完美契合"架在 skill 之上，skill 可独立升级"的原则

---

## 🚀 使用方式

```bash
# 干跑验证（不烧 token，用 mock Agent 验证编排逻辑）
bash test-run.sh

# 真实运行（会调用 codex exec / claude -p）
bash guazi-workflow.sh <任务ID> [platform] [max-retries]
bash guazi-workflow.sh ABC-123 codex

# 只跑到某阶段（Make 的能力）
make plan TASK_ID=ABC-123 PLATFORM=codex

# 改了 plan 只想重跑 plan 及下游（Make 增量）
rm docs/guazi-flow/ABC-123/.orchestrator/.plan.done
bash guazi-workflow.sh ABC-123 codex   # doctor 跳过，plan 起重跑

# 强制全部重跑
FORCE=1 bash guazi-workflow.sh ABC-123 codex

# 清所有 flag
make clean TASK_ID=ABC-123
```

---

## 🔄 阶段与门禁

| 阶段 | skill | 门禁校验内容 |
|------|-------|-------------|
| doctor | guazi-flow-doctor | （无门禁，纯前置检查）|
| plan | guazi-flow-plan | frontmatter(version/current_stage/profile) + plan-readall.json |
| implement | guazi-flow-implement | current_stage=implement + write_set |
| test | guazi-flow-test | run-report.md + 6机器字段 + result∈{pass,not_pass} + 4章节 |
| review | guazi-flow-review | evidence/review.md + 6字段(含review_subject_hash) |
| complete | guazi-flow-complete | review 证据 pass+fresh + Test report pass |

**门禁失败 → 删除对应 flag → make 自动从上一阶段重建 → 强制回退重做。**

---

## 📁 状态文件（与 skill 产物严格分离）

```
docs/guazi-flow/<task>/
├── index.md                    ← skill 拥有（编排器只读不写）
├── plan-readall.json           ← skill 拥有
├── test/run-report.md          ← skill 拥有
├── evidence/review.md          ← skill 拥有
└── .orchestrator/              ← 编排器拥有（skill 不碰）
    ├── .doctor.done            ← make flag
    ├── .plan.done
    ├── ...
    └── .workflow-status        ← 流程终态
```

> **关注点分离**：skill 拥有业务产物，编排器拥有 flag/状态。两个平面互不覆盖。

---

## ✅ 已修复的 P0 缺陷（第二、三轮 grill 后）

- **✅ 插件安装校验**：启动前 `check_guazi_flow_installed()` 检测 guazi-flow 是否安装，未装直接 fail-fast（避免白跑）。`DRY_RUN=1` 或 `SKIP_INSTALL_CHECK=1` 可跳过。
- **✅ CWD 陷阱修复**：引入 `WORKROOT`（业务仓库绝对路径），所有产物/flag/gate 校验都基于它，与脚本目录彻底解耦。真实 `codex exec --cd $WORKROOT --skip-git-repo-check` 让 Agent 在业务仓库工作。
- **✅ `--skip-git-repo-check`（真跑实证）**：冒烟测试发现 codex 在非 git 目录会拒绝执行，已补上该参数。
- **✅ frontmatter 格式兼容（真跑实证）**：真跑发现 LLM 产出用 `flow:` 嵌套结构，而 gate 只认顶层字段。新增 `gates/_lib.sh` 共享库（`fm_value`/`fm_has`/`check_field`），**同时兼容顶层格式和 `flow:` 嵌套格式**，5 个 gate 全部改用。

## ✅ 架构重构（第四轮 grill / code review 后）

- **✅ 增量判断唯一归属 make（P0-A）**：重构前 Shell 用 `[[ -f flag ]]` 和 make 时间戳【双重判断】增量，逻辑重叠易打架。重构后 **Shell 不再自己判 flag，增量 100% 交给 make**；Shell 只负责触发 make、跑门禁、门禁失败删 flag 回退。职责单一。
- **✅ 回退语义清晰（P0-B）**：旧 `rollback()` "删2个flag却只退1格"语义模糊。重构为 `invalidate_stage_flag()`（职责单一，只删一个 flag），回退策略在主循环显式表达。
- **✅ 两种失败计数分离（P1-C）**：`make 执行失败` 用 `exec_retry`，`门禁失败` 用 `GATE_RETRY`，不再共用一个计数器混淆语义。
- **✅ WORKROOT 不存在友好报错（P1-D）**：传入不存在的路径时明确报错并退出 1，而非 `set -e` 静默崩溃。

**验证**：重构后回退机制（doctor+plan 各执行2次）、增量跳过（第二次跑 Mock 执行 0 次）、WORKROOT 报错，全部实测通过。

## 🧪 真跑实验结论（第三轮 grill）

真实 codex exec 跑了 doctor→plan（约 6.7 万 token），证明：
- ✅ **编排机制在真实 LLM 下成立**：Agent 真的被强制按阶段走、真的产出文件、真的拒绝跨阶段
- ✅ **WORKROOT 隔离真跑下生效**：产物落在业务目录，PoC 目录零污染
- 🔴 **暴露并已修复 2 个真 bug**：`--skip-git-repo-check` 缺失、frontmatter 嵌套格式错配

## ⚠️ 剩余限制 / 待完善

- **🔴 真实 guazi-flow skill 未端到端验证**：真跑时未装 guazi-flow（LLM 自由发挥），装上真 skill 后产出格式会遵循 skill 规范，gate 已兼容两种格式故应能对齐，但仍需真装一次确认。
- **🟡 MCP/网络/认证未处理**：figma/cwiki/swagger 等 skill 依赖的 MCP 工具、网络、认证，编排器未处理，真实跑可能卡住。
- **🟡 headless 审批策略**：`--sandbox workspace-write` 下若 skill 需审批，headless 行为未验证。
- **回退只回退 1 级**：门禁失败只回退到上一阶段，跨多级需扩展 `rollback()`。
- **doctor 无门禁**：设计如此（纯前置）。
- **write_set 越界是软校验**：`implement-gate.sh` 需接入真实 git diff 脚本才能硬校验。
- **Cursor 需手动**：Cursor 无 headless，`run-stage.sh` 会提示手动执行 prompt。

## 🚀 使用方式（补充 WORKROOT）

```bash
# 在业务仓库里运行（WORKROOT 默认 = 当前目录）
cd /path/to/业务仓库
bash /path/to/poc/guazi-workflow.sh ABC-123 codex

# 或显式指定 WORKROOT
WORKROOT=/path/to/业务仓库 bash guazi-workflow.sh ABC-123 codex

# 仅调试编排逻辑（跳过插件校验）
SKIP_INSTALL_CHECK=1 bash guazi-workflow.sh ABC-123 codex
```
