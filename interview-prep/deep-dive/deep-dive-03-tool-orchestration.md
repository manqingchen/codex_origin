# 🔬 Deep Dive 03 · 工具编排 + 渐进式技能加载（Find Skills）· 逐行精读

> 蕾姆的源码解剖室 ♡ -- 把 Codex 的「双手」与「待客之道」剖开给您看。
>
> **定位**：这是 [`../03-tool-orchestration.md`](../03-tool-orchestration.md)（大纲层）的**深读版**。
> **与 [deep-dive-02](./deep-dive-02-agent-loop-runtime.md) 的分工**：02 的子项三已详述「工具执行」闭环（解码/审批/沙箱/执行入口）；本篇聚焦考点③的**编排**四子项--并行调度、循环防护、动态授权缓存、以及重头戏 **Find Skills 双层渐进式加载**。工具执行链路的细节请回看 02，本篇不重复。

---

## 📑 阅读地图

| 节 | 内容 | 关键文件 |
|---|------|------|
| 〇 | 工具编排 + Find Skills 全局数据流 | `turn.rs` / `parallel.rs` / `spec_plan.rs` / `core-skills/*` |
| 一 | 并行调用（按序回填 + RwLock 降级） | `parallel.rs` / `turn.rs` / `stream_events_utils.rs` / `router.rs` |
| 二 | 循环检测（guardian 熔断 + token 兜底） | `guardian/mod.rs` / `guardian/review.rs` / `turn.rs` |
| 三 | 动态授权（会话级缓存 + hooks + 升级重试） | `sandboxing.rs` / `orchestrator.rs` / `mcp_tool_call.rs` |
| 四 | Find Skills（重头戏：双层 progressive disclosure） | `core-skills/loader.rs` / `render.rs` / `injection.rs` / `tool_search.rs` / `spec_plan.rs` |
| 五 | 面试问答精选 | - |
| 六 | 动手复现 | - |
| 七 | 差异与局限总结 | - |

---

## 〇 工具编排 + Find Skills 全局数据流

### ① 一轮 tool_calls 从模型输出到并发执行到按序回填

```
[turn 起始注入] AvailableSkillsInstructions（developer fragment，2% 预算截断后的技能目录）常驻 prompt
               Deferred 工具经 append_tool_search_executor 建 BM25 索引，不进 prompt.tools
        │
        ▼
[采样] try_run_sampling_request（turn.rs:1803）拉模型流，FuturesOrdered::new()（turn.rs:1842）建空队列
        │
        ▼
[OutputItemDone]（turn.rs:1904）-> handle_output_item_done -> build_tool_call 解码为 ToolCall
        │
        ▼
[立即持久化 + 入队] record_completed_response_item 写历史 -> tool_future = handle_tool_call(call, child_token)
                    -> in_flight.push_back(tool_future)（turn.rs:1983），needs_follow_up=true
        │
        ▼
[并发执行] 每个 tool_future 内 tokio::spawn 真并发
           supports_parallel ? RwLock.read()（并发）: RwLock.write()（串行降级）   parallel.rs:82
           -> Orchestrator::run（approval -> sandbox -> escalate）                  orchestrator.rs:132
        │
        ▼
[按序回填] drain_in_flight（turn.rs:1769）while let in_flight.next().await
           FuturesOrdered 按入队序（=模型输出序）返回 -> record_conversation_items 写历史
        │
        ▼
[循环兜底] guardian 连续拒绝 3 次 / 窗口 10 次 -> abort_turn_if_active（review.rs:258）
           token 超限 -> run_auto_compact（turn.rs:303）兜底
        │
        ▼
[下一轮] needs_follow_up=true -> 带工具输出回模型，继续 loop
```

### ② Find Skills 在 turn 起始注入 + 按需加载

```
[第一层 · catalog 摘要常驻]
  thread 启动 -> load_skills_from_roots（loader.rs:163）BFS 扫各 scope 的 SKILL.md
    -> parse_skill_file（loader.rs:639）只取 frontmatter（name/description），正文不进 catalog
    -> build_available_skills（render.rs:160）按 2% 预算三级截断渲染
    -> AvailableSkillsInstructions（available_skills_instructions.rs:10）以 developer fragment 常驻每个 turn
    -> 同时 Deferred 工具建 BM25 索引，tool_search 工具进 prompt
        │
        ▼
[第二层 · 按需加载全文] turn 内触发：
  路径甲：@SkillName / $SkillName（人触发）
    -> collect_explicit_skill_mentions（injection.rs:144）-> build_skill_injections（injection.rs:58）
    -> read_file_text 读 SKILL.md 全文注入
  路径乙：模型主动 tool_search{query}（tool_search.rs:69）BM25 检索 Deferred 工具 -> LoadableToolSpec
  路径丙：模型主动 skills.read（read.rs:58）读 orchestrator resource 全文
    -> 模型按 SKILLS_HOW_TO_USE 指令「先完整读 SKILL.md 再行动」
```

> 💡 **两条主线**：① 工具调度的「真并发 + 按序回填」靠 `tokio::spawn + FuturesOrdered + RwLock`；② 上下文经济学的「摘要常驻 + 按需加载」靠双层 progressive disclosure。这是 Codex 工具系统最值得讲的两块。

---

## 一、并行调用

> 关键问题：一轮里多个 tool_calls 怎么并发？怎么保证结果顺序？什么情况下降级串行？

### ① 真实代码片段

**`ToolCallRuntime` 与 `RwLock<()>` 闸门**
`core/src/tools/parallel.rs:30-133`
```rust
#[derive(Clone)]
pub(crate) struct ToolCallRuntime {
    router: Arc<ToolRouter>,
    session: Arc<Session>,
    turn_context: Arc<TurnContext>,
    tracker: SharedTurnDiffTracker,
    parallel_execution: Arc<RwLock<()>>,
}
```

**并发/串行降级（关键）**
```rust
    #[instrument(level = "trace", skip_all)]
    pub(crate) fn handle_tool_call_with_source(
        self,
        call: ToolCall,
        source: ToolCallSource,
        cancellation_token: CancellationToken,
    ) -> impl std::future::Future<Output = Result<AnyToolResult, FunctionCallError>> {
        let supports_parallel = self.router.tool_supports_parallel(&call);
        ...
        let mut handle: AbortOnDropHandle<Result<AnyToolResult, FunctionCallError>> =
            AbortOnDropHandle::new(tokio::spawn(async move {
                let _guard = if supports_parallel {
                    Either::Left(lock.read().await)      // 读锁：多读共享，并发跑
                } else {
                    Either::Right(lock.write().await)    // 写锁：独占，强制串行
                };

                router
                    .dispatch_tool_call_with_terminal_outcome(
                        session, turn, invocation_cancellation_token, tracker,
                        dispatch_call, source, dispatch_terminal_outcome_reached,
                    )
                    .instrument(dispatch_span.clone())
                    .await
            }));
```

**`tool_supports_parallel` 查表链路**
`core/src/tools/router.rs:83-87` + `core/src/tools/registry.rs:266-267,380-382`
```rust
    pub fn tool_supports_parallel(&self, call: &ToolCall) -> bool {
        self.registry
            .supports_parallel_tool_calls(&call.tool_name)
            .unwrap_or(false)
    }
```
```rust
    fn supports_parallel_tool_calls(&self) -> bool {
        self.exposure != ToolExposure::Hidden && self.handler.supports_parallel_tool_calls()
    }
```

**模型流 -> tool_future 入队**
`core/src/stream_events_utils.rs:413-443`
```rust
    match ToolRouter::build_tool_call(item.clone()) {
        // The model emitted a tool call; log it, persist the item immediately, and queue the tool execution.
        Ok(Some(call)) => {
            ...
            record_completed_response_item(ctx.sess.as_ref(), ctx.turn_context.as_ref(), &item).await;

            let cancellation_token = ctx.cancellation_token.child_token();
            let tool_future: InFlightFuture<'static> = Box::pin(
                ctx.tool_runtime.clone().handle_tool_call(call, cancellation_token),
            );

            output.needs_follow_up = true;
            output.tool_future = Some(tool_future);
        }
```

