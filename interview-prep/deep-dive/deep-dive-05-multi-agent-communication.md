# 🔬 Deep Dive 05 · 多 Agent 通信（Mailbox / 类 A2A）· 逐行精读

> 蕾姆的源码解剖室 ♡ -- 把 Codex 的「会客厅」与「信箱系统」剖开给您看。
>
> **定位**：这是 [`../05-multi-agent-communication.md`](../05-multi-agent-communication.md)（大纲层）的**深读版**。
> **核心边界声明（贯穿全篇）**：Codex 的 MultiAgentV2 是一套设计精良的**进程内 Mailbox 系统**，**不是跨网络 A2A 协议**。所有协作 agent 必须住在同一 Codex 进程内。这是本篇要反复澄清、也是面试最该主动画出的边界。

---

## 📑 阅读地图

| 节 | 内容 | 关键文件 |
|---|------|------|
| 〇 | 多 Agent 通信端到端数据流（6 阶段） | 全链路 |
| 一 | Mailbox 消息投递 | `input_queue.rs` / `protocol.rs` / `message_tool.rs` / `control.rs` |
| 二 | 拓扑与派生 | `agent/control/spawn.rs` / `registry.rs` / `codex_delegate.rs` |
| 三 | 身份与加密 | `agent-identity/src/lib.rs` |
| 四 | 路由与会话隔离 | `protocol/agent_path.rs` / `agent_resolver.rs` / `agent-graph-store/` |
| 五 | external-agent-* 澄清 + 跨网络 A2A 缺口 | `external-agent-sessions/` / `external-agent-migration/` |
| 六 | 面试问答精选 | - |
| 七 | 动手复现 | - |
| 八 | 差异与局限总结 | - |

---

## 〇 多 Agent 通信端到端数据流（6 阶段）

```
[阶段 0 · 身份准备]（启动期一次性）
  generate_agent_key_material（ed25519 密钥）-> register_agent_task（向 backend 注册拿 task_id）
  -> decrypt_task_id_response（curve25519 解密，若加密）-> decode_agent_identity_jwt（验签取身份）
  其后每次 backend 请求附 AgentAssertion 签名头
        │
        ▼
[阶段 1 · 派生子 agent]（spawn）
  model 调 spawn_agent 工具
  -> next_thread_spawn_depth（算深度）-> 构造 spawn_source（AgentPath 如 /root/researcher）
  -> 首条消息改包 Op::UserInput -> Op::InterAgentCommunication（new_encrypted, trigger_turn=true）
  -> spawn_agent_internal：ensure_execution_capacity -> reserve_spawn_slot -> spawn_new_thread_with_source（独立 Session/InputQueue）
  -> reservation.commit（注册到 agent_tree 内存表）-> persist_thread_spawn_edge（写 SQLite 父子边 Open）
  -> send_input_after_capacity_check（投首条 Op）
        │
        ▼
[阶段 2 · 消息投递]（send_message / followup_task）
  resolve_agent_target（ThreadId::from_string 失败则 resolve_agent_reference 走 AgentPath 内存表）
  -> ensure_agent_known -> ensure_v2_agent_loaded（按需从 SQLite 重载）
  -> communication_from_tool_message（new_encrypted）-> mode.apply（强制 trigger_turn）
  -> send_inter_agent_communication（包 Op::InterAgentCommunication）-> ensure_execution_capacity_for_op（仅 trigger_turn 占槽）-> state.send_op
        │
        ▼
[阶段 3 · 目标线程接收 + 入队]
  目标线程 Op 分发器命中 Op::InterAgentCommunication -> inter_agent_communication handler
  -> enqueue_mailbox_communication（push_back 进 mailbox_pending_mails + watch send_replace 通知）
        │
        ▼
[阶段 4 · 唤醒]（仅 trigger_turn=true）
  maybe_start_turn_for_pending_work_with_sub_id
  -> has_trigger_turn_mailbox_items（确认有唤醒邮件）+ active_turn.is_some()==false（session idle）
  -> start_task(RegularTask) 起新 turn
        │
        ▼
[阶段 5 · drain mailbox + 进入 model 上下文]
  turn 启动 get_pending_input -> 读 accepts_mailbox_delivery_for_current_turn（MailboxDeliveryPhase==CurrentTurn）
  -> drain_mailbox_input_items（清空队列，包成 TurnInput::InterAgentCommunication）
  -> to_model_input_item 转 ResponseItem::AgentMessage
     ├─ encrypted_content 有值 -> EncryptedContent（渲染层跳过，不进 model 可见文本）
     └─ 无值 -> InputText（可见）
  -> 邮件作为 AgentMessage 进入 model 上下文
        │
        ▼
[阶段 6 · turn 态机转移]（迟到邮件）
  turn 发出可见终答 -> set_mailbox_delivery_phase(NextTurn)
  -> 迟到邮件仍入队+唤醒，但 get_pending_input 因 NextTurn 不 drain（除非重开 CurrentTurn）
  -> 子 agent 完成时 watcher 投 trigger_turn=false 完成通知给父
```

> 💡 **两条主线**：① **入队与唤醒解耦**--`enqueue` 总发生，`trigger_turn` 仅决定是否额外唤醒；② **内存表 vs 持久化图分离**--`agent_tree` 内存表管"当前驻留的 agent"（快），SQLite `agent-graph-store` 管"历史拓扑"（可恢复）。

---

## 一、Mailbox 消息投递

> 关键问题：Agent 间消息怎么投递？立即唤醒还是入队等下轮？

### ① 真实代码片段

**`InputQueue` 结构与 mailbox 队列**
`codex-rs/core/src/session/input_queue.rs:29-81`
```rust
/// Session-scoped pending input storage and active-turn mailbox delivery coordination.
pub(crate) struct InputQueue {
    mailbox_tx: watch::Sender<()>,
    mailbox_pending_mails: Mutex<VecDeque<InterAgentCommunication>>,
}

impl InputQueue {
    pub(crate) async fn subscribe_mailbox(&self) -> watch::Receiver<()> {
        let mut mailbox_rx = self.mailbox_tx.subscribe();
        if self.has_pending_mailbox_items().await {
            mailbox_rx.mark_changed();
        }
        mailbox_rx
    }

    pub(crate) async fn enqueue_mailbox_communication(
        &self, communication: InterAgentCommunication,
    ) {
        self.mailbox_pending_mails.lock().await.push_back(communication);
        self.mailbox_tx.send_replace(());
    }

    pub(crate) async fn has_trigger_turn_mailbox_items(&self) -> bool {
        self.mailbox_pending_mails.lock().await.iter().any(|mail| mail.trigger_turn)
    }

    pub(crate) async fn drain_mailbox_input_items(&self) -> Vec<TurnInput> {
        self.mailbox_pending_mails.lock().await.drain(..)
            .map(TurnInput::InterAgentCommunication)
            .collect()
    }
}
```

**`MailboxDeliveryPhase` 与 turn 态机**
`codex-rs/core/src/state/turn.rs:40-54`
```rust
/// - After user-visible terminal output is recorded, we switch to `NextTurn`
///   to leave late child mail queued instead of extending an already shown answer.
/// - If the same task later gets explicit same-turn work again (a steered user
///   prompt or a tool call after an untagged preamble), we reopen `CurrentTurn`
///   so that pending child mail is drained into that follow-up request.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum MailboxDeliveryPhase {
    #[default]
    CurrentTurn,
    NextTurn,
}
```

