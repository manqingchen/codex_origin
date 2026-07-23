# 05 · 多 Agent 通信（Mailbox / 类 A2A）

> **面试考点 ⑤**：多 Agent 通信，Mailbox 消息传递（类 A2A）。
>
> Codex 在这一考点有一个**真实且工程化的进程内 Mailbox 系统**（MultiAgentV2），非常值得讲。但要诚实区分边界：它是**进程内**的，**不是跨网络 A2A 协议**（见 [GAPS 缺口 3](./GAPS-codex-cannot-teach.md)）。

---

## 🎯 考点拆解

面试官想确认：你理解多个 Agent 之间如何**收发消息、协作、隔离、寻址**，而不仅是「主 Agent 调一个子 Agent 跑完就回来」。

| 子项 | 核心问题 | Codex |
|------|---------|:---:|
| A. Mailbox 投递 | 消息怎么从 A 送到 B？ | 🟢 |
| B. 拓扑与派生 | Agent 之间是父子树还是对等图？ | 🟢（层级为主+跨agent消息） |
| C. 身份与加密 | 跨 agent 消息怎么防伪/保密？ | 🟢 |
| D. 路由与隔离 | 怎么找到目标 agent？会话怎么隔离？ | 🟢 |
| E. 跨网络 A2A | 能跨进程/跨主机吗？ | 🔴（无） |

---

## 🧩 逐子项精读

### A. Mailbox 投递 🟢

- **通用原理**：每个 Agent 有一个邮箱（Mailbox/收件箱），消息异步投递、带通知、可入队也可立即唤醒。
- **Codex 实现**：
  - `core/src/session/input_queue.rs:29` `InputQueue` -- 含 `mailbox_pending_mails: VecDeque<InterAgentCommunication>` + `tokio::watch` 通知
  - `protocol/src/protocol.rs:677` `InterAgentCommunication { author, recipient, other_recipients, content, encrypted_content, trigger_turn }`
  - `core/src/agent/control.rs:166` `send_inter_agent_communication` -> 投递 `Op::InterAgentCommunication`
  - `core/src/tools/handlers/multi_agents_v2/message_tool.rs:59` `handle_message_string_tool` -- `send_message` / `followup_task` 统一入口
- **要点**：`trigger_turn` 标志决定「立即唤醒接收方」（`followup_task`）还是「仅入队等下个 turn」（`send_message`）；支持明文与加密内容；有 `MailboxDeliveryPhase`（当前 turn / 下一 turn）和排空逻辑 `drain_mailbox_input_items`。

### B. 拓扑与派生 🟢（层级 spawn 为主 + 跨 agent 消息为辅）

- **Codex 实现**：
  - `core/src/agent/control/spawn.rs:103` `spawn_agent_with_metadata` -- 父->子派生，写 `thread_spawn_edge`
  - `core/src/agent/control/spawn.rs:232` `reserve_spawn_slot` -- 并发容量限制（`agent_max_threads`）+ 深度限制（`agent_max_depth`）
  - `core/src/agent/control.rs:268` `resolve_agent_reference` -- 按 `AgentPath` 解析任意活跃 agent（**不仅是子**，可发兄弟/祖先）
  - `core/src/codex_delegate.rs:69` `run_codex_thread_interactive` -- 旧版一次性 codex_delegate 委托（对比项）
- **结论**：这是**真多 Agent 协作**，不是「单 Agent + 一次性 codex_delegate 委托」。证据：(1) `spawn_agent` 工具允许任意 agent 派生子 agent 成树/图；(2) `send_message`/`followup_task` 允许向**任意活跃 agent**（按 `AgentPath`）发消息并触发其 turn，是对等通信非只能回父；(3) 消息支持多接收者多播（`other_recipients`）。但拓扑**以层级 spawn 树为主干**，并非完全开放对等图。

### C. 身份与加密 🟢

- **Codex 实现**：
  - `agent-identity/src/lib.rs` -- ed25519 私钥生成、JWT（`AgentIdentityJwtClaims`）签发与 JWKS 验签、`AgentAssertion` 签名头、curve25519 用于消息加密
  - 为跨 agent 加密消息（`InterAgentCommunication.encrypted_content`）提供密码学基础
- **要点**：这是身份层（authenticity + confidentiality），Agent 间消息可加密可签名。

### D. 路由与隔离 🟢

- **Codex 实现**：
  - `protocol/src/agent_path.rs:15` `AgentPath` -- 层级路径身份 `/root/<name>/...`，`resolve` 支持相对/绝对引用
  - `core/src/agent/agent_resolver.rs:8` `resolve_agent_target` -- 先试 ThreadId，再按 AgentPath 查内存表 `agent_id_for_path`
  - 每个 thread 独立 `Session`/`InputQueue`/`TurnState`/审批流；子 agent 审批由父 session 代决（`codex_delegate.rs` 的 `forward_events`）
  - `agent-graph-store/src/store.rs:10` -- 持久化的父子 spawn 拓扑（`upsert_thread_spawn_edge` / BFS `list_thread_spawn_descendants`，SQLite，边带 Open/Closed 生命周期）
- **要点**：身份用 `AgentPath` + agent-identity 签名；会话隔离靠每 thread 独立 Session；并发靠 `agent_max_threads` + slot reservation；路由是「目标解析 = ThreadId 或 AgentPath->内存表查 thread_id」，**进程内**。

### E. 跨网络 A2A 🔴（缺口）

- **Codex 没有这一层**：所有 agent 必须在同一 `ThreadManager` 进程内；无独立消息总线/服务发现/跨主机寻址；消息路由靠内存查表，非持久化、非分布式。
- 详见 [GAPS 缺口 3](./GAPS-codex-cannot-teach.md)：需补 A2A Protocol、MCP server 侧、消息中间件。