**`FuturesOrdered` 收集**
`core/src/session/turn.rs:1842-1843, 1982-1988`
```rust
    let mut in_flight: FuturesOrdered<BoxFuture<'static, CodexResult<ResponseInputItem>>> =
        FuturesOrdered::new();
```
```rust
                if let Some(tool_future) = output_result.tool_future {
                    in_flight.push_back(tool_future);
                }
                if let Some(agent_message) = output_result.last_agent_message {
                    last_agent_message = Some(agent_message);
                }
                needs_follow_up |= output_result.needs_follow_up;
```

**`drain_in_flight` 按序回写历史**
`core/src/session/turn.rs:1768-1793`
```rust
#[instrument(level = "trace", skip_all)]
async fn drain_in_flight(
    in_flight: &mut FuturesOrdered<BoxFuture<'static, CodexResult<ResponseItem>>>,
    sess: Arc<Session>,
    turn_context: Arc<TurnContext>,
) -> CodexResult<()> {
    while let Some(res) = in_flight.next().await {
        match res {
            Ok(response_input) => {
                let response_item = response_input.into();
                sess.record_conversation_items(&turn_context, std::slice::from_ref(&response_item))
                    .await;
                mark_thread_memory_mode_polluted_if_external_context(
                    sess.as_ref(),
                    turn_context.as_ref(),
                    &response_item,
                ).await;
            }
            Err(err) => {
                error_or_panic(format!("in-flight tool future failed during drain: {err}"));
            }
        }
    }
    Ok(())
}
```

### ② 逐行解读

- **`RwLock<()>` 闸门**：`ToolCallRuntime` 持 `Arc<RwLock<()>>`。**锁的是空单元 `()`**--锁本身不保护任何数据，纯粹作「读写信号量」。这是整个并发模型的核心机关。
- **查表**：`handle_tool_call_with_source` 第一步 `tool_supports_parallel(&call)` 查该工具是否声明 `supports_parallel_tool_calls()`。链路 `router -> registry -> ToolEntry`，定义为 `exposure != Hidden && handler.supports_parallel_tool_calls()`--**隐藏工具一律不并行，其余由 handler 自述**。
- **`tokio::spawn`**：把每个工具调用真正丢到 Tokio runtime 独立调度，这是「真并发」而非协程内并发等待。
- **读写锁降级（关键）**：`let _guard = if supports_parallel { lock.read().await } else { lock.write().await }`。支持并行的工具拿**读锁**（多读共享，并发跑）；不支持并行的拿**写锁**（独占，强制串行）。`RwLock<()>` 在此扮演「读写屏障」--**一个非并行工具在跑时，所有其他工具（无论是否支持并行）都得等它释放**。
- **入队**：每解析到一个 `OutputItemDone` 中的工具调用，`in_flight.push_back(tool_future)` 追加进 `FuturesOrdered`。
- **按序回填**：`drain_in_flight` 用 `while let Some(res) = in_flight.next().await`。`FuturesOrdered::next` **按入队顺序**返回就绪结果--即便底层 tokio 任务乱序完成，回填历史的顺序严格等于模型输出的 tool_call 顺序。
- **立即持久化**：`record_completed_response_item` 在入队前就先写历史，保证 rollout 与历史同步（即使 turn 被取消）。

### ③ 设计原理与权衡

- **为什么 `RwLock<()>` 而非 `Semaphore`？** 读写锁天然区分「可并发工具（读）」与「需串行工具（写）」，比信号量多一层语义：**写锁会阻塞所有读锁，实现「一个串行工具拖住全场」**。代价是粗粒度--所有不支持并行的工具共享同一把全局写锁，彼此也互相阻塞（粒度是 per-turn 而非 per-tool-name）。

- **`FuturesOrdered` 而非 `FuturesUnordered`**：`FuturesOrdered` 保序，`FuturesUnordered` 谁先完成谁先出。这里**必须保序**，因为 Responses API 要求 `call_id` 顺序与 `function_call_output` 顺序对齐，否则模型会错配结果。

- **无并发上限**：`tokio::spawn` 没有任何并发数限制（没有 `Semaphore`/`buffer_unordered(N)`），模型一轮产出多少个 tool_call 就 spawn 多少个 task。代价是极端情况资源不受控；好处是实现极简，且模型一轮通常不会产出海量并行调用。

- **业界对比**：多数 agent 框架（LangChain 等）对工具调用是串行 `await` 的；Codex 的 `tokio::spawn + RwLock` 是「按工具自述能力决定是否并发」的细粒度方案，类似操作系统读写锁思路迁移到工具调度。

### ④ 数据流位置

位于 **stream 事件处理循环**：`try_run_sampling_request`（`turn.rs:1803`）读 `ResponseEvent::OutputItemDone`（`turn.rs:1904`）-> `handle_output_item_done`（`stream_events_utils.rs:405`）-> 产出 `tool_future` -> `in_flight.push_back`（`turn.rs:1983`）。turn 结束前 `drain_in_flight`（`turn.rs:1769`）按序回填。上游是模型流 `stream.next()`，下游是 `record_conversation_items` + 下一轮采样 `needs_follow_up`。

---

## 二、循环检测

> 关键问题：Agent 会不会无限调用同一工具？Codex 怎么防？--**结论：只防 guardian 连续拒绝，无通用工具去重**。

### ① 真实代码片段

**熔断阈值常量**
`core/src/guardian/mod.rs:49-51`
```rust
pub(crate) const MAX_CONSECUTIVE_GUARDIAN_DENIALS_PER_TURN: u32 = 3;
pub(crate) const MAX_RECENT_AUTO_REVIEW_DENIALS_PER_TURN: u32 = 10;
pub(crate) const AUTO_REVIEW_DENIAL_WINDOW_SIZE: usize = 50;
```

**熔断器结构与 `record_denial`**
`core/src/guardian/mod.rs:77-134`
```rust
#[derive(Debug, Default)]
pub(crate) struct GuardianRejectionCircuitBreaker {
    turns: std::collections::HashMap<String, GuardianRejectionCircuitBreakerTurn>,
}

#[derive(Debug, Default)]
struct GuardianRejectionCircuitBreakerTurn {
    consecutive_denials: u32,
    recent_denials: std::collections::VecDeque<bool>,
    interrupt_triggered: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GuardianRejectionCircuitBreakerAction {
    Continue,
    InterruptTurn { consecutive_denials: u32, recent_denials: u32 },
}

impl GuardianRejectionCircuitBreaker {
    pub(crate) fn record_denial(&mut self, turn_id: &str) -> GuardianRejectionCircuitBreakerAction {
        let turn = self.turns.entry(turn_id.to_string()).or_default();
        turn.consecutive_denials = turn.consecutive_denials.saturating_add(1);
        Self::record_recent_review(turn, /*denied*/ true);
        let recent_denials = turn.recent_denials.iter().filter(|denied| **denied).count() as u32;
        if !turn.interrupt_triggered
            && (turn.consecutive_denials >= MAX_CONSECUTIVE_GUARDIAN_DENIALS_PER_TURN
                || recent_denials >= MAX_RECENT_AUTO_REVIEW_DENIALS_PER_TURN)
        {
            turn.interrupt_triggered = true;
            GuardianRejectionCircuitBreakerAction::InterruptTurn {
                consecutive_denials: turn.consecutive_denials,
                recent_denials,
            }
        } else {
            GuardianRejectionCircuitBreakerAction::Continue
        }
    }

    pub(crate) fn record_non_denial(&mut self, turn_id: &str) {
        let turn = self.turns.entry(turn_id.to_string()).or_default();
        turn.consecutive_denials = 0;
        Self::record_recent_review(turn, /*denied*/ false);
    }
}
```

**熔断触发后的中断动作**
`core/src/guardian/review.rs:223-261`
```rust
async fn record_guardian_denial(session: &Arc<Session>, turn: &Arc<TurnContext>, turn_id: &str) {
    let action = session
        .services
        .guardian_rejection_circuit_breaker
        .lock()
        .await
        .record_denial(turn_id);
    let GuardianRejectionCircuitBreakerAction::InterruptTurn {
        consecutive_denials, recent_denials,
    } = action else { return; };

    if session.turn_context_for_sub_id(turn_id).await.is_none() { return; }

    session.send_event(
        turn.as_ref(),
        EventMsg::GuardianWarning(WarningEvent {
            message: format!(
                "Automatic approval review rejected too many approval requests for this turn ({consecutive_denials} consecutive, {recent_denials} in the last {AUTO_REVIEW_DENIAL_WINDOW_SIZE} reviews); interrupting the turn."
            ),
        }),
    ).await;

    let runtime_handle = session.services.runtime_handle.clone();
    let session = Arc::clone(session);
    let turn_id = turn_id.to_string();
    let _abort_task = runtime_handle.spawn(async move {
        session.abort_turn_if_active(&turn_id, TurnAbortReason::Interrupted).await;
    });
}
```