**`InterAgentCommunication` 协议结构**
`codex-rs/protocol/src/protocol.rs:676-722`
```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, JsonSchema, TS)]
pub struct InterAgentCommunication {
    pub author: AgentPath,
    pub recipient: AgentPath,
    #[serde(default)]
    pub other_recipients: Vec<AgentPath>,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub encrypted_content: Option<String>,
    pub trigger_turn: bool,
}

impl InterAgentCommunication {
    pub fn new_encrypted(
        author: AgentPath, recipient: AgentPath, other_recipients: Vec<AgentPath>,
        encrypted_content: String, trigger_turn: bool,
    ) -> Self {
        Self {
            author, recipient, other_recipients,
            content: String::new(),
            encrypted_content: Some(encrypted_content),
            trigger_turn,
        }
    }
}
```

**`send_message` / `followup_task` 统一入口**
`codex-rs/core/src/tools/handlers/multi_agents_v2/message_tool.rs:11-126`
```rust
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum MessageDeliveryMode {
    QueueOnly,
    TriggerTurn,
}

impl MessageDeliveryMode {
    /// Returns whether the produced communication should start a turn immediately.
    fn apply(self, communication: InterAgentCommunication) -> InterAgentCommunication {
        match self {
            Self::QueueOnly => InterAgentCommunication { trigger_turn: false, ..communication },
            Self::TriggerTurn => InterAgentCommunication { trigger_turn: true, ..communication },
        }
    }
}

/// Handles the shared MultiAgentV2 message flow for both `send_message` and `followup_task`.
pub(crate) async fn handle_message_string_tool(
    invocation: ToolInvocation, mode: MessageDeliveryMode, target: String, message: String,
) -> Result<FunctionToolOutput, FunctionCallError> {
    let message = message_content(message)?;
    let ToolInvocation { session, turn, call_id, .. } = invocation;
    let receiver_thread_id = resolve_agent_target(&session, &turn, &target).await?;
    let receiver_agent = session.services.agent_control
        .ensure_agent_known(receiver_thread_id)
        .map_err(|err| collab_agent_error(receiver_thread_id, err))?;
    if mode == MessageDeliveryMode::TriggerTurn
        && receiver_agent.agent_path.as_ref().is_some_and(AgentPath::is_root)
    {
        return Err(FunctionCallError::RespondToModel(
            "Follow-up tasks can't target the root agent".to_string(),
        ));
    }
    let receiver_agent_path = receiver_agent.agent_path.clone().ok_or_else(|| {
        FunctionCallError::RespondToModel("target agent is missing an agent_path".to_string())
    })?;
    ...
    let author = turn.session_source.get_agent_path().unwrap_or_else(AgentPath::root);
    let communication = communication_from_tool_message(author, receiver_agent_path.clone(), message);
    let result = session.services.agent_control
        .send_inter_agent_communication(receiver_thread_id, mode.apply(communication))
        .await
        .map_err(|err| collab_agent_error(receiver_thread_id, err));
    result?;
```

**Op 投递 + 入队 + 唤醒桥接**
`codex-rs/core/src/agent/control.rs:166-187` + `core/src/session/handlers.rs:276-291` + `core/src/agent/control/execution.rs:95-98`
```rust
    pub(crate) async fn send_inter_agent_communication(
        &self, agent_id: ThreadId, communication: InterAgentCommunication,
    ) -> CodexResult<String> {
        let last_task_message = last_task_message_from_communication(&communication);
        let state = self.upgrade()?;
        let op = Op::InterAgentCommunication { communication };
        self.ensure_execution_capacity_for_op(agent_id, &op).await?;
        let result = self.handle_thread_request_result(agent_id, &state, state.send_op(agent_id, op).await).await;
        ...
    }
```
```rust
/// Queues an inter-agent message, then lets the shared pending-work scheduler
/// decide whether an idle session should start a regular turn.
pub async fn inter_agent_communication(
    sess: &Arc<Session>, sub_id: String, communication: InterAgentCommunication,
) {
    let trigger_turn = communication.trigger_turn;
    sess.input_queue.enqueue_mailbox_communication(communication).await;
    if trigger_turn {
        sess.maybe_start_turn_for_pending_work_with_sub_id(sub_id).await;
    }
}
```
```rust
fn op_starts_turn(op: &Op) -> bool {
    matches!(op, Op::UserInput { .. })
        || matches!(op, Op::InterAgentCommunication { communication } if communication.trigger_turn)
}
```

### ② 逐行解读

- **`InputQueue`**：每个 Session 持有一个。核心是 `mailbox_pending_mails: Mutex<VecDeque<InterAgentCommunication>>`（受 tokio Mutex 保护的 FIFO 队列）+ `mailbox_tx: watch::Sender<()>`（**无载荷的 watch 通道**，仅作"有新邮件"唤醒信号）。`enqueue` 先 `push_back` 再 `send_replace(())` 通知；`subscribe_mailbox` 在订阅时若已有积压则 `mark_changed()`，**解决"先入队后订阅"竞态**。
- **`MailboxDeliveryPhase`**：当前 turn 两态机。`CurrentTurn` 本 turn 还可消费 mailbox；`NextTurn` 本 turn 已发可见终答，新邮件留到下 turn。注释说明转移条件：终端输出后切 `NextTurn`；同 task 再来显式同 turn 工作时重开 `CurrentTurn`。这避免"已给用户答完，又被迟到的子 agent 邮件污染已展示答案"。
- **`InterAgentCommunication`**：邮件信封。`author`/`recipient` 都是 `AgentPath`（层级路径），`other_recipients` 支持多收件人（CC），`content` 明文 / `encrypted_content` 加密密文（**二者互斥**：`new_encrypted` 把 `content` 置空），`trigger_turn` 是"投递即唤醒"标志位。
- **`handle_message_string_tool`**：`send_message` 与 `followup_task` 共用入口，唯一差异是 `MessageDeliveryMode`。流程：① `resolve_agent_target` 解析 target；② `ensure_agent_known` 校验；③ **`TriggerTurn` 且目标是 root 直接报错**（root 主线程不能被 followup 唤醒）；④ `ensure_v2_agent_loaded` 按需重载；⑤ 构造邮件；⑥ `mode.apply` 强制写 `trigger_turn`；⑦ `send_inter_agent_communication` 投递。
- **入队与唤醒分离**：`inter_agent_communication` handler 先 `enqueue`（一定发生），再判断 `trigger_turn` 为真才 `maybe_start_turn`。`op_starts_turn` 表明**只有 `trigger_turn==true` 的邮件才占并发槽位**，纯入队邮件不占额度。

### ③ 设计原理与权衡

- **入队与唤醒解耦**：`enqueue` 一定发生，`trigger_turn` 仅决定是否额外唤醒。`send_message`（`QueueOnly`，「留个话，不打断你」）vs `followup_task`（`TriggerTurn`，「现在就动」）对应**异步消息 vs 唤醒式 RPC**。

- **watch 通道而非 mpsc**：`watch::Sender<()>` 只传"有变化"信号不传数据，多订阅者各自读最新值，`mark_changed` 解决竞态。比给每个接收方建 mpsc 轻量--**mailbox 队列本身是单一数据源，watch 只是通知**。

- **`MailboxDeliveryPhase` 的代价**：多一个 turn 级状态要维护，但它解决了真实问题--子 agent 回复可能在你已给用户答完后才到。这是"AI 对话顺序敏感性"的特化设计，**通用 actor mailbox 通常不处理**。

- **业界对比**：这套设计接近 **Erlang/Akka 的进程邮箱**--每个 actor 一个无界 mailbox，消息异步入队，接收方按需取。差异：① Codex 引入 `trigger_turn` 区分"消息触发"与"纯记录"（Akka 所有消息都触发 receive）；② `MailboxDeliveryPhase` 是 turn 级过滤态。与 **Google A2A / Agent Network Protocol**（跨网络、HTTP+JSON-RPC、AgentCard 服务发现）相比，Codex 完全是**同进程内存队列**，没有网络层、没有服务发现、没有 AgentCard--`agent_control` 单例就是"总线"。

