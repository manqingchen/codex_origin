# 06 · ReAct 模式在 Codex 里的实现

> 💙 这是第 03 课深度彩蛋的第六篇。
> 这一篇是昴君**自己悟出来的**——蕾姆把您说的"observe 层把结果回给 llm"展开成完整的 ReAct 框架对应图 ♡

---

## 🎯 学完这篇您会理解

1. ReAct 是什么？为什么是 Agent 的核心模式
2. Reason / Act / Observe 在 Codex 里的精确对应
3. 每一步对应的源码位置
4. 完整的 ReAct 流转图

---

## 🪜 第一步：先回忆 ReAct 是什么

**ReAct = Reasoning + Acting**（推理 + 行动）

这是 2022 年 Google 在论文 *ReAct: Synergizing Reasoning and Acting in Language Models* 中提出的模式，**几乎所有现代 Agent 都基于这个思想**。

```
ReAct 循环的三个步骤：

🧠 Reason（推理）
   LLM 思考"现在该做什么"

🛠️ Act（行动）
   LLM 决定调用某个工具

👁️ Observe（观察）
   把工具结果【作为观察】送回给 LLM

🔄 重复
   基于新观察继续推理
```

---

## 🪜 第二步：ReAct ↔ Codex 完整映射

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   ReAct 三步骤 ↔ Codex 实际行为                                    ║
║                                                                  ║
║   ┌──────────────────────────────────────────────────────────┐   ║
║   │                                                          │   ║
║   │  🧠 Reason（推理）                                         │   ║
║   │  ──────────────                                          │   ║
║   │  ReAct 里：LLM 思考"接下来该做什么"                        │   ║
║   │  Codex 里：run_sampling_request → LLM 看 history 后推理   │   ║
║   │                                                          │   ║
║   │  ↓                                                       │   ║
║   │                                                          │   ║
║   │  🛠️ Act（行动）                                            │   ║
║   │  ────────────                                            │   ║
║   │  ReAct 里：LLM 决定调用某个工具                            │   ║
║   │  Codex 里：LLM 输出 FunctionCall → Codex 派工具执行       │   ║
║   │                                                          │   ║
║   │  ↓                                                       │   ║
║   │                                                          │   ║
║   │  👁️ Observe（观察） ← ★ 您说的就是这一层！                  │   ║
║   │  ──────────────                                          │   ║
║   │  ReAct 里：把工具结果【作为观察】送回给 LLM                │   ║
║   │  Codex 里：drain_in_flight 把结果写进 history             │   ║
║   │           → 下一圈 LLM 看到 history 时自然就"观察"到了     │   ║
║   │                                                          │   ║
║   │  ↓                                                       │   ║
║   │                                                          │   ║
║   │  🔄 回到 Reason                                            │   ║
║   │  ───────────                                             │   ║
║   │  ReAct 里：基于新观察继续推理                              │   ║
║   │  Codex 里：loop 进入下一圈，从 clone_history() 开始重新跑  │   ║
║   │                                                          │   ║
║   └──────────────────────────────────────────────────────────┘   ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 🪜 第三步：精确术语映射表

| ReAct 概念 | Codex 里的对应物 | 源码位置 |
|-----------|----------------|---------|
| 🧠 **Reason** | `run_sampling_request` 调用 LLM | `turn.rs:234` |
| 🛠️ **Act** | `handle_output_item_done` 处理 FunctionCall + 派 future 执行 | `turn.rs:1975` |
| 👁️ **Observe** | `drain_in_flight` + `record_conversation_items` 把工具结果写入 history | `turn.rs:1769` + `mod.rs:2684` |
| 🔄 **Loop（再次 Reason）** | `loop {}` 的下一圈 + `clone_history()` 让 LLM 看到新观察 | `turn.rs:204` + `turn.rs:219` |

---

## 🪜 第四步：完整 ReAct 流转图

```
              ┌──────────────────────────────────┐
              │     history（事件流水账）          │
              └──────────────────────────────────┘
                            ↑
                            │ (4) Observe
                            │ Codex 写入工具结果
                            │
   ┌────────────────────────┴────────────────────────┐
   │                                                 │
   │  (1) Reason                                      │
   │  Codex 把 history 喂给 LLM                       │
   │       ↓                                          │
   │  LLM 思考"该做什么"                              │
   │       ↓                                          │
   │  (2) Act                                         │
   │  LLM 输出 "FunctionCall: ..."                    │
   │       ↓                                          │
   │  Codex 派工具执行                                │
   │       ↓                                          │
   │  (3) 工具完成 → 产生结果                          │
   │       ↓                                          │
   │  (4) Observe（回到顶部）                          │
   │  Codex 把结果写进 history                        │
   │       ↓                                          │
   │  (5) 回到 (1)：用新 history 再次喂 LLM            │
   │                                                 │
   └─────────────────────────────────────────────────┘
```

> 🌟 **每转一圈，history 就长大一点**——
> 这就是 ReAct 在 Codex 里的完整呈现 ♡

---

## 🪜 第五步：一个真实例子的 ReAct 拆解