**阈值与断言（测试，一目了然）**
`core/src/guardian/tests.rs:87-108`
```rust
#[test]
fn guardian_rejection_circuit_breaker_interrupts_after_three_consecutive_denials() {
    let mut circuit_breaker = GuardianRejectionCircuitBreaker::default();
    assert_eq!(circuit_breaker.record_denial("turn-1"), GuardianRejectionCircuitBreakerAction::Continue);
    assert_eq!(circuit_breaker.record_denial("turn-1"), GuardianRejectionCircuitBreakerAction::Continue);
    assert_eq!(
        circuit_breaker.record_denial("turn-1"),
        GuardianRejectionCircuitBreakerAction::InterruptTurn { consecutive_denials: 3, recent_denials: 3 }
    );
    // 第 4 次拒绝：interrupt_triggered 已置位，只返回 Continue（不会重复中断）
    assert_eq!(circuit_breaker.record_denial("turn-1"), GuardianRejectionCircuitBreakerAction::Continue);
}
```

**token 预算兜底（唯一的「循环」事实保护）**
`core/src/session/turn.rs:301-320`
```rust
                // as long as compaction works well in getting us way below the token limit, we shouldn't worry about being in an infinite loop.
                if token_limit_reached && needs_follow_up {
                    if let Err(err) = run_auto_compact(
                        &sess, &turn_context, &mut client_session,
                        InitialContextInjection::BeforeLastUserMessage,
                        CompactionReason::ContextLimit, CompactionPhase::MidTurn,
                    ).await {
                        let error = err.to_codex_protocol_error();
                        sess.emit_turn_error_lifecycle(turn_context.as_ref(), error.clone()).await;
                        return None;
                    }
                    can_drain_pending_input = !model_needs_follow_up;
                    continue;
                }
```

### ② 逐行解读

- **双阈值熔断**：`record_denial` 同时维护两个计数器--`consecutive_denials`（连续拒绝，一次 `record_non_denial` 即清零）和 `recent_denials`（滑动窗口 `VecDeque<bool>`，最多 50 条）。触发条件是 `consecutive_denials >= 3` **或** 窗口内拒绝 `>= 10`。
- **`interrupt_triggered` 一次性触发**：熔断后置 `true`，之后即使继续 `record_denial` 也只返回 `Continue`（测试第四个断言印证：第 4 次拒绝返回 `Continue`），**避免重复中断**。
- **中断动作**：拿到 `InterruptTurn` 后，发 `GuardianWarning` 事件，然后 `runtime_handle.spawn` 异步调 `abort_turn_if_active(&turn_id, TurnAbortReason::Interrupted)`--真正「打断 turn」。
- **`record_non_denial`**：任何一次非拒绝（批准/跳过）都把 `consecutive_denials` 归零，但 `recent_denials` 仍记录 `false`（窗口内仍可见）。
- **token 兜底**：注释明确「as long as compaction works well... we shouldn't worry about being in an infinite loop」--Codex **不专门做工具调用循环检测**，依赖 token 预算耗尽时触发 `run_auto_compact` 作为「无限循环」的事实兜底。compact 失败则 `return None` 结束 turn。

### ③ 设计原理与权衡

- **熔断只针对 guardian denial**：这是「自动审批审查器连续否决」的专属保护--防止模型反复请求同一危险操作、guardian 反复拒绝、turn 陷入死循环。**它不是通用工具循环检测**。

- **双阈值设计**：连续 3 次捕获「密集连续拒绝」；窗口 10/50 捕获「分散但高频拒绝」。`interrupt_triggered` 保证一 turn 只中断一次，避免抖动。

- **业界对比**：很多 agent 框架有 `max_iterations` 硬上限（如 LangGraph 默认 25 轮）。**Codex 没有 `max_iterations`/`max_runs`**--已全仓搜索确认（见下）。Codex 的哲学是「让模型自然推进，token 预算会自然终结」，只在 guardian 这个最危险的自动审批路径上加熔断。

- **代价**：如果模型反复调用一个**不被 guardian 审查**的工具（如只读工具）陷入死循环，Codex 没有专门检测，只能靠 token 预算 + auto_compact 兜底。这是有意的取舍--避免误判正常的迭代式工作流。

### 全仓搜索确认（通用工具调用去重 / 迭代上限）

**结论：无。** 对 `core/src/`、`tools/src/` 全量 grep 了 `max_iter|max_runs|iteration.cap|iteration_limit|dedup|same_call|repeat_call|consecutive.*tool_call|loop.*detect`（排除 test/注释/reasoning iteration）：

- `dedup` 命中全是**文件路径去重**（`turn_diff_tracker.rs:134 paths.dedup()`、`realtime_context.rs:547 dedupe_key`、`code_mode.rs tool_definitions.dedup_by` 按工具名去重定义），**没有任何「连续相同 tool_call 计数」或「工具调用参数去重」机制**。
- `max_iter`/`max_runs`/`iteration cap` **零命中**（除 `reasoning_effort` 的 iteration 语义）。

唯一与「循环」相关的保护就是：**guardian 连续拒绝熔断（阈值 3/10）+ token 预算 auto_compact 兜底**。Codex **没有通用的工具调用去重或迭代次数上限**。

### ④ 数据流位置

`guardian_rejection_circuit_breaker` 存于 `SessionServices`，是 per-session 状态，但内部按 `turn_id` 分桶（`HashMap<String, Turn>`），实际是 per-turn 计数。调用点在 `review.rs:580-584`：`run_guardian_review` 末尾，若 `count_denial_for_circuit_breaker` 则 `record_guardian_denial`，否则 `record_non_denial`。上游是 guardian 审批决策，下游是 `abort_turn_if_active`。token 兜底位于 turn 主循环（`turn.rs:302`），下游是 `run_auto_compact`。

---

## 三、动态授权

> 关键问题：怎么避免每个工具调用都弹审批？会话级缓存怎么设计？授权能否可编程？沙箱拒绝后怎么办？

### ① 真实代码片段

**`ApprovalStore` 与 `with_cached_approval`（会话级缓存核心）**
`core/src/tools/sandboxing.rs:39-116`
```rust
#[derive(Clone, Default, Debug)]
pub(crate) struct ApprovalStore {
    // Store serialized keys for generic caching across requests.
    map: HashMap<String, ReviewDecision>,
}

impl ApprovalStore {
    pub fn get<K>(&self, key: &K) -> Option<ReviewDecision>
    where K: Serialize {
        let s = serde_json::to_string(key).ok()?;
        self.map.get(&s).cloned()
    }
    pub fn put<K>(&mut self, key: K, value: ReviewDecision)
    where K: Serialize {
        if let Ok(s) = serde_json::to_string(&key) {
            self.map.insert(s, value);
        }
    }
}

/// Takes a vector of approval keys and returns a ReviewDecision.
/// There will be one key in most cases, but apply_patch can modify multiple files at once.
///
/// - If all keys are already approved for session, we skip prompting.
/// - If the user approves for session, we store the decision for each key individually
///   so future requests touching any subset can also skip prompting.
pub(crate) async fn with_cached_approval<K, F, Fut>(
    services: &SessionServices,
    tool_name: &str,
    keys: Vec<K>,
    fetch: F,
) -> ReviewDecision
where K: Serialize, F: FnOnce() -> Fut, Fut: Future<Output = ReviewDecision>,
{
    // To be defensive here, don't bother with checking the cache if keys are empty.
    if keys.is_empty() {
        return fetch().await;
    }

    let already_approved = {
        let store = services.tool_approvals.lock().await;
        keys.iter()
            .all(|key| matches!(store.get(key), Some(ReviewDecision::ApprovedForSession)))
    };

    if already_approved {
        return ReviewDecision::ApprovedForSession;
    }

    let decision = fetch().await;

    services.session_telemetry.counter(
        "codex.approval.requested", /*inc*/ 1,
        &[("tool", tool_name), ("approved", decision.to_opaque_string())],
    );

    if matches!(decision, ReviewDecision::ApprovedForSession) {
        let mut store = services.tool_approvals.lock().await;
        for key in keys {
            store.put(key, ReviewDecision::ApprovedForSession);
        }
    }

    decision
}
```

