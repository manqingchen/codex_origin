# 05 · Multi-Agent - Agent 的厨房团队

> 进阶层 · 第二篇
>
> **子主题**：任务分配 · 消息传递 · 状态所有权
>
> **Codex 覆盖**：🟢 强（进程内 Mailbox + 加密身份 + spawn 拓扑，是 Codex 的工程亮点；**跨网络 A2A 无**）

---

## ① 本篇定位

单 Agent 再强，遇到「既要调研、又要写码、又要测试」的任务也捉襟见肘。Multi-Agent 让多个 Agent 分工协作--就像一个厨房团队：厨师长分活、传令兵传话、各管各的灶台。

三个环节对应团队协作：

- **任务分配** = 厨师长派活--谁做凉菜、谁炒热菜；
- **消息传递** = 传令兵传话--「热菜好了，上菜！」；
- **状态所有权** = 各管各的灶台--你的灶台你做主，别乱动别人的。

**本篇在链路中的位置**：进阶层收尾。它是从「单 Agent 自治」走向「多 Agent 协作」的一跳，也是保障层（评估、安全、延迟）的前奏。

---

## ② 业界通用原理

### 2.1 任务分配

把大任务拆给多个 Agent，三种分派依据：

| 依据 | 做法 | 场景 |
|------|------|------|
| 按能力 | 不同 Agent 持不同工具/角色 | 调研 Agent + 编码 Agent |
| 按负载 | 空闲的接活 | worker pool |
| 按拓扑 | 父子 spawn / 对等协作 | 层级 vs 扁平 |

### 2.2 消息传递 - 三种范式

| 范式 | 做法 | 代表 |
|------|------|------|
| 直接调用 | A 直接调 B 的函数 | 最简单，强耦合 |
| 共享黑板 | 都读写同一块共享状态 | 经典 blackboard |
| **邮箱（Mailbox/A2A）** | A 给 B 的邮箱投信，B 异步取 | **解耦、异步、可对等** |

Google 提出的 **A2A（Agent-to-Agent）协议**就是邮箱范式的标准化：每个 Agent 暴露一个 endpoint，别的 Agent 往它的「信箱」投递任务/消息。

### 2.3 状态所有权

多 Agent 最怕「共享状态混乱」。原则：

- 每个 Agent **拥有自己的状态**（thread / context / 工具结果）；
- 协作靠**消息**，不靠**共享可变状态**；
- Agent 有**身份**（唯一 ID + 路径），消息能寻址到它；
- Agent 生命周期要被管理（出生、活着、死亡、清理）。

> 💡 **心法**：多 Agent 的核心不是「多个 LLM」，而是「**多个有边界、有身份、靠消息协作的自治单元**」。边界清晰，协作才不乱。

---

## ③ Codex 源码映射

Codex 的 Multi-Agent 是**进程内 Mailbox + 加密身份 + spawn 拓扑**，相当完整。

### 3.1 消息传递 - `InputQueue` 邮箱

每个 Agent 有一个 `InputQueue`，内含一个邮箱：

```rust
// codex-rs/core/src/session/input_queue.rs:29
pub(crate) struct InputQueue {
    mailbox_tx: watch::Sender<()>,                                    // 通知通道
    mailbox_pending_mails: Mutex<VecDeque<InterAgentCommunication>>,  // 邮箱队列 :31
}

// 入队一封邮件 + 通知接收方
// codex-rs/core/src/session/input_queue.rs:51
pub(crate) async fn enqueue_mailbox_communication(&self, communication: InterAgentCommunication) {
    self.mailbox_pending_mails.lock().await.push_back(communication);  // 入队
    self.mailbox_tx.send_replace(());                                   // watch 通知 :59
}

// 检查是否有「立即唤醒」邮件
// codex-rs/core/src/session/input_queue.rs:66
pub(crate) async fn has_trigger_turn_mailbox_items(&self) -> bool {
    self.mailbox_pending_mails.lock().await.iter().any(|mail| mail.trigger_turn)
}
```

读法：邮箱是 `VecDeque` + `tokio::watch`。邮件入队（`:51`）即 `send_replace` 通知；接收方 `subscribe_mailbox`（`:43`）订阅 watch 来唤醒。`trigger_turn`（`:66`）决定是**立即唤醒**（followup_task）还是**入队等下轮**（send_message）。

### 3.2 消息结构 - `InterAgentCommunication`

```rust
// codex-rs/core/src/protocol/protocol.rs:677
InterAgentCommunication {
    author,           // 发件人
    recipient,        // 收件人
    other_recipients, // 抄送（多播）
    content,          // 明文内容
    encrypted_content,// 加密内容
    trigger_turn,     // 是否立即唤醒
}
```

