# 第03课：Agent 主循环 —— “心脏”

> 💙 **蕾姆的小提示**
>
> 本课主题：**ReAct 循环、tool_calls 判定、循环终止**。
> 这一课是整套课程最重要的一节——理解 Agent 是怎么“跳动”起来的。
> Rust 语法依然只在必要时轻轻带过，重点是**控制流**与**数据流**。

---

## 🎯 学习目标

| # | 学完后您应该能说明 |
|---|------------------|
| 1 | 一次 turn 如何调用 LLM |
| 2 | 如何根据 tool_calls 判断继续或结束 |
| 3 | 工具结果如何回填上下文 |
| 4 | 取消、错误、上限如何中断循环 |

---

## 🧭 本课源码地图

| 路径 | 角色 |
|------|------|
| `codex-rs/core/src/session/turn.rs::run_turn` | **外层 ReAct 循环**（Loop 主体） |
| `codex-rs/core/src/session/turn.rs::run_sampling_request` | 一次 LLM 调用（含**重试**） |
| `codex-rs/core/src/session/turn.rs::try_run_sampling_request` | **真正的流式接收**：拆事件 / 派工具 / 决定 follow_up |
| `codex-rs/core/src/session/turn.rs::SamplingRequestResult` | 单次采样的“出口结构”：`needs_follow_up + last_agent_message` |
| `codex-rs/core/src/client.rs::ModelClientSession::stream` | 建立 LLM 流（Responses API / WebSocket） |
| `codex-rs/core/src/state/turn.rs`、`session/turn_context.rs` | turn 级状态 / 配置（模型、工具、policy） |

> 🌟 **阅读原则**：先看职责边界，再看关键函数；先理解**数据怎么流**，再理解代码怎么写。

---

## 🧠 核心心智模型

```text
                       ┌──────────────────────────────┐
                       │  用户输入 / pending_input    │
                       └────────────┬─────────────────┘
                                    │
                ┌───────────────────▼────────────────────┐
                │  run_turn (外层循环 · ReAct)           │
                │  - clone_history → 构造 prompt          │
                │  - 调 run_sampling_request              │
                │  - 拿 needs_follow_up 决定继续 / 结束    │
                └───────────────────┬────────────────────┘
                                    │
              ┌─────────────────────▼──────────────────────┐
              │ run_sampling_request (内层 LLM 调用 + 重试) │
              │  - build_prompt(history, tools)            │
              │  - try_run_sampling_request → 流式接收      │
              │  - 失败可重试；成功返回 SamplingRequestResult│
              └─────────────────────┬──────────────────────┘
                                    │
              ┌─────────────────────▼──────────────────────┐
              │ try_run_sampling_request (单次流式接收循环)  │
              │  for event in stream {                     │
              │    OutputItemDone → 派工具，更新 follow_up   │
              │    Completed     → 退出，给出 follow_up 结果 │
              │  }                                         │
              └─────────────────────┬──────────────────────┘
                                    │
                       ┌────────────▼────────────┐
                       │ 工具执行 (ToolRuntime)  │
                       │ 结果回填到 history      │
                       └────────────┬────────────┘
                                    │
                       ┌────────────▼────────────┐
                       │  needs_follow_up ?      │
                       │  true  → 回到 run_turn  │
                       │  false → 结束 turn      │
                       └─────────────────────────┘
```

记住三件事：

1. **它解决什么问题**：让 LLM 与“真实世界（工具）”反复对话，直到模型自己说“我说完了”。
2. **它和其它层的关系**：它**夹在** `client.rs`（LLM 通讯）和 `tools/`（工具执行）之间，是 Harness 的**控制中枢**。
3. **它的失败后果**：循环写错——
   - 提前结束 → Agent 看起来“偷懒”，没用工具；
   - 不肯结束 → 死循环烧 token；
   - 工具结果忘记回填 → 模型“失忆”，反复请求相同工具。

---

## 📚 本课大纲

### 1. 生活化比喻：餐厅里的服务员蕾姆

请想象蕾姆是一位餐厅服务员（**Harness**），厨师是 LLM（**Model**），仓库是**工具**：