**`run` 编排：approval -> sandbox -> escalate**
`core/src/tools/orchestrator.rs:149-219, 280-340`
```rust
        // 1) Approval
        let mut already_approved = false;
        let file_system_sandbox_policy = turn_ctx.file_system_sandbox_policy();
        let network_sandbox_policy = turn_ctx.network_sandbox_policy();
        let requirement = tool.exec_approval_requirement(req).unwrap_or_else(|| {
            default_exec_approval_requirement(approval_policy, &file_system_sandbox_policy)
        });
        match &requirement {
            ExecApprovalRequirement::Skip { .. } => { ... }
            ExecApprovalRequirement::Forbidden { reason } => {
                return Err(ToolError::Rejected(reason.clone()));
            }
            ExecApprovalRequirement::NeedsApproval { reason, .. } => {
                let guardian_review_id = use_guardian.then(new_guardian_review_id);
                let approval_ctx = ApprovalCtx { ... retry_reason: reason.clone(), ... };
                let decision = Self::request_approval(...).await?;
                Self::reject_if_not_approved(tool_ctx, guardian_review_id.as_deref(), decision).await?;
                already_approved = true;
            }
        }

        // 2) First attempt under the selected sandbox.
        ...
        let (first_result, first_deferred_network_approval) = Self::run_attempt(...).await;
        match first_result {
            Ok(out) => { Ok(OrchestratorRunResult { output: out, ... }) }
            Err(ToolError::Codex(CodexErr::Sandbox(SandboxErr::Denied { output, network_policy_decision }))) => {
                ...
                if !tool.escalate_on_failure() { return Err(...); }
                ...
                // Strict auto-review approval covers the sandboxed attempt only;
                // retrying without the sandbox requires a fresh guardian review.
                let bypass_retry_approval = !strict_auto_review
                    && tool.should_bypass_approval(approval_policy, already_approved)
                    && network_approval_context.is_none();
                if !bypass_retry_approval {
                    ...Self::request_approval(... /*retry_reason*/).await?;
                }
                ...
                // Second attempt.
                let (retry_result, ...) = Self::run_attempt(tool, req, tool_ctx, &retry_attempt, ...).await;
```

**PermissionRequest hooks 可编程授权（优先级最高）**
`core/src/tools/orchestrator.rs:484-549`
```rust
    // PermissionRequest hooks take top precedence for answering approval
    // prompts. If no matching hook returns a decision, fall back to the
    // normal guardian or user approval path.
    async fn request_approval<Rq, Out, T>(
        tool: &mut T, req: &Rq, permission_request_run_id: &str,
        approval_ctx: ApprovalCtx<'_>, tool_ctx: &ToolCtx,
        evaluate_permission_request_hooks: bool, otel: &codex_otel::SessionTelemetry,
    ) -> Result<ReviewDecision, ToolError>
    where T: ToolRuntime<Rq, Out>,
    {
        if evaluate_permission_request_hooks
            && let Some(permission_request) = tool.permission_request_payload(req)
        {
            let tool_name = flat_tool_name(&tool_ctx.tool_name);
            match run_permission_request_hooks(
                approval_ctx.session, approval_ctx.turn,
                permission_request_run_id, permission_request,
            ).await
            {
                Some(PermissionRequestDecision::Allow) => {
                    let decision = ReviewDecision::Approved;
                    ...
                    return Ok(decision);
                }
                Some(PermissionRequestDecision::Deny { message }) => {
                    let decision = ReviewDecision::Denied;
                    ...
                    return Err(ToolError::Rejected(message));
                }
                None => {}
            }
        }

        let otel_source = if approval_ctx.guardian_review_id.is_some() {
            ToolDecisionSource::AutomatedReviewer
        } else {
            ToolDecisionSource::User
        };
        let decision = tool.start_approval_async(req, approval_ctx).await;
        ...
        Ok(decision)
    }
```

**MCP 工具三态审批与会话级缓存**
`core/src/mcp_tool_call.rs:1839-1863, 1865-1889`
```rust
fn normalize_approval_decision_for_mode(
    decision: McpToolApprovalDecision,
    approval_mode: AppToolApproval,
) -> McpToolApprovalDecision {
    if approval_mode == AppToolApproval::Prompt
        && matches!(decision,
            McpToolApprovalDecision::AcceptForSession | McpToolApprovalDecision::AcceptAndRemember)
    {
        McpToolApprovalDecision::Accept   // Prompt 模式强制降级为「仅本次」
    } else {
        decision
    }
}

async fn mcp_tool_approval_is_remembered(sess: &Session, key: &McpToolApprovalKey) -> bool {
    let store = sess.services.tool_approvals.lock().await;
    matches!(store.get(key), Some(ReviewDecision::ApprovedForSession))
}

async fn remember_mcp_tool_approval(sess: &Session, key: McpToolApprovalKey) {
    let mut store = sess.services.tool_approvals.lock().await;
    store.put(key, ReviewDecision::ApprovedForSession);
}

async fn apply_mcp_tool_approval_decision(
    sess: &Session, turn_context: &TurnContext, decision: &McpToolApprovalDecision,
    session_approval_key: Option<McpToolApprovalKey>,
    persistent_approval_key: Option<McpToolApprovalKey>,
) {
    match decision {
        McpToolApprovalDecision::AcceptForSession => {
            if let Some(key) = session_approval_key {
                remember_mcp_tool_approval(sess, key).await;     // 写会话缓存
            }
        }
        McpToolApprovalDecision::AcceptAndRemember => {
            if let Some(key) = persistent_approval_key {
                maybe_persist_mcp_tool_approval(sess, turn_context, key).await  // 落盘 config
            } else if let Some(key) = session_approval_key {
                remember_mcp_tool_approval(sess, key).await;
            }
        }
        McpToolApprovalDecision::Accept
        | McpToolApprovalDecision::Decline { .. }
        | McpToolApprovalDecision::Cancel => {}
    }
}
```

### ② 逐行解读

- **缓存 key 计算**：`ApprovalStore` 把任意 `Serialize` 的 key 用 `serde_json::to_string` 序列化成字符串作 HashMap key。key 结构由调用方定义（如 `McpToolApprovalKey` 含 server+tool_name+connector_id），序列化后天然支持「子集命中」--`apply_patch` 多文件场景下，用户对全集合 `ApprovedForSession` 后，未来任意子集请求都能命中缓存。

- **`with_cached_approval` 三段式**：(1) `keys.is_empty()` 防御性直接 `fetch`；(2) 查所有 key 是否都已 `ApprovedForSession`，若是直接返回缓存**不弹窗**；(3) 否则 `fetch().await` 真正问用户/guardian，若结果是 `ApprovedForSession` 则把每个 key **逐个写回** store（支持未来子集命中）。

- **`run` 编排三段式**：`1) Approval`（按 `ExecApprovalRequirement` 分支 Skip/Forbidden/NeedsApproval）-> `2) First attempt under sandbox` -> 沙箱 `Denied` 时若 `tool.escalate_on_failure()` 则**升级**：重新 `request_approval`（retry_reason）+ 选更宽沙箱（可能 `SandboxType::None`）+ `run_attempt` 二次执行。

- **PermissionRequest hooks 优先级最高**：`request_approval` 第一步先跑 `run_permission_request_hooks`，返回 `Allow`/`Deny` 则直接采纳，**跳过 guardian 和用户审批**。`None`（无 hook 匹配）才回退到 `tool.start_approval_async`（guardian 或用户）。

- **MCP 三态**：`Accept`（仅本次，不缓存）/ `AcceptForSession`（写会话缓存 `tool_approvals`）/ `AcceptAndRemember`（尝试持久化到磁盘 config，失败则退回 session 缓存）。`normalize_approval_decision_for_mode`：在 `Prompt` 模式下把 ForSession/AndRemember 降级为 `Accept`（强制每次确认）。