读法：一条消息带发件人、收件人、抄送（多播）、内容（明文/加密）、是否立即唤醒。**支持多播 + 加密**。

### 3.3 发送入口 - 工具与控制层

LLM 通过**工具**发消息，底层走**控制层**：

```rust
// codex-rs/core/src/tools/handlers/multi_agents_v2/message_tool.rs:59
pub(crate) async fn handle_message_string_tool(...) { ... }
//   ↑ send_message / followup_task 的统一工具入口

// codex-rs/core/src/agent/control.rs:166
pub(crate) async fn send_inter_agent_communication(
    &self, agent_id: ThreadId, communication: InterAgentCommunication,
) -> CodexResult<String> {
    let op = Op::InterAgentCommunication { communication };        // :173 包装成 Op
    self.ensure_execution_capacity_for_op(agent_id, &op).await?;   // :174 确保容量
    let result = self.handle_thread_request_result(
        agent_id, &state, state.send_op(agent_id, op).await         // :176 发给目标 agent
    ).await;
    ...
}
```

### 3.4 任务分配 - spawn 拓扑与寻址

```rust
// codex-rs/core/src/agent/control/spawn.rs:103
pub(crate) async fn spawn_agent_with_metadata(...) { ... }
//   ↑ 派生子 Agent（父子 spawn 边）+ reserve_spawn_slot 并发/深度限制

// codex-rs/core/src/agent/control.rs:268
pub(crate) async fn resolve_agent_reference(...) { ... }
//   ↑ 按 AgentPath 解析任意活跃 Agent（可发兄弟/祖先）
```

读法：Agent 通过 `spawn_agent_with_metadata`（`spawn.rs:103`）派生子 Agent，带并发/深度限制（`reserve_spawn_slot`）。`resolve_agent_reference`（`control.rs:268`）能按 `AgentPath` 找到任意活跃 Agent--**真「对等消息」，可发兄弟甚至祖先**，不只是父发子。

### 3.5 状态所有权 - 身份、路径、拓扑持久化

```rust
// codex-rs/core/src/protocol/agent_path.rs:15
pub struct AgentPath(String);   // 如 /root/parent/child 的层级路径，唯一身份

// codex-rs/agent-graph-store/src/store.rs:15
fn upsert_thread_spawn_edge(...) { ... }       // 记 spawn 边（Open/Closed 生命周期）
// codex-rs/agent-graph-store/src/store.rs:48
fn list_thread_spawn_descendants(...) { ... }  // BFS 列后代（SQLite）
```

加上 `agent-identity` crate（ed25519 私钥 + JWT/JWKS + curve25519 消息加密），Codex 给每个 Agent 配了**密码学身份**，为跨 Agent 加密消息提供基础。

### 3.6 生命周期 - Agent 死亡的清理

```rust
// codex-rs/core/src/agent/control.rs:206
if matches!(result, Err(CodexErr::InternalAgentDied)) {
    let _ = state.remove_thread(&agent_id).await;      // 移除线程
    self.forget_v2_residency(agent_id);                 // 清除驻留
    self.state.release_spawned_thread(agent_id);        // 释放 spawn 名额
}
```

读法：Agent 死亡（`InternalAgentDied`）时，自动移除线程、清驻留、释放 spawn 名额--**状态所有权伴随生命周期严格清理**，不残留。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| 消息范式 | 进程内 Mailbox（`VecDeque` + `watch`） | ✅ 异步解耦、可对等；❌ 仅进程内 |
| 多播 | `other_recipients` 支持抄送 | ✅ 一对多 |
| 立即唤醒 | `trigger_turn` 区分 followup_task / send_message | ✅ 灵活调度 |
| 拓扑 | 层级 spawn 树为主干 + 对等消息 | ✅ 可发兄弟/祖先 |
| 身份 | ed25519 + curve25519 加密 | ✅ 完整密码学基础 |
| 持久化 | SQLite 存 spawn edge（Open/Closed） | ✅ 拓扑可恢复 |
| 跨网络 A2A | 🔴 **无** | ❌ 所有 Agent 必须同进程，无独立消息总线/服务发现 |

> ⚠️ **重要边界**：Codex 的 Multi-Agent 是**进程内**协作，不是**跨网络**的 A2A 协议。所有 Agent 必须在同一个 `ThreadManager` 进程内。`external-agent-*` crate 是「导入别的 CLI 会话历史 / 迁移 Claude Code 配置」，与运行时通信无关。

