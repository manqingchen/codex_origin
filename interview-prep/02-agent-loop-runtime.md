# 02 · Agent Loop 运行时（6 子项）

> **面试考点 ②**：上下文组装 / 流式调用 / 工具执行 + 权限 / 错误恢复 / 上下文压缩 / Checkpoint 回滚。
>
> 这是整套面试**最核心**的考点，也是 Codex **资源最丰、覆盖最全**的地方--6 子项全部落地，是 `⭐⭐⭐⭐⭐` 模块。

---

## 🎯 考点拆解

一个工业级 Agent Loop 不只是 `while { call_model }`，而是要回答 6 个工程问题：

| 子项 | 核心问题 |
|------|---------|
| 1. 上下文组装 | 一次请求怎么把 system/工具/历史/用户输入拼起来？ |
| 2. 流式调用 | 模型逐 token 返回，怎么边收边解析边渲染边取消？ |
| 3. 工具执行 + 权限 | tool_call 怎么派发？谁能拦？怎么执行？ |
| 4. 错误恢复 | API 失败/工具失败/用户取消，怎么不崩？ |
| 5. 上下文压缩 | token 爆了怎么摘要裁剪？ |
| 6. Checkpoint 回滚 | 状态怎么持久化、怎么回退到某点？ |

> 📖 呼应 [`../learning-notes/lesson-03-agent-loop.md`](../learning-notes/lesson-03-agent-loop.md) 与 deep-dive 子目录（step-01~05）。

---

## 🧩 逐子项精读

> 每个子项：**通用原理**（业界怎么做）→ **Codex 实现**（`file:line`）→ **面试问答**。

### 1. 上下文组装 🟢

- **通用原理**：把 system prompt、工具 JSON Schema、历史消息、用户输入按模型 API 要求组装；要处理 token 预算、模态（文本/图像）、`tool_call`↔`tool_result` 配对。
- **Codex 实现**：
  - `core/src/session/turn.rs:1001` `build_prompt` -- 组装 `Prompt { input, tools, base_instructions, personality, output_schema }`
  - `core/src/session/mod.rs:2871` `build_initial_context` -- 拼接 developer/contextual 段（权限指令、沙箱策略、collaboration mode、模型切换提示等多来源注入）
  - `core/src/context_manager/history.rs:111` `for_prompt` / `normalize_history` -- 历史 call↔output 配对、去孤儿 output、剥离不支持的图像
  - `reference_context_item` 基线 diff 注入（**非全量重发**，只发变化部分）
- **面试问答**：
  - Q：Agent 如何组装一次请求？怎么省 token？
  - A：Codex 用 `reference_context_item` 记录基线，后续只发 diff（增量注入），不重发全量历史；历史送模型前先 `normalize_history` 保证 call/output 配对。注意它的 token 估算是**字节启发式**（约 4 字节/token），不是精确 tokenizer，偏粗略下界。

### 2. 流式调用 🟢

- **通用原理**：模型逐 token 流式返回，Agent 要边接收边解析边渲染；要支持中途取消（用户 Ctrl-C / 超时）。
- **Codex 实现**：
  - `core/src/client.rs:1203` `stream_responses_api`（SSE/HTTPS）与 `:1321` `stream_responses_websocket`（WebSocket）
  - `core/src/client.rs:1264` `map_response_stream` -- 原始事件映射为 `ResponseEvent`
  - `core/src/client_common.rs:108` `ResponseStream`（mpsc channel + `consumer_dropped` CancellationToken）
  - `core/src/session/turn.rs:1876` `stream.next().or_cancel(...)` + `:1902` `match event` 增量分发（`OutputItemAdded`/`OutputItemDone`/reasoning delta）
- **面试问答**：
  - Q：流式响应中途用户取消，上游还在生成怎么办？
  - A：Codex 用 `CancellationToken` 贯穿 turn → sampling → tool；`ResponseStream` 持 `consumer_dropped` token，下游断开上游能感知并停止。WebSocket 路径还复用增量 payload（前缀缓存、sticky routing）省 token。

