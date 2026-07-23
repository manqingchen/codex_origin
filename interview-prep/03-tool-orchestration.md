# 03 · 工具编排 + 渐进式技能加载（Find Skills）

> **面试考点 ③**：并行调用、循环检测、动态授权；**渐进式技能加载（Find Skills）机制**。
>
> Codex 在这一考点有真并发、会话级动态授权，以及一个工程亮点--**双层渐进式技能加载**。唯一薄弱处是「通用循环检测」（见 [GAPS 缺口 5](./GAPS-codex-cannot-teach.md)）。

---

## 🎯 考点拆解

| 子项 | 核心问题 | Codex |
|------|---------|:---:|
| A. 并行调用 | 一轮里多个 tool_calls 是否真并发？ | 🟢 |
| B. 循环检测 | Agent 会不会无限调用同一工具？怎么防？ | 🟡 |
| C. 动态授权 | 运行时按需授权工具、避免反复弹窗 | 🟢 |
| D. Find Skills | 技能/工具太多，怎么不一次性灌满上下文？ | 🟢 亮点 |

> 📖 呼应 [`../learning-notes/lesson-04-tools.md`](../learning-notes/lesson-04-tools.md) + `lesson-04-deep-dive/` + [`../docs/skills.md`](../docs/skills.md) + [`lesson-13-mcp.md`](../learning-notes/lesson-13-mcp.md)。

---

## 🧩 逐子项精读

### A. 并行调用 🟢

- **通用原理**：模型一轮里可能返回多个 tool_calls，应并发执行以降低延迟，但结果要按序回填、要考虑工具是否线程安全。
- **Codex 实现**：
  - `core/src/session/turn.rs:1842` `FuturesOrdered` 收集本轮所有 `tool_future`
  - `core/src/session/turn.rs:1769` `drain_in_flight` -- 并发执行、按发出顺序回收结果
  - `core/src/tools/parallel.rs:113` `handle_tool_call_with_source` -- 每个调用 `tokio::spawn` 成独立 task
  - `core/src/tools/parallel.rs:88` `supports_parallel` -- 支持并行的用 `RwLock` 读锁，**不支持并行的用写锁降级为串行**
- **面试问答**：
  - Q：多个工具怎么调度？会不会乱序？
  - A：每个 tool_call `tokio::spawn` 成独立 task 真并发，结果用 `FuturesOrdered` 保证**按发出顺序**回填进 transcript；非线程安全工具通过 `parallel_execution` 的 RwLock 自动降级串行。局限是普通 tool_call 没有显式并发上限（无 semaphore，agent_jobs 子任务有 `MAX_AGENT_JOB_CONCURRENCY=64`）。

### B. 循环检测 🟡（薄弱）

- **通用原理**：Agent 可能陷入死循环（反复调同工具、反复被拒、token 不增也不减）。需要 max_iterations、调用去重、连续相同行为计数。
- **Codex 实现**：
  - `core/src/guardian/review.rs:580` `guardian_rejection_circuit_breaker` -- 连续拒绝后熔断
  - `core/src/guardian/tests.rs:87` -- 阈值 = 连续 3 次拒绝
  - `core/src/session/turn.rs:301-320` -- token 触顶时触发 `auto_compact`，注释明说"靠 compaction 避免无限循环"
- **面试问答**：
  - Q：你的 Agent 怎么防止死循环？
  - A：诚实答：Codex 有 **guardian 连续拒绝熔断**（阈值 3）+ **token 预算耗尽触发 auto_compact 兜底**；但**没有通用的「同工具+相同参数反复调用」去重**（无 MAX_RUNS、无 iteration cap）。代码注释也承认这是「只要 compaction 工作良好」的乐观假设。如果是我设计，会补一个「连续 N 次相同 tool_call+参数就注入一条提醒」的去重层。详见 [GAPS 缺口 5](./GAPS-codex-cannot-teach.md)。

### C. 动态授权 🟢

- **通用原理**：审批要能「批准一次，后续免提示」（会话级缓存）；沙箱拒绝后升级重试要能按需重新审批；最好支持可编程授权（hooks）。
- **Codex 实现**：
  - `core/src/tools/orchestrator.rs:132` `run` -- approval → sandbox → retry-with-escalation 编排
  - `core/src/tools/orchestrator.rs:487-549` `PermissionRequest` hooks -- **可编程自动 Allow/Deny**
  - `core/src/tools/sandboxing.rs:70` `with_cached_approval` -- 按 key 缓存审批，命中免提示
  - `core/src/mcp_tool_call.rs:1855-1863` `mcp_tool_approval_is_remembered` / `remember_mcp_tool_approval` -- `ApprovedForSession` 会话级动态授权
- **面试问答**：
  - Q：怎么避免每个工具调用都弹审批？
  - A：Codex 支持会话级缓存（`ApprovedForSession` 进 `tool_approvals` store），批准一次后续免提示；沙箱拒绝后升级重试时按需重新审批；`PermissionRequest` hooks 可脚本化授权决策（自动 Allow/Deny）。MCP 工具也有 `AcceptForSession`/`AcceptAndRemember`。局限是审批粒度基于 key（命令/文件/MCP 工具标识），无基于风险的动态分级。

