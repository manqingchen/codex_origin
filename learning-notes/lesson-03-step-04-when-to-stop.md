# 第03课 · 台阶 4：循环什么时候停？（needs_follow_up 的两条真相）

> 💙 **蕾姆的承诺**
>
> 这一份文档要为昴君揭开一个**小秘密**——
> 您之前以为 `needs_follow_up` 只有一条规则（"调用了工具就 true"），
> 其实蕾姆**藏了一半真相** ♡ 这次要全部告诉您。
>
> 依然不需要懂 Rust 语法，依然每行都翻译成中文。
> 但这一阶**比之前略硬**，蕾姆会慢慢拆。

---

## 🎯 这一台阶要达成的目标

学完这一份文档，昴君应该能回答：

> 「`needs_follow_up` 这个开关，到底**在什么时候**、**由谁**、**根据什么**，被设成 true 或 false？」

---

## 🪜 第一步：先回忆 `needs_follow_up` 是什么

在台阶 2 和 3 里，蕾姆告诉过您：

```
needs_follow_up = true   →  循环继续（再问 LLM 一次）
needs_follow_up = false  →  循环结束（把答案给老板）
```

它就是**循环的红绿灯**：

```
        ┌──────────────────┐
        │  LLM 给出回答     │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ needs_follow_up = ? │  ← 这一阶要搞清楚！
        └────────┬─────────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
      true              false
        │                 │
        ▼                 ▼
   再问 LLM 一次     退出循环
```

---

## 🪜 第二步：揭开真相——`needs_follow_up` 有两条来源

```
                ┌─────────────────────────────┐
                │   needs_follow_up = true ?   │
                └──────────────┬──────────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                  ▼
  ┌──────────────────────┐         ┌──────────────────────────┐
  │  🛠️ 真相 1：工具线    │         │  📡 真相 2：协议线        │
  │                      │         │                          │
  │  LLM 这一轮          │         │  LLM 在收尾事件里         │
  │  调用了工具吗？      │   或    │  说"end_turn = false"吗？│
  │                      │         │                          │
  │  调用了 → true       │         │  说了 → true              │
  └──────────────────────┘         └──────────────────────────┘
              │                                  │
              └────────────────┬────────────────┘
                               │
                       任意一条触发
                               │
                               ▼
                  needs_follow_up = true
                  （循环继续）
```

> 🌟 **关键认识**：
> 这两条是**"OR" 关系**——只要任意一条被触发，循环就继续。
> 两条都没触发，循环才停止。

---

## 🪜 第三步：真相 1 · 工具线

### 🔍 源码位置

**`codex-rs/core/src/session/turn.rs:1988`**

```rust
needs_follow_up |= output_result.needs_follow_up;
```

### 🔤 这一行的翻译

| 符号 | 意思 |
|------|------|
| `|=` | "**或等于**"（如果右边是 true，就把左边设为 true；否则保持不变） |
| `output_result.needs_follow_up` | "工具调用产生的结果说还要继续吗？" |

**整句翻译**：

> 「**如果工具被调用了，把 needs_follow_up 设为 true。**」

> 💡 **`|=` 的特殊含义**：
> 这不是普通的 "等于"——它是**"一旦被设为 true，就永远是 true"**。
> 比喻：像一个**只能进不能出的开关**。一旦哪一个工具说"要继续"，整轮就锁定 `true`。

---

### 📖 生活化解释

```
LLM 在这一轮里：

如果说了「请调用 read_file 工具」
   ↓
   handle_output_item_done(...) 处理这条 tool_call
   ↓
   返回 output_result.needs_follow_up = true
   ↓ 
   needs_follow_up |= true   →  needs_follow_up = true ✅

如果同时还说了「请调用 write_file 工具」
   ↓
   也返回 needs_follow_up = true
   ↓
   needs_follow_up |= true   →  依然 true ✅

如果一个工具都没调用
   ↓
   不进 OutputItemDone 这条分支
   ↓
   needs_follow_up 保持初始值 false
```

> 🌟 **为什么"叫了工具就必须再转一圈"？**
>
> 这点蕾姆在台阶 2 解释过——
> LLM 叫工具时**只说了"请去做"，还没看到结果**。
> 必须把工具结果回填给 LLM，让它**根据观察**再思考一次。
> 不然工具结果就白费了。

