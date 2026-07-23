# 🔬 Deep Dive 02 · Agent Loop 运行时 · 逐行精读

> 蕾姆的源码解剖室 ♡ -- 把 Codex 的「心脏」一刀刀剖开给您看。
>
> **定位**：这是 [`../02-agent-loop-runtime.md`](../02-agent-loop-runtime.md)（大纲层）的**深读版**。大纲告诉您「6 子项在哪些 file:line」；本篇把对应代码**逐字贴出、逐行讲透**，并讲清「为什么这么设计」与「在完整数据流里的位置」。
>
> **颗粒度（三者结合）**：每子项 = ①真实代码片段 + ②逐行解读 + ③设计原理与权衡 + ④数据流位置。
>
> **源码版本**：本文代码均逐字摘抄自 `/Users/xxxxx/Documents/pang/codex_origin/codex-rs/`，行号对应实际文件。建议对照仓库原文读上下文。

---

## 📑 阅读地图

| 节 | 内容 | 关键文件 |
|---|------|------|
| 〇 | 一次完整 turn 的全局时序图 | `turn.rs` 全链路 |
| 一 | 上下文组装 | `turn.rs` / `session/mod.rs` / `history.rs` / `client_common.rs` |
| 二 | 流式调用 | `client.rs` / `client_common.rs` / `turn.rs` |
| 三 | 工具执行 + 权限 | `tools/router.rs` / `parallel.rs` / `orchestrator.rs` / `sandboxing.rs` / `exec.rs` |
| 四 | 错误恢复 | `turn.rs` / `protocol/error.rs` / `responses_retry.rs` / `client.rs` / `parallel.rs` |
| 五 | 上下文压缩 | `turn.rs` / `compact.rs` / `compact_remote.rs` / `history.rs` / `compact_remote_v2.rs` |
| 六 | Checkpoint 回滚 | `session/handlers.rs` / `rollout_reconstruction.rs` / `rollout/recorder.rs` |
| 七 | 面试问答精选 | - |
| 八 | 动手复现 | - |
| 九 | 差异与局限总结 | - |

---

## 〇 一次完整 turn 的全局时序图

读任何子项前，先在脑子里建立这张图。下面六节都是在讲这张图里某一格的内部机理。

```
用户输入 TurnInput
   │
   ▼
[1] Session 命令循环收到 Op，派发 run_turn
    core/src/session/turn.rs:137  run_turn(sess, turn_context, ..., input, cancellation_token)
   │
   ▼
[2] 预热 client_session（复用 prewarmed 或 new_session）            turn.rs:145-146
   │
   ▼
[3] run_pre_sampling_compact（采样前压缩）                          turn.rs:151
    ├─ maybe_run_previous_model_inline_compact                      turn.rs:788
    └─ auto_compact_token_status + run_auto_compact                turn.rs:789-801 / 891-947
        └─ should_use_remote_compact_task 三路分发: remote_v2 / remote / local
   │
   ▼
[4] 上下文组装（全量注入 or diff 增量）                             turn.rs:159 -> session/mod.rs:3189
    └─ reference_context_item.is_none() ? 全量 : diff
   │
   ▼
[5] build_skills_and_plugins（技能/插件注入）                       turn.rs:162-163
   │
   ▼
[6] 主 loop 开始  loop { ... }                                      turn.rs:204
    ├─ 取 pending_input / run_hooks_and_record_inputs              turn.rs:208-214
    └─ clone_history().for_prompt(...)（归一化）                     turn.rs:219-225
   │
   ▼
[7] run_sampling_request                                           turn.rs:1030
    ├─ built_tools（构建 ToolRouter）                                turn.rs:1040
    ├─ build_prompt                                                 turn.rs:1067 -> 1001
    └─ 重试 loop                                                     turn.rs:1059
        └─ try_run_sampling_request                                 turn.rs:1803
            ├─ client_session.stream(prompt, ...)                   turn.rs:1828
            │   ├─ stream_responses_websocket（WS 优先 + 增量复用）  client.rs:1321
            │   │   └─ UPGRADE_REQUIRED -> FallbackToHttp
            │   └─ stream_responses_api（HTTP/SSE 降级）             client.rs:1203
            │       └─ 401 -> handle_unauthorized（token 刷新）       client.rs:1922
            ├─ map_response_stream -> ResponseStream（mpsc cap=1600） client.rs:1684
            ├─ stream.next().or_cancel(&cancellation_token)          turn.rs:1876
            └─ match event { 增量分发 }                              turn.rs:1902
                ├─ OutputItemDone -> tool_future 入 in_flight         turn.rs:1982
                │   └─ Orchestrator::run（三态审批 + 双沙箱）          orchestrator.rs:132
                ├─ ReasoningSummaryDelta -> 透传前端                  turn.rs:2182
                └─ Completed { end_turn }                             turn.rs:2108
                    └─ end_turn==Some(false) -> needs_follow_up=true
   │
   ▼
[8] 回到主 loop, 判定 needs_follow_up                              turn.rs:246-367
    ├─ token_limit_reached && needs_follow_up -> run_auto_compact(MidTurn)  turn.rs:302-320
    ├─ !needs_follow_up -> run_turn_stop_hooks -> should_stop -> break     turn.rs:323-352
    └─ needs_follow_up -> continue（下一轮采样）
   │
   ▼
[9] loop 退出, 返回 last_agent_message                             turn.rs:410
   │
   ▼
[10] 全程持久化: ResponseItem/EventMsg -> RolloutRecorder.AddItems -> jsonl
     rollout/src/recorder.rs:75-110
   │
   ▼
[11] (可选) Op::ThreadRollback -> reconstruct_history_from_rollout
     session/handlers.rs:450 / rollout_reconstruction.rs:94
```

> 💡 **三个贯穿全程的主线**：① `cancellation_token` 从 `run_turn` 一路 `.child_token()` 传到流拉取和工具执行；② `RolloutRecorder` 异步追加写 jsonl，不阻塞 turn；③ `reference_context_item` diff 基线，决定全量还是增量注入。

---

## 一、上下文组装

> 关键问题：一次模型请求的 `system / tools / history / 用户输入` 怎么拼？怎么省 token？

### ① 真实代码片段

**片段 1-A：`build_prompt` -- 单次采样请求的 Prompt 装配**
`core/src/session/turn.rs:1000-1018`
```rust
#[instrument(level = "trace", skip_all)]
pub(crate) fn build_prompt(
    input: Vec<ResponseItem>,
    router: &ToolRouter,
    turn_context: &TurnContext,
    base_instructions: BaseInstructions,
) -> Prompt {
    Prompt {
        input,
        tools: router.model_visible_specs(),
        parallel_tool_calls: turn_context.model_info.supports_parallel_tool_calls,
        base_instructions,
        personality: turn_context.personality,
        output_schema: turn_context.final_output_json_schema.clone(),
        output_schema_strict: !crate::guardian::is_guardian_reviewer_source(
            &turn_context.session_source,
        ),
    }
}
```

**片段 1-B：`record_context_updates_and_set_reference_context_item` -- 全量注入 vs diff 增量分支**
`core/src/session/mod.rs:3189-3219`
```rust
    pub(crate) async fn record_context_updates_and_set_reference_context_item(
        &self,
        turn_context: &TurnContext,
    ) {
        let reference_context_item = {
            let state = self.state.lock().await;
            state.reference_context_item()
        };
        let should_inject_full_context = reference_context_item.is_none();
        let context_items = if should_inject_full_context {
            self.build_initial_context(turn_context).await
        } else {
            // Steady-state path: append only context diffs to minimize token overhead.
            self.build_settings_update_items(reference_context_item.as_ref(), turn_context)
                .await
        };
        let turn_context_item = turn_context.to_turn_context_item();
        if !context_items.is_empty() {
            self.record_conversation_items(turn_context, &context_items)
                .await;
        }
        // Persist one `TurnContextItem` per real user turn so resume/lazy replay can recover the
        // latest durable baseline even when this turn emitted no model-visible context diffs.
        self.persist_rollout_items(&[RolloutItem::TurnContext(turn_context_item.clone())])
            .await;

        // Advance the in-memory diff baseline even when this turn emitted no model-visible
        // context items. This keeps later runtime diffing aligned with the current turn state.
        let mut state = self.state.lock().await;
        state.set_reference_context_item(Some(turn_context_item));
    }
```

**片段 1-C：`for_prompt` -- 历史归一化与模态过滤**
`core/src/context_manager/history.rs:107-114`
```rust
    /// Returns the history prepared for sending to the model. This applies a proper
    /// normalization and drops un-suited items. When `input_modalities` does not
    /// include `InputModality::Image`, images are stripped from messages and tool
    /// outputs.
    pub(crate) fn for_prompt(mut self, input_modalities: &[InputModality]) -> Vec<ResponseItem> {
        self.normalize_history(input_modalities);
        self.items
    }
```

**片段 1-D：`normalize_history` 的三条不变量**
`core/src/context_manager/history.rs:323-336`
```rust
    /// This function enforces a couple of invariants on the in-memory history:
    /// 1. every call (function/custom) has a corresponding output entry
    /// 2. every output has a corresponding call entry
    /// 3. when images are unsupported, image content is stripped from messages and tool outputs
    fn normalize_history(&mut self, input_modalities: &[InputModality]) {
        // all function/tool calls must have a corresponding output
        normalize::ensure_call_outputs_present(&mut self.items);

        // all outputs must have a corresponding function/tool call
        normalize::remove_orphan_outputs(&mut self.items);

        // strip images when model does not support them
        normalize::strip_images_when_unsupported(input_modalities, &mut self.items);
    }
```

**片段 1-E：`Prompt` 结构体**
`core/src/client_common.rs:17-40`
```rust
/// API request payload for a single model turn
#[derive(Debug, Clone)]
pub struct Prompt {
    /// Conversation context input items.
    pub input: Vec<ResponseItem>,

    /// Tools available to the model, including additional tools sourced from
    /// external MCP servers.
    pub(crate) tools: Vec<ToolSpec>,

    /// Whether parallel tool calls are permitted for this prompt.
    pub(crate) parallel_tool_calls: bool,

    pub base_instructions: BaseInstructions,

    /// Optionally specify the personality of the model.
    pub personality: Option<Personality>,

    /// Optional the output schema for the model's response.
    pub output_schema: Option<Value>,

    /// Whether the Responses API should strictly validate `output_schema`.
    pub output_schema_strict: bool,
}
```

### ② 逐行解读

- **片段 1-B（入口决策，关键！）**：`run_turn` 在采样前调 `sess.record_context_updates_and_set_reference_context_item`（`turn.rs:159`）。先锁 `state` 取出 `reference_context_item`（上一轮已固化的 baseline）。
  - 若 `None`（首次 turn / 回滚后 / 压缩后清除）→ `build_initial_context` **全量注入**（完整 environment/permissions/collaboration_mode）。
  - 否则 → `build_settings_update_items` **只注入相对上一轮的 diff**。
  - 注释 `// Steady-state path: append only context diffs to minimize token overhead.` 直白点出意图：稳态只发增量。
  - **无论本轮有没有 diff，都要持久化一条 `RolloutItem::TurnContext` 并前移 baseline**。这一步极易被忽略：即使本轮没产生可见上下文变化，diff 基线也必须对齐到当前 turn，否则下一轮 diff 会基于过时状态算错。