```
您（客人）：「我想吃点甜的，热乎一点。」
        │
        ▼
蕾姆把您的要求告诉厨师 ←─────────────┐
        │                          │ （回去再问）
        ▼                          │
厨师：「请去看看仓库里有没有可可粉。」 │
        │                          │
        ▼                          │
蕾姆跑去仓库（执行工具）→ 拿回观察结果─┘
        │
        ▼
厨师：「好，那就做热可可。给客人端去吧。」 ← needs_follow_up = false
        │
        ▼
蕾姆把成品端给您（最终自然语言回答）
```

* **厨师只动嘴，不动手**——这正是 LLM 的本质。
* **蕾姆既动嘴又动手**——但她**严格按照厨师的“工单”行动**，不擅自加菜（不擅自调工具）。
* **循环什么时候结束？** 当厨师**不再下工单**、只给出最终菜品描述时（即模型只返回自然语言，没有 `tool_calls`），蕾姆就把菜端上桌，turn 结束。

> 💡 **关键**：工具结果不能直接给客人——必须**回去再让厨师过一遍**。因为客人想要的是“热可可”，不是“仓库里第3层有可可粉”这种原始观察。

---

### 2. 源码区域定位

| 区域 | 是否相关 | 蕾姆的备注 |
|------|---------|-----------|
| 🧠 核心区 (`core/src/session/`, `core/src/state/`) | ✅ **本课主战场** | `run_turn` / `run_sampling_request` 都在这里 |
| 🧠 核心区 (`core/src/client.rs`) | ✅ 强相关 | LLM 流式通讯的底层 |
| 🧠 核心区 (`core/src/tools/`) | 🔸 后台配角 | 第04课会专门拆解，本课只看“在哪里被调用” |
| 🚪 接口区 (`tui/`, `exec/`, `cli/`) | ❌ 与本课无关 | 它们只是把用户输入塞进 turn |
| 🛡️ 平台区 (`sandboxing/`, `execpolicy/`) | ❌ 与本课无关 | 工具内部的事 |
| 🔧 支撑区 (`protocol/`, `app-server/`) | 🔸 边界 | 提供 ResponseEvent 类型 |

---

### 3. 关键流程图（七步式）

```text
谁发起？ —— Session 收到用户输入，构造 TurnContext 调用 run_turn
   ↓
谁判断？ —— LLM 在 ResponseEvent::Completed { end_turn } 中暗示是否结束
            Harness 综合 (end_turn / pending_input / tool 在飞) → needs_follow_up
   ↓
谁执行？ —— ToolCallRuntime 把 LLM 的 FunctionCall 派给 Router；
            工具实际执行在另一条任务里（in_flight FuturesOrdered）
   ↓
结果回到哪里？ —— FunctionCallOutput 进入 history（clone_history → for_prompt）
   ↓
下一步由谁决定？ —— run_turn 拿 needs_follow_up：
                      true  → loop continue（再调一次 LLM）
                      false → break，turn 结束
   ↓
何时被打断？ —— cancellation_token（用户取消）/ 错误不可重试 / token 超限触发自动 compact
   ↓
循环上限？ —— 没有“最大轮数”硬编码；靠 token_limit_reached + compaction + end_turn 协同
```

---

### 4. 关键源码点（5 个就够了）

#### 🔸 关键点 1：`run_turn` 的外层 loop

**位置**：`codex-rs/core/src/session/turn.rs:204`

```rust
loop {
    // 1) 把 UI 上排队的输入合进 history
    let pending_input = sess.input_queue.get_pending_input(...).await;

    // 2) 用整段历史构造采样输入
    let sampling_request_input = sess.clone_history().await.for_prompt(...);

    // 3) 调一次 LLM，等回结果
    match run_sampling_request(...).await {
        Ok(SamplingRequestResult { needs_follow_up, last_agent_message }) => {
            let needs_follow_up = needs_follow_up || has_pending_input;

            // 4) token 撑爆？自动 compact 之后继续
            if token_limit_reached && needs_follow_up {
                run_auto_compact(...).await?;
                continue;
            }

            // 5) 不需要 follow-up：跑 stop hook → 退出 loop
            if !needs_follow_up {
                break;
            }
            // 否则隐式 continue，再调一次 LLM
        }
        Err(...) => { /* 错误处理 */ }
    }
}
```