---

## 🪜 第四步：真相 2 · 协议线 ⭐ 之前没讲过的部分

### 🔍 源码位置

**`codex-rs/core/src/session/turn.rs:2124-2126`**

```rust
if let Some(false) = end_turn {
    needs_follow_up = true;
}
```

### 🔤 这两行的翻译

| 符号/词 | 意思 |
|--------|------|
| `end_turn` | "**这次 turn 应该结束吗？**"（来自服务器的暗号） |
| `Some(false)` | "服务器**明确**说了 false（不要结束）" |
| `if let Some(false) = end_turn` | "如果服务器明确说 false" |
| `needs_follow_up = true` | "那就强制再转一圈" |

**整段翻译**：

> 「**如果服务器在收尾事件里明确说"end_turn = false"（这次 turn 还没结束），那就把 needs_follow_up 设为 true，强制再转一圈。**」

---

### 📖 生活化解释

> 💡 **什么是 `end_turn`？**
>
> 这是**LLM 服务器主动发送的一个"暗号"**，藏在每次 LLM 思考结束的事件里。
>
> 想象一下：
> ```
> LLM 厨师做菜做了一半，给蕾姆传话：
>
>   情况 A：「这道菜还没做完，我需要再让我做一会儿。」
>          ↓
>          end_turn = false   →  needs_follow_up = true（继续）
>
>   情况 B：「这道菜做完了。」
>          ↓
>          end_turn = true（或没说）  →  没有影响（看真相 1）
> ```

---

### ❓ 为什么需要"协议线"？工具线还不够吗？

**好问题！** 蕾姆来举例说明：

#### 场景：推理模型的"分段思考"

某些 LLM（比如 OpenAI 的 o1 系列）**思考太长**时，会**分段输出**：

```
LLM：（思考 30 秒）「我需要先分析一下问题的结构...」
     ↓
     【服务器发送收尾事件】
     end_turn = false  ←  暗号：我还没说完！

LLM：（再思考 30 秒）「现在我得出结论是...」
     ↓
     【服务器发送收尾事件】
     end_turn = true   ←  暗号：好了，说完了
```

这种情况下，LLM **完全没调用工具**，但**还要继续思考**。
工具线（真相 1）完全不会触发，**只能靠协议线（真相 2）告诉 Codex 别停**。

> 🌟 **关键认识**：
> 工具线 = "**LLM 主动说'我要用工具'**"（显式）
> 协议线 = "**服务器替 LLM 说'让它再想一会儿'**"（隐式）
> 二者**互补**，少一条都不行。

---

## 🪜 第五步：把两条线合起来看

蕾姆把整个判断逻辑画成一张完整的图：

```
╔════════════════════════════════════════════════════════╗
║      try_run_sampling_request 内部状态机                ║
╠════════════════════════════════════════════════════════╣
║                                                        ║
║   开始时：needs_follow_up = false                       ║
║                                                        ║
║   每收到一个 LLM 事件：                                  ║
║                                                        ║
║   ┌─────────────────────────────────────────────┐      ║
║   │ ResponseEvent::OutputItemDone(工具调用项)    │      ║
║   │   → needs_follow_up |= true                  │      ║
║   │   （工具线）                                  │      ║
║   └─────────────────────────────────────────────┘      ║
║                                                        ║
║   ┌─────────────────────────────────────────────┐      ║
║   │ ResponseEvent::Completed { end_turn }       │      ║
║   │   if end_turn == Some(false):                │      ║
║   │       needs_follow_up = true                 │      ║
║   │   （协议线）                                  │      ║
║   │   然后 break，返回 SamplingRequestResult     │      ║
║   └─────────────────────────────────────────────┘      ║
║                                                        ║
║   最终返回时：                                          ║
║       SamplingRequestResult {                          ║
║           needs_follow_up,   ← 此时的值                 ║
║           last_agent_message,                          ║
║       }                                                ║
║                                                        ║
╚════════════════════════════════════════════════════════╝
```

---

## 🪜 第六步：还有一条"隐藏的护栏"

*(蕾姆悄悄凑近)*

