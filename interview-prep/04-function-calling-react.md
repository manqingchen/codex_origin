# 04 · Function Calling / Tool Use / ReAct

> **面试考点 ④**：Function Calling / Tool Use / ReAct 深入使用。
>
> Codex 在 FC 闭环上完整且成熟；**关键差异**是它的 ReAct 走 OpenAI Responses API 原生 reasoning，**不是**自研的 `Thought/Action/Observation` 文本协议。后者需要单独补（见 [GAPS 缺口 6](./GAPS-codex-cannot-teach.md)）。

---

## 🎯 考点拆解

| 子项 | 核心问题 | Codex |
|------|---------|:---:|
| 1. Tool schema 定义与注入 | 工具怎么用 JSON Schema 描述、怎么塞进请求？ | 🟢 |
| 2. tool_calls 解析/分发/回填 | 模型输出的 tool_call 怎么变成执行、结果怎么回去？ | 🟢 |
| 3. ReAct 落地 | 思考-行动-观察循环怎么实现？ | 🟡（走原生） |

> 📖 呼应 [`../learning-notes/lesson-04-step-04-functioncall.md`](../learning-notes/lesson-04-step-04-functioncall.md) + [`lesson-03-agent-loop.md`](../learning-notes/lesson-03-agent-loop.md)。

---

## 🧩 逐子项精读

### 1. Tool schema 定义与注入 🟢

- **通用原理**：每个工具用 JSON Schema 描述（name/description/parameters/strict），随每次请求注入模型的 `tools` 字段；可选 strict 模式强制模型输出合法参数。
- **Codex 实现**：
  - `codex-rs/tools/src/tool_spec.rs:17` `enum ToolSpec` -- Function / Namespace / ToolSearch / ImageGeneration / WebSearch / Freeform，序列化为 OpenAI Responses API 的 tool JSON
  - `codex-rs/tools/src/responses_api.rs:26` `ResponsesApiTool` -- name/description/strict/defer_loading/parameters: JsonSchema
  - `codex-rs/core/src/client.rs:732` `create_tools_json_for_responses_api(&prompt.tools)` -- 注入请求
  - `codex-rs/core/src/client_common.rs:25` `Prompt.tools: Vec<ToolSpec>`
- **面试问答**：
  - Q：工具 schema 怎么定义？strict 模式可靠吗？
  - A：Codex 用 `ToolSpec` 枚举统一描述，序列化为 Responses API 的 tool JSON（含 JsonSchema 参数、namespace 分组 MCP 工具为 `mcp__server`）。注意 `strict=true` 时的参数校验在代码里标了 **TODO 未实现**（`responses_api.rs:29` 注释）--这是个可以主动指出的瑕疵点。

### 2. tool_calls 解析 / 分发 / 回填 🟢

- **通用原理**：模型流式输出 `tool_call` -> Agent 解析出 tool_name/args -> 异步执行 -> 结果（成功 payload / 失败 / 中止）回填进历史 -> 触发下一轮采样。这是 FC 的完整闭环。
- **Codex 实现**：
  - `core/src/tools/router.rs:96` `build_tool_call` -- 解析 `ResponseItem::FunctionCall`/`ToolSearchCall`/`CustomToolCall` -> `ToolCall{tool_name, call_id, payload}`
  - `core/src/tools/router.rs:170` `dispatch_tool_call_with_terminal_outcome` -- 按 tool_name 路由到 registry 中的 executor
  - `core/src/session/turn.rs:1774` `drain_in_flight` -> `record_conversation_items` -- 结果回填 transcript
  - `core/src/tools/parallel.rs:186` `failure_response` -- 失败/异常转 `FunctionCallOutput{success:false}` 回填
- **面试问答**：
  - Q：一个 tool_call 从产生到结果回填，完整链路是什么？
  - A：模型流式输出 tool_call -> `build_tool_call` 解析成 `ToolCall` -> spawn 异步执行 -> `router` 分发到注册的 handler -> 结果有三种 payload 形态（成功/失败/中止）-> 回填进 conversation history 供下一轮采样。`ToolSearchCall` 也有独立 payload 通道（配合 [03 的 Find Skills](./03-tool-orchestration.md)）。

### 3. ReAct 落地 🟡（走原生，非自研文本协议）