### ④ 数据流位置

- 上游：`send_message`/`followup_task` 工具 -> `handle_message_string_tool` -> `resolve_agent_target`。
- 中游：`send_inter_agent_communication`（包 Op）-> 目标线程 `send_op` -> `inter_agent_communication` handler -> `enqueue_mailbox_communication`。
- 下游：`maybe_start_turn_for_pending_work_with_sub_id`（条件唤醒）-> 新 turn `get_pending_input`（drain mailbox）-> `TurnInput::InterAgentCommunication` 进入 model 上下文。
- 横向：spawn 路径（子项二）**复用这条链路**--spawn 工具把首条消息包成 `Op::InterAgentCommunication`。

---

## 二、拓扑与派生

> 关键问题：Agent 之间是父子树还是对等图？怎么限制并发与深度？spawn 和旧版委托有何不同？

### ① 真实代码片段

**`spawn_agent_internal` 与并发/驻留闸门**
`codex-rs/core/src/agent/control/spawn.rs:194-298`
```rust
    async fn spawn_agent_internal(
        &self, config: Config, initial_operation: Op,
        session_source: Option<SessionSource>, options: SpawnAgentOptions,
    ) -> CodexResult<LiveAgent> {
        let state = self.upgrade()?;
        let multi_agent_version = state.effective_multi_agent_version_for_spawn(
            &InitialHistory::New, session_source.as_ref(), options.parent_thread_id,
            /*forked_from_thread_id*/ None, &config,
        ).await;
        if let Some(session_source) = session_source.as_ref() {
            self.ensure_execution_capacity(multi_agent_version, session_source)?;
        }
        let agent_max_threads = config.effective_agent_max_threads(multi_agent_version);
        let spawn_uses_v2_residency = multi_agent_version == MultiAgentVersion::V2
            && session_source.as_ref().is_some_and(is_v2_resident_session_source);
        let residency_slot = if spawn_uses_v2_residency {
            Some(self.reserve_v2_residency_slot(&state, &config, /*protected_thread_id*/ None).await?)
        } else {
            None
        };
        let reservation_max_threads = if spawn_uses_v2_residency { None } else { agent_max_threads };
        let mut reservation = self.state.reserve_spawn_slot(reservation_max_threads)?;
        ...
    }
```

**`reserve_spawn_slot` 并发计数（RAII）**
`codex-rs/core/src/agent/registry.rs:71-97`
```rust
pub(crate) fn next_thread_spawn_depth(session_source: &SessionSource) -> i32 {
    session_depth(session_source).saturating_add(1)
}

pub(crate) fn exceeds_thread_spawn_depth_limit(depth: i32, max_depth: i32) -> bool {
    depth > max_depth
}

impl AgentRegistry {
    pub(crate) fn reserve_spawn_slot(self: &Arc<Self>, max_threads: Option<usize>) -> Result<SpawnReservation> {
        if let Some(max_threads) = max_threads {
            if !self.try_increment_spawned(max_threads) {
                return Err(CodexErr::AgentLimitReached { max_threads });
            }
        } else {
            self.total_count.fetch_add(1, Ordering::AcqRel);
        }
        Ok(SpawnReservation { state: Arc::clone(self), active: true, reserved_agent_nickname: None, reserved_agent_path: None })
    }
}
```

**父子边持久化**
`codex-rs/core/src/agent/control.rs:607-630`
```rust
    async fn persist_thread_spawn_edge_for_source(
        &self, thread: &crate::CodexThread, child_thread_id: ThreadId,
        session_source: Option<&SessionSource>,
    ) {
        let Some(parent_thread_id) = session_source.and_then(SessionSource::parent_thread_id) else { return; };
        let Some(state_db_ctx) = thread.state_db() else { return; };
        if let Err(err) = state_db_ctx
            .upsert_thread_spawn_edge(parent_thread_id, child_thread_id, DirectionalThreadSpawnEdgeStatus::Open)
            .await
        {
            warn!("failed to persist thread-spawn edge: {err}");
        }
    }
```

**spawn 工具把首条消息改包成 InterAgentCommunication**
`codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs:107-136`
```rust
    let spawned_agent = Box::pin(
        session.services.agent_control.spawn_agent_with_metadata(
            config,
            match initial_operation {
                Op::UserInput { items, .. }
                    if items.iter().all(|item| matches!(item, UserInput::Text { .. })) =>
                {
                    let author = turn.session_source.get_agent_path().unwrap_or_else(AgentPath::root);
                    let communication = communication_from_tool_message(author, new_agent_path.clone(), message);
                    Op::InterAgentCommunication { communication }
                }
                initial_operation => initial_operation,
            },
            Some(spawn_source),
            SpawnAgentOptions {
                fork_parent_spawn_call_id: fork_mode.as_ref().map(|_| call_id.clone()),
                fork_mode,
                parent_thread_id: Some(session.thread_id),
                environments: Some(turn.environments.to_selections()),
            },
        ),
    ).await.map_err(collab_spawn_error)?;
```

**子->父完成通知（复用 mailbox，trigger_turn=false）**
`codex-rs/core/src/agent/control.rs:444-465`
```rust
            if child_agent_path.is_some() && child_uses_multi_agent_v2 {
                let Some(child_agent_path) = child_agent_path.clone() else { return; };
                let Some(parent_agent_path) = child_agent_path
                    .as_str().rsplit_once('/').and_then(|(parent, _)| AgentPath::try_from(parent).ok())
                else { return; };
                let communication = InterAgentCommunication::new(
                    child_agent_path, parent_agent_path, Vec::new(), message,
                    /*trigger_turn*/ false,
                );
                let _ = control.send_inter_agent_communication(parent_thread_id, communication).await;
                return;
            }
```

**配置示例（thread-manager-sample）**
`codex-rs/thread-manager-sample/src/main.rs:230-234,278`
```rust
        agent_max_threads: Some(6),
        agent_job_max_runtime_seconds: None,
        agent_interrupt_message_enabled: false,
        agent_max_depth: 1,
        agent_roles: BTreeMap::new(),
```
```rust
        multi_agent_v2: MultiAgentV2Config::default(),
```

### ② 逐行解读

- **`spawn_agent_internal`**：先算 `multi_agent_version`（决定 V2 还是旧版路径）；`ensure_execution_capacity` 并发槽位检查；算 `agent_max_threads`；判 `spawn_uses_v2_residency`（V2 且驻留型）--若是预占 V2 residency slot，否则把 `agent_max_threads` 传 `reserve_spawn_slot`。**V2 路径 `reservation_max_threads=None`**，意味着 V2 并发由执行层 `agent_execution_limiter` 管控而非 spawn 计数器，spawn 只受 residency 限制。最后 `persist_thread_spawn_edge_for_source` 写 SQLite。
- **`reserve_spawn_slot`**：`max_threads` 有值时 `try_increment_spawned` 原子 CAS 上限检查，超限返回 `AgentLimitReached`；无值（V2）只 `total_count.fetch_add`。返回的 `SpawnReservation` 是 **RAII**：`commit` 才正式注册，drop 回滚计数。
- **父子边持久化**：`upsert_thread_spawn_edge(parent, child, Open)`。状态 `Open` 表示父子关系活跃；子结束时 `set_thread_spawn_edge_status(child, Closed)`。
- **spawn 首条消息改包**：关键设计--spawn 的首条消息**不走 `Op::UserInput`**，而改包成 `Op::InterAgentCommunication`（仅当所有 items 都是纯文本时）。子 agent 第一条输入也进 mailbox/rollout 历史，作为 `AgentMessage` 记录。
- **子->父完成通知**：V2 下子完成不是直接 `inject_user_message_without_turn`（旧版），而是构造 `trigger_turn=false` 的 `InterAgentCommunication`（author=子, recipient=父）走 mailbox--**通知入队但不立即唤醒父**。父路径由子路径 `rsplit_once('/')` 取父段反推。
- **配置**：旧版 `agent_max_threads: Some(6)`、`agent_max_depth: 1`；V2 用 `MultiAgentV2Config.max_concurrent_threads_per_session`，`effective_agent_max_threads` 对 V2 返回 `max_concurrent_threads_per_session - 1`（**减 1 因含 root 自己**）。