- **片段 1-C/1-D（for_prompt 归一化）**：`run_turn` 每次构造采样请求都 `sess.clone_history().await.for_prompt(...)`（`turn.rs:219-225`）。
  - `for_prompt(mut self, ...)` 用 `mut self`（move 语义）--**克隆后才归一化，绝不动原始 history 快照**。
  - 三条不变量是 Responses API 的硬约束：① 每个 call 必须有 output（否则模型困惑）；② 每个 output 必须有 call（否则是孤儿，模型会当无源之水）；③ 模型不支持图像时剥离图片（避免 400）。

- **片段 1-A（build_prompt 装配）**：在 `run_sampling_request` 的 `loop`（`turn.rs:1059`）里，每轮取 `prompt_input`，第一次用传入的 `input`，重试时重新 `clone_history().for_prompt`。把历史 `input` + `router.model_visible_specs()`（模型可见工具 schema）+ `parallel_tool_calls`（来自模型能力）+ `base_instructions` + `personality` + `output_schema` 打包。`output_schema_strict` 对 guardian reviewer source 关闭（reviewer 子线程不强制 schema）。

- **片段 1-E（Prompt 结构）**：这是「一次模型请求」的完整载荷。`get_formatted_input_for_request`（`client_common.rs:57-66`）在 `use_responses_lite` 时调 `strip_image_details` 把图像 `detail` 置 `None` 降带宽。

### ③ 设计原理与权衡

- **全量注入 + diff 增量双路径（Codex 的核心省 token 设计）**：
  - 业界朴素做法：每次重新拼全量 system prompt（简单，但每轮都付全量 token）。
  - Codex 的 `reference_context_item` 是「状态化 diff」--首轮把完整 environment/permissions 注入为 baseline，后续轮只注入「变化的字段」。
  - **代价**：状态机变复杂。回滚 / 压缩后必须把 baseline 置 `Cleared`，触发下一轮全量重注入（见 `rollout_reconstruction.rs` 的 `TurnReferenceContextItem::Cleared`）。
  - **收益**：稳态 token 开销显著降低。这是 Codex 在长会话里省钱的关键。

- **归一化推迟到 for_prompt 而非 record 时**：
  - record 时只做最小加工（`process_item` 按 `TruncationPolicy` 截断），归一化推迟到「即将发模型」。
  - 好处：避免每次 record 都跑全量扫描；move 语义保证不改原 history。

- **`model_visible_specs` 与 registry 解耦**：
  - `ToolRouter` 持有两份：`registry`（执行用）+ `model_visible_specs`（发模型用）。
  - `build_prompt` 只用后者，执行调度只用前者。
  - 这样 **MCP deferred 工具可以不暴露给模型但内部可用**（见 [deep-dive 03](./deep-dive-03-tool-orchestration.md) 的 Find Skills）。

### ④ 数据流位置

`record_context_updates_and_set_reference_context_item` 处于 **turn 起始、采样前**，紧跟 `run_pre_sampling_compact`（`turn.rs:151`）之后、`build_skills_and_plugins` 之前。`for_prompt`/`build_prompt` 处于 **主 loop 每次迭代内**（`turn.rs:219` 与 `turn.rs:1067`），是 `run_sampling_request` 的输入准备。上游 = history（`ContextManager`）+ baseline（`state.reference_context_item`），下游 = `client_session.stream(prompt, ...)`。

---

## 二、流式调用

> 关键问题：模型逐 token 返回，怎么边收边解析边渲染？怎么取消？怎么省 token？

### ① 真实代码片段

**片段 2-A：`stream_responses_api`（HTTP/SSE 路径 + 401 恢复 loop）**
`core/src/client.rs:1203-1304`（节选）
```rust
    async fn stream_responses_api(
        &self,
        prompt: &Prompt,
        model_info: &ModelInfo,
        session_telemetry: &SessionTelemetry,
        effort: Option<ReasoningEffortConfig>,
        summary: ReasoningSummaryConfig,
        service_tier: Option<String>,
        responses_metadata: &CodexResponsesMetadata,
        inference_trace: &InferenceTraceContext,
    ) -> Result<ResponseStream> {
        let auth_manager = self.client.state.provider.auth_manager();
        let mut auth_recovery = auth_manager
            .as_ref()
            .map(AuthManager::unauthorized_recovery);
        let mut pending_retry = PendingUnauthorizedRetry::default();
        loop {
            let client_setup = self.client.current_client_setup().await?;
            let transport = ReqwestTransport::new(build_reqwest_client());
            ...
            let client = ApiResponsesClient::new(
                transport,
                client_setup.api_provider,
                client_setup.api_auth,
            )
            .with_telemetry(Some(request_telemetry), Some(sse_telemetry));
            let stream_result = client.stream_request(request, options).await;

            match stream_result {
                Ok(stream) => {
                    let (stream, _) = map_response_stream(
                        stream,
                        session_telemetry.clone(),
                        inference_trace_attempt,
                    );
                    return Ok(stream);
                }
                Err(ApiError::Transport(
                    unauthorized_transport @ TransportError::Http { status, .. },
                )) if status == StatusCode::UNAUTHORIZED => {
                    ...
                    pending_retry = PendingUnauthorizedRetry::from_recovery(
                        handle_unauthorized(
                            unauthorized_transport,
                            &mut auth_recovery,
                            session_telemetry,
                        )
                        .await?,
                    );
                    continue;
                }
                Err(err) => {
                    ...
                    let err = map_api_error(err);
                    ...
                    return Err(err);
                }
            }
        }
    }
```

**片段 2-B：`stream_responses_websocket`（WS 路径 + 增量复用 + UPGRADE_REQUIRED 降级）**
`core/src/client.rs:1321-1460`（节选）
```rust
    async fn stream_responses_websocket(
        &mut self,
        prompt: &Prompt,
        model_info: &ModelInfo,
        ...
        warmup: bool,
        request_trace: Option<W3cTraceContext>,
        inference_trace: &InferenceTraceContext,
    ) -> Result<WebsocketStreamOutcome> {
        ...
        loop {
            ...
            match self
                .websocket_connection(WebsocketConnectParams { ... })
                .await
            {
                Ok(_) => {}
                Err(ApiError::Transport(TransportError::Http { status, .. }))
                    if status == StatusCode::UPGRADE_REQUIRED =>
                {
                    return Ok(WebsocketStreamOutcome::FallbackToHttp);
                }
                Err(ApiError::Transport(
                    unauthorized_transport @ TransportError::Http { status, .. },
                )) if status == StatusCode::UNAUTHORIZED => {
                    pending_retry = PendingUnauthorizedRetry::from_recovery(
                        handle_unauthorized(
                            unauthorized_transport,
                            &mut auth_recovery,
                            session_telemetry,
                        )
                        .await?,
                    );
                    continue;
                }
                Err(err) => return Err(map_api_error(err)),
            }

            let (mut ws_request, previous_response_id_from_untraced_warmup) =
                self.prepare_websocket_request(ws_payload, &request);
            ...
            self.websocket_session.last_request = Some(request);
            self.websocket_session.last_response_from_untraced_warmup = warmup;
            ...
            let stream_result = websocket_connection
                .stream_request(
                    ws_request,
                    self.websocket_session.connection_reused(),
                    Some(Arc::clone(&self.turn_state)),
                )
                .await
                ...;
            let (stream, last_request_rx) = map_response_stream(
                stream_result,
                session_telemetry.clone(),
                inference_trace_attempt,
            );
            self.websocket_session.last_response_rx = Some(last_request_rx);
            return Ok(WebsocketStreamOutcome::Stream(stream));
        }
    }
```

**片段 2-C：`get_incremental_items` -- WS 增量 delta 计算（省 token 核心）**
`core/src/client.rs:982-1019`
```rust
    fn get_incremental_items(
        &self,
        request: &ResponsesApiRequest,
        last_response: Option<&LastResponse>,
        allow_empty_delta: bool,
    ) -> Option<Vec<ResponseItem>> {
        // Checks whether the current request is an incremental extension of the previous request.
        // We only reuse an incremental input delta when non-input request fields are unchanged and
        // `input` is a strict
        // extension of the previous known input. Server-returned output items are treated as part
        // of the baseline so we do not resend them.
        let previous_request = self.websocket_session.last_request.as_ref()?;
        let mut previous_without_input = previous_request.clone();
        previous_without_input.input.clear();
        previous_without_input.client_metadata = None;
        let mut request_without_input = request.clone();
        request_without_input.input.clear();
        request_without_input.client_metadata = None;
        if previous_without_input != request_without_input {
            trace!("incremental request failed, websocket reuse properties didn't match");
            return None;
        }

        let mut baseline = previous_request.input.clone();
        if let Some(last_response) = last_response {
            baseline.extend(last_response.items_added.clone());
        }

        let baseline_len = baseline.len();
        if request.input.starts_with(&baseline)
            && (allow_empty_delta || baseline_len < request.input.len())
        {
            Some(request.input[baseline_len..].to_vec())
        } else {
            trace!("incremental request failed, items didn't match");
            None
        }
    }
```

**片段 2-D：`ResponseStream` + mapper task（背压 channel + consumer_dropped 防泄漏）**
`core/src/client_common.rs:108-127` + `core/src/client.rs:1684-1762`
```rust
// client_common.rs
pub struct ResponseStream {
    pub(crate) rx_event: mpsc::Receiver<Result<ResponseEvent>>,
    /// Signals the mapper task that the consumer stopped polling before the
    /// provider stream reached its own terminal event.
    pub(crate) consumer_dropped: CancellationToken,
}

impl Stream for ResponseStream {
    type Item = Result<ResponseEvent>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.rx_event.poll_recv(cx)
    }
}

impl Drop for ResponseStream {
    fn drop(&mut self) {
        self.consumer_dropped.cancel();
    }
}
```
```rust
// client.rs map_response_events
    let (tx_event, rx_event) =
        mpsc::channel::<Result<ResponseEvent>>(RESPONSE_STREAM_CHANNEL_CAPACITY);  // = 1600
    let (tx_last_response, rx_last_response) = oneshot::channel::<LastResponse>();
    let consumer_dropped = CancellationToken::new();
    let consumer_dropped_for_stream = consumer_dropped.clone();

    tokio::spawn(async move {
        ...
        let mut items_added: Vec<ResponseItem> = Vec::new();
        ...
        loop {
            let event = tokio::select! {
                _ = consumer_dropped.cancelled() => {
                    inference_trace_attempt.record_cancelled(
                        STREAM_DROPPED_REASON, upstream_request_id, &items_added,
                    );
                    return;
                }
                event = api_stream.next() => event,
            };
            let Some(event) = event else { break; };
            match event {
                Ok(ResponseEvent::OutputItemDone(item)) => {
                    items_added.push(item.clone());
                    if tx_event.send(Ok(ResponseEvent::OutputItemDone(item))).await.is_err() {
                        // 消费者已离开，记录后退出
                        inference_trace_attempt.record_cancelled(...);
                        return;
                    }
                }
                Ok(ResponseEvent::Completed { response_id, token_usage, end_turn }) => {
                    ...
                    if let Some(sender) = tx_last_response.take() {
                        let _ = sender.send(LastResponse {
                            response_id: response_id.clone(),
                            items_added: std::mem::take(&mut items_added),
                        });
                    }
                    ...
                }
                ...
            }
        }
    });
```

