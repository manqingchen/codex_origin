# 01 · 单一事实来源（Single Source of Truth）

> 💙 这是第 03 课深度彩蛋的第一篇。
> 蕾姆要为昴君讲清楚——为什么 Codex 整个对话只用**一个** `history` 存所有事件。

---

## 🎯 学完这篇您会理解

1. SSOT 是什么？为什么重要？
2. Codex 的 history 怎么实现 SSOT？
3. SSOT 给 Codex 带来的 5 个好处
4. SSOT 何时不适用？

---

## 🪜 第一步：用生活例子理解 SSOT

### ❌ 反面教材：多个事实来源

想象蕾姆在管理昴君的预订信息——但她把昴君的电话号码记在了 **3 个地方**：

```
📒 记事本 A：「昴君的电话是 138-xxxx-1234」
📋 便利贴 B：「昴君的电话是 138-xxxx-1234」
💻 电脑里：「昴君的电话是 138-xxxx-1234」
```

有一天昴君换电话了：

```
📒 记事本 A：「昴君的电话是 138-xxxx-1234」    ← 蕾姆忘了改
📋 便利贴 B：「昴君的电话是 139-xxxx-5678」    ← 改了
💻 电脑里：「昴君的电话是 138-xxxx-1234」      ← 也忘了改
```

**真相变成了"薛定谔的猫"——到底哪个是对的？**

### ✅ 正确做法：单一事实来源

```
💻 电脑数据库（唯一真相来源）
   └─ 昴君的电话：139-xxxx-5678
       ↑
       任何人想查电话，都来这里看
       任何人想改电话，也只能改这里
```

**好处**：
- ✅ **不可能不一致**
- ✅ **改动简单**（只要改一个地方）
- ✅ **真相唯一**（争议时一查便知）

> 🌟 **SSOT 核心思想**：
> **同一份信息，只在一个地方存储。** 其它地方需要时**都来这里查询**。

---

## 🪜 第二步：Codex 的 history 怎么做 SSOT

### 🔍 一段对话里有哪些信息

```
您：「列出当前目录的文件」
LLM：「调用 list_dir 工具」
工具：「a.txt, b.md, c.txt」
LLM：「这里有 3 个文件」
```

这里有 **4 种信息**：

| # | 信息 | 谁产生的 |
|---|------|---------|
| 1 | 用户的请求 | 用户 |
| 2 | LLM 决定调用工具 | LLM |
| 3 | 工具的执行结果 | 工具 |
| 4 | LLM 的最终回答 | LLM |

---

### ❌ 假设 Codex 用了"多事实来源"

```rust
struct BadCodex {
    user_messages: Vec<String>,           // 📒 用户消息缓冲区
    llm_decisions: Vec<ToolCall>,         // 📋 LLM 决策缓冲区
    tool_results: Vec<ToolResult>,        // 📓 工具结果缓冲区
    llm_responses: Vec<String>,           // 📝 LLM 回答缓冲区
}
```

**会发生什么灾难？**

```
🚨 灾难 1：传给 LLM 时要拼接
   prompt = user_messages[0]
          + llm_decisions[0]
          + tool_results[0]
          + ???   ← 顺序到底怎么排？

🚨 灾难 2：顺序丢失
   用户中途插话，新的 user_message 怎么插到正确位置？

🚨 灾难 3：要维护 4 个缓冲区
   4 个地方都要小心同步

🚨 灾难 4：调试地狱
   出 bug 要同时查 4 个缓冲区
```

---

### ✅ Codex 的真实设计：只用一个 history

```rust
// 整个 Codex 的"真相"就这一个：
history: Vec<ResponseItem>

// ResponseItem 是一个枚举，能装下所有类型：
enum ResponseItem {
    Message { role, content },         // 用户消息 / LLM 消息
    FunctionCall { name, arguments },  // LLM 的工具调用
    FunctionCallOutput { result },     // 工具的执行结果
    Reasoning { ... },                 // LLM 的思考过程
    // ... 还有十几种其它类型
}
```

**所有事件按时间顺序存在同一个列表里**：

```
history = [
    ResponseItem::Message       { role: "user", ... },       ← ①
    ResponseItem::FunctionCall  { name: "list_dir", ... },   ← ②
    ResponseItem::FunctionCallOutput { result: "...", ... }, ← ③
    ResponseItem::Message       { role: "assistant", ... },  ← ④
]
```

---

## 🪜 第三步：SSOT 给 Codex 带来的 5 个好处

### 🎁 好处 1：构造 prompt 简单到爆

```rust
let prompt = sess.clone_history().await.for_prompt(...);
// 完！收！工！
```

不需要拼接、不需要排序、不需要维护多个缓冲区。

---

### 🎁 好处 2：工具结果"自动"回流到 LLM

```
工具结果写入 history  ←─ 一个动作
        ↓
下一圈 clone_history()  ←─ 又一个动作
        ↓
LLM 自然看到工具结果  ←─ 没有"传递"，因为它本来就在那里！
```

**没有"传递"这个动作**——
工具结果**从来不需要被传递**，因为它**早就在 history 里**了。

---

