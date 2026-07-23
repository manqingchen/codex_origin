# 01 · ReAct 框架 — Agent 的心跳

> 基础层 · 第一篇
>
> **子主题**：循环逻辑 · 终止条件 · 异常处理
>
> **Codex 覆盖**：🟢 强（主循环是 Codex 最核心、最值得读的源码之一）

---

## ① 本篇定位

如果把一个 Agent 比作一道菜，那么 ReAct 就是厨师反复「尝味道 → 加调料 → 再尝」的过程：

- **思考（Thought）**：尝一口，判断咸淡；
- **行动（Action）**：根据判断加盐或加水；
- **观察（Observation）**：再尝一口，看是否到位；
- **循环**：直到满意为止，才端上桌。

ReAct（Reasoning + Acting）是 Agent 区别于「一次性问答 Chatbot」的根本--它能让 LLM 在「想」和「做」之间反复横跳，直到任务真正完成。

**本篇在链路中的位置**：八篇的起点。没有循环，工具（②）和记忆（③）都无处发力。它是整个基础层的心脏。

---

## ② 业界通用原理

### 2.1 经典 ReAct 协议（Yao et al. 2022）

原始论文提出一个**文本协议**，让 LLM 按固定格式自说自话：

```text
Thought: 我需要先查一下今天上海的天气
Action: search_weather
Action Input: {"city": "上海"}
Observation: 上海今天 28℃，多云
Thought: 天气合适，可以安排户外活动
Action: finish
Action Input: {"answer": "今天上海适合户外活动"}
```

循环的三个要素：

| 要素 | 含义 | 谁负责 |
|------|------|--------|
| 循环逻辑 | 「调 LLM → 执行工具 → 把结果拼回 prompt → 再调 LLM」周而复始 | Harness（编排层） |
| 终止条件 | LLM 不再产出 Action，而是产出最终自然语言答案 | LLM 的输出决定 |
| 异常处理 | 工具失败 / API 失败 / 上下文超限，循环不能崩，要能恢复 | Harness |

### 2.2 三个要素的通用设计要点

1. **循环逻辑**：必须是 Harness 用代码强制的外层 `while/loop`，**不能交给 LLM 自觉**。LLM 只负责「这一步该干嘛」，循环边界由代码守。
2. **终止条件**：经典做法是「LLM 不再请求工具」。但工业级还要叠加：用户中途插入新指令、达到最大轮数、token 耗尽。
3. **异常处理**：分三层--
   - 传输层（API 429/超时/断流）：重试 + 退避 + 传输降级；
   - 任务层（工具抛错）：把错误当 Observation 喂回 LLM，让它自我修正；
   - 上下文层（超 token）：压缩历史或开新窗口。

> 💡 **迁移心法**：无论 LangChain、Claude Code 还是自研框架，ReAct 的骨架都是这三要素。看任何 Agent 源码，先找它的「循环在哪、靠什么停、错了怎么办」。

---

## ③ Codex 源码映射

Codex 的主循环实现在 `codex-rs/core/src/session/turn.rs` 的 `run_turn`。下面把三要素一一对应到真实代码。

### 3.1 循环逻辑 — `run_turn` 的 `loop {}`

```rust
// codex-rs/core/src/session/turn.rs:137
pub(crate) async fn run_turn(
    sess: Arc<Session>,
    turn_context: Arc<TurnContext>,
    turn_extension_data: Arc<codex_extension_api::ExtensionData>,
    input: Vec<TurnInput>,
    prewarmed_client_session: Option<ModelClientSession>,
    cancellation_token: CancellationToken,
) -> Option<String> {
    // ... 采样前压缩、技能注入、hooks ...
    loop {                                   // :204 主循环开始
        let pending_input = ...;             // :208 取用户中途新输入
        // 构造喂给模型的上下文
        let sampling_request_input: Vec<ResponseItem> = async {
            sess.clone_history().await
                .for_prompt(&turn_context.model_info.input_modalities)  // :222
        }.await;
        match run_sampling_request(...).await {  // :234 调 LLM（核心一步）
            Ok(sampling_request_output) => { ... }   // :246
            Err(...) => { ... }
        }
    }
}
```

**读法**：`run_turn` 是「一次用户请求的一生」。外层 `loop {}` 在 `turn.rs:204`，每轮做四件事：

1. 取 `pending_input`（用户在模型思考时又插话了）；
2. `clone_history().for_prompt()` 把历史组装成 prompt（`:222`）；
3. `run_sampling_request` 调 LLM（`:234`）；
4. 根据返回判定要不要再来一轮。