- **通用原理**：经典 ReAct = `Thought: ... \n Action: ... \n Observation: ...` 文本协议，Agent 用正则解析出 Action 执行，拼 Observation 再喂回模型，循环到模型不再输出 Action。
- **Codex 实现**：
  - `core/src/session/turn.rs:204` `run_turn` 主 `loop` -- 采样 -> 执行 tool -> `needs_follow_up` 决定继续/终止
  - `core/src/session/turn.rs:322` -- `!needs_follow_up` 时跑 stop hooks 后 `break`，否则 `continue` 下一轮
  - `core/src/session/turn.rs:2182` `ResponseEvent::ReasoningSummaryDelta` -- **reasoning 作为原生 item 流式回传**
- **关键差异**：Codex 把「思考」**外包给 OpenAI Responses API 的原生 reasoning items**（带 summary delta 流），「行动」= tool_call，「观察」= tool output 回填触发 `needs_follow_up`。**没有客户端侧的 `Thought/Action/Observation` 文本协议解析**，本地也不做 ReAct prompt 工程。
- **面试问答**：
  - Q：Codex 的 ReAct 是怎么实现的？
  - A：它走 **Responses API 原生形态**--思考 = 服务端 reasoning items（流式 delta），行动 = tool_call，观察 = tool output 回填后触发下一轮 `needs_follow_up`，由 `run_turn` 的 `loop` 驱动。**不依赖模型自发的 ReAct 文本协议**，省掉了不可靠的正则解析步骤。这其实是 ReAct 的现代化演进：模型直接输出结构化 tool_call，而非让你从自然语言里抠 Action。能讲清这个演进，比只会实现经典 ReAct 更显功力。
  - 追问「那经典 ReAct 文本协议你实现过吗？」-> 诚实答：Codex 没做这层，我另外手写过 50 行的经典版（见 [GAPS 缺口 6](./GAPS-codex-cannot-teach.md) 的动手任务）。

---

## 🛣️ 学习顺序（建议 2-3 天）

1. 读 [`lesson-04-step-04-functioncall.md`](../learning-notes/lesson-04-step-04-functioncall.md) 建立 FC 直觉。
2. 读 `tools/src/tool_spec.rs` + `responses_api.rs` 理解 schema。
3. 读 `core/src/tools/router.rs` 的 `build_tool_call` / `dispatch_tool_call_with_terminal_outcome` 理解解析分发。
4. 读 `core/src/session/turn.rs:204` 的 `run_turn` loop + `needs_follow_up`，理解 ReAct 循环终止。
5. 读 `ReasoningSummaryDelta` 处理，理解「原生 reasoning」形态。

---

## 🛠️ 动手任务

- [ ] 跑一个会触发多轮 tool_call 的任务，观察 `needs_follow_up` 如何在 tool output 后让 loop 继续。
- [ ] 看 `tools/src/responses_api.rs:29` 的 strict TODO，思考如果你来补会怎么做。
- [ ] （补缺口·必做）手写一个 50 行经典 ReAct Agent：prompt 引导模型输出 `Thought:/Action:/Observation:` -> 正则解析 Action -> 执行工具 -> 拼 Observation 回喂。详见 [GAPS 缺口 6](./GAPS-codex-cannot-teach.md)。

---

## ⚠️ 差异注意点

| 子项 | Codex | 业界对照 / 需补 |
|------|------|------|
| Tool schema | ToolSpec + JsonSchema，strict 校验未实现 | 标准 OpenAI tool calling |
| tool_call 闭环 | 完整（解析->分发->回填） | - |
| ReAct | **原生 reasoning**，非文本协议 | 经典 ReAct 文本协议（LangChain 老版 `ReActAgent`），需补（[GAPS 缺口 6](./GAPS-codex-cannot-teach.md)） |

> 💡 **面试加分点**：能讲清「Codex 用原生 reasoning + tool_call 是 ReAct 的现代化形态，省掉文本解析这一不可靠步骤」--这是把「读过源码」升级为「懂演进」的关键一跃。

---

*(蕾姆把函数调用的回环画成一个莫比乌斯环)*

昴君，思考、行动、观察--三者首尾相衔，便是 Agent 的呼吸。Codex 让模型直接吐出结构化的行动，省去了从文字里猜心思的麻烦，这正是它比老式 ReAct 高明的地方 ♡