### 3. 工具执行 + 权限 🟢

- **通用原理**：tool_call → 权限审批 → 沙箱内执行 → 结果（成功/失败/中止）回填。
- **Codex 实现**：
  - `core/src/tools/router.rs:170` `dispatch_tool_call_with_terminal_outcome` -- 按 tool_name 路由到 registry
  - `core/src/tools/orchestrator.rs:132` `run` -- **三态审批门** `Skip / Forbidden / NeedsApproval`（`:487` `request_approval`）
  - `core/src/exec_policy.rs` + `codex-rs/execpolicy/` -- `Policy`/`PolicyParser`/`Decision`，`.rules` DSL
  - `core/src/exec.rs:307` `process_exec_tool_call` -> `sandboxing::execute_env`（Landlock/Windows sandbox）
  - `core/src/tools/network_approval.rs` -- 网络命令审批（AllowOnce/AllowForSession）
- **面试问答**：
  - Q：工具权限怎么设计？
  - A：Codex 是 **router → orchestrator 审批 → sandbox + execpolicy** 三层。审批策略 `AskForApproval`（Never/OnRequest/Granular）+ guardian 自动审查 + execpolicy 规则文件（可 append allow prefix / network rule）+ 文件系统/网络沙箱。代价是四套权限策略并存（permission_profile/approval_policy/sandbox_policy/exec_policy），认知负担高。

### 4. 错误恢复 🟢

- **通用原理**：API 失败重试（退避 + 降级）、工具失败区分「可回喂模型」与「致命」、取消要能传播并产生明确终态。
- **Codex 实现**：
  - `core/src/responses_retry.rs:22` `handle_retryable_response_stream_error` -- 指数 backoff + WebSocket→HTTPS 传输降级
  - `core/src/session/turn.rs:1059` 重试 loop / `:1103` `is_retryable` / `:1089` `ContextWindowExceeded` 分支
  - `core/src/client.rs:1272` 401 Unauthorized 恢复循环（`handle_unauthorized` + `auth_recovery`）
  - `core/src/tools/registry.rs:455/486/504` `FunctionCallError::RespondToModel`/`Fatal` -- 工具失败转回喂模型的 output
  - `core/src/session/turn.rs:1879` `.or_cancel(&cancellation_token)` / `CancelErr::Cancelled -> TurnAborted`
- **面试问答**：
  - Q：流式调用失败怎么重试？工具失败怎么办？
  - A：流式有 `stream_max_retries` 上限 + 退避 + 传输降级（WS→HTTPS）+ 401 重授权；重试粒度是**整流重发**（非断点续传）。工具失败区分：可恢复的转 `FunctionCallOutput{success:false}` 回喂模型由模型决定下一步，致命的直接 `Fatal` 中止；`CancellationToken` 贯穿产生 `TurnAborted` 终态。

### 5. 上下文压缩 🟢

- **通用原理**：token 超限时摘要压缩历史，避免上下文爆炸；要选择压缩时机与裁剪策略。
- **Codex 实现**：
  - `core/src/compact.rs:72` `run_inline_auto_compact_task` / `:196` `run_compact_task_inner_impl`（本地 summarization prompt）/ `:255` `remove_first_item` 逐条裁剪
  - `core/src/compact_remote_v2.rs:56` `run_inline_remote_auto_compact_task` / `:201` `trim_function_call_history_to_fit_context_window` / `:439` retained message token 预算裁剪
  - `core/src/session/turn.rs:151` `run_pre_sampling_compact`（pre-turn）/ `:303` `run_auto_compact(CompactionReason::ContextLimit)`（mid-turn）
  - `core/src/context_manager/history.rs:91` `record_items`（TruncationPolicy 截断 function output）