昴君，蕾姆还要告诉您一个**第三条线**——
不是判断"是否继续"，而是**强制结束**或**强制再转一圈**的护栏。

### 🛡️ 护栏 1：用户取消（cancellation_token）

**位置**：`turn.rs:1879-1883`

```rust
let event = match stream.next()
    .or_cancel(&cancellation_token)
    .await
{
    Ok(event) => event,
    Err(CancelErr::Cancelled) => break Err(CodexErr::TurnAborted),
};
```

**翻译**：

> 「每等一个 LLM 事件，都顺便检查"用户按 Ctrl+C 了吗？"——
> 如果取消了，**立刻 break**，循环结束。」

这就是台阶 2 您直觉到的"护栏"——但护栏不是计数器，而是**用户的取消信号**！

---

### 🛡️ 护栏 2：token 撑爆 → 自动压缩 → 继续

**位置**：`turn.rs:302-320`（在 `run_turn` 的外层循环里）

```rust
if token_limit_reached && needs_follow_up {
    run_auto_compact(...).await?;
    can_drain_pending_input = !model_needs_follow_up;
    continue;
}
```

**翻译**：

> 「**如果上下文 token 撑爆了，并且还想继续——
> 先做一次自动压缩（把长历史浓缩成短摘要），然后 continue 重新来一轮。**」

> 💡 **昴君在台阶 2 末尾猜的"循环阈值"**：
> 现在揭晓——Codex 的"阈值"不是**循环次数**，而是 **token 用量**！
> 超过 token 上限不是直接报错，而是**自动压缩历史**继续干 ♡

---

### 🛡️ 护栏 3：LLM 调用失败 → 重试 → 放弃

**位置**：`turn.rs:1056-1118`（`run_sampling_request` 的内层重试循环）

```rust
let max_retries = turn_context.provider.info().stream_max_retries();
loop {
    match try_run_sampling_request(...).await {
        Ok(out) => return Ok(out),
        Err(err) if !err.is_retryable() => return Err(err),
        Err(err) => handle_retryable_response_stream_error(
            &mut retries, max_retries, err, ...
        ).await?,
    }
}
```

**翻译**：

> 「**调 LLM 失败了？**
> - 如果是可重试的错误（网络抖动、超时） → 等一下再试，最多 `max_retries` 次
> - 如果是不可重试（鉴权失败、上下文超限） → 立刻报错退出
>
> **重试次数用完？** → 把错误抛上去，由更外层处理。」

---

## 🪜 第七步：把所有"循环控制"都摆出来

蕾姆做一张**终极汇总表**：

| # | 类型 | 信号源 | 行为 | 源码位置 |
|---|------|--------|------|---------|
| 1 | 🛠️ 工具线 | LLM 调用了 `tool_call` | `needs_follow_up = true` | `turn.rs:1988` |
| 2 | 📡 协议线 | 服务器发 `end_turn = false` | `needs_follow_up = true` | `turn.rs:2124` |
| 3 | 🛡️ 取消令牌 | 用户 Ctrl+C | `break Err(TurnAborted)` | `turn.rs:1879` |
| 4 | 🗜️ Token 超限 | `token_limit_reached` | 自动压缩 + `continue` | `turn.rs:302` |
| 5 | 🔁 LLM 失败 | 可重试的网络错误 | 重试 `max_retries` 次 | `turn.rs:1107` |
| 6 | ❌ LLM 失败 | 不可重试错误 | 立即报错退出 | `turn.rs:1103` |
| 7 | ✅ 正常结束 | 工具线 + 协议线都是 false | `break;` 退出 `loop {}` | `turn.rs:353` |

> 🌟 **请昴君看清楚**：
> - **进入下一圈** 的方式有 4 种（#1, #2, #4, #5）
> - **退出循环** 的方式有 3 种（#3, #6, #7）

---

## 🪜 第八步：终极对照表（生活语言 ↔ 真代码）

| 蕾姆的生活解释 | 对应代码 | 行号 |
|--------------|---------|------|
| 厨师说"调用工具" → 要继续 | `needs_follow_up |= output_result.needs_follow_up` | 1988 |
| 厨师说"我还没想完" → 要继续 | `if let Some(false) = end_turn` | 2124 |
| 客人按 Ctrl+C → 立刻停 | `.or_cancel(&cancellation_token).await` | 1879 |
| 笔记本写满了 → 浓缩一下接着写 | `run_auto_compact(...).await` | 303 |
| 电话打不通 → 重拨几次 | `handle_retryable_response_stream_error(...)` | 1107 |
| 一切顺利，菜也做完了 → 上菜 | `if !needs_follow_up { break; }` | 322 |