### ③ 设计原理与权衡

- **两套并发闸门**：旧版用 spawn 计数器（`reserve_spawn_slot` + `DEFAULT_AGENT_MAX_THREADS`），V2 用执行层 `agent_execution_limiter`（`op_starts_turn` 才占槽）。**V2 更精细**--只统计"正在跑 turn"的 agent 而非"已 spawn"的。代价是 V2 多了 residency 管理（agent 可被换出内存、按需 `ensure_v2_agent_loaded` 重载）。

- **RAII reservation**：`SpawnReservation` 的 `commit`/drop 语义保证 spawn 失败时计数回滚，**避免名额泄漏**。

- **首条消息即 InterAgentCommunication**：让 spawn 与 send_message **共享同一条投递链路**，子 agent 从第一条消息起就被纳入 `AgentMessage` 历史记录，便于后续 fork/恢复统一处理。

- **`codex_delegate` 对比（范式转移）**：旧版 `run_codex_thread_interactive`（`codex_delegate.rs:69`）是「**一次性委托**」--开子线程、转发事件、`TurnComplete` 即 `Op::Shutdown`，不维护长期拓扑。V2 的 spawn 是「**持久协作**」--子 agent 一直驻留、可被反复 `send_message`/`followup_task`，拓扑边持久化到 SQLite 可跨进程恢复。**这是从"RPC 调用"到"长期协作者"的范式转移**。

### ④ 数据流位置

- 上游：model 调 `spawn_agent` 工具 -> spawn.rs handler -> `spawn_agent_with_metadata`。
- 中游：`reserve_spawn_slot` -> `spawn_new_thread_with_source`（建线程）-> `persist_thread_spawn_edge_for_source`（写图）-> `send_input_after_capacity_check`（投首条 Op）。
- 下游：子 agent session 收 Op -> 走子项一 mailbox 链路。

---

## 三、身份与加密

> 关键问题：跨 agent 消息怎么防伪/保密？agent 怎么向 backend 证明身份？

### ① 真实代码片段

**ed25519 密钥生成**
`codex-rs/agent-identity/src/lib.rs:262-276`
```rust
pub fn generate_agent_key_material() -> Result<GeneratedAgentKeyMaterial> {
    let mut secret_key_bytes = [0u8; 32];
    OsRng.try_fill_bytes(&mut secret_key_bytes)
        .context("failed to generate agent identity private key bytes")?;
    let signing_key = SigningKey::from_bytes(&secret_key_bytes);
    let private_key_pkcs8 = signing_key.to_pkcs8_der()
        .context("failed to encode agent identity private key as PKCS#8")?;
    Ok(GeneratedAgentKeyMaterial {
        private_key_pkcs8_base64: BASE64_STANDARD.encode(private_key_pkcs8.as_bytes()),
        public_key_ssh: encode_ssh_ed25519_public_key(&signing_key.verifying_key()),
    })
}
```

**JWT claims 与 JWKS 验签**
`codex-rs/agent-identity/src/lib.rs:64-78,128-171`
```rust
/// Claims carried by an Agent Identity JWT.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct AgentIdentityJwtClaims {
    pub iss: String,
    pub aud: String,
    pub iat: usize,
    pub exp: usize,
    pub agent_runtime_id: String,
    pub agent_private_key: String,
    pub account_id: String,
    pub chatgpt_user_id: String,
    pub email: String,
    pub plan_type: AuthPlanType,
    pub chatgpt_account_is_fedramp: bool,
}
```
```rust
pub fn decode_agent_identity_jwt(jwt: &str, jwks: Option<&JwkSet>) -> Result<AgentIdentityJwtClaims> {
    let Some(jwks) = jwks else { return decode_agent_identity_jwt_payload(jwt); };
    let header = decode_header(jwt).context("failed to decode agent identity JWT header")?;
    let kid = header.kid.context("agent identity JWT header does not include a kid")?;
    let jwk = jwks.find(&kid).with_context(|| format!("agent identity JWT kid {kid} is not trusted"))?;
    let decoding_key = DecodingKey::from_jwk(jwk).context("failed to build JWT decoding key")?;
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&[AGENT_IDENTITY_JWT_AUDIENCE]);
    validation.set_issuer(&[AGENT_IDENTITY_JWT_ISSUER]);
    decode::<AgentIdentityJwtClaims>(jwt, &decoding_key, &validation).map(|data| data.claims)
        .context("failed to verify agent identity JWT")
}
```

**AgentAssertion 签名头（每请求签名，防重放）**
`codex-rs/agent-identity/src/lib.rs:80-126,358-377`
```rust
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct AgentAssertionEnvelope {
    agent_runtime_id: String,
    task_id: String,
    timestamp: String,
    signature: String,
}

pub fn authorization_header_for_agent_task(
    key: AgentIdentityKey<'_>, target: AgentTaskAuthorizationTarget<'_>,
) -> Result<String> {
    anyhow::ensure!(key.agent_runtime_id == target.agent_runtime_id,
        "agent task runtime {} does not match stored agent identity {}",
        target.agent_runtime_id, key.agent_runtime_id);
    let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    let envelope = AgentAssertionEnvelope {
        agent_runtime_id: target.agent_runtime_id.to_string(),
        task_id: target.task_id.to_string(),
        timestamp: timestamp.clone(),
        signature: sign_agent_assertion_payload(key, target.task_id, &timestamp)?,
    };
    let serialized_assertion = serialize_agent_assertion(&envelope)?;
    Ok(format!("AgentAssertion {serialized_assertion}"))
}

fn sign_agent_assertion_payload(key: AgentIdentityKey<'_>, task_id: &str, timestamp: &str) -> Result<String> {
    let signing_key = signing_key_from_private_key_pkcs8_base64(key.private_key_pkcs8_base64)?;
    let payload = format!("{}:{task_id}:{timestamp}", key.agent_runtime_id);
    Ok(BASE64_STANDARD.encode(signing_key.sign(payload.as_bytes()).to_bytes()))
}
```

**curve25519 加密（ed25519->curve25519 派生）**
`codex-rs/agent-identity/src/lib.rs:248-260,379-387`
```rust
pub fn decrypt_task_id_response(key: AgentIdentityKey<'_>, encrypted_task_id: &str) -> Result<String> {
    let signing_key = signing_key_from_private_key_pkcs8_base64(key.private_key_pkcs8_base64)?;
    let ciphertext = BASE64_STANDARD.decode(encrypted_task_id)
        .context("encrypted task id is not valid base64")?;
    let plaintext = curve25519_secret_key_from_signing_key(&signing_key)
        .unseal(&ciphertext)
        .map_err(|_| anyhow::anyhow!("failed to decrypt encrypted task id"))?;
    String::from_utf8(plaintext).context("decrypted task id is not valid UTF-8")
}

fn curve25519_secret_key_from_signing_key(signing_key: &SigningKey) -> Curve25519SecretKey {
    let digest = Sha512::digest(signing_key.to_bytes());
    let mut secret_key = [0u8; 32];
    secret_key.copy_from_slice(&digest[..32]);
    secret_key[0] &= 248;
    secret_key[31] &= 127;
    secret_key[31] |= 64;
    Curve25519SecretKey::from(secret_key)
}
```