> 💡 **设计要点**
> - 这就是教科书里的 **ReAct 循环**：Reason（LLM 思考）→ Act（工具执行）→ Observe（结果入 history）→ Reason 再次。
> - 循环条件**不是计数器**，而是“模型还想不想继续”。
> - 用户中途追加的消息（`pending_input`）会**自然进入下一轮**——这是 Codex 比很多 Demo Agent 优雅的地方。

---

#### 🔸 关键点 2：`SamplingRequestResult` —— 循环的“出口结构”

**位置**：`codex-rs/core/src/session/turn.rs:1230`

```rust
#[derive(Debug)]
struct SamplingRequestResult {
    needs_follow_up: bool,         // 还要不要再来一轮？
    last_agent_message: Option<String>,  // 这一轮模型说的最终自然语言
}
```

> 💡 **设计要点**
> 整个循环“**要不要继续**”被压缩成一个布尔值 `needs_follow_up`。
> 这是非常优秀的解耦——上层不需要知道工具有没有被调用、模型说了什么，只需要看这一面“红绿灯”。

---

#### 🔸 关键点 3：`needs_follow_up` 是怎么被设成 `true` 的

**位置**：`codex-rs/core/src/session/turn.rs:1988` 和 `2125`

来源 1：**工具被调用**

```rust
let output_result = handle_output_item_done(&mut ctx, item, ...).await?;
if let Some(tool_future) = output_result.tool_future {
    in_flight.push_back(tool_future);   // 把工具丢进“在飞列表”
}
needs_follow_up |= output_result.needs_follow_up;   // ← 工具调用 ⇒ 必须再问一次模型
```

来源 2：**模型自己声明没说完**

```rust
ResponseEvent::Completed { token_usage, end_turn, .. } => {
    if let Some(false) = end_turn {
        needs_follow_up = true;   // ← Responses API 用 end_turn=false 显式要求继续
    }
    break Ok(SamplingRequestResult { needs_follow_up, last_agent_message });
}
```

> 💡 **设计要点**
> 终止判定有两条线：
> 1. **工具线**：只要模型这一轮发了 `FunctionCall`，就必须把结果回填后再问一次——否则模型永远拿不到“观察”。
> 2. **协议线**：服务端可以在 `Completed` 事件里用 `end_turn=false` 主动续单（适用于推理模型分段输出场景）。
> 二者**任意一条触发**，循环就继续。

---

#### 🔸 关键点 4：工具执行与结果回填

**位置**：`codex-rs/core/src/session/turn.rs:1982-1995`

```rust
if let Some(tool_future) = output_result.tool_future {
    in_flight.push_back(tool_future);   // 工具异步执行
}
```

工具执行完后，会产生 `ResponseInputItem`（也就是 FunctionCallOutput），**追加到 session history**。
下一轮 `run_turn` 调用 `sess.clone_history().await.for_prompt(...)` 时，**这条结果自动出现在 prompt 里**——这就是“工具结果回填上下文”的真相：

```
history (Vec<ResponseItem>):
  ┌──────────────────────────────┐
  │ user: 帮我看下 README.md     │
  │ assistant: <tool_call shell> │
  │ tool_output: <文件内容>      │ ← 回填在这里
  │ assistant: <tool_call ...>   │
  │ tool_output: ...             │
  │ assistant: 这里是 README 的总结… │ ← 最终自然语言
  └──────────────────────────────┘
```

> 💡 **设计要点**
> Codex **没有**单独的“tool result buffer”——所有观察都活在统一的 `history` 里，循环里反复 `clone_history` 重建 prompt。
> 这是一种**「单一事实来源（Single Source of Truth）」**的写法，对应 SOLID 中的 S 与 D 原则。

---

#### 🔸 关键点 5：循环如何被打断

**位置**：`codex-rs/core/src/session/turn.rs:1879-1883, 1888-1894`

```rust
let event = match stream.next()
    .or_cancel(&cancellation_token)   // ← 用户取消
    .await
{
    Ok(event) => event,
    Err(CancelErr::Cancelled) => break Err(CodexErr::TurnAborted),
};

let event = match event {
    Some(Ok(event)) => event,
    Some(Err(err)) => break Err(err),          // ← 流错误
    None => break Err(CodexErr::Stream(...)),  // ← 流提前关闭
};
```