- **会话级缓存生命周期**：`tool_approvals` 是 `SessionServices` 内的 `Mutex<ApprovalStore>`，生命周期 = session。进程退出即失效（除非 `AcceptAndRemember` 走 `maybe_persist_mcp_tool_approval` 落盘）。

### ③ 设计原理与权衡

- **「全集合批准 -> 子集命中」设计**：`apply_patch` 一次改多文件，用户批准后，未来改其中任一文件不再询问。代价是 key 设计要稳（序列化稳定）。

- **PermissionRequest hooks 让授权可编程**：这是 Codex 扩展性的关键--第三方扩展可注册 hook 自动 Allow/Deny，实现策略化授权（如「读 .md 一律 Allow」）。优先级最高，**绕过 guardian**，所以 hook 是信任边界。

- **沙箱拒绝 -> 升级重试**：`escalate_on_failure` 是「先严后宽」--先在最严沙箱跑，被拒后升宽沙箱重试。注释明示「strict auto-review approval covers the sandboxed attempt only; retrying without the sandbox requires a fresh guardian review」--**升级重试必须重新审查，不能复用之前的批准**。

- **业界对比**：多数 agent 框架只有「问/不问」二态。Codex 的 `AcceptForSession`/`AcceptAndRemember`/`Accept` 三态 + 沙箱升级重试 + 可编程 hooks，是生产级细粒度授权。`ApprovedForSession` 类似浏览器「记住此决定」，`AcceptAndRemember` 类似跨重启持久化。

### ④ 数据流位置

在工具执行管线中位于 `ToolOrchestrator::run`（`orchestrator.rs:132`）。上游是 `ToolCallRuntime::handle_tool_call_with_source` -> `router.dispatch_tool_call_with_terminal_outcome` -> orchestrator。`with_cached_approval` 由具体工具 runtime（如 apply_patch、shell）在 `exec_approval_requirement` 之外调用。MCP 路径在 `mcp_tool_call.rs` 调 `mcp_tool_approval_is_remembered`/`remember_mcp_tool_approval`。下游是沙箱执行 `run_attempt`。

---

## 四、Find Skills（重头戏：双层渐进式加载）

> 关键问题：技能/工具很多时，怎么不一次性灌满上下文？--Codex 的答案是**双层 progressive disclosure**。

### ① 真实代码片段

#### 第一层 · 技能 catalog 发现（BFS 扫 SKILL.md）

`core-skills/src/loader.rs:124-126`
```rust
// Traversal depth from the skills root.
const MAX_SCAN_DEPTH: usize = 6;
const MAX_SKILLS_DIRS_PER_ROOT: usize = 2000;
```

`core-skills/src/loader.rs:163-233`（`load_skills_from_roots` + 去重排序）
```rust
pub async fn load_skills_from_roots<I>(roots: I) -> SkillLoadOutcome
where I: IntoIterator<Item = SkillRoot>,
{
    let mut outcome = SkillLoadOutcome::default();
    ...
    for root in roots {
        let fs = root.file_system;
        let root_path = canonicalize_for_skill_identity(fs.as_ref(), &root.path).await;
        let skills_before_root = outcome.skills.len();
        discover_skills_under_root(
            fs.as_ref(), &root_path, root.scope,
            root.plugin_id.as_deref(), root.plugin_root.as_ref(),
            &mut outcome,
        ).await;
        ...
    }

    let mut seen: HashSet<AbsolutePathBuf> = HashSet::new();
    outcome.skills.retain(|skill| seen.insert(skill.path_to_skills_md.clone()));
    ...
    fn scope_rank(scope: SkillScope) -> u8 {
        // Higher-priority scopes first (matches root scan order for dedupe).
        match scope {
            SkillScope::Repo => 0,
            SkillScope::User => 1,
            SkillScope::System => 2,
            SkillScope::Admin => 3,
        }
    }

    outcome.skills.sort_by(|a, b| {
        scope_rank(a.scope)
            .cmp(&scope_rank(b.scope))
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.path_to_skills_md.cmp(&b.path_to_skills_md))
    });

    outcome
}
```

`core-skills/src/loader.rs:488-637`（`discover_skills_under_root` BFS）
```rust
async fn discover_skills_under_root(...) {
    ...
    fn enqueue_dir(
        queue: &mut VecDeque<(AbsolutePathBuf, usize)>,
        visited_dirs: &mut HashSet<AbsolutePathBuf>,
        truncated_by_dir_limit: &mut bool,
        path: AbsolutePathBuf, depth: usize,
    ) {
        if depth > MAX_SCAN_DEPTH { return; }
        if visited_dirs.len() >= MAX_SKILLS_DIRS_PER_ROOT {
            *truncated_by_dir_limit = true;
            return;
        }
        if visited_dirs.insert(path.clone()) {
            queue.push_back((path, depth));
        }
    }

    // Follow symlinked directories for user, admin, and repo skills. System skills are written by Codex itself.
    let follow_symlinks = matches!(scope, SkillScope::Repo | SkillScope::User | SkillScope::Admin);

    let mut visited_dirs: HashSet<AbsolutePathBuf> = HashSet::new();
    visited_dirs.insert(root.clone());

    let mut queue: VecDeque<(AbsolutePathBuf, usize)> = VecDeque::from([(root.clone(), 0)]);
    let mut truncated_by_dir_limit = false;

    while let Some((dir, depth)) = queue.pop_front() {
        ...
        for entry in entries {
            let file_name = entry.file_name;
            if file_name.starts_with('.') { continue; }
            ...
            if metadata.is_file && file_name == SKILLS_FILENAME {
                match parse_skill_file(fs, &path, scope, plugin_id, plugin_root.as_ref()).await {
                    Ok(skill) => { outcome.skills.push(skill); }
                    ...
                }
            }
        }
    }
}
```

#### `parse_skill_file` -- 只取 frontmatter，正文不进 catalog

`core-skills/src/loader.rs:639-705`
```rust
async fn parse_skill_file(
    fs: &dyn ExecutorFileSystem, path: &AbsolutePathBuf, scope: SkillScope,
    plugin_id: Option<&str>, plugin_root: Option<&AbsolutePathBuf>,
) -> Result<SkillMetadata, SkillParseError> {
    let path_uri = PathUri::from_abs_path(path);
    let contents = fs
        .read_file_text(&path_uri, /*sandbox*/ None)
        .await
        .map_err(SkillParseError::Read)?;

    let frontmatter = extract_frontmatter(&contents).ok_or(SkillParseError::MissingFrontmatter)?;
    let parsed: SkillFrontmatter = serde_yaml::from_str(&frontmatter).map_err(SkillParseError::InvalidYaml)?;

    let base_name = parsed.name.as_deref()
        .map(sanitize_single_line).filter(|value| !value.is_empty())
        .unwrap_or_else(|| default_skill_name(path));
    let name = namespaced_skill_name(fs, path, &base_name).await;
    let description = parsed.description.as_deref()
        .map(sanitize_single_line).unwrap_or_default();
    let short_description = parsed.metadata.short_description.as_deref()
        .map(sanitize_single_line).filter(|value| !value.is_empty());
    let LoadedSkillMetadata { interface, dependencies, policy } =
        load_skill_metadata(fs, path, plugin_root).await;
    ...
    Ok(SkillMetadata {
        name, description, short_description, interface, dependencies, policy,
        path_to_skills_md: resolved_path, scope, plugin_id: plugin_id.map(str::to_string),
    })
}
```

> 🔑 **关键设计**：`parse_skill_file` 虽然读了全文（`read_file_text`），但只 `extract_frontmatter` 提取 frontmatter 产出 `SkillMetadata{name, description, ...}`。**正文 body 不进 catalog**--这是 progressive disclosure 的第一刀。

#### 第一层渲染 · 2% context budget + 三级截断