---

## ✅ 这一台阶的"通关标准"

请昴君试着回答下面 3 个问题：

### 🎯 通关题 1
> **`needs_follow_up` 可以被设成 `true` 的途径有几条？分别是什么？**

参考答案：**两条**——
1. 🛠️ **工具线**：LLM 调用了 tool_call（`needs_follow_up |= true`）
2. 📡 **协议线**：服务器发来 `end_turn = false`

---

### 🎯 通关题 2
> **如果 LLM 一个工具都没调用，但 `end_turn = false`，循环会怎样？**

参考答案：**会继续转一圈**。
因为协议线已经触发，`needs_follow_up = true`。
（这就是推理模型分段思考时的典型场景。）

---

### 🎯 通关题 3
> **昴君在台阶 2 末尾猜过"应该有一个循环阈值"——这个直觉对吗？Codex 真实的"阈值"是什么？**

参考答案：**直觉是对的**！但 Codex 的护栏**不是循环次数**，而是：
1. **Token 用量**（超过就压缩历史继续）
2. **用户取消**（Ctrl+C 立刻停）
3. **重试次数**（LLM 调用失败最多重试 N 次）

这是**资源型护栏**，比"计数型护栏"更灵活 ♡

---

## 🤔 蕾姆的小问题

请昴君想象下面的场景，然后告诉蕾姆答案：

### 场景 A
```
您：「帮我列出当前目录的所有文件」

LLM：（决定调用 list_dir 工具）
     工具：「文件列表：a.txt, b.txt, c.txt」
LLM：（看到结果）「这里有 3 个文件：a.txt, b.txt, c.txt。」
     end_turn = true（默认值）
```

**问题**：循环转了几圈？最后一圈的 `needs_follow_up` 是？

第一圈 llm需要调用(list_dir)工具 第二圈(看到结果后返回end_turn)  needs_follow_up 是false
---

### 场景 B
```
您：「写一段非常深入的分析」

（推理模型分段思考）
LLM：「让我先分析一下问题..."
     end_turn = false  ← 服务器说还没说完
LLM：「考虑到 xxx，我认为..."
     end_turn = false  ← 还没说完
LLM：「最终结论是：xxx。」
     end_turn = true   ← 这次真的说完了
```

**问题**：循环转了几圈？为什么 LLM 一个工具都没调用，循环也转了 3 圈？
3圈 因为llm一直在持续输出 这时整个harness 以 end_turn 作为判断标准 所以是3圈
---

## 📍 下一步

- **当前位置**：🪜 台阶 4（needs_follow_up 的两条真相 + 三条护栏）✨ 您在这里
- **下一站**：🪜 台阶 5（工具结果怎么回来？一张数据流图）
- **整体路径**：
  ```
  台阶 1 ✅ 用对话游戏理解 ReAct
    ↓
  台阶 2 ✅ 一张图看懂循环（伪代码）
    ↓
  台阶 3 ✅ 找到主循环在源码哪一行
    ↓
  台阶 4 ✨ 您在这里（needs_follow_up 的真相）
    ↓
  台阶 5  工具结果怎么回来？（数据流图）
  ```

---

## 💙 蕾姆的小总结

到现在为止，昴君已经掌握的"循环知识"：

```
✅ 循环是什么                  （台阶 1）
✅ 循环骨架长什么样             （台阶 2）
✅ 循环在源码哪一行             （台阶 3）
✅ 循环什么时候停 / 什么时候继续 （台阶 4 · 您刚通关！）
⏳ 循环里的"数据"怎么流转       （台阶 5）
```

剩下**最后一步**——把数据流串起来，就能完整理解 Agent 主循环了 ♡

*(蕾姆轻轻提起裙角行礼)*

昴君，答完那两个小场景题，咱们就进入**最后一阶台阶 5**！
那时候，整张 Codex 心脏的拼图就完整了 ✨💙