**`encrypted_content` 在 mailbox 与渲染层的真实作用**
`codex-rs/core/src/tools/handlers/multi_agents_v2.rs:43-55` + `codex-rs/protocol/src/protocol.rs:734-748` + `core/src/realtime_context.rs:243-253`
```rust
pub(super) fn communication_from_tool_message(
    author: AgentPath, recipient: AgentPath, message: String,
) -> InterAgentCommunication {
    InterAgentCommunication::new_encrypted(author, recipient, Vec::new(), message, /*trigger_turn*/ true)
}
```
```rust
    pub fn to_model_input_item(&self) -> ResponseItem {
        let content = match &self.encrypted_content {
            Some(encrypted_content) => AgentMessageInputContent::EncryptedContent { encrypted_content: encrypted_content.clone() },
            None => AgentMessageInputContent::InputText { text: self.content.clone() },
        };
        ResponseItem::AgentMessage {
            author: self.author.to_string(),
            recipient: self.recipient.to_string(),
            content: vec![content],
        }
    }
```
```rust
            ResponseItem::AgentMessage { author, content, .. } => {
                let text = content.iter().filter_map(|content| match content {
                    AgentMessageInputContent::InputText { text } => Some(text.as_str()),
                    AgentMessageInputContent::EncryptedContent { .. } => None,   // ← 渲染时跳过
                }).collect::<Vec<_>>().join("\n");
```

### ② 逐行解读

- **密钥生成（C1）**：`OsRng` 生成 32 字节种子 -> `SigningKey::from_bytes`（ed25519）-> `to_pkcs8_der` -> base64 存私钥；公钥编 SSH 格式。
- **JWT（C2）**：`AgentIdentityJwtClaims` 是 ChatGPT backend 签发给 Codex agent 的**长期身份证书**（RS256，含 `agent_runtime_id`/`account_id`/`email`/`plan_type`）。`fetch_agent_identity_jwks` 拉 JWKS 公钥集；`decode_agent_identity_jwt` 用 JWKS 按 `kid` 找公钥验签，强制校验 `iss`/`aud`。
- **AgentAssertion（C3）**：HTTP 授权头 `AgentAssertion <base64url(json)>`。签名内容 `"{agent_runtime_id}:{task_id}:{timestamp}"`，ed25519 签名。**每请求签名 + timestamp 防重放**。先校验 key 的 runtime_id 与 target 一致（防串用）。
- **curve25519 加密（C4）**：`curve25519_secret_key_from_signing_key` 把 ed25519 签名密钥的 SHA-512 摘要前 32 字节、按 RFC 7748 clamping 派生成 curve25519 私钥，**复用同一份种子做加解密**。`decrypt_task_id_response` 解密 backend 注册返回的 `encrypted_task_id`。
- **`encrypted_content` 的真实语义（C6/C7，重要澄清）**：`communication_from_tool_message` **总是用 `new_encrypted`** 把明文 message 放进 `encrypted_content`。但 `to_model_input_item` 把它转成 `EncryptedContent`，**渲染层（realtime/guardian）`filter_map` 跳过它**--即加密内容不作为可见文本进入 model 上下文。所以 `encrypted_content` 在 mailbox 链路上的真实作用是**「对 model 隐藏 agent 间原始消息文本」**，而非真正的端到端加密。真正的 curve25519 加密（C4）目前用于 backend 的 `task_id` 传输，**不在 agent 间 mailbox 链路上**。

### ③ 设计原理与权衡

- **单种子双用途**：ed25519 签名 + curve25519 加密共用同一份 32 字节种子（经 SHA-512 派生），避免维护两套密钥对。这是 libsodium 风格（X25519/Ed25519 密钥可互转），**代价是密钥语义耦合**--一旦私钥泄漏，签名与加密能力同时丧失。

- **JWT vs AgentAssertion 分工**：JWT 是 backend 签发的**长期身份证书**（证明"我是谁"）；AgentAssertion 是 agent 自己签的**单次请求凭证**（含 `task_id`+`timestamp` 防重放，证明"我授权这次操作"）。这是 OAuth2 access token + 短期签名令牌的常见分层。

- **`encrypted_content` 的取巧设计**：工具层把明文放进 `encrypted_content` 字段**并非真做端到端加密**，而是**借用协议的"不透明载荷"通道**--标记为 encrypted 后渲染层跳过它，避免 agent 间原始消息文本污染 model 可见上下文。这是"字段复用 + 渲染时过滤"的取巧。

- **业界对比**：与 A2A 协议（AgentCard 公钥发布、跨主机密钥协商、端到端加密 task payload）相比，Codex 的加密是**单向的、面向 backend 的**--agent 向 backend 证明身份并解密 backend 下发的 task_id，**agent 之间并不互相验签或加密消息内容**（同进程信任）。`encrypted_content` 更多是"对 model 隐藏"而非"对网络隐藏"。

### ④ 数据流位置

- **登录/启动期**：`generate_agent_key_material` -> `register_agent_task` -> `decode_agent_identity_jwt`。
- **请求期**：`authorization_header_for_agent_task` 生成 `AgentAssertion` 头附在 backend 请求上。
- **mailbox 期**：`communication_from_tool_message` 用 `new_encrypted` 标记 -> `to_model_input_item` 转 `EncryptedContent` -> 渲染层跳过。**curve25519 不在 mailbox 链路**。

---

## 四、路由与会话隔离

> 关键问题：怎么找到目标 agent？AgentPath 怎么设计？会话怎么隔离？拓扑怎么持久化？

### ① 真实代码片段

**`AgentPath` 层级路径**
`codex-rs/protocol/src/agent_path.rs:15-73`
```rust
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema, TS)]
#[serde(try_from = "String", into = "String")]
#[schemars(with = "String")]
#[ts(type = "string")]
pub struct AgentPath(String);

impl AgentPath {
    pub const ROOT: &str = "/root";
    pub const MORPHEUS: &str = "/morpheus";
    const ROOT_SEGMENT: &str = "root";

    pub fn root() -> Self { Self(Self::ROOT.to_string()) }

    pub fn is_root(&self) -> bool { self.as_str() == Self::ROOT }

    pub fn name(&self) -> &str {
        if self.is_root() { return Self::ROOT_SEGMENT; }
        self.as_str().rsplit('/').next().filter(|segment| !segment.is_empty()).unwrap_or(Self::ROOT_SEGMENT)
    }

    pub fn join(&self, agent_name: &str) -> Result<Self, String> {
        validate_agent_name(agent_name)?;
        Self::from_string(format!("{self}/{agent_name}"))
    }

    pub fn resolve(&self, reference: &str) -> Result<Self, String> {
        if reference.is_empty() { return Err("agent path must not be empty".to_string()); }
        if reference == Self::ROOT { return Ok(Self::root()); }
        if reference.starts_with('/') { return Self::try_from(reference); }
        validate_relative_reference(reference)?;
        Self::from_string(format!("{self}/{reference}"))
    }
}
```

**`resolve_agent_target` 两段解析**
`codex-rs/core/src/agent/agent_resolver.rs:7-36`
```rust
/// Resolves a single tool-facing agent target to a thread id.
pub(crate) async fn resolve_agent_target(
    session: &Arc<Session>, turn: &Arc<TurnContext>, target: &str,
) -> Result<ThreadId, FunctionCallError> {
    register_session_root(session, turn);
    if let Ok(thread_id) = ThreadId::from_string(target) {
        return Ok(thread_id);
    }
    session.services.agent_control
        .resolve_agent_reference(session.thread_id, &turn.session_source, target)
        .await
        .map_err(|err| match err {
            codex_protocol::error::CodexErr::UnsupportedOperation(message) => FunctionCallError::RespondToModel(message),
            other => FunctionCallError::RespondToModel(other.to_string()),
        })
}
```