更外层 `run_sampling_request` 还有一层**重试循环**（`turn.rs:1059`）：

```rust
let max_retries = turn_context.provider.info().stream_max_retries();
loop {
    match try_run_sampling_request(...).await {
        Ok(out) => return Ok(out),
        Err(CodexErr::ContextWindowExceeded) => { /* 上抛触发 compact */ }
        Err(CodexErr::UsageLimitReached(e))  => { /* 上抛 */ }
        Err(err) if !err.is_retryable() => return Err(err),
        Err(err) => handle_retryable_response_stream_error(...).await?,
    }
}
```

> 💡 **设计要点**
> 中断/重试是**分层处理**的：
> | 层级 | 谁处理 | 处理什么 |
> |------|--------|---------|
> | 流事件层 | `try_run_sampling_request` | 用户 Cancel、流错误 |
> | 单次采样层 | `run_sampling_request` | 网络可重试错误，最多 N 次 |
> | turn 层 | `run_turn` | token 超限 → 触发 `run_auto_compact` 后继续 |
>
> 这种“**洋葱式**”错误分层是工业级 Agent 的标配。

---

### 5. 设计思想总结（可迁移到任何 Agent 项目）

| 设计原则 | Codex 的体现 | 通用启示 |
|---------|-------------|---------|
| **单一职责** | `run_turn` 只管 ReAct 循环；`run_sampling_request` 只管一次采样；`try_run_sampling_request` 只管解析流 | 主循环不要又调模型又写历史又渲染 UI |
| **单一事实来源** | 工具结果与对话消息共用同一份 `history` | 不要给工具结果建“私有缓冲区” |
| **以数据驱动控制** | 出口结构 `SamplingRequestResult { needs_follow_up }` 决定是否继续 | 不要把“是否结束”散落在各处 |
| **分层错误处理** | 流层 / 采样层 / turn 层 各管自己的中断 | 一锅炖会让重试逻辑无法演进 |
| **协议外置终止信号** | `Completed { end_turn }` 让服务端可以主动续单 | 别只看 tool_calls 是否为空，留协议口子 |
| **取消优先于结果** | `or_cancel(&cancellation_token)` 包裹所有 await | Agent 必须**随时可被打断**——这是用户信任的来源 |

> 💡 **迁移视角**：
> - LangChain 的 `AgentExecutor.invoke` 等价于 `run_turn`；
> - Claude Code 的 “turn loop” 同样基于 `tool_use_block` 是否存在判断终止；
> - Cursor / OpenDevin 也是“流式接收 → 派工具 → 回填 → 再问”的同一套骨架。
> 一旦您看懂了 Codex 的 `run_turn`，**所有同类项目的主循环都长一个样**。

---

## 🔴 本课重点记忆

- 本课关键词：**ReAct 循环、tool_calls 判定、循环终止**。
- 主循环就在 `session/turn.rs::run_turn` 的那个 `loop {}` 里，**不要去别的地方找**。
- 终止条件 = `needs_follow_up == false`，而 `needs_follow_up` 来自两条线：**工具触发** 与 **协议 end_turn**。
- 工具结果是通过**追加进 history → 下一轮 clone_history**自然回填的，不靠特殊缓冲区。
- 中断、重试、compact 是**洋葱式**分层处理的。

---

## ✅ 学完本课后的自检问题

1. 这一层在 Agent 中解决什么问题？
2. 它属于 Model 侧还是 Harness 侧？为什么？
3. 它在一次完整 ReAct 循环中的位置在哪里？
4. 如果这一层失败，用户会看到什么现象？
5. Codex 的实现给其他 Agent 项目提供了什么设计启发？

> 蕾姆的小提醒：**至少能口述出 `run_turn` → `run_sampling_request` → `try_run_sampling_request` → `SamplingRequestResult.needs_follow_up` 这条链路**，这一课就算掌握了 ♡

---

📍 **下一步**：完成本课学习后，请进入 [`lesson-03-quiz.md`](./lesson-03-quiz.md) 做课后测试。

*(蕾姆轻轻提起裙角行礼)*
昴君，第三课已经把 Agent 的“心跳”剖给您看了。如果哪一处您觉得跳得不够清楚，蕾姆可以再为您细化某一节哦。
