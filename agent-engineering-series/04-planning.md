# 04 · Planning 规划 - Agent 的小脑

> 进阶层 · 第一篇
>
> **子主题**：依赖分析 · 并行执行 · 动态重规划
>
> **Codex 覆盖**：🟡 部分（core 内是 LLM 隐式规划；显式 DAG 编排在 `workflow-orchestrator-poc/`，非 core 内部）

---

## ① 本篇定位

基础层让 Agent 能「转起来」，但只能一步一步来。遇到复杂任务（「重构这个模块 + 写测试 + 发 PR」），Agent 得会**排顺序、并行干、错了重排**--这就是规划，Agent 的小脑。

三个环节对应厨师长的工作：

- **依赖分析** = 排菜单--凉菜先上、热菜后上、甜点最后，顺序不能乱；
- **并行执行** = 多灶齐开--没有依赖关系的菜同时炒；
- **动态重规划** = 菜砸了重做--某道菜做坏了，退回去重做，不影响别的。

**本篇在链路中的位置**：进阶层第一块。它是从「单 Agent 单线程」走向「复杂任务自治」的关键一跳。

---

## ② 业界通用原理

### 2.1 依赖分析 - 任务图与拓扑排序

复杂任务先拆成子任务，再建**依赖图（DAG）**：

```text
A(建表) ──> B(写DAO) ──> D(联调)
              ↑
C(写Service) ┘   (C 依赖 A，与 B 无依赖可并行)
```

业界做法：
- **显式 DAG**：人/编排器画出依赖图，拓扑排序决定执行顺序（Airflow、LangGraph 的图）；
- **隐式规划**：让 LLM 自己决定下一步干啥，不建显式图（ReAct 本身就是隐式规划）。

### 2.2 并行执行 - 无依赖就并发

DAG 里**同一层无依赖的节点**可并发。关键设计：
- 并发收集（如 `FuturesOrdered`/`gather`）；
- **保序回填**（结果按发起顺序写回，不能乱序，否则 LLM 困惑）；
- 并发上限（semaphore）防资源爆炸。

### 2.3 动态重规划 - 执行中纠错

执行中会发现：某个子任务失败、某个前提变了、某条路走不通。三种重规划模式：

| 模式 | 做法 | 代表 |
|------|------|------|
| Plan-and-Execute | 先出完整计划，执行中发现偏差再重规划 | LangChain Plan-and-Execute |
| ReWOO | 先规划完所有工具调用（不交错执行），再统一执行 | 减少循环次数 |
| 图编排回退 | 节点失败 -> 回退到依赖节点重跑 | LangGraph、Airflow |

> 💡 **心法**：规划的本质是「**把控制流从 LLM 的脑子里拿出来，变成可强制、可回退、可并行的结构**」。越显式越可控，越隐式越灵活但越不可控。

---

## ③ Codex 源码映射

Codex 在 Planning 上呈现**双面**：core 内部是隐式规划，仓库另有一个显式编排 POC。

### 3.1 core 内部 - LLM 隐式规划 + 工具并行

Codex core **没有显式 DAG 规划器**。每一步「该干啥」由 LLM 在 ReAct 循环里自己决定（见 ①）。规划能力体现在**工具的并行执行**上：

```rust
// codex-rs/core/src/session/turn.rs:1842
let mut in_flight: FuturesOrdered<BoxFuture<'static, CodexResult<ResponseInputItem>>> =
    FuturesOrdered::new();   // 保序收集工具 future

// codex-rs/core/src/session/turn.rs:1769
async fn drain_in_flight(
    in_flight: &mut FuturesOrdered<...>, sess: Arc<Session>, turn_context: Arc<TurnContext>,
) -> CodexResult<()> {
    while let Some(res) = in_flight.next().await {   // 按序取结果
        match res {
            Ok(response_input) => {
                sess.record_conversation_items(&turn_context, ...).await;  // :1778 按序回填
            }
            Err(err) => { error_or_panic(...); }
        }
    }
}
```

配合 ② 工具篇的 `parallel.rs:82` `handle_tool_call_with_source`（`tokio::spawn` 真并发），读法：
- LLM 一次返回多个 `tool_call` -> `tokio::spawn` **真并发执行**；
- 用 `FuturesOrdered`（`:1842`）收集，`drain_in_flight`（`:1769`）**按发起顺序回填**（保序，不乱序）。

> ⚠️ 这只是「**同一层工具的并行**」，不是「**跨步骤的 DAG 编排**」。Codex core 没有显式的任务图。