### 3.2 终止条件 — `needs_follow_up`

```rust
// codex-rs/core/src/session/turn.rs:263
let needs_follow_up = model_needs_follow_up || has_pending_input;
...
// codex-rs/core/src/session/turn.rs:322
if !needs_follow_up {
    last_agent_message = sampling_request_last_agent_message;
    let stop_outcome = run_turn_stop_hooks(...).await;   // :324 跑停止 hooks
    ...
}
```

**关键变量**：

- `model_needs_follow_up`：来自 `run_sampling_request` 的返回（`:248`）--LLM 这一轮**是否还返回了 `tool_calls`**。这是 ReAct「无 Action 即终止」在 Codex 里的直接体现。
- `has_pending_input`：用户中途是否插了新消息（`:254`）。
- `needs_follow_up = model_needs_follow_up || has_pending_input`（`:263`）--**只要 LLM 还想继续行动，或用户有新指令，循环就继续**。
- `!needs_follow_up`（`:322`）才真正退出循环。

> 这是比经典 ReAct 更稳健的设计：终止不只看 LLM，还看用户。用户随时能「打断+追加」，循环会接住。

### 3.3 ReAct 的「思考」— 原生 reasoning 而非文本协议

```rust
// codex-rs/core/src/session/turn.rs:2182
ResponseEvent::ReasoningSummaryDelta { ... } => { ... }
```

Codex **没有**自研 `Thought/Action/Observation` 文本协议。它走 OpenAI Responses API 的**原生 reasoning**：模型把「思考」放在结构化的 `reasoning` 字段里，把「行动」放在结构化的 `tool_calls` 字段里。Harness 解析的是结构化对象，不是正则文本。

> ⚠️ **这是 Codex 与教科书 ReAct 最大的不同**：解析靠 provider 原生结构，而非 prompt 工程。好处是可靠、不被文本格式坑；代价是**绑死在 Responses API**（见 ④ 局限）。

### 3.4 异常处理 — 三层恢复

**(a) 传输层重试 + 传输降级**

```rust
// codex-rs/core/src/responses_retry.rs:22
pub(crate) async fn handle_retryable_response_stream_error(
    retries: &mut u64, max_retries: u64, err: CodexErr,
    client_session: &mut ModelClientSession, ...
) -> Result<(), CodexErr> {
    if *retries >= max_retries
        && client_session.try_switch_fallback_transport(...)   // :32 WS->HTTPS 降级
    {
        sess.send_event(... WarningEvent { message: "Falling back from WebSockets to HTTPS transport..." }).await;
        *retries = 0;       // :44 降级后重置重试计数
        return Ok(());
    }
    if *retries < max_retries {
        *retries += 1;
        let delay = match &err {
            CodexErr::Stream(_, requested_delay) => requested_delay.unwrap_or_else(|| backoff(retry_count)),
            _ => backoff(retry_count),   // :55 指数退避
        };
        ...
    }
}
```

读法：先用 `backoff(retry_count)` 指数退避重试；**重试次数耗尽时，尝试把传输从 WebSocket 切到 HTTPS**（`try_switch_fallback_transport`，`:32`），并重置计数器从 0 再来。这是「先重试、再降级传输」的两段式恢复。

**(b) 上下文层 — `ContextWindowExceeded` 与 auto_compact**

```rust
// codex-rs/core/src/session/turn.rs:1089  （在 run_sampling_request 内）
Err(CodexErr::ContextWindowExceeded) => { ... return Err(CodexErr::ContextWindowExceeded); }
```

```rust
// codex-rs/core/src/session/turn.rs:302
if token_limit_reached && needs_follow_up {
    if let Err(err) = run_auto_compact(..., CompactionReason::ContextLimit, ...).await { ... }
    can_drain_pending_input = !model_needs_follow_up;
    continue;       // 压缩完继续循环
}
```

读法：token 触顶时，不直接报错退出，而是 `run_auto_compact` 压缩历史（详见 ③ Memory 篇），压缩完 `continue` 继续循环。**「上下文超限」被当作可恢复的异常**，不是致命错误。

**(c) 用户取消 — `CancellationToken`**