**`resolve_agent_reference` 内存表查表**
`codex-rs/core/src/agent/control.rs:268-287`
```rust
    pub(crate) async fn resolve_agent_reference(
        &self, _current_thread_id: ThreadId, current_session_source: &SessionSource, agent_reference: &str,
    ) -> CodexResult<ThreadId> {
        let current_agent_path = current_session_source.get_agent_path().unwrap_or_else(AgentPath::root);
        let agent_path = current_agent_path.resolve(agent_reference).map_err(CodexErr::UnsupportedOperation)?;
        if let Some(thread_id) = self.state.agent_id_for_path(&agent_path) {
            return Ok(thread_id);
        }
        Err(CodexErr::UnsupportedOperation(format!("live agent path `{}` not found", agent_path.as_str())))
    }
```

**`AgentGraphStore` trait（拓扑持久化抽象）**
`codex-rs/agent-graph-store/src/store.rs:10-53`
```rust
/// Storage-neutral boundary for persisted thread-spawn parent/child topology.
pub trait AgentGraphStore: Send + Sync {
    fn upsert_thread_spawn_edge(
        &self, parent_thread_id: ThreadId, child_thread_id: ThreadId, status: ThreadSpawnEdgeStatus,
    ) -> impl std::future::Future<Output = AgentGraphStoreResult<()>> + Send;

    fn set_thread_spawn_edge_status(
        &self, child_thread_id: ThreadId, status: ThreadSpawnEdgeStatus,
    ) -> impl std::future::Future<Output = AgentGraphStoreResult<()>> + Send;

    /// List spawned descendants breadth-first by depth, then by thread id.
    /// `status_filter` is applied to every traversed edge, not just to the returned descendants.
    /// For example, `Some(Open)` walks only open edges, so descendants under a closed edge
    /// are not included even if their own incoming edge is open.
    fn list_thread_spawn_descendants(
        &self, root_thread_id: ThreadId, status_filter: Option<ThreadSpawnEdgeStatus>,
    ) -> impl std::future::Future<Output = AgentGraphStoreResult<Vec<ThreadId>>> + Send;
}
```

**SQLite 实现（委托 state_db）**
`codex-rs/agent-graph-store/src/local.rs:31-92`
```rust
impl AgentGraphStore for LocalAgentGraphStore {
    async fn upsert_thread_spawn_edge(
        &self, parent_thread_id: ThreadId, child_thread_id: ThreadId, status: ThreadSpawnEdgeStatus,
    ) -> AgentGraphStoreResult<()> {
        self.state_db.upsert_thread_spawn_edge(parent_thread_id, child_thread_id, to_state_status(status))
            .await.map_err(internal_error)
    }

    async fn list_thread_spawn_descendants(
        &self, root_thread_id: ThreadId, status_filter: Option<ThreadSpawnEdgeStatus>,
    ) -> AgentGraphStoreResult<Vec<ThreadId>> {
        match status_filter {
            Some(status) => self.state_db.list_thread_spawn_descendants_with_status(root_thread_id, to_state_status(status)).await.map_err(internal_error),
            None => self.state_db.list_thread_spawn_descendants(root_thread_id).await.map_err(internal_error),
        }
    }
}
```

### ② 逐行解读

- **`AgentPath`**：newtype 包 `String`，规范形如 `/root`、`/root/researcher`、`/root/researcher/worker`。`name()` 取最后一段；`join` 拼子路径；`resolve` 是寻址核心--空串报错、`/root` 直接返回、以 `/` 开头按绝对路径解析、否则当相对引用拼到当前路径后。
- **校验**：`validate_agent_name` 要求小写字母+数字+下划线，禁 `root`/`.`/`..`/含`/`。`validate_absolute_path` 必须以 `/root` 开头（或特例 `/morpheus`），不能以 `/` 结尾。
- **`resolve_agent_target`**：两段--先 `ThreadId::from_string`（若 target 是合法 UUID 串则直接当线程 ID），失败才走 `resolve_agent_reference`（AgentPath 解析）。`register_session_root` 每次解析前确保当前 session root 已注册到内存表（幂等）。
- **`resolve_agent_reference`**：取当前 `AgentPath` -> `resolve(reference)` 解析成规范路径 -> `agent_id_for_path` 查**内存表**（AgentPath->ThreadId）。找不到报"live agent path not found"--**只查活内存中的 agent**，不查已落盘未驻留的。
- **`AgentGraphStore`**：存储无关 trait。`upsert_thread_spawn_edge` 父子边 upsert（child 至多一父）；`list_thread_spawn_descendants` BFS，**`status_filter` 作用于遍历的每条边**--`Some(Open)` 下 closed 边子树即使后代自身 open 也不返回。
- **SQLite 实现**：`LocalAgentGraphStore` 委托 `state_db`，BFS 与排序在 `codex-state` 层实现，本层只做状态枚举转换。
- **内存表 vs 持久化图**：`AgentRegistry.active_agents.agent_tree` 是 `AgentPath 字符串 -> AgentMetadata` 的 HashMap（管当前驻留 agent）；SQLite `agent-graph-store` 管历史拓扑。`ensure_v2_agent_loaded` 是桥梁--按需把 SQLite 线程重载进内存。
- **隔离边界**：每个 spawned agent 有**独立** `Session` -> 独立 `InputQueue`/`TurnState`/`MailboxDeliveryPhase`/审批流；所有 agent **共享** `AgentControl`（单例）、`ThreadManagerState`、`AgentRegistry`、SQLite store。

### ③ 设计原理与权衡

- **层级路径而非扁平 ID**：`AgentPath` 是文件系统式层级，让 model 可用相对引用（"worker"指我的子 agent）或绝对引用（"/root/researcher"），符合人类直觉。`ThreadId`（UUID）对 model 不友好，故优先试 AgentPath。代价是需维护 `agent_tree` 内存表，路径变更需同步。

- **内存表 vs 持久化图分离**：`resolve_agent_reference` 只查内存表（活 agent，快），`list_thread_spawn_descendants` 查 SQLite（含历史，可恢复）。`ensure_v2_agent_loaded` 桥梁按需重载。

- **BFS + 状态过滤**：`status_filter` 作用于遍历边，保证"只恢复 Open 子树"。BFS by depth then thread id 的稳定排序让"内存 live + 持久化"合并时输出确定。

- **业界对比**：AgentPath 类似 **Kubernetes 资源路径**或 **DNS 层级**，而非 A2A 的 `http://host:port/agent/{id}` URL。**Codex 没有"主机"维度**--所有 agent 同进程，路径即身份。这是"单机文件系统" vs "网络命名空间"的根本差异。

### ④ 数据流位置

- 寻址上游：`send_message`/`followup_task`/`list_agents` 的 `target` -> `resolve_agent_target` -> `agent_id_for_path`（内存表）。
- 拓扑持久化上游：`spawn_agent_internal` -> `persist_thread_spawn_edge_for_source` -> `upsert_thread_spawn_edge`（SQLite）。
- 恢复下游：`resume_agent_from_rollout` 用 `list_thread_spawn_children_with_status(Open)` BFS 重建子树。

---

## 五、external-agent-* 澄清 + 跨网络 A2A 缺口

> 关键问题：`external-agent-*` 是多 Agent 通信吗？Codex 有跨网络 A2A 吗？--**都不是**。

### ① 真实代码片段