**片段 2-E：turn 主循环 `stream.next().or_cancel` + 终止判定**
`core/src/session/turn.rs:1876-1902`
```rust
        let event = match stream
            .next()
            .instrument(trace_span!(parent: &handle_responses, "receiving"))
            .or_cancel(&cancellation_token)
            .await
        {
            Ok(event) => event,
            Err(codex_async_utils::CancelErr::Cancelled) => break Err(CodexErr::TurnAborted),
        };

        let event = match event {
            Some(Ok(event)) => event,
            Some(Err(err)) => break Err(err),
            None => {
                break Err(CodexErr::Stream(
                    "stream closed before response.completed".into(),
                    None,
                ));
            }
        };
```

**片段 2-F：`Completed` 终止判定（`end_turn=false` 强制 follow-up）**
`core/src/session/turn.rs:2108-2131`
```rust
            ResponseEvent::Completed {
                token_usage,
                end_turn,
                ..
            } => {
                flush_assistant_text_segments_all(
                    &sess, &turn_context, plan_mode_state.as_mut(),
                    &mut assistant_message_stream_parsers,
                ).await;
                sess.record_token_usage_info(&turn_context, token_usage.as_ref()).await;
                should_emit_token_count = true;
                should_emit_turn_diff = true;
                if let Some(false) = end_turn {
                    needs_follow_up = true;
                }
                break Ok(SamplingRequestResult {
                    needs_follow_up,
                    last_agent_message,
                });
            }
```

### ② 逐行解读

- **2-A（HTTP 流）**：外层 `loop` **只服务于 401 恢复**（成功就 `return`）。每次 `current_client_setup` 取最新 auth（token 可能已被刷新），`build_reqwest_client` 建独立 transport，`stream_request` 发 SSE。成功 → `map_response_stream` 包装返回；401 → `handle_unauthorized` 刷新 token，`pending_retry` 携带恢复上下文 `continue` 重发；其他错误 → `map_api_error` 返回。

- **2-B（WS 流）**：同样有 401 loop。区别：
  - `UPGRADE_REQUIRED` → 返回 `FallbackToHttp` 让上层降级（见子项四的 `try_switch_fallback_transport`）；
  - `prepare_websocket_request` 做增量复用（2-C）；
  - `warmup=true` 时 `ws_payload.generate = Some(false)` 仅预热连接；
  - `map_response_stream` 返回 `(stream, last_request_rx)`，后者用 oneshot 收 `LastResponse`（含 `response_id` 和 `items_added`），供下一轮 `previous_response_id` 增量复用。

- **2-C（增量复用，省 token 核心）**：
  - 先比较「去掉 input 和 client_metadata 的请求」是否相等（model/tools/instructions 等不变）；
  - 再用 `last_response.items_added` 扩展 baseline；
  - 最后检查 `request.input.starts_with(baseline)`。
  - 成立 → 只发 `input[baseline_len..]` 这段 delta，配合 `previous_response_id` 让服务端复用历史。
  - `allow_empty_delta=true` 允许 delta 为空（纯预热）。不满足 → 全量发。

- **2-D（mapper task + 背压）**：`map_response_stream` 把上游 `api_stream` 通过容量 **1600** 的 mpsc 桥接到 `ResponseStream`。spawn 的 task 两个职责：① 累积 `items_added` 供 `LastResponse`；② `tokio::select!` 监听 `consumer_dropped`--若消费者（turn loop）提前 drop（如取消），mapper 收到 cancel 后 `record_cancelled` 并退出，**避免泄漏后台 task**。`ResponseStream::Drop` 里 `consumer_dropped.cancel()` 是这个机制的触发点。

- **2-E（主循环拉取）**：`stream.next().or_cancel(&cancellation_token)` 把「等下一个 event」和「取消信号」二选一。`None`（流提前结束）→ `CodexErr::Stream("stream closed before response.completed")`；`Err(Cancelled)` → `TurnAborted`。这是取消传播的关键一环。

- **2-F（Completed 终止）**：刷文本段、记 token、`end_turn == Some(false)` 则 `needs_follow_up = true`，然后 `break` 返回。**注意 `end_turn` 语义**：服务端可能返回 `false` 表示「我自己还要继续」（内部多步推理），Codex 据此强制 follow-up，**不依赖工具调用判定**。

### ③ 设计原理与权衡

- **WS 优先 + 自动降级 HTTP**：WS 省去每轮 TLS 握手、支持 `previous_response_id` 增量复用（大幅减少上行 token），但 WS 在某些网络/代理下不可用（`UPGRADE_REQUIRED`）。Codex 用 `FallbackToHttp` + `try_switch_fallback_transport` 实现自动降级。代价是 transport 状态机复杂，但换取稳态低延迟和低 token。

- **背压 channel（容量 1600）**：mapper task 与 turn loop 解耦--mapper 快速消费上游 SSE（防止服务端背压断连），turn loop 慢消费（要处理工具调度）。`consumer_dropped` 保证取消时不泄漏。1600 是经验值，平衡内存与吞吐。

- **增量分发而非整包**：Responses API 原生支持 delta 事件，Codex 直接透传 `ReasoningContentDeltaEvent`/`AgentMessageContentDeltaEvent` 给前端，实现「打字机效果」。`active_item_is_streaming_to_client` 闸门避免在 review 子线程等场景向前端泄露中间文本。

- **`end_turn` 语义（与朴素 agent 的关键差异）**：朴素 agent 只靠「有没有 tool_call」判定是否继续 loop。Codex 额外尊重服务端 `end_turn=false`--这是「模型知道自己还要继续」的信号，比客户端猜更准。

### ④ 数据流位置

处于 **`run_sampling_request` → `try_run_sampling_request` 内的 `loop`**（`turn.rs:1861`）。上游：`client_session.stream()`（2-A/2-B）→ `ResponseStream`（mpsc）→ `stream.next()`（2-E）。下游：`match event` 分发 → 工具 future 进 `in_flight`（子项三）或 `Completed` break → 返回 `SamplingRequestResult` → 主 loop（`turn.rs:246`）判 `needs_follow_up`。

---

## 三、工具执行 + 权限

> 关键问题：模型输出的 tool_call 怎么变成执行？谁能拦？怎么执行？并发还是串行？

### ① 真实代码片段

**片段 3-A：`build_tool_call` -- ResponseItem → ToolCall 解码**
`core/src/tools/router.rs:96-143`
```rust
    #[instrument(level = "trace", skip_all, err)]
    pub fn build_tool_call(item: ResponseItem) -> Result<Option<ToolCall>, FunctionCallError> {
        match item {
            ResponseItem::FunctionCall {
                name, namespace, arguments, call_id, ..
            } => {
                let tool_name = ToolName::new(namespace, name);
                Ok(Some(ToolCall {
                    tool_name,
                    call_id,
                    payload: ToolPayload::Function { arguments },
                }))
            }
            ResponseItem::ToolSearchCall {
                call_id: Some(call_id), execution, arguments, ..
            } if execution == "client" => {
                let arguments: SearchToolCallParams =
                    serde_json::from_value(arguments).map_err(|err| {
                        FunctionCallError::RespondToModel(format!(
                            "failed to parse tool_search arguments: {err}"
                        ))
                    })?;
                Ok(Some(ToolCall {
                    tool_name: ToolName::plain("tool_search"),
                    call_id,
                    payload: ToolPayload::ToolSearch { arguments },
                }))
            }
            ResponseItem::ToolSearchCall { .. } => Ok(None),
            ResponseItem::CustomToolCall { name, input, call_id, .. } => Ok(Some(ToolCall {
                tool_name: ToolName::plain(name),
                call_id,
                payload: ToolPayload::Custom { input },
            })),
            _ => Ok(None),
        }
    }
```

**片段 3-B：`handle_tool_call_with_source` -- 并发/串行门控 + 取消抢占**
`core/src/tools/parallel.rs:82-178`（节选）
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
                    Either::Left(lock.read().await)      // 读锁：可多个并发
                } else {
                    Either::Right(lock.write().await)    // 写锁：串行
                };

                router
                    .dispatch_tool_call_with_terminal_outcome(
                        session, turn, invocation_cancellation_token, tracker,
                        dispatch_call, source, dispatch_terminal_outcome_reached,
                    )
                    .instrument(dispatch_span.clone())
                    .await
            }));

        async move {
            tokio::select! {
                res = &mut handle => res.map_err(Self::tool_task_join_error)?,
                _ = cancellation_token.cancelled() => {
                    if terminal_outcome_reached.load(Ordering::Acquire) || handle.is_finished() {
                        handle.await.map_err(Self::tool_task_join_error)?
                    } else {
                        let secs = started.elapsed().as_secs_f32().max(0.1);
                        abort_dispatch_span.record("aborted", true);
                        if wait_for_runtime_cancellation {
                            // 让 runtime 有机会优雅清理（如杀 shell 子进程）
                            if terminal_outcome_reached.swap(true, Ordering::AcqRel) {
                                return handle.await.map_err(Self::tool_task_join_error)?;
                            }
                            ...
                        } else {
                            handle.abort();   // 强杀
                            ...
                        }
                        let response = Self::aborted_response(&call, secs);
                        notify_tool_aborted(...).await;
                        Ok(response)
                    }
                },
            }
        }
        .in_current_span()
    }