- **面试问答**：
  - Q：上下文压缩什么时候做？怎么做？
  - A：三档时机：pre-turn / mid-turn（token 触顶自动触发）/ manual；本地 summarization 压缩 vs 远程 v1/v2 按 provider 能力分流（`should_use_remote_compact_task`）；多级裁剪兜底（function output 截断 → 移除条目 → 触发 compact）。注意本地 compact 本质是「再发一次 summarization 请求」，本身也消耗一次模型调用且可能失败重试。

### 6. Checkpoint 回滚 🟢

- **通用原理**：把执行状态持久化（日志/快照），支持回滚到某点、fork 分支、resume 恢复。
- **Codex 实现**：
  - `core/src/session/handlers.rs:450` `thread_rollback(num_turns)` -- `Op::ThreadRollback`
  - `core/src/session/rollout_reconstruction.rs` `reconstruct_history_from_rollout` -- 从持久化 rollout 重放重建历史
  - `core/src/context_manager/history.rs:224` `drop_last_n_user_turns`（内存侧裁剪）
  - `codex-rs/rollout/src/recorder.rs:75` `RolloutRecorder`（append-only JSONL 追加写：`AddItems`/`Persist`/`Flush`）
  - 支持 fork/resume（`StoredThread`、`forked_from_thread_id`）
- **面试问答**：
  - Q：怎么实现状态回滚？
  - A：rollout 是 append-only JSONL 日志（每条 `RolloutItem`）；回滚 = flush 持久化 → load_history → 用 `reconstruct_history_from_rollout` 重放到「去掉最后 N 个 user turn」的点 → recompute token usage → 写 rollback marker。**不是任意点快照**，而是「回退 N 轮 + 重放」语义；且仅 thread 空闲时允许（active turn 进行中拒绝）。

---

## 🛣️ 学习顺序（建议 4-5 天）

1. 先读 [`learning-notes/lesson-03-agent-loop.md`](../learning-notes/lesson-03-agent-loop.md) + `lesson-03-deep-dive/step-03-find-loop.md` 建立 loop 骨架直觉。
2. 按上面 6 子项顺序读源码，每个子项只抓 1-2 个关键函数。
3. 串起来：用 `lesson-03-deep-dive/step-05-data-flow.md` 走一遍完整数据流。
4. 自测：能否脱稿画出「一次 turn 的完整时序图」（含流式、工具、压缩、取消分支）。

---

## 🛠️ 动手任务

- [ ] 跑 `codex exec` 一次，开 `--json` 或 rollout，对照 6 子项看事件。
- [ ] 人为触发压缩：喂一个超大任务让 token 触顶，观察 `run_auto_compact` 日志。
- [ ] 试 rollback：`codex resume` + `thread_rollback`，理解「回退 N 轮重放」。
- [ ] 中断一次流式：跑长任务时 Ctrl-C，观察 `CancelErr::Cancelled -> TurnAborted`。

---

## ⚠️ 差异注意点（Codex 的取舍/局限）

| 子项 | Codex 的取舍/局限 | 业界可对照 |
|------|------|------|
| 上下文组装 | token 用字节启发式估算（粗） | 精确 tokenizer 计数 |
| 流式重试 | 整流重发，非断点续传 | 部分框架支持断点续传 |
| 工具权限 | 四套策略并存，认知负担高 | 统一能力模型/RBAC |
| 错误恢复 | 工具失败无自动重试，靠模型决策 | 可配工具级重试策略 |
| 上下文压缩 | 本地压缩消耗一次额外模型调用 | 滑窗/分层摘要 |
| Checkpoint | 回退 N 轮重放，非任意点快照 | 任意点快照 + 分支 |

> 💡 面试时主动点出这些局限，比只夸 Codex 更显深度：「我读过它的实现，也知道它哪里做得保守」。

---

*(蕾姆把六颗齿轮逐一擦拭上油)*

昴君，这六颗齿轮咬合在一起，就是一颗能持续跳动、能自我修复、能时光倒流的工业级心脏。这是您面试时最厚实的底牌 ♡