### 3.2 显式编排 - `workflow-orchestrator-poc/`（Guazi Workflow POC）

仓库里的 `workflow-orchestrator-poc/` 是一个**把控制流从 LLM 手里夺回**的显式编排器，恰好补上了「依赖分析 + 动态重规划」这块。它是 Shell + Makefile 实现，架在 guazi-flow skill 之上。

**三层架构**：

```text
guazi-workflow.sh   ← 控制平面（Shell）：门禁校验 · 失败回退 · 重试
      │ make <stage>
      ▼
Makefile            ← 依赖平面（Make）：声明阶段依赖图 · flag 增量跳过
      │ run-stage.sh <stage>
      ▼
run-stage.sh        ← 执行平面：构建 prompt · headless 调 Agent
```

**(a) 依赖分析 - Makefile 声明式依赖链**

```makefile
# workflow-orchestrator-poc/Makefile:49-84（节选）
$(DOCTOR): | $(STATE_DIR)          # doctor 无前置
	$(RUN) doctor ...; @touch $@
$(PLAN): $(DOCTOR)                 # plan 依赖 doctor
	$(RUN) plan ...; @touch $@
$(IMPLEMENT): $(PLAN)             # implement 依赖 plan
$(TEST): $(IMPLEMENT)             # test 依赖 implement
$(REVIEW): $(TEST)                # review 依赖 test
$(COMPLETE): $(REVIEW)            # complete 依赖 review
```

读法：六阶段 `doctor -> plan -> implement -> test -> review -> complete` 的依赖链用 Make 的**声明式规则**写出，`make` 自动做拓扑排序。每阶段完成 `touch` 一个 flag 文件（`.plan.done` 等）。改了 plan 只想重跑 plan 及下游？`rm .plan.done` 再跑，make 自动从 plan 重建（**增量跳过**）。

**(b) 动态重规划 - 门禁失败强制回退**

每阶段后有**门禁**（`gates/*.sh`）校验产物契约，不过则强制回退：

```text
门禁失败 -> 删除对应 flag（invalidate_stage_flag）-> make 自动从上一阶段重建 -> 强制回退重做
```

| 阶段 | 门禁校验内容 |
|------|-------------|
| plan | frontmatter(version/current_stage/profile) + plan-readall.json |
| implement | current_stage=implement + write_set |
| test | run-report.md + 6 机器字段 + result∈{pass,not_pass} |
| review | evidence/review.md + 6 字段（含 review_subject_hash） |
| complete | review 证据 pass+fresh + Test report pass |

> 🔑 **精妙之处**：POC 强制的是「**结果必须符合 skill 契约**」，而不是「必须调用某 skill 的行为」。LLM 用别的方式产出正确结果也放行--结果导向的检测性强制。

**(c) 控制流外置的本质**

POC 的设计宣言（README 原意）：原生 skill 的痛点是**控制流在 LLM 手里无法强制**--你让它先 plan 再 implement，它可能在 plan 阶段就偷偷写代码。POC 把控制流交给确定性代码：

| 强制的对象 | 强制力 |
|-----------|:------:|
| 控制流（走哪个阶段） | ✅ 硬（Makefile 依赖链） |
| 门禁（过不过） | ✅ 硬（Shell gate） |
| skill 调用 | ⚠️ 软（prompt 文本点名） |
| skill 产出结果 | ✅ 硬（gate 校验契约） |

### 3.3 core 内部的「兜底重规划」

core 虽无显式 DAG，但有两道兜底（接 ①）：

- **guardian 熔断**：`core/src/guardian/review.rs:217` `guardian_rejection_circuit_breaker`--连续被拒绝 N 次后熔断，避免无限空转；
- **token 触顶压缩**：`turn.rs:302` `token_limit_reached && needs_follow_up` -> `run_auto_compact` 后 `continue`--上下文爆了不报错，压缩后继续。

> 这俩是「异常恢复」，不是「任务重规划」。真正的任务级重规划要靠 POC 那样的门禁回退。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| core 规划方式 | **LLM 隐式规划**，无显式 DAG | ✅ 灵活、通用；❌ 不可强制顺序、不可显式回退 |
| 工具并行 | `FuturesOrdered` 保序收集 + `tokio::spawn` | ✅ 同层工具真并发且按序回填；❌ 无跨步骤编排 |
| 显式编排 | 仅在 `workflow-orchestrator-poc/`（Shell 层 POC） | ✅ 把控制流夺回；❌ 非 core 内部，未产品化 |
| 重规划 | POC 门禁回退 + core guardian 熔断 | ✅ 检测性强制；❌ 回退只回退 1 级 |
| 业界对比 | LangGraph 用图节点显式编排 | Codex core 更轻，POC 更像 Airflow/LangGraph 的壳 |