`run_turn` 的签名里就带了 `cancellation_token: CancellationToken`（`:143`），并在调 `run_sampling_request` 时传 `cancellation_token.child_token()`（`:242`）。用户 ESC 取消时，整个循环能被协同打断，in-flight 的工具任务也会收到取消信号。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| ReAct 协议形态 | provider 原生 `tool_calls` + `reasoning`，**非自研文本协议** | ✅ 解析可靠、不被格式坑；❌ 绑死 Responses API |
| 终止判定 | `model_needs_follow_up \|\| has_pending_input`，**双信号** | ✅ 用户能随时打断追加；比纯「无 tool_calls」更稳 |
| 循环检测 | **无通用「同工具反复调用」去重**，仅 `guardian` 熔断 + token 兜底 | ❌ 乐观假设，可能空转烧 token |
| 异常恢复粒度 | **整流重发**（重试整次 sampling），非断点续传 | 简单但重试成本高，长流式要重头再来 |
| 上下文超限 | 不致命，`auto_compact` 后 `continue` | ✅ 优雅降级 |

> **面试金句**：Codex 的 ReAct 是「**结构化 ReAct**」--它把 Thought/Action 都交给 provider 的结构化字段，Harness 只管循环边界和异常恢复。这是工程成熟度的体现，但也意味着它的 ReAct **不可移植到不支持原生 tool use 的模型**。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| 主循环的完整时序与代码走读 | [`../learning-notes/lesson-03-agent-loop.md`](../learning-notes/lesson-03-agent-loop.md) + `lesson-03-step-*` 台阶练习 |
| Agent Loop 运行时 6 子项（含 checkpoint 回滚） | [`../interview-prep/02-agent-loop-runtime.md`](../interview-prep/02-agent-loop-runtime.md) |
| Function Calling / ReAct 的面试答法 | [`../interview-prep/04-function-calling-react.md`](../interview-prep/04-function-calling-react.md) |
| 上下文压缩的细节 | 本卷 [03 Memory 记忆](./03-memory-system.md) |
| 工具如何被分发执行 | 本卷 [02 工具设计](./02-tool-design.md) |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「讲讲 Agent 的 ReAct 循环，以及它怎么处理异常。」

1. **业界原理**：ReAct = Reasoning + Acting，核心是「调 LLM → 执行工具 → 结果回填 prompt → 再调 LLM」的循环。循环由 Harness 代码强制，终止靠 LLM 不再请求工具，异常分传输/任务/上下文三层恢复。
2. **Codex 实现**：主循环在 `turn.rs:204` 的 `loop{}`；每轮 `for_prompt` 组装上下文 → `run_sampling_request` 调模型；终止条件 `needs_follow_up = model_needs_follow_up || has_pending_input`（`turn.rs:263`），`!needs_follow_up` 退出（`:322`）；异常上 `responses_retry.rs:22` 做指数退避 + WS→HTTPS 传输降级，`turn.rs:302` 在 token 触顶时 `auto_compact` 后 `continue`。
3. **取舍局限**：Codex 用 provider 原生 `tool_calls`/`reasoning` 而非自研文本协议，可靠但绑死 Responses API；无通用循环检测，靠 guardian 熔断 + token 兜底；重试是整流重发而非断点续传。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `codex-rs/core/src/session/turn.rs` 里找到 `loop {`（`:204`），沿着 `run_sampling_request` 往里读一层，找到 LLM 返回 `tool_calls` 后是如何决定 `model_needs_follow_up = true` 的。
2. 在 `responses_retry.rs` 里把 `backoff()` 函数读出来，确认它是指数退避还是别的策略。
3. 用断点 / 日志观察：让 Codex 连续调用同一工具 3 次，看它有没有循环检测（预期：没有，会一直调到 token 兜底）。

### 自测题
1. `needs_follow_up` 由哪两个信号组成？为什么不能只看 `model_needs_follow_up`？
2. `ContextWindowExceeded` 时 Codex 是直接报错退出吗？走的是哪条恢复路径？
3. WS → HTTPS 传输降级发生在什么时刻？降级后重试计数为什么重置为 0？
4. Codex 的 ReAct 与教科书 ReAct（Thought/Action/Observation 文本）最大的实现差异是什么？带来什么好处和代价？
5. 如果用户在模型思考时又发了一条消息，Codex 的循环会怎么处理？（提示：`has_pending_input` + `can_drain_pending_input`）

---

## ⑧ 小结

> ReAct 是 Agent 的心跳：`run_turn` 的 `loop{}` 跳一下，Agent 就「想一步、做一步」。
> 心跳何时停？看 `needs_follow_up`--LLM 不再要工具、用户也没插话，就停。
> 心跳出问题怎么办？退避重试、降级传输、压缩上下文、协同取消--四道保险让循环崩不了。

---

*下一站 → [02 工具设计](./02-tool-design.md)：心跳每跳一下，LLM 要伸出手去「做事」，那双手是怎么长出来的？*