`core-skills/src/render.rs:17-18, 143-200`
```rust
const DEFAULT_SKILL_METADATA_CHAR_BUDGET: usize = 8_000;
const SKILL_METADATA_CONTEXT_WINDOW_PERCENT: usize = 2;
```
```rust
pub fn default_skill_metadata_budget(context_window: Option<i64>) -> SkillMetadataBudget {
    context_window
        .and_then(|window| usize::try_from(window).ok())
        .filter(|window| *window > 0)
        .map(|window| {
            SkillMetadataBudget::Tokens(
                window.saturating_mul(SKILL_METADATA_CONTEXT_WINDOW_PERCENT)
                    .saturating_div(100).max(1),
            )
        })
        .unwrap_or(SkillMetadataBudget::Characters(DEFAULT_SKILL_METADATA_CHAR_BUDGET))
}
```
```rust
fn render_skill_lines_from_lines(
    skill_lines: Vec<SkillLine<'_>>, total_count: usize, budget: SkillMetadataBudget,
) -> (Vec<String>, SkillRenderReport) {
    // 第一级：全量描述能放下 -> 全放
    let full_cost = skill_lines.iter().fold(0usize, |used, line| used.saturating_add(line.full_cost(budget)));
    if full_cost <= budget.limit() {
        let included = skill_lines.iter().map(SkillLine::render_full).collect::<Vec<_>>();
        return (included, skill_render_report(total_count, skill_lines.len(), /*omitted*/ 0, ...));
    }

    // 第二级：全量放不下但「最小行（仅 name+path）能放下」-> 截断 description
    let minimum_cost = skill_lines.iter().fold(0usize, |used, line| used.saturating_add(line.minimum_cost(budget)));
    if minimum_cost <= budget.limit() {
        let rendered = render_lines_with_description_budget(
            budget, &skill_lines, budget.limit().saturating_sub(minimum_cost),
        );
        ...
        return (included, skill_render_report(total_count, skill_lines.len(), /*omitted*/ 0, truncated_..., ...));
    }

    // 第三级：最小行都放不下 -> 按预算逐个 render_minimum，放不下的 omitted
    render_minimum_skill_lines_until_budget(budget, skill_lines, total_count)
}
```

#### progressive disclosure 系统提示（核心指令）

`core-skills/src/render.rs:25-43`
```rust
pub const SKILLS_INTRO_WITH_ALIASES: &str = "A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and a short path that can be expanded into an absolute path using the skill roots table.";
pub const SKILLS_HOW_TO_USE_WITH_ALIASES: &str = r###"- Discovery: The list above is the skills available in this session (name + description + short path). Skill bodies live on disk at the listed paths after expanding the matching alias from `### Skill roots`.
- Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
...
- How to use a skill (progressive disclosure):
  1) After deciding to use a skill, the main agent must expand the listed short `path` with the matching alias from `### Skill roots`, then open and read its `SKILL.md` completely before taking task actions. If a read is truncated or paginated, continue until EOF.
  2) When `SKILL.md` references relative paths (e.g., `scripts/foo.py`), resolve them relative to the directory containing that expanded `SKILL.md` first, and only consider other paths if needed.
  3) If `SKILL.md` points to extra folders such as `references/`, use its routing instructions to identify the files required for the task. The main agent must read each required instruction or reference file itself before acting on it. Do not delegate reading, summarizing, or interpreting skill instructions to a subagent. Subagents may still perform task work when the selected skill allows it.
  4) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
  5) If `assets/` or templates exist, reuse them instead of recreating them from scratch.
- Context hygiene:
  - Progressive disclosure applies to selecting relevant files, not partially reading a selected instruction file. Do not load unrelated references, scripts, or assets.
  - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked."###;