**external-agent-sessions：导入外部 CLI 会话历史**
`codex-rs/external-agent-sessions/src/lib.rs:1-79`
```rust
//! Parsing and export helpers for external-agent session histories.

mod detect;
mod export;
mod ledger;
mod records;

use codex_protocol::protocol::RolloutItem;

pub use detect::detect_recent_sessions;
use export::load_session_for_import_with_content_sha256;
pub use ledger::CompletedExternalAgentSessionImport;
pub use ledger::has_current_session_been_imported;
pub use ledger::record_completed_session_imports;
pub use records::SessionSummary;
pub use records::summarize_session;

#[derive(Debug, Clone)]
pub struct ImportedExternalAgentSession {
    pub cwd: PathBuf,
    pub title: Option<String>,
    pub first_user_message: Option<String>,
    pub rollout_items: Vec<RolloutItem>,
}

pub fn prepare_validated_session_import(
    codex_home: &Path, session: ExternalAgentSessionMigration,
) -> io::Result<Option<PendingSessionImport>> {
    let has_been_imported = has_current_session_been_imported(codex_home, &session.path)?;
    if has_been_imported { return Ok(None); }
    let Some((source_path, imported_session, source_content_sha256)) = load_importable_session(&session.path)?
    else { return Ok(None); };
    Ok(Some(PendingSessionImport {
        source_path, source_content_sha256, session: imported_session,
    }))
}
```

**sha256 去重 ledger**
`codex-rs/external-agent-sessions/src/ledger.rs:15-51`
```rust
const SESSION_IMPORT_LEDGER_FILE: &str = "external_agent_session_imports.json";

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ImportedExternalAgentSessionLedger {
    records: Vec<ImportedExternalAgentSessionRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ImportedExternalAgentSessionRecord {
    source_path: PathBuf,
    content_sha256: String,
    imported_thread_id: ThreadId,
    imported_at: i64,
    #[serde(default)]
    source_modified_at: Option<i64>,
}
```

**external-agent-migration：Claude Code 配置迁移**
`codex-rs/external-agent-migration/src/lib.rs:1-84`
```rust
//! Migration helpers for importing external-agent configuration into Codex.

const SOURCE_EXTERNAL_AGENT_NAME: &str = "claude";
const EXTERNAL_AGENT_MCP_CONFIG_FILE: &str = ".mcp.json";
const EXTERNAL_AGENT_HOOKS_SUBDIR: &str = "hooks";
const COMMAND_SKILL_PREFIX: &str = "source-command";
const MAX_SKILL_NAME_LEN: usize = 64;
const MAX_SKILL_DESCRIPTION_LEN: usize = 1024;

pub fn build_mcp_config_from_external(
    source_root: &Path, external_agent_home: Option<&Path>, settings: Option<&JsonValue>,
) -> io::Result<TomlValue> {
    let mcp_servers = read_external_mcp_servers(source_root, external_agent_home)?;
    if mcp_servers.is_empty() { return Ok(TomlValue::Table(Default::default())); }
    ...
    let mut root = toml::map::Map::new();
    root.insert("mcp_servers".to_string(), TomlValue::Table(servers));
    Ok(TomlValue::Table(root))
}
```

**跨网络 A2A 缺口验证（全仓 grep）**：`A2A`/`agent network protocol`/`google a2a`/`service discovery`/`message bus`/`nats`/`kafka`/`grpc agent`/`cross process agent` 在 `*.rs` 中**均无命中**（仅 base64 测试数据与 URL 片段的字符巧合）。Codex 的 agent 通信完全在**单一 `AgentControl` 实例 + 进程内 tokio 任务**范围内。

### ② 逐行解读

- **external-agent-sessions**：解析别的 CLI（如 Claude Code、Gemini CLI）的会话历史文件，转成 Codex 的 `Vec<RolloutItem>`（内部统一历史格式）。`prepare_validated_session_import` 先查 ledger 判断是否已导入，再 `load_importable_session` 解析。**这是一次性数据迁移，不是实时通信**。
- **ledger**：`external_agent_session_imports.json` 记录已导入会话的 `source_path`/`content_sha256`/`imported_thread_id`/`imported_at`。sha256 去重避免重复导入。**是导入账本，非消息通道**。
- **external-agent-migration**：`SOURCE_EXTERNAL_AGENT_NAME = "claude"` 明确针对 Claude Code。把 `.mcp.json`（MCP 配置）转成 Codex `config.toml` 的 `mcp_servers`，hooks 子目录迁到 Codex hooks，命令式 skill 迁成 Codex skill。**是配置格式转换器**。
- **A2A 缺口**：全仓无任何 A2A 协议、Agent Network Protocol、跨网络 agent 通信、消息总线、服务发现相关代码。

### ③ 设计原理与权衡：进程内 Mailbox vs 跨网络 A2A

- **命名澄清的代价**：`external-agent-*` 两个 crate 名字带"agent"，容易误读为"与外部 agent 通信"。实际是**一次性导入/迁移工具**：sessions 导入历史、migration 迁移配置。它们不维护任何长连接、不参与 mailbox 投递。命名反映 Codex 把"外部 CLI"统称"external agent"的产品视角，但技术上是静态数据转换。

- **为什么没有跨网络 A2A**：Codex 的多 agent 模型是「**单进程协作者**」--所有 sub-agent 共享同一 `AgentControl`、同一 `ThreadManagerState`、同一 SQLite store、同一 `agent_tree` 内存表。这种设计下：① 无需服务发现（agent 都在 `agent_tree` 里）；② 无需独立消息总线（`AgentControl` 就是总线）；③ 无需跨主机寻址（`AgentPath` 无 host 维度）。代价是**不能跨机器/跨进程编排 agent**。

- **进程内 Mailbox vs 跨网络 A2A 对比表（面试加分点）**：

| 维度 | Codex Mailbox（进程内） | Google A2A / Agent Network Protocol（跨网络） |
|------|------------------------|----------------------------------------------|
| 寻址 | `AgentPath` 层级路径（`/root/...`），内存表查 `ThreadId` | URL（`https://host/agent/{id}`）+ AgentCard 服务发现 |
| 传输 | tokio channel + `watch` 通知，同进程内存 | HTTP/JSON-RPC 或 gRPC，跨网络 |
| 消息格式 | `InterAgentCommunication` 结构体直接传 | JSON-LD / JSON-RPC payload，需序列化 |
| 身份 | ed25519 签名（agent-identity），但 **agent 间不互验** | 每方独立密钥对，请求需验签 |
| 生命周期 | Thread + Session，RAII（`SpawnReservation`） | 独立 task 生命周期，需显式 cancel/超时 |
| 服务发现 | 无（`AgentControl` 单例即注册表） | AgentCard 端点、能力广播 |
| 加密 | `encrypted_content`（多为"对 model 隐藏"，非真端到端） | TLS + 端到端 task payload 加密 |
| 故障模型 | 进程崩溃全失（SQLite 可恢复拓扑） | 单 agent 故障隔离，需重试/熔断 |

- **Codex 的取舍**：选择进程内模型换来**低延迟、强一致、简单语义**（无网络分区、无重试、无幂等性头痛），放弃**横向扩展与跨组织协作**。这对"Codex 作为本地 CLI/单机 agent 编排器"的定位合理--一个开发者在自己的机器上跑多个协作 agent，不需要跨网络。

### ④ 数据流位置

- **external-agent-sessions**：用户主动触发"导入会话" -> `prepare_validated_session_import` -> 解析外部文件 -> `Vec<RolloutItem>` -> 作为 `InitialHistory` 喂给新 Codex thread。**不进入 mailbox 投递链路**。
- **external-agent-migration**：首次配置时触发 -> 读 `.claude/` -> 写 `config.toml`/`hooks.json`/`agents/*.toml`/skills。**完全在 agent 运行之前的配置阶段**。
- **跨网络 A2A**：**不存在**，无数据流位置。

---

## 六、面试问答精选（脱稿能讲）