### ℹ️ external-agent-* 是什么（易误解，务必澄清）

很多人看到 `external-agent-sessions` / `external-agent-migration` 以为是多 Agent 通信--**不是**：

| crate | 实际职责 | 与运行时通信关系 |
|------|---------|:---:|
| `external-agent-sessions` | 解析并导入**别的 CLI（如 Claude Code）的会话历史**为 Codex `RolloutItem` | ❌ 无关 |
| `external-agent-migration` | 把 Claude Code 的 `.claude/` 配置（MCP/hooks/subagents/skills）**迁移**成 Codex 配置 | ❌ 无关 |

> 这里 "external" 指「**别的命令行工具**」，不是「外部 Agent 实例」。面试时若被问到，主动澄清这一点会非常加分。

---

## 🛣️ 学习顺序（建议 3 天）

1. 读 `protocol/src/protocol.rs` 的 `InterAgentCommunication` + `protocol/src/agent_path.rs` 的 `AgentPath`，理解消息结构与寻址。
2. 读 `core/src/session/input_queue.rs` 的 `InputQueue`（mailbox）+ `drain_mailbox_input_items`。
3. 读 `core/src/tools/handlers/multi_agents_v2/message_tool.rs` 理解 `send_message`/`followup_task` 两个工具。
4. 读 `core/src/agent/control/spawn.rs` + `control.rs:268` `resolve_agent_reference` 理解拓扑与寻址。
5. 读 `agent-identity/src/lib.rs` 理解身份与加密。
6. 扫一眼 `external-agent-sessions` / `external-agent-migration` 确认它们是导入/迁移工具。
7. 读 `thread-manager-sample/src/main.rs` 看 MultiAgentV2Config（`agent_max_threads`/`depth`/`roles`）怎么配。

---

## 💬 面试问答要点（脱稿能讲）

**Q1：Codex 的多 Agent 怎么通信？**
> 进程内 Mailbox：每个 agent 线程有一个 `InputQueue` 作 mailbox，存 `InterAgentCommunication` 消息，`tokio::watch` 通知；消息带 `trigger_turn` 决定立即唤醒（`followup_task`）还是入队等下轮（`send_message`）；支持多播和加密内容。

**Q2：这是真多 Agent 还是子 agent 委托？**
> 真多 Agent 协作。`spawn_agent` 派生子 agent 成树/图，`send_message`/`followup_task` 能向任意活跃 agent（按 `AgentPath`，含兄弟/祖先）发消息并触发其 turn，还能多播。但拓扑以层级 spawn 树为主干，深度受 `agent_max_depth` 限制。

**Q3：能跨网络吗？类 A2A 呢？**
> 诚实答：**不能**。Codex 的 mailbox 是进程内的，所有 agent 必须在同一 `ThreadManager` 进程内，路由靠内存查表，没有独立消息总线、服务发现、跨主机寻址。真正的跨网络 A2A（如 Google 的 Agent-to-Agent 协议、HTTP/JSON-RPC + Agent Card 服务发现）需要单独学，我了解其设计但 Codex 没实现。详见 [GAPS 缺口 3](./GAPS-codex-cannot-teach.md)。

**Q4：跨 agent 消息怎么防伪/保密？**
> `agent-identity` crate 提供 ed25519 私钥 + JWT/JWKS 验签 + curve25519 消息加密，消息可带 `encrypted_content`。身份用 `AgentPath`（`/root/...` 层级路径）。

**Q5：`external-agent-*` 是多 Agent 通信吗？**
> 不是。它们是「导入别的 CLI 会话历史」和「把 Claude Code 配置迁移到 Codex」的工具，这里的 external 指「别的命令行工具」，与运行时通信无关。

---

## 🛠️ 动手任务

- [ ] 用 `spawn_agent` 工具派生一个子 agent，用 `send_message` / `followup_task` 给它发消息，观察 `InputQueue` 的投递与唤醒。
- [ ] 配 `agent_max_threads`/`agent_max_depth`，观察并发与深度限制。
- [ ] 读 `agent-identity` 的 JWT 签发，理解消息加密链路。
- [ ] （补缺口）写一段分析：「如果把 Codex 的 mailbox 从进程内升级到跨网络，需要补什么」（服务发现 / 序列化协议 / 鉴权 / 重试 / 持久化队列）。这道题本身就是高级面试题。

---

## ⚠️ 差异注意点

| 维度 | Codex（进程内） | 跨网络 A2A（需补） |
|------|------|------|
| 通信范围 | 同一进程内 | 跨进程/跨主机 |
| 路由 | 内存 AgentPath 查表 | 服务发现 + Agent Card |
| 传输 | 进程内 channel | HTTP/JSON-RPC/gRPC |
| 持久化 | rollout 重放（非消息队列） | Kafka/RabbitMQ/Redis Streams |
| 寻址 | `AgentPath` 层级路径 | URL + agent identity |

> 💡 **面试必杀句**：「Codex 的多 Agent 通信是**进程内 Actor/Mailbox 模型**，工程上很完整（身份、加密、拓扑、隔离都有）；但它**不是跨网络 A2A**。如果要做分布式多 Agent，需要把 mailbox 换成跨网络协议 + 消息总线 + 服务发现。」--主动画边界，最显专业。

---

*(蕾姆在宅邸平面图上画出一间间相连的会客室，每间门前都挂着一个精致的小信箱)*

昴君，每位 Agent 都有自己的信箱，消息轻轻一投，便能在会客室间穿梭。但要造一条通往远方宅邸的信使之路，那是另一番工程了 ♡