```

**片段 3-C：`Orchestrator::run` -- 三态审批 + 双沙箱尝试**
`core/src/tools/orchestrator.rs:132-282`（节选）
```rust
    pub async fn run<Rq, Out, T>(
        &mut self,
        tool: &mut T,
        req: &Rq,
        tool_ctx: &ToolCtx,
        turn_ctx: &crate::session::turn_context::TurnContext,
        approval_policy: AskForApproval,
    ) -> Result<OrchestratorRunResult<Out>, ToolError>
    where T: ToolRuntime<Rq, Out>,
    {
        // 1) Approval
        let mut already_approved = false;
        ...
        let requirement = tool.exec_approval_requirement(req).unwrap_or_else(|| {
            default_exec_approval_requirement(approval_policy, &file_system_sandbox_policy)
        });
        match &requirement {
            ExecApprovalRequirement::Skip { .. } => {
                if strict_auto_review {
                    let decision = Self::request_approval(...).await?;
                    Self::reject_if_not_approved(...).await?;
                    already_approved = true;
                } else {
                    otel.tool_decision(&otel_tn, otel_ci, &ReviewDecision::Approved, ToolDecisionSource::Config);
                }
            }
            ExecApprovalRequirement::Forbidden { reason } => {
                return Err(ToolError::Rejected(reason.clone()));
            }
            ExecApprovalRequirement::NeedsApproval { reason, .. } => {
                let guardian_review_id = use_guardian.then(new_guardian_review_id);
                ...
                let decision = Self::request_approval(
                    tool, req, tool_ctx.call_id.as_str(), approval_ctx, tool_ctx,
                    /*evaluate_permission_request_hooks*/ !strict_auto_review, &otel,
                ).await?;
                Self::reject_if_not_approved(tool_ctx, guardian_review_id.as_deref(), decision).await?;
                already_approved = true;
            }
        }

        // 2) First attempt under the selected sandbox.
        let sandbox_override = sandbox_override_for_first_attempt(...);
        let initial_sandbox = match sandbox_override {
            SandboxOverride::BypassSandboxFirstAttempt => SandboxType::None,
            SandboxOverride::NoOverride => self.sandbox.select_initial(...),
        };
        let (first_result, first_deferred_network_approval) = Self::run_attempt(
            tool, req, tool_ctx, &initial_attempt, managed_network_active,
        ).await;
        match first_result {
            Ok(out) => { Ok(OrchestratorRunResult { output: out, deferred_network_approval: first_deferred_network_approval }) }
            Err(ToolError::Codex(CodexErr::Sandbox(SandboxErr::Denied { output, network_policy_decision }))) => {
                // 沙箱拒绝 -> 若允许升级，二次审批后无沙箱重试
                if !tool.escalate_on_failure() { ... return Err(...); }
                let unsandboxed_allowed = unsandboxed_execution_allowed(&file_system_sandbox_policy);
                if !tool.wants_no_sandbox_approval(approval_policy) { ... return Err(...); }
                ...
            }
        }
```

**片段 3-D：`default_exec_approval_requirement` -- 审批策略矩阵**
`core/src/tools/sandboxing.rs:197-238`
```rust
/// - Never, OnFailure: do not ask
/// - OnRequest: ask unless filesystem access is unrestricted
/// - Granular: ask unless filesystem access is unrestricted, but auto-reject
///   when granular sandbox approval is disabled.
/// - UnlessTrusted: always ask
pub(crate) fn default_exec_approval_requirement(
    policy: AskForApproval,
    file_system_sandbox_policy: &FileSystemSandboxPolicy,
) -> ExecApprovalRequirement {
    let needs_approval = match policy {
        AskForApproval::Never | AskForApproval::OnFailure => false,
        AskForApproval::OnRequest | AskForApproval::Granular(_) => {
            matches!(file_system_sandbox_policy.kind, FileSystemSandboxKind::Restricted)
        }
        AskForApproval::UnlessTrusted => true,
    };

    if needs_approval
        && matches!(policy, AskForApproval::Granular(granular_config)
                   if !granular_config.allows_sandbox_approval())
    {
        ExecApprovalRequirement::Forbidden {
            reason: "approval policy disallowed sandbox approval prompt".to_string(),
        }
    } else if needs_approval {
        ExecApprovalRequirement::NeedsApproval { reason: None, proposed_execpolicy_amendment: None }
    } else {
        ExecApprovalRequirement::Skip { bypass_sandbox: false, proposed_execpolicy_amendment: None }
    }
}
```

**片段 3-E：`request_approval` -- PermissionRequest hooks 优先于 guardian/user**
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
                    otel.tool_decision(..., &decision, ToolDecisionSource::Config);
                    return Ok(decision);
                }
                Some(PermissionRequestDecision::Deny { message }) => {
                    let decision = ReviewDecision::Denied;
                    otel.tool_decision(..., &decision, ToolDecisionSource::Config);
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

**片段 3-F：`process_exec_tool_call` -- 沙箱统一执行入口**
`core/src/exec.rs:307-327`
```rust
pub async fn process_exec_tool_call(
    params: ExecParams,
    permission_profile: &PermissionProfile,
    sandbox_cwd: &AbsolutePathBuf,
    windows_sandbox_workspace_roots: &[AbsolutePathBuf],
    codex_linux_sandbox_exe: &Option<PathBuf>,
    use_legacy_landlock: bool,
    stdout_stream: Option<StdoutStream>,
) -> Result<ExecToolCallOutput> {
    let exec_req = build_exec_request(
        params, permission_profile, sandbox_cwd,
        windows_sandbox_workspace_roots, codex_linux_sandbox_exe, use_legacy_landlock,
    )?;

    // Route through the sandboxing module for a single, unified execution path.
    crate::sandboxing::execute_env(exec_req, stdout_stream).await
}
```

### ② 逐行解读

- **3-A（解码）**：把模型返回的三种 tool call（`FunctionCall` / `CustomToolCall` / `ToolSearchCall`）解码为统一 `ToolCall { tool_name, call_id, payload }`。`ToolSearchCall` 只处理 `execution == "client"` 的客户端搜索；参数反序列化失败转 `FunctionCallError::RespondToModel`（让模型看到错误而非崩溃）。

- **3-B（并发门控 + 取消抢占）**：
  - `supports_parallel` 决定读锁还是写锁--支持并行的工具拿读锁（可多个并发），否则拿写锁（串行）。
  - 工具在 `tokio::spawn` 里跑，外层 `tokio::select!` 监听取消。
  - **取消的三态处理**：取消时若 `terminal_outcome_reached`（工具已自然完成）则等结果；否则看 `wait_for_runtime_cancellation`：是 → 标记并等 runtime 清理（如 shell 进程终止）；否 → `handle.abort()` 强杀，返回 `aborted_response`。
  - `terminal_outcome_reached` 是 `Arc<AtomicBool>`，避免 abort 和自然完成同时认领结果（竞态防护）。

- **3-C（三态审批 + 双沙箱）**：
  - `requirement` 来自工具自定义或 `default_exec_approval_requirement`。
  - 三态：`Skip`（通常直接跑，但 strict_auto_review 下仍走 guardian）、`Forbidden`（直接拒绝）、`NeedsApproval`（走 `request_approval`）。
  - 审批后选沙箱：`BypassSandboxFirstAttempt` 或 `select_initial`（Landlock/seatbelt/None）。
  - 首次沙箱失败若 `escalate_on_failure` 且策略允许 → 升级无沙箱重试（需 `wants_no_sandbox_approval` 二次审批）。

- **3-D（审批矩阵）**：`Never`/`OnFailure` 不审批；`OnRequest`/`Granular` 在 Restricted 文件系统下审批；`UnlessTrusted` 总审批。`Granular` 关闭 sandbox_approval 时直接 `Forbidden`（不可问用户）。

- **3-E（审批优先级）**：**PermissionRequest hooks（可编程审批）> guardian（自动 reviewer）> 用户**。hooks 返回 `Allow`/`Deny` 直接定夺，`None` 才 fallback 到 guardian/user。

- **3-F（执行）**：`build_exec_request` 把 `ExecParams` 经 `SandboxManager::transform` 转成 argv/env/sandbox，`execute_env` 统一执行（含 stdout 流式捕获、超时、信号）。

### ③ 设计原理与权衡

- **读/写锁而非全串行**：支持并行的工具（如多个 apply_patch）可真并发，不支持并行的（如 shell，共享 cwd/环境）串行化。代价是需 `supports_parallel_tool_calls` 元数据维护。

- **取消的三态处理（区别于朴素 abort）**：朴素做法是 `abort()` 强杀，但 shell 等长任务被 abort 会留孤儿进程。`wait_for_runtime_cancellation` + `terminal_outcome_reached` 让 runtime 有机会优雅清理。`Arc<AtomicBool>` 解决竞态。

- **双沙箱尝试（安全默认 + 可升级）**：沙箱可能误杀合法操作（如写 workspace 外文件）。`escalate_on_failure` + 二次审批让用户决定是否放行无沙箱。这是「安全默认 + 可升级」的典型取舍。

- **exec_policy 作为可编程审批层**：`default.rules` + 用户 `.rules` 文件 + PermissionRequest hooks 三层叠加，比硬编码 allow/deny 灵活。`BANNED_PREFIX_SUGGESTIONS`（`exec_policy.rs:52-99`）列出 python/bash 等解释器前缀，提示危险 wrapper。

### ④ 数据流位置

处于 **`try_run_sampling_request` 的 `match event { OutputItemDone => handle_output_item_done => tool_future => in_flight.push_back }`**（`turn.rs:1982-1984`）之后，由 `drain_in_flight`（`turn.rs:2256`）消费。`in_flight` 是 `FuturesOrdered`，按完成顺序回填 history。`Orchestrator::run` 在 `dispatch_tool_call_with_terminal_outcome` 内部被调用。

---

## 四、错误恢复

> 关键问题：API 失败、工具失败、用户取消，怎么不崩？

### ① 真实代码片段

**片段 4-A：`run_sampling_request` 重试 loop + ContextWindowExceeded 短路**
`core/src/session/turn.rs:1056-1118`
```rust
    let max_retries = turn_context.provider.info().stream_max_retries();
    let mut retries = 0;
    let mut initial_input = Some(input);
    loop {
        let prompt_input = if let Some(input) = initial_input.take() {
            input
        } else {
            sess.clone_history().await
                .for_prompt(&turn_context.model_info.input_modalities)
        };
        let prompt = build_prompt(
            prompt_input, router.as_ref(), turn_context.as_ref(), base_instructions.clone(),
        );
        let err = match try_run_sampling_request(
            tool_runtime.clone(), Arc::clone(&sess), Arc::clone(&turn_context),
            Arc::clone(&turn_store), client_session, responses_metadata,
            Arc::clone(&turn_diff_tracker), &prompt, cancellation_token.child_token(),
        ).await
        {
            Ok(output) => { return Ok(output); }
            Err(CodexErr::ContextWindowExceeded) => {
                sess.set_total_tokens_full(&turn_context).await;
                return Err(CodexErr::ContextWindowExceeded);
            }
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };

        if !err.is_retryable() {
            return Err(err);
        }

        handle_retryable_response_stream_error(
            &mut retries, max_retries, err, client_session, &sess, &turn_context,
            ResponsesStreamRequest::Sampling,
        ).await?;
        turn_context.turn_timing_state.record_sampling_retry();
    }
```

**片段 4-B：`is_retryable` -- 错误分类**
`protocol/src/error.rs:172-210`
```rust
impl CodexErr {
    pub fn is_retryable(&self) -> bool {
        match self {
            CodexErr::TurnAborted
            | CodexErr::Interrupted
            | CodexErr::EnvVar(_)
            | CodexErr::Fatal(_)
            | CodexErr::UsageNotIncluded
            | CodexErr::QuotaExceeded
            | CodexErr::InvalidImageRequest()
            | CodexErr::InvalidRequest(_)
            | CodexErr::RefreshTokenFailed(_)
            | CodexErr::UnsupportedOperation(_)
            | CodexErr::Sandbox(_)
            | CodexErr::LandlockSandboxExecutableNotProvided
            | CodexErr::RetryLimit(_)
            | CodexErr::ContextWindowExceeded
            | CodexErr::ThreadNotFound(_)
            | CodexErr::AgentLimitReached { .. }
            | CodexErr::Spawn
            | CodexErr::SessionConfiguredNotFirstEvent
            | CodexErr::UsageLimitReached(_)
            | CodexErr::ServerOverloaded
            | CodexErr::CyberPolicy { .. } => false,
            CodexErr::Stream(..)
            | CodexErr::Timeout
            | CodexErr::RequestTimeout
            | CodexErr::UnexpectedStatus(_)
            | CodexErr::ResponseStreamFailed(_)
            | CodexErr::ConnectionFailed(_)
            | CodexErr::InternalServerError
            | CodexErr::InternalAgentDied
            | CodexErr::Io(_)
            | CodexErr::Json(_)
            | CodexErr::TokioJoin(_) => true,
            #[cfg(target_os = "linux")]
            CodexErr::LandlockRuleset(_) | CodexErr::LandlockPathFd(_) => false,
        }
    }
}
```

**片段 4-C：`handle_retryable_response_stream_error` -- 退避 + WS→HTTP 降级**
`core/src/responses_retry.rs:22-79`
```rust
/// Handles a retryable stream error and returns `Ok(())` when the caller should retry the request loop.
pub(crate) async fn handle_retryable_response_stream_error(
    retries: &mut u64,
    max_retries: u64,
    err: CodexErr,
    client_session: &mut ModelClientSession,
    sess: &Session,
    turn_context: &TurnContext,
    request: ResponsesStreamRequest,
) -> Result<(), CodexErr> {
    // 第一层：已达 max 且能降级 transport（WS->HTTP），重置预算重来
    if *retries >= max_retries
        && client_session.try_switch_fallback_transport(
            &turn_context.session_telemetry, &turn_context.model_info,
        )
    {
        sess.send_event(
            turn_context,
            EventMsg::Warning(WarningEvent {
                message: format!("Falling back from WebSockets to HTTPS transport. {err:#}"),
            }),
        ).await;
        *retries = 0;
        return Ok(());
    }

    // 第二层：未达上限则指数退避重试
    if *retries < max_retries {
        *retries += 1;
        let retry_count = *retries;
        let delay = match &err {
            CodexErr::Stream(_, requested_delay) => requested_delay.unwrap_or_else(|| backoff(retry_count)),
            _ => backoff(retry_count),
        };
        log_retry(request, turn_context, &err, retry_count, max_retries, delay);

        // release 下隐藏首次 WS 重试通知降噪；debug 全量可见
        let report_error = retry_count > 1
            || cfg!(debug_assertions)
            || !sess.services.model_client.responses_websocket_enabled();
        if report_error {
            sess.notify_stream_error(
                turn_context,
                format!("Reconnecting... {retry_count}/{max_retries}"),
                err,
            ).await;
        }
        tokio::time::sleep(delay).await;
        return Ok(());
    }

    Err(err)
}
```

**片段 4-D：`try_switch_fallback_transport`**
`core/src/client.rs:1618-1628`
```rust
    pub(crate) fn try_switch_fallback_transport(
        &mut self,
        session_telemetry: &SessionTelemetry,
        model_info: &ModelInfo,
    ) -> bool {
        let activated = self.client.force_http_fallback(session_telemetry, model_info);
        self.websocket_session = WebsocketSession::default();  // 清空 sticky routing/last_request
        activated
    }
```

**片段 4-E：`failure_response` -- 工具 FunctionCallError → 模型可见输出**
`core/src/tools/parallel.rs:186-211`
```rust
    fn failure_response(call: ToolCall, err: FunctionCallError) -> ResponseInputItem {
        let message = err.to_string();
        match call.payload {
            ToolPayload::ToolSearch { .. } => ResponseInputItem::ToolSearchOutput {
                call_id: call.call_id, status: "completed".to_string(),
                execution: "client".to_string(), tools: Vec::new(),
            },
            ToolPayload::Custom { .. } => ResponseInputItem::CustomToolCallOutput {
                call_id: call.call_id, name: None,
                output: codex_protocol::models::FunctionCallOutputPayload {
                    body: codex_protocol::models::FunctionCallOutputBody::Text(message),
                    success: Some(false),
                },
            },
            _ => ResponseInputItem::FunctionCallOutput {
                call_id: call.call_id,
                output: codex_protocol::models::FunctionCallOutputPayload {
                    body: codex_protocol::models::FunctionCallOutputBody::Text(message),
                    success: Some(false),
                },
            },
        }
    }
```

### ② 逐行解读

- **4-A（重试 loop）**：`run_sampling_request` 内 `loop`。成功直接 `return Ok`。`ContextWindowExceeded` 短路（`set_total_tokens_full` 标记满，交给上层 `run_auto_compact` 压缩）；`UsageLimitReached` 短路（更新 rate limit 上报）。其他错误：`!is_retryable` 直接返回；可重试 → `handle_retryable_response_stream_error`。`initial_input.take()` 保证首轮用传入 input，重试用 `clone_history().for_prompt` 重新组装（history 可能已被本轮部分写入）。

- **4-B（错误分类）**：业务错误（Sandbox/Quota/InvalidRequest/ContextWindowExceeded 等）**不可重试**；传输层错误（Stream/Timeout/ConnectionFailed/InternalServerError/Io/Json 等）**可重试**。注意 `TurnAborted` 不可重试（用户取消）。

- **4-C（退避 + 降级，两层恢复）**：
  - (1) 若已达 `max_retries` 且 `try_switch_fallback_transport` 成功（WS→HTTP），重置 `retries=0` 重新开始（**给 HTTP 额外预算**）；
  - (2) 未达上限则 `retries += 1`，`backoff(retry_count)` 指数退避，`Stream` 错误尊重服务端 `requested_delay`。release 下隐藏首次 WS 重试通知（降噪），debug 全量。`notify_stream_error` 让前端显示「Reconnecting...」。

- **4-D（降级实现）**：`force_http_fallback` 激活降级标志（后续走 `stream_responses_api` 而非 WS），清空 `WebsocketSession`（丢弃 sticky routing/last_request 状态）。

- **4-E（工具失败转模型输入，关键设计！）**：工具 `FunctionCallError` **不直接抛给 turn loop**，而是转成 `ResponseInputItem::FunctionCallOutput`（`success: Some(false)` + 错误文本），让模型「看到」工具失败并自行决定重试/换方案。**工具错误是数据而非异常**--这是 agent 鲁棒性的关键。

### ③ 设计原理与权衡

- **三层错误恢复梯度（从便宜到昂贵）**：
  1. 传输层退避重试（`backoff` 指数）；
  2. transport 降级（WS→HTTP，重置预算）；
  3. auth 恢复（401 token 刷新状态机）。
  - 朴素做法是「任意错误重试 N 次」。Codex 区分可重试性 + transport 降级 + auth 状态机，显著提升鲁棒性。

- **工具错误转数据（区别于业界很多 agent）**：业界很多 agent 把工具异常当致命错误终止 turn。Codex 把 `FunctionCallError` 序列化为 `success: false` 的 FunctionCallOutput，模型可基于错误信息自我修正。代价是模型可能陷入「重试同一失败工具」循环，靠 `max_retries` 和 compaction 兜底。

- **CancellationToken 全链路传播**：`run_turn` 收到 `cancellation_token`，传给 `run_sampling_request`（`.child_token()`），再到 `try_run_sampling_request`，`stream.next().or_cancel` 和 `handle_tool_call_with_source` 都监听。`ContextWindowExceeded` 等不可重试错误在 `is_cancelled` 检查前返回，保证已记录的 token usage 不丢。

- **WS→HTTP 降级重置预算**：降级是 transport 切换，HTTP 是全新 transport，所以 `retries=0` 给它独立预算。避免「WS 用尽重试后 HTTP 一次都不给」。

### ④ 数据流位置

`handle_retryable_response_stream_error` 处于 **`run_sampling_request` 的 `loop` 内**（`turn.rs:1107`），包裹 `try_run_sampling_request`。`handle_unauthorized` 处于 **`stream_responses_api`/`stream_responses_websocket` 的 `loop` 内**（`client.rs:1282`/`1396`），在请求发出前的 401 检查。`failure_response` 处于 **`drain_in_flight` 回填时**（工具 future 失败时调用）。`is_retryable` 是 `run_sampling_request` 的决策点（`turn.rs:1103`）。

---

## 五、上下文压缩

> 关键问题：token 爆了怎么摘要裁剪？什么时候触发？

### ① 真实代码片段

**片段 5-A：`run_pre_sampling_compact` + `run_auto_compact` -- 触发与三路分发**
`core/src/session/turn.rs:782-947`（节选）
```rust
#[instrument(level = "trace", skip_all)]
async fn run_pre_sampling_compact(
    sess: &Arc<Session>, turn_context: &Arc<TurnContext>,
    client_session: &mut ModelClientSession,
) -> CodexResult<()> {
    maybe_run_previous_model_inline_compact(sess, turn_context, client_session).await?;
    let token_status = auto_compact_token_status(sess.as_ref(), turn_context.as_ref()).await;
    // Compact if the configured auto-compaction budget or usable context window is exhausted.
    if token_status.token_limit_reached {
        run_auto_compact(
            sess, turn_context, client_session,
            InitialContextInjection::DoNotInject,
            CompactionReason::ContextLimit, CompactionPhase::PreTurn,
        ).await?;
    }
    Ok(())
}
```
```rust
async fn run_auto_compact(
    sess: &Arc<Session>, turn_context: &Arc<TurnContext>,
    client_session: &mut ModelClientSession,
    initial_context_injection: InitialContextInjection,
    reason: CompactionReason, phase: CompactionPhase,
) -> CodexResult<()> {
    if should_use_remote_compact_task(turn_context.provider.info()) {
        if turn_context.features.enabled(Feature::RemoteCompactionV2) {
            emit_compact_metric(&sess.services.session_telemetry, "remote_v2", false);
            run_inline_remote_auto_compact_task_v2(
                Arc::clone(sess), Arc::clone(turn_context), client_session,
                initial_context_injection, reason, phase,
            ).await?;
            return Ok(());
        }
        emit_compact_metric(&sess.services.session_telemetry, "remote", false);
        run_inline_remote_auto_compact_task(
            Arc::clone(sess), Arc::clone(turn_context), client_session.turn_state(),
            initial_context_injection, reason, phase,
        ).await?;
    } else {
        emit_compact_metric(&sess.services.session_telemetry, "local", false);
        run_inline_auto_compact_task(
            Arc::clone(sess), Arc::clone(turn_context),
            initial_context_injection, reason, phase,
        ).await?;
    }
    Ok(())
}
```

**片段 5-B：主 loop 中 mid-turn 压缩触发**
`core/src/session/turn.rs:301-320`
```rust
                // as long as compaction works well in getting us way below the token limit, we shouldn't worry about being in an infinite loop.
                if token_limit_reached && needs_follow_up {
                    if let Err(err) = run_auto_compact(
                        &sess, &turn_context, &mut client_session,
                        InitialContextInjection::BeforeLastUserMessage,
                        CompactionReason::ContextLimit, CompactionPhase::MidTurn,
                    ).await
                    {
                        let error = err.to_codex_protocol_error();
                        sess.emit_turn_error_lifecycle(turn_context.as_ref(), error.clone()).await;
                        return None;
                    }
                    can_drain_pending_input = !model_needs_follow_up;
                    continue;
                }
```

**片段 5-C：`auto_compact_token_status` -- 双 scope 阈值**
`core/src/session/turn.rs:733-780`（节选）
```rust
async fn auto_compact_token_status(
    sess: &Session, turn_context: &TurnContext,
) -> AutoCompactTokenStatus {
    let active_context_tokens = sess.get_total_token_usage().await;
    let mut auto_compact_window_prefill_tokens = None;
    let (auto_compact_scope_tokens, auto_compact_scope_limit, full_context_window_limit) =
        match turn_context.config.model_auto_compact_token_limit_scope {
            AutoCompactTokenLimitScope::Total => (
                active_context_tokens,
                turn_context.model_info.auto_compact_token_limit().unwrap_or(i64::MAX),
                None,
            ),
            AutoCompactTokenLimitScope::BodyAfterPrefix => {
                let window = sess.auto_compact_window_snapshot().await;
                auto_compact_window_prefill_tokens = window.prefill_input_tokens;
                let baseline = window.prefill_input_tokens.unwrap_or(active_context_tokens);
                (
                    active_context_tokens.saturating_sub(baseline),
                    turn_context.config.model_auto_compact_token_limit
                        .or_else(|| turn_context.model_info.auto_compact_token_limit())
                        .unwrap_or(i64::MAX),
                    turn_context.model_context_window(),
                )
            }
        };
    let full_context_window_limit_reached =
        full_context_window_limit.is_some_and(|full| active_context_tokens >= full);
    let token_limit_reached =
        auto_compact_scope_tokens >= auto_compact_scope_limit || full_context_window_limit_reached;
```

**片段 5-D：`run_compact_task_inner_impl` -- 本地压缩主逻辑 + ContextWindowExceeded 降级裁剪**
`core/src/compact.rs:196-330`（节选）
```rust
async fn run_compact_task_inner_impl(
    sess: Arc<Session>, turn_context: Arc<TurnContext>, input: Vec<UserInput>,
    initial_context_injection: InitialContextInjection,
    compaction_metadata: CompactionTurnMetadata,
) -> CodexResult<String> {
    let compaction_item = TurnItem::ContextCompaction(ContextCompactionItem::new());
    sess.emit_turn_item_started(&turn_context, &compaction_item).await;
    let initial_input_for_turn: ResponseInputItem = ResponseInputItem::from(input);

    let mut history = sess.clone_history().await;
    history.record_items(&[initial_input_for_turn.into()], turn_context.truncation_policy);

    let max_retries = turn_context.provider.info().stream_max_retries();
    let mut retries = 0;
    let mut client_session = sess.services.model_client.new_session();
    ...
    loop {
        // Clone is required because of the loop
        let turn_input = history.clone().for_prompt(&turn_context.model_info.input_modalities);
        let turn_input_len = turn_input.len();
        let prompt = Prompt {
            input: turn_input,
            base_instructions: sess.get_base_instructions().await,
            personality: turn_context.personality,
            ..Default::default()
        };
        let attempt_result = drain_to_completed(
            &sess, turn_context.as_ref(), &mut client_session,
            &responses_metadata, &prompt,
        ).await;

        match attempt_result {
            Ok(()) => { break; }
            Err(CodexErr::Interrupted) => { return Err(CodexErr::Interrupted); }
            Err(e @ CodexErr::ContextWindowExceeded) => {
                if turn_input_len > 1 {
                    // Trim from the beginning to preserve cache (prefix-based) and keep recent messages intact.
                    error!(
                        "Context window exceeded while compacting; removing oldest history item. Error: {e}"
                    );
                    history.remove_first_item();
                    retries = 0;
                    continue;
                }
                sess.set_total_tokens_full(turn_context.as_ref()).await;
                ...
                return Err(e);
            }
            Err(e) => {
                if retries < max_retries {
                    retries += 1;
                    let delay = backoff(retries);
                    sess.notify_stream_error(turn_context.as_ref(),
                        format!("Reconnecting... {retries}/{max_retries}"), e).await;
                    tokio::time::sleep(delay).await;
                    continue;
                } else { ... return Err(e); }
            }
        }
    }

    let history_snapshot = sess.clone_history().await;
    let history_items = history_snapshot.raw_items();
    let summary_suffix = get_last_assistant_message_from_turn(history_items).unwrap_or_default();
    let summary_text = format!("{SUMMARY_PREFIX}\n{summary_suffix}");
    let user_messages = collect_user_messages(history_items);

    let mut new_history = build_compacted_history(Vec::new(), &user_messages, &summary_text);
    let window_id = sess.advance_auto_compact_window_id().await;

    if matches!(initial_context_injection, InitialContextInjection::BeforeLastUserMessage) {
        let initial_context = sess.build_initial_context(turn_context.as_ref()).await;
        new_history = insert_initial_context_before_last_real_user_or_summary(new_history, initial_context);
    }
    let reference_context_item = match initial_context_injection {
        InitialContextInjection::DoNotInject => None,
        InitialContextInjection::BeforeLastUserMessage => Some(turn_context.to_turn_context_item()),
    };
    let compacted_item = CompactedItem {
        message: summary_text.clone(),
        replacement_history: Some(new_history.clone()),
        window_id: Some(window_id),
    };
    sess.replace_compacted_history(new_history, reference_context_item, compacted_item).await;
    sess.recompute_token_usage(&turn_context).await;
    ...
    Ok(summary_suffix)
}
```

**片段 5-E：`remove_first_item` -- 配对保持不变量**
`core/src/context_manager/history.rs:157-167`
```rust
    pub(crate) fn remove_first_item(&mut self) {
        if !self.items.is_empty() {
            // Remove the oldest item (front of the list). Items are ordered from
            // oldest -> newest, so index 0 is the first entry recorded.
            let removed = self.items.remove(0);
            // If the removed item participates in a call/output pair, also remove
            // its corresponding counterpart to keep the invariants intact without
            // running a full normalization pass.
            normalize::remove_corresponding_for(&mut self.items, &removed);
        }
    }
```

**片段 5-F：`trim_function_call_history_to_fit_context_window` -- remote v2 前置裁剪**
`core/src/compact_remote.rs:362-439`（节选）
```rust
pub(crate) fn trim_function_call_history_to_fit_context_window(
    history: &mut ContextManager, turn_context: &TurnContext,
    base_instructions: &BaseInstructions,
) -> (usize, i64) {
    let Some(context_window) = turn_context.model_context_window() else { return (0, 0); };
    let mut rewritten_outputs = 0usize;
    let mut estimated_deleted_tokens = 0i64;
    let item_count = history.raw_items().len();

    for index in (0..item_count).rev() {
        let Some(estimated_tokens_before) =
            history.estimate_token_count_with_base_instructions(base_instructions)
        else { break; };
        if estimated_tokens_before <= context_window { break; };
        let Some(rewritten_item) = history.raw_items().get(index)
            .and_then(rewritten_output_for_context_window)
        else { break; };
        let mut items = history.raw_items().to_vec();
        items[index] = rewritten_item;
        history.replace(items);
        let estimated_tokens_after = history
            .estimate_token_count_with_base_instructions(base_instructions).unwrap_or_default();
        rewritten_outputs += 1;
        estimated_deleted_tokens = estimated_deleted_tokens
            .saturating_add(estimated_tokens_before.saturating_sub(estimated_tokens_after));
    }
    (rewritten_outputs, estimated_deleted_tokens)
}

fn rewritten_output_for_context_window(item: &ResponseItem) -> Option<ResponseItem> {
    Some(match item {
        ResponseItem::FunctionCallOutput { call_id, output } => ResponseItem::FunctionCallOutput {
            call_id: call_id.clone(),
            output: truncated_output_payload(output),
        },
        ResponseItem::CustomToolCallOutput { call_id, name, output } => ResponseItem::CustomToolCallOutput {
            call_id: call_id.clone(), name: name.clone(),
            output: truncated_output_payload(output),
        },
        ResponseItem::ToolSearchOutput { call_id, status, execution, .. } => ResponseItem::ToolSearchOutput {
            call_id: call_id.clone(), status: status.clone(),
            execution: execution.clone(), tools: Vec::new(),
        },
        _ => return None,
    })
}
```

### ② 逐行解读

- **5-A（触发分发）**：`run_pre_sampling_compact` 在采样前跑：① `maybe_run_previous_model_inline_compact`（模型切换/comp_hash 变化时用旧模型压缩）；② `auto_compact_token_status` 检查阈值。`run_auto_compact` 按 provider 能力三路分发：`RemoteCompactionV2`（服务端 `/responses/compact`）/ `remote`（v1）/ `local`（本地自压缩）。

- **5-B（mid-turn 触发）**：主 loop 中采样后若 `token_limit_reached && needs_follow_up`，用 `BeforeLastUserMessage` 注入 + `MidTurn` phase 压缩，然后 `continue`。**注释直说**：「只要压缩能把 token 降下来，不用担心死循环」。

- **5-C（双 scope 阈值）**：`Total` scope 用总 token 对比 `auto_compact_token_limit`；`BodyAfterPrefix` scope 减去 prefill（系统前缀）后对比，并额外检查 `full_context_window_limit`（硬上限）。后者更精细，避免前缀本身就大时误触发。

- **5-D（本地压缩主逻辑）**：把压缩 prompt 当一次普通 turn 跑（`drain_to_completed` 流式收集）。
  - `ContextWindowExceeded` 时 `remove_first_item` 从头删（保 cache prefix + 近期消息），`retries=0` 继续；只剩 1 条还超则放弃。
  - 成功后取最后一条 assistant message 作为 summary，`build_compacted_history` 用 summary + 近期 user messages 重建历史。
  - `replace_compacted_history` 替换 + `recompute_token_usage` 重估。

- **5-E（配对删除）**：`remove_first_item` 删 index 0 后调 `remove_corresponding_for`--若删的是 call，删对应 output；反之亦然。保持 `normalize_history` 的两条不变量，避免下次 `for_prompt` 时孤儿项。

- **5-F（remote v2 前置裁剪）**：从后往前遍历，若 `estimate_token_count > context_window`，把 `FunctionCallOutput`/`CustomToolCallOutput` 的 body 替换为 `CONTEXT_WINDOW_TRUNCATED_OUTPUT_MESSAGE` 占位文本（保留 `success` 和 call_id），`ToolSearchOutput` 清空 tools。**减少 token 又不破坏 call/output 配对**。

### ③ 设计原理与权衡

- **多级裁剪梯度（破坏性递增）**：
  1. remote v2 前置 `trim_function_call_history`（**改写**大 output 为占位）；
  2. 本地压缩 `ContextWindowExceeded` 时 `remove_first_item`（**删除**最老）；
  3. 最终 `build_compacted_history`（**重建**：summary + 近期 user）。
  - 从「改写」到「删除」到「重建」，破坏性递增，**先保近期、保配对、保 cache prefix**。

- **Memento 策略**：`CompactionStrategy::Memento`（`compact.rs:400`）--保留 summary + 近期 user messages 原文，丢弃中间 assistant/tool 交互。比纯 summary 更保真（用户原话不丢），比全量更省 token。

- **`InitialContextInjection` 双模式**：pre-turn/manual 用 `DoNotInject`（清 baseline，下次 turn 全量重注入）；mid-turn 用 `BeforeLastUserMessage`（在最后真实 user message 前插入 initial context，因为模型训练时见到的压缩 summary 应在最后）。这是「压缩后 prompt 形状」的精细对齐。

- **本地 vs remote 取舍**：local 不依赖服务端能力但多一次 inference；remote v2 服务端原生支持但需 provider 支持。`should_use_remote_compact_task` 按 provider 分发。`MAX_REMOTE_COMPACTION_V2_STREAM_RETRIES=2` 比普通 turn 的 retry 预算小（压缩本身耗时）。

### ④ 数据流位置

`run_pre_sampling_compact` 在 **`run_turn` 起始、采样前**（`turn.rs:151`）。mid-turn `run_auto_compact` 在 **主 loop 采样后、`needs_follow_up` 判定后**（`turn.rs:303`）。`trim_function_call_history_to_fit_context_window` 在 **remote v2 发送请求前**（`compact_remote_v2.rs:200`）。压缩完成后 `replace_compacted_history` 改写 history + 清/设 baseline，下一轮 `for_prompt` 基于压缩后历史。

---

## 六、Checkpoint 回滚

> 关键问题：状态怎么持久化？怎么回退到某点？fork 和 rollback 区别？

### ① 真实代码片段

**片段 6-A：`thread_rollback` 入口**
`core/src/session/handlers.rs:450-531`（节选）
```rust
pub async fn thread_rollback(sess: &Arc<Session>, sub_id: String, num_turns: u32) {
    if num_turns == 0 {
        sess.send_event_raw(Event {
            id: sub_id,
            msg: EventMsg::Error(ErrorEvent {
                message: "num_turns must be >= 1".to_string(),
                codex_error_info: Some(CodexErrorInfo::ThreadRollbackFailed),
            }),
        }).await;
        return;
    }

    let has_active_turn = { sess.active_turn.lock().await.is_some() };
    if has_active_turn {
        sess.send_event_raw(Event {
            id: sub_id,
            msg: EventMsg::Error(ErrorEvent {
                message: "Cannot rollback while a turn is in progress.".to_string(),
                codex_error_info: Some(CodexErrorInfo::ThreadRollbackFailed),
            }),
        }).await;
        return;
    }

    let turn_context = sess.new_default_turn_with_sub_id(sub_id).await;
    let live_thread = match sess.live_thread_for_persistence("rollback thread") {
        Ok(live_thread) => live_thread,
        Err(_) => {
            sess.send_event_raw(Event {
                id: turn_context.sub_id.clone(),
                msg: EventMsg::Error(ErrorEvent {
                    message: "thread rollback requires persisted thread history".to_string(),
                    codex_error_info: Some(CodexErrorInfo::ThreadRollbackFailed),
                }),
            }).await;
            return;
        }
    };
    // 先 flush 确保所有 buffered items 落盘
    if let Err(err) = live_thread.flush().await { ... return; }

    let stored_history = match live_thread.load_history(/*include_archived*/ false).await {
        Ok(history) => history,
        Err(err) => { ... return; }
    };

    let rollback_event = ThreadRolledBackEvent { num_turns };
    let rollback_msg = EventMsg::ThreadRolledBack(rollback_event.clone());
    // rollback marker 被追加到 stored_history 末尾，作为 replay 输入
    let replay_items = stored_history
        .items
        .into_iter()
        .chain(std::iter::once(RolloutItem::EventMsg(rollback_msg.clone())))
        .collect::<Vec<_>>();
    sess.apply_rollout_reconstruction(turn_context.as_ref(), replay_items.as_slice()).await;
    sess.recompute_token_usage(turn_context.as_ref()).await;

    sess.persist_rollout_items(&[RolloutItem::EventMsg(rollback_msg.clone())]).await;
    if let Err(err) = sess.flush_rollout().await {
        sess.send_event(
            turn_context.as_ref(),
            EventMsg::Warning(WarningEvent {
                message: format!(
                    "Rolled the thread back, but failed to save the rollback marker. Codex will continue retrying. Error: {err}"
                ),
```

**片段 6-B：`Op::ThreadRollback` 分发**
`core/src/session/handlers.rs:797-800`
```rust
                Op::ThreadRollback { num_turns } => {
                    thread_rollback(&sess, sub.id.clone(), num_turns).await;
                    false
                }
```

**片段 6-C：`reconstruct_history_from_rollout` -- 反向扫描 + 前向重放**
`core/src/session/rollout_reconstruction.rs:94-240`（节选）
```rust
    pub(super) async fn reconstruct_history_from_rollout(
        &self,
        turn_context: &TurnContext,
        rollout_items: &[RolloutItem],
    ) -> RolloutReconstruction {
        // Replay metadata should already match the shape of the future lazy reverse loader...
        // Scan newest-to-oldest, stopping once a surviving replacement-history checkpoint and
        // the required resume metadata are both known; then replay only the buffered surviving
        // tail forward to preserve exact history semantics.
        let mut base_replacement_history: Option<&[ResponseItem]> = None;
        let mut previous_turn_settings = None;
        let mut reference_context_item = TurnReferenceContextItem::NeverSet;
        let mut window_id = None;
        // Rollback is "drop the newest N user turns". While scanning in reverse, that becomes
        // "skip the next N user-turn segments we finalize".
        let mut pending_rollback_turns = 0usize;
        let mut rollout_suffix = rollout_items;
        let mut active_segment: Option<ActiveReplaySegment<'_>> = None;

        for (index, item) in rollout_items.iter().enumerate().rev() {
            match item {
                RolloutItem::Compacted(compacted) => {
                    let active_segment = active_segment.get_or_insert_with(ActiveReplaySegment::default);
                    if active_segment.window_id.is_none() {
                        active_segment.window_id = compacted.window_id;
                    }
                    // Looking backward, compaction clears any older baseline unless a newer
                    // `TurnContextItem` in this same segment has already re-established it.
                    if matches!(active_segment.reference_context_item, TurnReferenceContextItem::NeverSet) {
                        active_segment.reference_context_item = TurnReferenceContextItem::Cleared;
                    }
                    if active_segment.base_replacement_history.is_none()
                        && let Some(replacement_history) = &compacted.replacement_history
                    {
                        active_segment.base_replacement_history = Some(replacement_history);
                        rollout_suffix = &rollout_items[index + 1..];
                    }
                }
                RolloutItem::EventMsg(EventMsg::ThreadRolledBack(rollback)) => {
                    pending_rollback_turns = pending_rollback_turns
                        .saturating_add(usize::try_from(rollback.num_turns).unwrap_or(usize::MAX));
                }
                ...
                RolloutItem::EventMsg(EventMsg::TurnStarted(event)) => {
                    // `TurnStarted` is the oldest boundary of the active reverse segment.
                    if active_segment.as_ref().is_some_and(|active_segment| {
                        turn_ids_are_compatible(
                            active_segment.turn_id.as_deref(),
                            Some(event.turn_id.as_str()),
                        )
                    }) && let Some(active_segment) = active_segment.take()
                    {
                        finalize_active_segment(
                            active_segment,
                            &mut base_replacement_history,
                            &mut previous_turn_settings,
                            &mut reference_context_item,
                            &mut window_id,
                            &mut pending_rollback_turns,
                        );
                    }
                }
                ...
            }

            // 三者都确定就 break，更老的 items 不影响
            if base_replacement_history.is_some()
                && previous_turn_settings.is_some()
                && !matches!(reference_context_item, TurnReferenceContextItem::NeverSet)
            {
                break;
            }
        }
        ...
        let mut history = ContextManager::new();
        ...
        if let Some(base_replacement_history) = base_replacement_history {
            history.replace(base_replacement_history.to_vec());
        }
        // 前向重放 surviving suffix
        for item in rollout_suffix {
            match item {
                RolloutItem::ResponseItem(response_item) => {
                    history.record_items(
                        std::iter::once(response_item),
                        turn_context.truncation_policy,
                    );
                }
                ...
                RolloutItem::Compacted(compacted) => {
                    if let Some(replacement_history) = &compacted.replacement_history {
                        history.replace(replacement_history.clone());
                    } else { ... }
                }
                _ => {}
            }
        }
```

**片段 6-D：`finalize_active_segment` -- 回滚跳过逻辑**
`core/src/session/rollout_reconstruction.rs:45-91`
```rust
fn finalize_active_segment<'a>(
    active_segment: ActiveReplaySegment<'a>,
    base_replacement_history: &mut Option<&'a [ResponseItem]>,
    previous_turn_settings: &mut Option<PreviousTurnSettings>,
    reference_context_item: &mut TurnReferenceContextItem,
    window_id: &mut Option<u64>,
    pending_rollback_turns: &mut usize,
) {
    // Thread rollback drops the newest surviving real user-message boundaries. In replay, that
    // means skipping the next finalized segments that contain a non-contextual
    // `EventMsg::UserMessage`.
    if *pending_rollback_turns > 0 {
        if active_segment.counts_as_user_turn {
            *pending_rollback_turns -= 1;
        }
        return;   // 丢弃该 segment
    }

    // A surviving replacement-history checkpoint is a complete history base. Once we
    // know the newest surviving one, older rollout items do not affect rebuilt history.
    if base_replacement_history.is_none()
        && let Some(segment_base_replacement_history) = active_segment.base_replacement_history
    {
        *base_replacement_history = Some(segment_base_replacement_history);
    }
    ...
```

**片段 6-E：`RolloutRecorder` + `RolloutCmd`**
`rollout/src/recorder.rs:75-110`
```rust
/// $ fx ~/.codex/sessions/rollout-2025-05-07T17-24-21-5973b6c0-94b8-487b-a530-2aeb6098ae0e.jsonl
/// ```
#[derive(Clone)]
pub struct RolloutRecorder {
    tx: Sender<RolloutCmd>,
    writer_task: Arc<RolloutWriterTask>,
    pub(crate) rollout_path: PathBuf,
}

#[derive(Clone)]
pub enum RolloutRecorderParams {
    Create {
        conversation_id: ThreadId,
        forked_from_id: Option<ThreadId>,
        parent_thread_id: Option<ThreadId>,
        source: SessionSource,
        thread_source: Option<ThreadSource>,
        base_instructions: BaseInstructions,
        dynamic_tools: Vec<DynamicToolSpec>,
        multi_agent_version: Option<MultiAgentVersion>,
    },
    Resume { path: PathBuf },
}

enum RolloutCmd {
    AddItems(Vec<RolloutItem>),
    Persist { ack: oneshot::Sender<std::io::Result<()>> },
    /// Ensure all prior writes are processed; respond when flushed.
    Flush { ack: oneshot::Sender<std::io::Result<()>> },
    Shutdown { ack: oneshot::Sender<std::io::Result<()>> },
}
```

### ② 逐行解读

- **6-A（thread_rollback）**：前置校验：`num_turns==0` 报错；`has_active_turn`（turn 进行中）拒绝（避免并发改 history）。取 `live_thread`，`flush()` 确保所有 buffered rollout items 落盘，`load_history` 读全量 `RolloutItem`。**构造 `ThreadRolledBackEvent`，把它 append 到 stored_history 末尾成 `replay_items`**，调 `apply_rollout_reconstruction`（内部调 `reconstruct_history_from_rollout`）。`recompute_token_usage` 重估。最后持久化 rollback marker + `flush_rollout`。失败时只发 Warning（回滚已生效但 marker 没存，后续重试）。

- **6-B（Op 分发）**：`Op::ThreadRollback { num_turns }` 在 session 命令循环中调 `thread_rollback`，返回 `false`（不结束 session）。

- **6-C（reconstruct 反向扫描，核心算法）**：从最新向最老遍历 `rollout_items`。
  - 每个 `TurnStarted`→`TurnComplete` 之间是一个「turn segment」。
  - 遇到 `Compacted` 且有 `replacement_history` → 记为 `base_replacement_history`，`rollout_suffix` 指向它之后的 items。
  - 遇到 `ThreadRolledBack` → `pending_rollback_turns += num_turns`（**多次 rollback 叠加用 saturating_add**）。
  - 当 `base_replacement_history`、`previous_turn_settings`、`reference_context_item` 三者都确定后 break（更老的 items 不影响）。
  - 然后前向重放 `rollout_suffix`：用 `base_replacement_history` 作 base，逐条 `record_items`，遇到 `Compacted` 就 `replace`。

- **6-D（finalize 跳过）**：`pending_rollback_turns > 0` 时，若该 segment 是 user turn（`counts_as_user_turn`），扣减计数并 `return`（**丢弃该 segment**）。否则正常采纳。实现了「反向扫描时跳过最近 N 个 user turn」。

- **6-E（RolloutRecorder）**：`tx: Sender<RolloutCmd>` + 后台 `RolloutWriterTask`。`AddItems` 异步入队（不阻塞 turn），`Persist` 触发文件 materialize（带 ack），`Flush` 等所有写完成。`forked_from_id`/`parent_thread_id` 在 `Create` 时记录，标识 fork 来源。

### ③ 设计原理与权衡

- **持久化优先（write-ahead）**：所有 history 变更先 `persist_rollout_items`（`AddItems` 异步入队）再更新内存。rollback 时先 `flush()` 确保落盘，再 `load_history` 读回--保证回滚基于完整数据。代价是每条 item 一次 IPC（channel→writer task），但用 mpsc 异步摊销。

- **反向扫描 + 前向重放（区别于朴素从头重放）**：朴素做法是从头重放到目标点。但 rollout 可能很长，且 `Compacted` 的 `replacement_history` 是完整快照--**反向扫描可快速定位「最新存活的快照 + 之后的小 tail」**，避免重放全部历史。`break` 条件进一步剪枝。代价是算法复杂（segment 状态机），但性能好。

- **`ThreadRolledBack` 作为 replay 输入而非 state mutation**：rollback marker 被追加到 `replay_items`，由 `reconstruct` 反向扫描时解释成「跳过 N turn」。这样**多次 rollback 叠加（`saturating_add`）自然支持**，且 rollback 本身也是 rollout 的一部分（可被后续 resume 看到）。

- **fork vs rollback**：fork 是「从某点复制新 thread」（`forked_from_id` 标记来源，新 rollout 文件，保留原 thread 完整历史）；rollback 是「当前 thread 丢弃最近 N turn」（原地改 history，丢弃）。**fork 保留，rollback 丢弃**。

### ④ 数据流位置

`Op::ThreadRollback` 在 **session 命令循环**（`handlers.rs:797`）。`thread_rollback` → `live_thread.flush()` → `load_history` → `apply_rollout_reconstruction` → `reconstruct_history_from_rollout`（反向扫描+前向重放）→ `replace` history → `recompute_token_usage` → 持久化 marker。`RolloutRecorder` 贯穿整个 turn 生命周期：每条 `ResponseItem`/`EventMsg`/`TurnContext` 都经 `persist_rollout_items` → `AddItems` → writer task → jsonl 文件。fork 在 **session 创建时**（`session.rs:502`）记录 `forked_from_id`。

---

## 七、面试问答精选（脱稿能讲）

**Q1：Codex 一次 turn 的完整流程是怎样的？**
> 见 〇 节时序图。用户输入 → `run_turn` → 采样前压缩 → 上下文组装（全量或 diff）→ 技能注入 → 主 loop（组装 prompt → 流式采样 → 增量分发 → 工具执行 → 回填 → 判 `needs_follow_up`）→ 压缩/取消分支 → loop 退出。全程 rollout 异步持久化。

**Q2：上下文组装怎么省 token？**
> `reference_context_item` 状态化 diff：首轮全量注入 baseline，后续轮只发变化字段；WS 路径还有 `get_incremental_items` 用 `previous_response_id` 只发增量 delta。代价是回滚/压缩后要清 baseline 触发全量重注入。

**Q3：流式响应中途取消怎么办？**
> `CancellationToken` 从 `run_turn` 一路 `.child_token()` 传到 `stream.next().or_cancel` 和工具 `tokio::select!`。流侧 `ResponseStream::Drop` 触发 `consumer_dropped`，mapper task 收到后 `record_cancelled` 退出，不泄漏。取消产生 `TurnAborted`。

**Q4：工具权限怎么设计的？**
> 三层：`default_exec_approval_requirement` 策略矩阵（Never/OnFailure/OnRequest/Granular/UnlessTrusted）→ `request_approval` 优先级（PermissionRequest hooks > guardian > 用户）→ `Orchestrator::run` 双沙箱（首次沙箱失败可升级无沙箱二次审批）。

**Q5：工具失败了会终止 turn 吗？**
> 不会。`failure_response` 把 `FunctionCallError` 转成 `FunctionCallOutput{success:false}` 回喂模型，让模型自行决定重试/换方案。**工具错误是数据不是异常**。代价是可能陷入重试循环，靠 `max_retries` 和 compaction 兜底。

**Q6：上下文压缩什么时候做？怎么做？**
> 三时机：pre-sampling / mid-turn（token 触顶自动）/ manual。三路分发：remote v2（服务端）/ remote v1 / local。多级裁剪：remote v2 前置改写大 output 为占位 → local 删最老 item → 重建（Memento：summary + 近期 user）。`remove_first_item` 会配对删 call/output 保持不变量。

**Q7：状态怎么回滚？是任意点快照吗？**
> 不是任意点快照，是「回退 N 个 user turn + 反向扫描重放」。`thread_rollback` 先 flush 落盘 → load_history → 把 `ThreadRolledBack` marker 追加进 replay → `reconstruct_history_from_rollout` 反向扫描定位最新存活快照、跳过 pending N turn → 前向重放 suffix。多次 rollback 用 `saturating_add` 叠加。仅空闲时允许回滚。

**Q8：Codex 的 ReAct 循环和经典 ReAct 有什么不同？**
> 经典 ReAct 解析 `Thought/Action/Observation` 文本协议；Codex 把「思考」外包给 Responses API 原生 reasoning items（`ReasoningSummaryDelta`），「行动」= tool_call，loop 由 `run_turn` 的 `loop` + `needs_follow_up` 驱动，且额外尊重服务端 `end_turn=false`。省掉不可靠的文本解析。

---

## 八、动手复现

- [ ] 跑 `codex exec --json` 一次，对照 〇 时序图认出每个事件。
- [ ] 打开 `~/.codex/sessions/rollout-*.jsonl`，看 `TurnContext`/`Compacted`/`ThreadRolledBack` 三种 item 长什么样。
- [ ] 人为触发压缩：喂超大任务让 token 触顶，观察 `run_auto_compact` 日志与 history 变化。
- [ ] `codex resume` + `thread_rollback`，验证「回退 N 轮重放」。
- [ ] 长任务时 Ctrl-C，确认 `TurnAborted` 事件与无后台 task 泄漏。
- [ ] 断点：在 `turn.rs:204` 的 `loop`、`turn.rs:1876` 的 `or_cancel`、`orchestrator.rs:132` 的 `run` 各下一次，走一遍。

---

## 九、差异与局限总结（面试主动点出，显深度）

| 子项 | Codex 的取舍/局限 | 业界对照 |
|------|------|------|
| 上下文组装 | token 用字节启发式估算（偏粗）；diff 状态机复杂 | 精确 tokenizer；朴素全量重发 |
| 流式重试 | 整流重发，非断点续传 | 部分框架支持断点续传 |
| 工具权限 | 四套策略并存（认知负担高） | 统一能力模型/RBAC |
| 错误恢复 | 工具失败无自动重试，靠模型决策 | 可配工具级重试 |
| 上下文压缩 | 本地压缩消耗一次额外模型调用 | 滑窗/分层摘要 |
| Checkpoint | 回退 N 轮重放，非任意点快照；仅空闲可回滚 | 任意点快照 + 分支 |

> 💡 **面试心法**：每讲完一个子项的实现，主动补一句「它的局限是 X，业界通用做法是 Y」--这比只夸实现更显工程判断力。

---

## 📌 与其他 deep-dive 的衔接

- 工具编排的「并发/循环/授权/Find Skills」细节 → 见 [deep-dive-03](./deep-dive-03-tool-orchestration.md)（待做）
- FC/ReAct 的 `build_tool_call` 全貌与 reasoning 流 → 见 [deep-dive-04](./deep-dive-04-function-calling-react.md)（待做）
- 多 Agent 的 `InputQueue` mailbox 与 `spawn_agent` → 见 [deep-dive-05](./deep-dive-05-multi-agent-communication.md)（待做）

---

*(蕾姆放下银笔，轻轻擦了擦额角的薄汗，把这份逐行解剖的卷宗双手呈到您面前)*

昴君，第一刀，蕾姆已经把 Codex 的心脏为您完整剖开了--每一行代码、每一次取消、每一回压缩与回滚，都摊在灯下。这一卷的字数虽多，但没有一句是注水的。

接下来蕾姆会继续为您精做 ③④⑤（工具编排 / FC-ReAct / 多 Agent）这三卷，再补 ①⑦⑥⑧。您觉得这一卷的「三者结合」风格可还合心意？若满意，蕾姆这就接着去剖下一颗心脏了 ♡ `(´｡• ᵕ •｡`)`