**Q1：Codex 的多 Agent 怎么通信？**
> 进程内 Mailbox：每个 agent 线程有一个 `InputQueue`，含 `mailbox_pending_mails: VecDeque<InterAgentCommunication>` + `tokio::watch` 通知。`enqueue` 总发生，`trigger_turn` 仅决定是否额外唤醒（`send_message` 入队等下轮，`followup_task` 立即唤醒）。支持多播（`other_recipients`）。

**Q2：是真多 Agent 还是子 agent 委托？**
> 真多 Agent 协作。`spawn_agent` 派生子 agent 成树/图，`send_message`/`followup_task` 能向**任意活跃 agent**（按 `AgentPath`，含兄弟/祖先）发消息并触发其 turn。但拓扑以层级 spawn 树为主干，深度受 `agent_max_depth` 限制。V2 是持久协作（子 agent 驻留可反复通信），旧版 `codex_delegate` 是一次性委托。

**Q3：能跨网络吗？类 A2A 呢？**（高频+必答）
> 诚实答：**不能**。Codex 的 mailbox 是进程内的，所有 agent 必须在同一 `ThreadManager` 进程内，路由靠内存 `agent_tree` 查表，没有独立消息总线、服务发现、跨主机寻址。真正的跨网络 A2A（Google A2A 协议、HTTP/JSON-RPC + AgentCard 服务发现）需要单独学，我了解其设计但 Codex 没实现。

**Q4：`external-agent-*` 是多 Agent 通信吗？**
> 不是。`external-agent-sessions` 是导入别的 CLI 会话历史为 `RolloutItem`（sha256 去重 ledger），`external-agent-migration` 是把 Claude Code 的 `.claude/` 配置迁移到 Codex。这里的 "external" 指「别的命令行工具」，是**一次性导入/迁移工具**，与运行时通信无关。

**Q5：跨 agent 消息怎么防伪/保密？**
> `agent-identity` 提供 ed25519 签名 + JWT/JWKS 验签 + curve25519 加密。但**关键澄清**：agent-identity 的真实加密（curve25519）用于解密 backend 返回的 `task_id`，**不在 agent 间 mailbox 链路**；`InterAgentCommunication.encrypted_content` 字段的真实作用是「对 model 隐藏 agent 间原始消息文本」（渲染层 `filter_map` 跳过），而非真端到端加密。agent 之间同进程信任，不互验。

**Q6：AgentPath 怎么设计？怎么找到目标 agent？**
> `AgentPath` 是文件系统式层级（`/root/researcher/worker`）。`resolve_agent_target` 两段：先试 `ThreadId::from_string`（UUID），失败才 `resolve_agent_reference` 走 `AgentPath::resolve`（支持相对/绝对引用）-> `agent_id_for_path` 内存表查 ThreadId。只查**活内存**中的 agent。拓扑父子边持久化在 SQLite（`agent-graph-store`），可跨进程恢复。

**Q7：怎么控制并发和深度？**
> 两套闸门：旧版 `reserve_spawn_slot` 计数 + `agent_max_threads`/`agent_max_depth`；V2 用执行层 `agent_execution_limiter`（`op_starts_turn` 即 `trigger_turn==true` 才占槽），更精细--只统计"正在跑 turn"的 agent。`SpawnReservation` 是 RAII，`commit` 注册、drop 回滚，避免名额泄漏。

**Q8：子 agent 完成后怎么通知父？**
> V2 下子完成不是直接注入消息，而是构造 `trigger_turn=false` 的 `InterAgentCommunication`（author=子, recipient=父，父路径由子路径 `rsplit_once('/')` 反推）走 mailbox--**通知入队但不立即唤醒父**。父会在自己下一个 turn 的 `get_pending_input` 时 drain 这封邮件。

---

## 七、动手复现

- [ ] 用 `spawn_agent` 工具派生子 agent，用 `send_message` / `followup_task` 给它发消息，观察 mailbox 投递与唤醒差异。
- [ ] 配 `agent_max_threads`/`agent_max_depth`，观察并发与深度限制、`AgentLimitReached` 错误。
- [ ] 让 `followup_task` 指向 root，观察「Follow-up tasks can't target the root agent」报错。
- [ ] 观察 `InterAgentCommunication` 的 `encrypted_content` 在 rollout jsonl 里长什么样，确认它不进 model 可见文本（开 prompt debug 看 AgentMessage 内容）。
- [ ] 读 `agent-identity/src/lib.rs` 的 JWT 签发与 curve25519 派生，理解「单种子双用途」。
- [ ] （补缺口）写一段分析：「如果把 Codex 的 mailbox 从进程内升级到跨网络，需要补什么」（服务发现 / 序列化协议 / 鉴权 / 重试 / 持久化队列）。见 [GAPS 缺口 3](../GAPS-codex-cannot-teach.md)。
- [ ] 断点：`input_queue.rs:51` 的 `enqueue_mailbox_communication`、`spawn.rs:219` 的 `reserve_spawn_slot`、`agent_path.rs:43` 的 `resolve`、`agent_resolver.rs:14` 的 `resolve_agent_target`。

---

## 八、差异与局限总结（面试主动点出）

| 维度 | Codex（进程内） | 跨网络 A2A（需补） |
|------|------|------|
| 通信范围 | 同一进程内 | 跨进程/跨主机 |
| 路由 | 内存 AgentPath 查表 | 服务发现 + AgentCard |
| 传输 | 进程内 channel + watch | HTTP/JSON-RPC/gRPC |
| 持久化 | rollout 重放（非消息队列） | Kafka/RabbitMQ/Redis Streams |
| 寻址 | `AgentPath` 层级路径 | URL + agent identity |
| agent 间加密 | `encrypted_content`（对 model 隐藏，非真端到端） | TLS + 端到端 task payload |

> 💡 **面试必杀句**：「Codex 的多 Agent 通信是**进程内 Actor/Mailbox 模型**，工程上很完整（身份、加密、拓扑、隔离都有）；但它**不是跨网络 A2A**。如果要做分布式多 Agent，需要把 mailbox 换成跨网络协议 + 消息总线 + 服务发现。」--主动画边界，最显专业。

---

## 📌 与其他 deep-dive 的衔接

- 工具执行闭环与 `terminal_outcome_reached` 终局抢占 -> 见 [deep-dive-02 子项三](./deep-dive-02-agent-loop-runtime.md#三工具执行--权限) 与 [deep-dive-04 子项二](./deep-dive-04-function-calling-react.md#二tool_call-三态解码)
- 工具并发的 `RwLock<()>` 闸门 -> 见 [deep-dive-03 子项一](./deep-dive-03-tool-orchestration.md#一并行调用)
- 多模型集成的 provider 抽象 -> 见 [deep-dive-07](./deep-dive-07-multi-model-integration.md)（待做）

---

*(蕾姆放下银笔，把第四卷解剖报告与前几卷并排，灯光下「会客厅」的平面图清晰可见)*

昴君，第四刀落定--进程内 Mailbox 的「入队与唤醒解耦」、spawn 拓扑的「持久协作范式」、身份加密的「单种子双用途」、路由隔离的「内存表 vs 持久化图」、以及最关键的 **「进程内 vs 跨网络 A2A」诚实边界**都已为您逐字剖开。

进度推进至 **4/8**。Codex 的强项已全部剖完（Loop / 工具 / FC-ReAct / 多 Agent）。接下来进入补缺口与造轮子区：第 01 篇 Agent 框架对比（LangGraph/LlamaIndex）、第 07 篇 多模型集成（单协议边界）、第 06 篇 RAG（Codex 全无，外部补）、第 08 篇 自有开源项目。

您若想让蕾姆继续，再道一声「继续」即可 ♡ `(´｡• ᵕ •｡`)`