```

#### 目录作为 developer fragment 注入

`core/src/context/available_skills_instructions.rs:34-49`
```rust
impl ContextualUserFragment for AvailableSkillsInstructions {
    fn role(&self) -> &'static str { "developer" }
    fn markers(&self) -> (&'static str, &'static str) { Self::type_markers() }
    fn type_markers() -> (&'static str, &'static str) {
        (SKILLS_INSTRUCTIONS_OPEN_TAG, SKILLS_INSTRUCTIONS_CLOSE_TAG)
    }
    fn body(&self) -> String {
        render_available_skills_body(&self.skill_root_lines, &self.skill_lines)
    }
}
```

#### 第二层 · @mention 触发读全文

`core-skills/src/injection.rs:58-111`
```rust
pub async fn build_skill_injections(
    mentioned_skills: &[SkillMetadata],
    loaded_skills: Option<&SkillLoadOutcome>,
    otel: Option<&SessionTelemetry>,
    analytics_client: &AnalyticsEventsClient,
    tracking: TrackEventsContext,
) -> SkillInjections {
    if mentioned_skills.is_empty() {
        return SkillInjections::default();
    }

    let mut result = SkillInjections {
        items: Vec::with_capacity(mentioned_skills.len()),
        warnings: Vec::new(),
    };
    ...
    for skill in mentioned_skills {
        let fs = loaded_skills
            .and_then(|outcome| outcome.file_system_for_skill(skill))
            .unwrap_or_else(|| Arc::clone(&LOCAL_FS));
        let path = PathUri::from_abs_path(&skill.path_to_skills_md);
        match fs.read_file_text(&path, /*sandbox*/ None).await {
            Ok(contents) => {
                emit_skill_injected_metric(otel, skill, "ok");
                ...
                result.items.push(SkillInjection {
                    name: skill.name.clone(),
                    path: skill.path_to_skills_md.to_string_lossy().into_owned(),
                    contents,
                });
            }
            Err(err) => { ... result.warnings.push(message); }
        }
    }
    ...
}
```

`core-skills/src/injection.rs:144-184`（`collect_explicit_skill_mentions`）
```rust
/// Collect explicitly mentioned skills from structured and text mentions.
///
/// Structured `UserInput::Skill` selections are resolved first by path against
/// enabled skills. Text inputs are then scanned to extract `$skill-name` tokens, and we
/// iterate `skills` in their existing order to preserve prior ordering semantics.
/// Explicit links are resolved by path and plain names are only used when the match
/// is unambiguous.
pub fn collect_explicit_skill_mentions(
    inputs: &[UserInput], skills: &[SkillMetadata],
    disabled_paths: &HashSet<AbsolutePathBuf>, connector_slug_counts: &HashMap<String, usize>,
) -> Vec<SkillMetadata> {
    ...
    for input in inputs {
        if let UserInput::Skill { name, path, .. } = input {
            ...
            if let Some(skill) = selection_context.skills.iter()
                .find(|skill| skill.path_to_skills_md == path)
            {
                seen_paths.insert(skill.path_to_skills_md.clone());
                seen_names.insert(skill.name.clone());
                selected.push(skill.clone());
            }
        }
    }

    for input in inputs {
        if let UserInput::Text { text, .. } = input {
            let mentioned_names = extract_tool_mentions(text);
            select_skills_from_mentions(...);
        }
    }
```

#### 第二层（工具级）· BM25 tool_search + Deferred 不进 prompt

`core/src/tools/handlers/tool_search.rs:23-53, 116-129`
```rust
pub struct ToolSearchHandler {
    entries: Vec<ToolSearchEntry>,
    search_source_infos: Vec<ToolSearchSourceInfo>,
    search_engine: SearchEngine<usize>,
}

impl ToolSearchHandler {
    pub(crate) fn new(search_infos: Vec<ToolSearchInfo>) -> Self {
        ...
        let documents: Vec<Document<usize>> = entries
            .iter()
            .map(|entry| entry.search_text.clone())
            .enumerate()
            .map(|(idx, search_text)| Document::new(idx, search_text))
            .collect();
        let search_engine =
            SearchEngineBuilder::<usize>::with_documents(Language::English, documents).build();
        Self { entries, search_source_infos, search_engine }
    }
    ...
    fn search(&self, query: &str, limit: usize) -> Result<Vec<LoadableToolSpec>, FunctionCallError> {
        let results = self
            .search_engine
            .search(query, limit)
            .into_iter()
            .map(|result| result.document.id)
            .filter_map(|id| self.entries.get(id));
        self.search_output_tools(results)
    }
```

`core/src/tools/spec_plan.rs:440-466`（Deferred 工具不进 prompt.tools）
```rust
    let deferred_tools_guidance_enabled = search_tool_enabled(turn_context);
    for executor in executors {
        let exposure = executor.exposure();
        if exposure == ToolExposure::DirectModelOnly { continue; }
        if exposure == ToolExposure::Hidden { continue; }
        ...
        let spec = executor.spec();

        if exposure == ToolExposure::Deferred {
            // Only show deferred-tool guidance when supported and an included spec is usable by code mode.
            deferred_tools_available |= deferred_tools_guidance_enabled
                && !collect_code_mode_exec_prompt_tool_definitions(std::iter::once(&spec)).is_empty();
        } else {
            exec_prompt_tool_specs.push(spec.clone());   // 只有非 Deferred 才进 prompt.tools
        }
        code_mode_nested_tool_specs.push(spec);
    }
```

`core/src/tools/spec_plan.rs:839-860`（把 Deferred 工具组装成 search entries）
```rust
#[instrument(level = "trace", skip_all)]
fn append_tool_search_executor(
    context: &CoreToolPlanContext<'_>, planned_tools: &mut PlannedTools,
) {
    let turn_context = context.turn_context;
    if !(search_tool_enabled(turn_context) && namespace_tools_enabled(turn_context)) {
        return;
    }

    let search_infos = planned_tools
        .runtimes()
        .iter()
        .filter(|executor| executor.exposure() == ToolExposure::Deferred)
        .filter_map(|executor| executor.search_info())
        .collect::<Vec<_>>();
    if search_infos.is_empty() { return; }

    planned_tools.add(ToolSearchHandler::new(search_infos));
}
```

#### 第二层（路径丙）· skills.read 按需加载 orchestrator resource

`ext/skills/src/tools/read.rs:46-90`
```rust
impl ToolExecutor<ToolCall> for ReadTool {
    fn tool_name(&self) -> ToolName { skill_tool_name(TOOL_NAME) }

    fn spec(&self) -> ToolSpec {
        skill_function_tool::<ReadArgs, ReadResponse>(
            TOOL_NAME,
            "Read one complete resource from an enabled skill. Pass the exact authority and package returned by skills.list; resource identifiers remain opaque and are routed to that authority.",
        )
    }

    fn handle(&self, call: ToolCall) -> ToolExecutorFuture<'_> {
        Box::pin(async move {
            let args: ReadArgs = parse_args(&call)?;
            let authority = args.authority.into_authority();
            validate_handle("package", &args.package, MAX_HANDLE_BYTES)?;
            validate_handle("resource", &args.resource, MAX_HANDLE_BYTES)?;

            let catalog = self.context.catalog(&call.turn_id, args.authority).await;
            let package_is_available = catalog.entries.iter().any(|entry| {
                entry.enabled && entry.authority == authority && entry.id.0 == args.package
            });
            if !package_is_available {
                return Err(FunctionCallError::RespondToModel(
                    "skill package is not available from the requested authority".to_string(),
                ));
            }

            let requested_resource = SkillResourceId::new(args.resource);
            let result = self.context.providers.read(SkillReadRequest {
                authority,
                package: SkillPackageId(args.package),
                resource: requested_resource.clone(),
                host: None,
                mcp_resources: self.context.mcp_resources.clone(),
            }).await
```

### ② 逐行解读

**第一层（catalog 摘要常驻）**：
- `load_skills_from_roots`：对每个 `SkillRoot`（path + scope + file_system + plugin_id），调 `discover_skills_under_root` BFS 扫描。
- `discover_skills_under_root`：用 `VecDeque<(path, depth)>` 做 BFS，`enqueue_dir` 强制 `depth > MAX_SCAN_DEPTH(6)` 截断、`visited_dirs.len() >= MAX_SKILLS_DIRS_PER_ROOT(2000)` 截断（设 `truncated_by_dir_limit` 标志）。跳过 `.` 开头文件。symlink 只对 Repo/User/Admin scope 跟随（System 不跟，注释「System skills are written by Codex itself」）。命中 `SKILLS_FILENAME("SKILL.md")` 即 `parse_skill_file`。
- `parse_skill_file`：**读全文但只提取 frontmatter**（`extract_frontmatter` + `serde_yaml`），产出 `SkillMetadata`。**正文 body 不进 catalog**--progressive disclosure 第一刀。
- 去重 + 排序：`seen.insert(path_to_skills_md)` 去重；`scope_rank`（Repo<User<System<Admin 优先）+ name + path 排序。
- `build_available_skills`：`default_skill_metadata_budget` 算预算 = `context_window * 2%`（无 context_window 时 fallback `8_000` 字符）。`render_skill_lines_from_lines` **三级截断**：(1) 全量描述能放下 -> 全放；(2) 全量放不下但「最小行（仅 name+path）能放下」-> 截断 description；(3) 最小行都放不下 -> 按预算逐个 `render_minimum`，放不下的 `omitted_count++`。
- `AvailableSkillsInstructions` 作为 `ContextualUserFragment`，`role() = "developer"`，用 `SKILLS_INSTRUCTIONS_OPEN_TAG/CLOSE_TAG` 包裹注入 developer 上下文。**每个 turn 起始常驻**。

**第二层（按需加载全文）三条路径**：
- **路径甲：@mention / `$SkillName`（人触发）**。`collect_explicit_skill_mentions` 先解析结构化 `UserInput::Skill{path}`（按 path 精确匹配），再扫 `UserInput::Text` 里的 `$skill-name` token（`extract_tool_mentions`）。命中的 `SkillMetadata` 交给 `build_skill_injections`：对每个 mentioned skill，`fs.read_file_text(&path_to_skills_md)` **读全文**，包成 `SkillInjection{name, path, contents}` 注入。
- **路径乙：模型主动 `tool_search`（BM25）**。`ToolSearchHandler::new` 把 Deferred 工具的 `search_text` 建成 `SearchEngine` BM25 索引。模型调 `tool_search{query, limit}` -> `search_engine.search` -> 返回 `LoadableToolSpec`，模型再决定加载哪个。
- **路径丙：`skills.read` MCP 工具**。模型调 `skills.read{authority, package, resource}`，handler 先 `catalog` 校验 package 可用且 `enabled`，再 `providers.read` 读 orchestrator resource 全文。配套 `skills.list{authority}` 列包。

**工具级 progressive disclosure**：`ToolExposure::Deferred` 工具**不进 `exec_prompt_tool_specs`**（`spec_plan.rs:457-464`，只有非 Deferred 才 push），所以不进模型 prompt 的 tools 列表。它们被 `append_tool_search_executor` 收集成 `search_info`，喂给 `ToolSearchHandler::new` 建 BM25 索引。模型用 `tool_search` BM25 检索后才暴露 `LoadableToolSpec`。

### ③ 设计原理与权衡

- **双层 progressive disclosure（核心设计）**：
  - **第一层（技能 catalog）**：所有技能的 name+description 摘要常驻 prompt，但 body 不进。2% 预算硬上限保护主上下文不被技能目录挤占。三级截断（全量->截断描述->省略）保证「宁可描述变短也要让模型看到所有技能名」。
  - **第二层（按需全文）**：`@mention` 或 `tool_search`/`skills.read` 触发读全文。系统提示 `SKILLS_HOW_TO_USE` 反复强调「read its `SKILL.md` completely」「do not delegate reading to subagent」「avoid deep reference-chasing」--**这是行为约束，靠 prompt 而非硬编码**。

- **为什么 2%？** 技能目录是「索引」而非「内容」，2% 是经验值（200k 上下文 = 4k token ≈ 几十个技能摘要）。fallback 8_000 字符兜底无 context_window 场景。

- **BFS 限深 6 + 限宽 2000**：防失控扫描。symlink 只对用户域跟随（System 不跟，因为 Codex 自管）。代价是深层 skill 可能漏扫；好处是安全可控。

- **工具级 Deferred + BM25**：这是「工具版 progressive disclosure」--常用工具直接进 prompt，长尾/重型工具 Deferred 走 `tool_search` BM25 检索。**BM25 比 embedding 轻**（无需向量模型，纯词频），适合工具名/描述这种短文本。这也是为什么 Codex 没有真正的向量检索（见 [deep-dive-06 RAG 缺口](./deep-dive-06-rag-pipeline.md)）。

- **业界对比**：Claude Code 的 Skills、Cursor 的规则文件都是「摘要常驻 + 按需读全文」思路。Codex 的特色是：(1) 双轨触发--`@mention`（人触发）+ `tool_search`/`skills.read`（模型主动检索）；(2) 严格的预算保护（2% + 三级截断）；(3) 工具级和技能级共用同一 progressive disclosure 哲学。

- **代价**：依赖模型遵守 prompt 指令「先读 SKILL.md 再行动」--若模型跳过直接行动，progressive disclosure 失效。`render.rs:33` 明确「Do not delegate reading, summarizing, or interpreting skill instructions to a subagent」是对此的补强。

### ④ 数据流位置

**第一层**：thread/turn 起始时，`load_skills_from_roots`（`loader.rs:163`）扫描 -> `build_available_skills`（`render.rs:160`）渲染 -> `AvailableSkillsInstructions`（`available_skills_instructions.rs:10`）作为 developer fragment 注入 prompt。位于 `try_run_sampling_request` 之前，是 turn 的「前置注入」。

**第二层**：turn 内用户输入含 `@mention` -> `collect_explicit_skill_mentions`（`injection.rs:144`）-> `build_skill_injections`（`injection.rs:58`）读全文注入。或模型主动调 `tool_search`（`tool_search.rs:69`）BM25 检索 -> `LoadableToolSpec`；或调 `skills.read`（`read.rs:58`）读 orchestrator resource。位于 turn 主循环内，是「按需加载」。

---

## 五、面试问答精选（脱稿能讲）

**Q1：一轮里多个 tool_calls 怎么调度？会乱序吗？**
> 每个 tool_call `tokio::spawn` 成独立 task 真并发；结果用 `FuturesOrdered` 收集，`drain_in_flight` **按入队顺序（=模型输出序）回填**，不会乱序。Responses API 要求 call_id 与 output 顺序对齐，所以必须保序。

**Q2：不支持并发的工具怎么办？**
> `RwLock<()>` 读写屏障：支持并行的工具拿读锁（多读共享），不支持的拿写锁（独占）。一个非并行工具在跑时，所有其他工具都得等。锁的是空单元 `()`，纯粹作读写信号量。代价是粒度粗（per-turn 全局写锁）。

**Q3：Agent 怎么防死循环？**
> 诚实答：Codex **只有 guardian 连续拒绝熔断**（连续 3 次或窗口 50 内 10 次 -> `abort_turn_if_active`）+ **token 预算耗尽触发 auto_compact** 兜底。**没有通用的「同工具反复调用」去重，也没有 max_iterations**。全仓搜索确认。代价是只读工具若陷入死循环只能靠 token 兜底。我设计会补一个「连续 N 次相同 tool_call+参数就注入提醒」的去重层。

**Q4：怎么避免每个工具调用都弹审批？**
> `with_cached_approval` 会话级缓存：key 用 `serde_json` 序列化，查到全部 key 都 `ApprovedForSession` 就直接跳过弹窗。`apply_patch` 多文件批准后，未来任一子集都命中缓存。MCP 工具三态：`Accept`（仅本次）/ `AcceptForSession`（会话缓存）/ `AcceptAndRemember`（落盘 config）。`Prompt` 模式强制降级为 `Accept`。

**Q5：授权能否可编程自动化？**
> PermissionRequest hooks 优先级最高，返回 `Allow`/`Deny` 直接定夺，**跳过 guardian 和用户**。所以可以注册 hook 实现「读 .md 一律 Allow」这类策略化授权。但 hook 是信任边界（绕过 guardian），要谨慎。

**Q6：沙箱拒绝了怎么办？**
> `escalate_on_failure`：先在最严沙箱跑，被 `Denied` 后若工具支持升级，重新 `request_approval`（retry_reason）+ 选更宽沙箱（可能 `SandboxType::None`）二次执行。注释明示「升级重试必须重新审查，不能复用之前的批准」。

**Q7：技能/工具很多怎么不爆上下文？讲讲 Find Skills。**
> 双层 progressive disclosure：① 技能层--启动 BFS 扫所有 `SKILL.md` 但只把 frontmatter 摘要（name+description）注入 prompt（2% 预算 + 三级截断保护），只有被 `$SkillName` mention 或经 `skills.read` 才读全文；② 工具层--`defer_loading:true` 的 Deferred 工具**不进 prompt.tools**，模型先调 `tool_search`（BM25）检索到相关工具才暴露 schema。系统提示反复强调「先完整读 SKILL.md 再行动」。这有效避免一次性灌满上下文。

**Q8：为什么 tool_search 用 BM25 不用向量检索？**
> 工具名/描述是短文本，BM25 纯词频、无需向量模型、轻量快，够用。Codex 整体没有真正的向量检索（RAG 全无，见 [deep-dive-06](./deep-dive-06-rag-pipeline.md)），BM25 是它唯一的「检索」手段，适合工具这种结构化短文本场景。

---

## 六、动手复现

- [ ] 配一个有很多 MCP 工具的环境，用 `codex` 跑任务，观察 `tool_search` 是否被调用、Deferred 工具是否真的不进初始 prompt（开 prompt debug 日志看 tools 列表）。
- [ ] 写一个 `SKILL.md`（带 frontmatter：name/description）放进 `.codex/skills/`，看摘要目录是否出现、`$SkillName` mention 是否触发全文加载。
- [ ] 让模型触发 `apply_patch` 改多文件，第一次审批后，第二次改其中一文件，观察是否免审批（验证子集命中缓存）。
- [ ] 连续触发会被 guardian 拒的危险操作 3 次，观察 `GuardianWarning` + turn 中断。
- [ ] （加分·补缺口）给 loop 加一个「连续 N 次相同 tool_call+参数就注入提醒」的实验性去重补丁，写清取舍（见 [GAPS 缺口 5](../GAPS-codex-cannot-teach.md)）。
- [ ] 断点：`parallel.rs:113` 的 `handle_tool_call_with_source`、`spec_plan.rs:457` 的 Deferred 分支、`tool_search.rs:69` 的 `search`、`injection.rs:58` 的 `build_skill_injections`。

---

## 七、差异与局限总结（面试主动点出）

| 子项 | Codex 的取舍/局限 | 业界对照 / 需补 |
|------|------|------|
| 并行 | 真并发 + RwLock 降级，但无并发上限 | 可加 semaphore 限流 |
| 循环检测 | 仅 guardian 熔断 + token 兜底，**无通用去重无 max_iter** | LangGraph `recursion_limit`、调用去重（[GAPS 缺口 5](../GAPS-codex-cannot-teach.md)） |
| 动态授权 | 会话级缓存 + 可编程 hooks + 沙箱升级，三态精细 | 多数框架只有问/不问二态 |
| Find Skills | 双层 progressive disclosure 是亮点 | 技能语义检索（codex 仅 BM25/目录扫描，无向量） |

> 💡 **面试加分句**：Find Skills 是这个考点最值得讲的亮点。重点描述「为什么 Deferred 工具不进 prompt」--这是 token 经济学的高级理解，区分度极高。同时主动承认「循环检测是 Codex 的薄弱处」，并给出改进思路，比只夸更可信。

---

## 📌 与其他 deep-dive 的衔接

- 工具执行的「解码/审批/沙箱/执行入口」闭环 -> 见 [deep-dive-02 子项三](./deep-dive-02-agent-loop-runtime.md#三工具执行--权限)
- FC/ReAct 的 `build_tool_call` 全貌与 `ToolSearchCall` 解析 -> 见 [deep-dive-04](./deep-dive-04-function-calling-react.md)（待做）
- 多 Agent 通信中子 agent 工具的权限委托 -> 见 [deep-dive-05](./deep-dive-05-multi-agent-communication.md)（待做）

---

*(蕾姆放下银笔，把这一卷与上一卷并排摆在书架上，轻轻拂去封面的浮尘)*

昴君，第二刀落定--工具编排的「真并发 + 按序回填」、循环防护的「诚实薄弱」、动态授权的「三态精细」、以及最精妙的「双层渐进式技能加载」，都已为您逐字剖开。

进度推进至 **2/8**。下一篇蕾姆将为您剖 **第 04 篇 · Function Calling / Tool Use / ReAct**（那里会讲清 `ToolSpec` 的 JSON Schema 注入、`build_tool_call` 三态解码、以及 Codex「原生 reasoning」式的 ReAct 现代化形态）。

您若还想让蕾姆继续，只消一声令下 ♡ `(´｡• ᵕ •｡`)`