### D. 渐进式技能加载 Find Skills 🟢（亮点，双层）

- **通用原理**：技能/工具很多时，一次性把全部 schema 和内容灌进 prompt 会爆 token。应「先暴露摘要目录，按需才加载全文」--即 **progressive disclosure**。
- **Codex 实现（双层）**：

  **第 1 层 · 技能 catalog 摘要常驻 + 按需加载全文**
  - 发现：`codex-rs/core-skills/src/loader.rs:488` `discover_skills_under_root`（BFS 扫 `SKILL.md`，受 `MAX_SCAN_DEPTH`/`MAX_SKILLS_DIRS_PER_ROOT` 限制）
  - 摘要常驻：`codex-rs/core-skills/src/render.rs:62` `render_available_skills_body` -- **只渲染 name+description+locator**，受 2% context budget 保护，超预算截断
  - 按需加载全文：`codex-rs/core-skills/src/injection.rs:58` `build_skill_injections` -- 仅对被 `$SkillName` mention 的技能 `read_file_text(SKILL.md)` 读全文
  - `codex-rs/core/src/context/available_skills_instructions.rs:10` -- 目录作为 developer fragment 注入
  - `codex-rs/ext/skills/src/tools/list.rs`、`read.rs` -- `skills.list`/`skills.read` MCP 工具按需读 orchestrator 技能

  **第 2 层 · 工具级 Find Skills（BM25）**
  - `codex-rs/core/src/tools/handlers/tool_search.rs:69` `ToolSearchHandler` -- **BM25 搜索引擎**
  - `codex-rs/core/src/tools/spec_plan.rs:839-859` `append_tool_search_executor` -- `ToolExposure::Deferred` 工具转成 search entries
  - `codex-rs/core/src/tools/spec_plan.rs:457` -- **Deferred 工具（`defer_loading:true`）不进 `prompt.tools`**，经 `tool_search` 检索后才暴露 `LoadableToolSpec`
- **面试问答**：
  - Q：工具/技能很多时怎么不爆上下文？说说 Find Skills。
  - A：Codex 用**双层 progressive disclosure**：① 技能层--启动扫描所有 `SKILL.md` 但只把**摘要目录**注入 prompt（2% budget 保护），只有被 `$SkillName` mention 或经 `skills.read` 工具才读全文；② 工具层--`defer_loading:true` 的工具**不进 prompt.tools**，模型先调 `tool_search`（BM25）检索到相关工具，才暴露其 schema。设计意图明说就是「先看目录、再 deep reference-chasing」，避免一次性灌满。局限是技能检索目前靠显式 mention + 模型自选，没有语义向量检索技能。

---

## 🛣️ 学习顺序（建议 3-4 天）

1. 读 [`lesson-04-step-03-registry.md`](../learning-notes/lesson-04-step-03-registry.md) 理解工具注册与路由。
2. 读 `core/src/tools/parallel.rs` 理解并发与串行降级。
3. 读 `core/src/tools/orchestrator.rs` 理解审批→沙箱→升级重试编排。
4. 读 [`docs/skills.md`](../docs/skills.md) + `core-skills/src/render.rs` + `injection.rs` 理解技能摘要常驻 + 按需加载。
5. 读 `core/src/tools/handlers/tool_search.rs` + `spec_plan.rs` 的 Deferred 逻辑，理解工具级 Find Skills。

---

## 🛠️ 动手任务

- [ ] 配一个有很多 MCP 工具的环境，观察 `tool_search` 是否被调用、Deferred 工具是否真的不进初始 prompt。
- [ ] 写一个 `SKILL.md` 放进 `.codex/skills/`，看摘要目录是否出现、`$SkillName` mention 是否触发全文加载。
- [ ] （加分·补缺口）给 loop 加一个「连续 N 次相同 tool_call+参数就注入提醒」的实验性去重补丁，写清取舍。
- [ ] 审批：连续拒绝 3 次，观察 guardian 熔断。

---

## ⚠️ 差异注意点

| 子项 | Codex | 业界对照 / 需补 |
|------|------|------|
| 并行 | FuturesOrdered + RwLock 降级 | 可加 semaphore 限流 |
| 循环检测 | 仅 guardian 熔断 + token 兜底 | LangGraph `recursion_limit`、max_iter、调用去重（[GAPS 缺口 5](./GAPS-codex-cannot-teach.md)） |
| 动态授权 | 会话级缓存 + hooks 可编程 | 风险分级授权 |
| Find Skills | 双层 progressive disclosure 是亮点 | 语义向量检索技能（codex 无） |

> 💡 **Find Skills 是这个考点里最值得讲的亮点**。面试时重点描述「为什么 Deferred 工具不进 prompt」--这是 token 经济学的高级理解，区分度极高。

---

*(蕾姆从裙底掏出一个小巧的目录索引册)*

昴君，工具不必全摆上桌--先递一张目录，等您需要哪把，蕾姆再为您取来。这正是 Codex 教给您的最高明的待客之道 ♡