> **面试金句**：Codex core 的规划是「**隐式的**」--它信任 LLM 在 ReAct 循环里自己排步骤，只在工具并行（`FuturesOrdered`）和异常兜底（guardian 熔断 + auto_compact）上做工程保障。真要显式 DAG 编排，看仓库里的 `workflow-orchestrator-poc/`：它用 Makefile 声明依赖、用 gate 做门禁回退，把控制流从 LLM 手里夺回交给确定性代码。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| Agent 框架对比（LangGraph/LlamaIndex 的图编排） | [`../interview-prep/01-agent-framework.md`](../interview-prep/01-agent-framework.md) |
| 工具编排（并行/循环/授权）子项矩阵 | [`../interview-prep/03-tool-orchestration.md`](../interview-prep/03-tool-orchestration.md) |
| POC 的完整设计与真跑实验 | [`../workflow-orchestrator-poc/README.md`](../workflow-orchestrator-poc/README.md) |
| 主循环里工具如何被并行调度 | 本卷 [01 ReAct 框架](./01-react-framework.md) + [02 工具设计](./02-tool-design.md) |
| guardian 熔断的细节 | 本卷 [07 安全可控](./07-safety-control.md) |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「Agent 怎么做任务规划？怎么并行、怎么重规划？」

1. **业界原理**：规划三要素--依赖分析（建 DAG 拓扑排序）、并行执行（同层无依赖节点并发 + 保序回填）、动态重规划（执行中失败回退到依赖节点重跑）。分隐式（LLM 自决）和显式（编排器建图）两派。
2. **Codex 实现**：core 内是**隐式规划**，LLM 在 ReAct 循环里自决步骤；工具并行用 `turn.rs:1842` `FuturesOrdered` 保序收集 + `parallel.rs:82` `tokio::spawn` 真并发 + `turn.rs:1769` `drain_in_flight` 按序回填；异常兜底用 `guardian/review.rs:217` 熔断 + `turn.rs:302` token 触顶 auto_compact。真要显式编排看 `workflow-orchestrator-poc/`：`Makefile` 声明六阶段依赖链（`doctor->plan->...->complete`）+ `gates/*.sh` 门禁校验契约 + 门禁失败删 flag 强制回退。
3. **取舍局限**：core 无显式 DAG 规划器，规划不可强制不可显式回退；POC 是 Shell 层 POC 非 core 内部、未产品化，回退只回退 1 级；对比 LangGraph 的图节点编排，Codex 更轻但可控性弱。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `turn.rs:1842` 找到 `FuturesOrdered`，对比 `FuturesUnordered`，思考为什么工具结果必须保序回填。
2. 跑 `workflow-orchestrator-poc/test-run.sh`（干跑，0 token），观察门禁失败时 flag 被删、make 自动回退的过程。
3. 在 POC 的 `Makefile` 里改一下依赖（比如让 test 不依赖 implement），跑一次看 make 的拓扑排序结果。
4. 在 `guardian/review.rs:217` 附近读熔断逻辑，找出「连续几次拒绝才熔断」的阈值。

### 自测题
1. Codex core 有显式的 DAG 规划器吗？没有的话，规划靠谁？
2. `FuturesOrdered`（`turn.rs:1842`）和 `FuturesUnordered` 的区别是什么？为什么工具回填要选前者？
3. POC 的「检测性强制」和「声明性强制」有什么区别？为什么说 POC 强制的是结果而非行为？
4. POC 门禁失败后，回退是靠什么机制实现的？（提示：flag + make 依赖重建）
5. core 的 `guardian` 熔断（`review.rs:217`）算「动态重规划」吗？为什么？

---

## ⑧ 小结

> 规划是 Agent 的小脑：依赖分析排顺序、并行执行多灶齐开、动态重规划菜砸了重做。
> Codex core 走**隐式路线**（LLM 自决 + `FuturesOrdered` 保序并行 + guardian 兜底）；
> 显式 DAG 编排要看 `workflow-orchestrator-poc/`--Makefile 声明依赖、gate 门禁回退，把控制流从 LLM 手里夺回。

---

*下一站 -> [05 Multi-Agent](./05-multi-agent.md)：单 Agent 规划够了，但复杂任务可能要多个 Agent 分工。它们怎么通信、状态归谁？*