> **面试金句**：Codex 的 Multi-Agent 是「**进程内加密邮箱**」--`InputQueue`（`input_queue.rs:29`）用 `VecDeque`+`watch` 做邮箱，`InterAgentCommunication`（`protocol.rs:677`）支持多播+加密+立即唤醒，`spawn.rs:103` 建父子拓扑，`agent-identity` 给密码学身份。亮点是「真对等消息+加密」，硬伤是「**仅进程内，无跨网络 A2A**」。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| 多 Agent 通信 Mailbox/类 A2A 子项矩阵（带 `file:line`） | [`../interview-prep/05-multi-agent-communication.md`](../interview-prep/05-multi-agent-communication.md) |
| 跨网络 A2A 的缺口说明 | [`../interview-prep/GAPS-codex-cannot-teach.md`](../interview-prep/GAPS-codex-cannot-teach.md) |
| 多 Agent 与多模型的能力边界 | [`../interview-prep/07-multi-model-integration.md`](../interview-prep/07-multi-model-integration.md) |
| 消息如何进入 ReAct 主循环 | 本卷 [01 ReAct 框架](./01-react-framework.md)（`pending_input` / `has_pending_input`） |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「多 Agent 之间怎么通信、状态归谁管？和 A2A 协议什么关系？」

1. **业界原理**：三要素--任务分配（按能力/负载/拓扑）、消息传递（直接调用/共享黑板/邮箱，A2A 是邮箱范式标准化）、状态所有权（每 Agent 拥有自己状态、靠消息协作不共享可变状态、有身份与生命周期管理）。
2. **Codex 实现**：消息靠 `input_queue.rs:29` `InputQueue`（`VecDeque` 邮箱 + `tokio::watch` 通知，`:51` 入队即通知）；消息结构 `protocol.rs:677` `InterAgentCommunication`（发件人/收件人/抄送/明文+加密/`trigger_turn`）；发送走 `message_tool.rs:59` 工具入口 -> `control.rs:166` `send_inter_agent_communication`（包装 `Op` 发给目标）；任务分配靠 `spawn.rs:103` `spawn_agent_with_metadata`（父子拓扑 + 并发/深度限制）+ `control.rs:268` `resolve_agent_reference`（对等寻址）；状态所有权靠 `agent_path.rs:15` `AgentPath` 层级身份 + `agent-identity` 加密 + `agent-graph-store` SQLite 存 spawn 边 + `control.rs:206` 死亡自动清理。
3. **取舍局限**：进程内加密邮箱是真亮点（多播+加密+对等+生命周期清理），但**仅进程内、无跨网络 A2A**（无独立消息总线/服务发现），`external-agent-*` 只是导入/迁移工具与运行时通信无关。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `input_queue.rs:29` 读 `InputQueue`，搞清 `mailbox_tx`（watch）和 `mailbox_pending_mails`（VecDeque）各自的作用--为什么需要两个？
2. 在 `control.rs:166` `send_inter_agent_communication` 里，追 `Op::InterAgentCommunication` 最终是怎么进入目标 Agent 的 `InputQueue` 的。
3. 对比 `trigger_turn=true`（followup_task）和 `trigger_turn=false`（send_message）在主循环里的不同唤醒路径。
4. 在 `control.rs:206` 确认 Agent 死亡时清理了哪三样东西，思考为什么必须清理。
5. 全仓 grep 跨网络 A2A 的痕迹（`cross_process|message_bus|service_discovery|a2a_protocol`），亲自确认 Codex 只有进程内 Mailbox、无跨网络 A2A 能力（预期：0 命中或仅无关）。

### 自测题
1. Codex 的 Mailbox 用了哪两个数据结构？`tokio::watch` 在这里起什么作用？
2. `InterAgentCommunication`（`protocol.rs:677`）有哪些字段？它怎么支持多播和加密？
3. `resolve_agent_reference`（`control.rs:268`）能让 Agent 给谁发消息？仅限父子吗？
4. Codex 的 Multi-Agent 是跨网络的 A2A 吗？`external-agent-*` crate 是干什么的？
5. `agent-identity` crate 提供了哪些密码学能力？为什么多 Agent 通信需要加密？

---

## ⑧ 小结

> Multi-Agent 是厨房团队：`spawn.rs:103` 派活建拓扑，
> `InputQueue`（`input_queue.rs:29`）做邮箱传话，`InterAgentCommunication`（`protocol.rs:677`）支持多播+加密+立即唤醒，
> `AgentPath`（`agent_path.rs:15`）管身份，`control.rs:206` 管生死清理。
> 亮点是进程内加密对等通信；硬伤是**跨网络 A2A 全无**。

---

*下一站 -> [06 Agent 评估](./06-agent-evaluation.md)：进阶层结束，进入保障层。Agent 做得再花哨，怎么评估它好不好？这是 Codex 的全缺口篇。*