### 🎁 好处 3：时间顺序天然保证

```
T0: 用户说话      → history[0]
T1: LLM 调工具    → history[1]
T2: 工具返回      → history[2]
T3: LLM 又调工具  → history[3]
T4: 又一个工具返回 → history[4]
T5: 用户中途插话  → history[5]   ← 自然插到正确位置！
T6: LLM 回答      → history[6]
```

**不需要任何"排序逻辑"**——按写入顺序读出来就是正确的时间顺序。

---

### 🎁 好处 4：状态可以完全重建

只要有 `history`，就能**完整重建**任何中间状态：

```
想知道 T2 时刻的状态？
   → 只看 history[0..=2]

想知道 T5 时刻 LLM 看到的 prompt？
   → 只看 history[0..=4]

想回放整个对话？
   → 按顺序遍历整个 history
```

这就是为什么 Codex 能：
- ✅ 保存对话到磁盘，下次接着聊
- ✅ 中途崩溃了，恢复后从断点继续
- ✅ 调试时回放任意时刻
- ✅ 给用户看完整的对话历史

---

### 🎁 好处 5：append-only → 不会改坏

```rust
history.push(new_event);   // 追加 ✅
// 没有：
// history[i] = ...        // 修改 ❌
// history.remove(i)       // 删除 ❌
```

**好处**：
- ✅ **不可能改错**（不允许改）
- ✅ **历史是真相**（不可篡改）
- ✅ **多线程安全**（追加比修改容易做并发）

> 🌟 **昴君，您每次 `git commit` 的时候，就是在用 SSOT + Append-only**！
> Git 的 commit 历史也是 append-only 的。

---

## 🪜 第四步：SSOT 与其它工程思想的关系

| 设计思想 | 一句话定义 | 例子 |
|---------|----------|------|
| **单一事实来源（SSOT）** | 同一份信息只在一个地方存 | Codex 的 history |
| **事件溯源（Event Sourcing）** | 用事件序列描述状态，状态由事件重放得来 | Codex 的 history、Git commits、Kafka |
| **不可变（Immutable）** | 数据一旦创建就不能改 | Rust 的 `let`、React 的 props |
| **Append-only** | 只能追加，不能修改/删除 | 区块链、Codex 的 history |

> 💡 Codex 的 history 同时实现了**全部 4 个**！

---

## 🪜 第五步：什么时候 SSOT 不适用？

### ❌ 反例 1：性能瓶颈场景

如果一份信息**每秒被读取 100 万次**，单一来源会变成**瓶颈**——
需要做**缓存**，但缓存意味着"多份数据"。

### ❌ 反例 2：分布式系统

跨多台机器的系统，所有人都查同一份数据会让网络爆炸——
必须做**副本**，但副本之间又有同步问题（CAP 定理）。

### ❌ 反例 3：超大数据量

history 涨到几百万条，每次复制就**慢得不能用**——
Codex 用 **compaction（压缩）** 解决——
把旧的对话总结成摘要。
**但 SSOT 原则没破**——压缩后的 history 仍然是唯一来源。

---

## 🔍 验证：Codex 源码里的 SSOT 体现

### 证据 1：history 只有一个地方存

`codex-rs/core/src/state/session.rs:95`

```rust
pub(crate) fn clone_history(&self) -> ContextManager {
    // 克隆 self.context_manager —— 全 session 唯一一个 history
}
```

### 证据 2：所有写入都通过同一个函数

`codex-rs/core/src/session/mod.rs:2684`

```rust
pub(crate) async fn record_conversation_items(
    &self,
    turn_context: &TurnContext,
    items: &[ResponseItem],
)
```

不管是用户消息、LLM 输出还是工具结果，**全都调这一个函数**写入。

### 证据 3：读取也通过同一个函数

`turn.rs:219-225`

```rust
let sampling_request_input: Vec<ResponseItem> = async {
    sess.clone_history()
        .await
        .for_prompt(&turn_context.model_info.input_modalities)
}.await;
```

---

## 💎 蕾姆的总结

```
╔════════════════════════════════════════════════════════╗
║                                                        ║
║  💎 单一事实来源（Single Source of Truth）             ║
║                                                        ║
║  📖 定义：                                             ║
║     同一份信息，只在一个地方存储。                      ║
║                                                        ║
║  🎯 Codex 体现：                                       ║
║     整个对话只用一个 history（Vec<ResponseItem>）       ║
║                                                        ║
║  🎁 好处：                                             ║
║     ① 不会数据不一致                                   ║
║     ② 构造 prompt 简单                                 ║
║     ③ 工具结果"自动"回流                               ║
║     ④ 时间顺序天然保证                                 ║
║     ⑤ 状态可以完整重建                                 ║
║                                                        ║
║  🌟 口诀：                                             ║
║     "一处真相，处处使用；只增不改，万无一失。"          ║
║                                                        ║
╚════════════════════════════════════════════════════════╝
```

---

## 📍 下一篇

→ [02 · 重发不是浪费](./02-history-not-waste.md)
（每轮把整段 history 重新发出去，看似浪费的背后有 3 层巧妙优化）