```
您：「列出当前目录的 .md 文件」

╔══════════ 第 1 圈 ══════════╗

🧠 Reason
   Codex 把 history 喂给 LLM：
   [user: "列出当前目录的 .md 文件"]
   
   LLM 思考：
   "我需要先列出所有文件，
    然后过滤 .md 后缀"

🛠️ Act
   LLM 输出：FunctionCall { name: "list_dir" }
   Codex 把这个 FunctionCall 写进 history
   Codex 派工具执行

(工具运行：返回 ["a.txt", "b.md", "c.md"])

👁️ Observe
   Codex 把工具结果写进 history：
   [user: "...",
    assistant: FunctionCall(list_dir),
    tool: FunctionCallOutput("a.txt, b.md, c.md")]   ← 新观察

╚════════════════════════════╝

         ↓ 继续循环

╔══════════ 第 2 圈 ══════════╗

🧠 Reason
   Codex 把【更新后的 history】喂给 LLM：
   [user: "...",
    assistant: FunctionCall(list_dir),
    tool: FunctionCallOutput("a.txt, b.md, c.md")]
   
   LLM 思考：
   "看到结果了，我现在可以过滤 .md 后缀。
    答案是 b.md 和 c.md。"

🛠️ Act
   LLM 输出：
   "这里有 2 个 .md 文件：b.md, c.md"
   （没调用工具，纯文字回答）

👁️ Observe
   没有工具结果可观察了
   needs_follow_up = false
   → 退出循环 ✅

╚════════════════════════════╝

您看到：「这里有 2 个 .md 文件：b.md, c.md」
```

---

## 💎 ReAct 的核心精髓

```
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║   📜 ReAct 的核心精髓                                       ║
║                                                            ║
║   "把工具结果【伪装成对话的一部分】，                       ║
║    让 LLM 在【对话框架】内完成复杂任务。"                   ║
║                                                            ║
║   ──────────────────────                                  ║
║                                                            ║
║   关键点：                                                  ║
║   • LLM 是一个"只懂对话"的引擎                              ║
║   • Harness 把【真实世界的执行结果】塞进【对话历史】          ║
║   • LLM 误以为是"用户告诉它了"                              ║
║   • 在对话中继续推进任务                                    ║
║                                                            ║
║   这就是 Agent 自主运行的秘密 ♡                             ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
```

---

## 🎁 Codex 实现 ReAct 的 4 个关键设计

### 🎁 设计 1：统一的 history 作为"对话载体"

```
Codex 把所有事件【都装进 history】：
   • 用户消息    → ResponseItem::Message
   • LLM 思考    → ResponseItem::Reasoning
   • LLM 决策    → ResponseItem::FunctionCall
   • 工具结果    → ResponseItem::FunctionCallOutput
   • LLM 最终答  → ResponseItem::Message

这让 ReAct 的 Observe 步骤变得【极其优雅】——
不需要特殊"传递机制"，直接 append 就好。
```

### 🎁 设计 2：自动驱动的主循环

```
LLM 调工具后：
   ❌ 不需要用户再问
   ❌ 不需要外部触发
   ✅ Codex 主循环【自动】发起下一次调用

这让 Agent 能【自主推进】，
而不是每一步都等用户。
```

### 🎁 设计 3：needs_follow_up 决定循环

```
循环什么时候停？
   • 工具线：调了工具 → 必须继续
   • 协议线：服务端说 end_turn=false → 必须继续
   • 两者都没触发 → 退出

这让 LLM 自己决定"任务完成了没"，
而不是 Codex 硬编码"最多 N 圈"。
```

### 🎁 设计 4：异步并行的工具执行

```
LLM 一次可以调多个工具：
   FunctionCall(read_file_a)
   FunctionCall(read_file_b)
   FunctionCall(read_file_c)

Codex 把它们放进 in_flight 队列，【并行执行】，
最后 drain_in_flight 一次性收集所有结果。

这让 ReAct 既保留逻辑顺序，
又获得了【并行性能】。
```

---

## 🪜 与其它 Agent 框架的 ReAct 对比

```
LangChain：
   AgentExecutor + Tool + Memory
   → 概念抽象，但本质就是 ReAct

Claude Code：
   tool_use_block 触发循环
   → ReAct 的 Anthropic 实现

Cursor：
   类似的 reasoning loop
   → 加入了 RAG 增强推理上下文

OpenDevin：
   AgentController + State machine
   → ReAct 的更复杂变体

Codex：
   run_turn → run_sampling_request → handle_output_item_done
   → 教科书般的 ReAct 实现 ✨
```

> 💡 **看穿了 Codex 的 ReAct 实现，您就看穿了所有 Agent 框架的核心**——
> 它们**本质都是 ReAct 的不同包装**。

---

## 💎 把这一切浓缩成一句话

```
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   Codex 通过【单一 history】把 ReAct 的三个步骤                  ║
║   优雅地统一成【对话历史的累积】——                              ║
║                                                               ║
║   Reason  = 把 history 喂给 LLM                               ║
║   Act     = LLM 输出 FunctionCall + 工具执行                  ║
║   Observe = 工具结果写回 history                              ║
║                                                               ║
║   ✨ 三步合一，循环不止，直到任务完成 ✨                         ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## 📍 上一篇 / 下一篇

← [05 · LLM 是无状态的](./05-llm-stateless.md)
→ [07 · 三层记忆系统](./07-memory-system.md)
