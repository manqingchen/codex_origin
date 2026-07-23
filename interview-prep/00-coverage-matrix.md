# 00 · 覆盖度矩阵（Codex 源码 vs 面试考点）

> 本文件是「查表用」的深度参考：把面试每个考点的每个**子项**，逐一对应到 Codex 仓库里**真实存在的文件与函数**，并给出覆盖判定。所有 `file:line` 均来自对 `/Users/xxxxx/Documents/pang/codex_origin/codex-rs/` 的实际源码核查。
>
> 判定图例：🟢 有 · 🟡 部分 · 🔴 无

---

## 考点 ② Agent Loop 运行时（6 子项）🟢 全覆盖

| 子项 | 判定 | 关键文件:行 | 实现深度 / 备注 |
|------|:---:|------|------|
| 上下文组装 | 🟢 | `core/src/session/turn.rs:1001` `build_prompt`<br>`core/src/session/mod.rs:2871` `build_initial_context`<br>`core/src/context_manager/history.rs:111` `for_prompt`/`normalize_history`<br>`core/src/tools/router.rs` `model_visible_specs` | 分层完整；`reference_context_item` diff 增量注入（非全量重发）；token 估算用字节启发式（4 字节/token，偏粗） |
| 流式调用 | 🟢 | `core/src/client.rs:1203` `stream_responses_api`<br>`core/src/client.rs:1321` `stream_responses_websocket`<br>`core/src/client.rs:1264` `map_response_stream`<br>`core/src/client_common.rs:108` `ResponseStream` | SSE + WebSocket 双传输；WS 增量 payload 复用（前缀缓存）；逐项增量 emit 给 UI |
| 工具执行 + 权限 | 🟢 | `core/src/tools/orchestrator.rs:132` `run`（三态审批门）<br>`core/src/tools/router.rs:170` `dispatch_tool_call_with_terminal_outcome`<br>`core/src/exec_policy.rs` + `execpolicy/`（`Policy`/`PolicyParser`/`Decision`）<br>`core/src/exec.rs:307` `process_exec_tool_call` → `sandboxing::execute_env` | router → orchestrator 审批 → sandbox + execpolicy 三层；四套权限策略并存（认知负担高） |
| 错误恢复 | 🟢 | `core/src/responses_retry.rs:22` `handle_retryable_response_stream_error`<br>`core/src/session/turn.rs:1059` 重试 loop / `:1103` `is_retryable` / `:1089` `ContextWindowExceeded`<br>`core/src/client.rs:1272` 401 恢复循环<br>`core/src/tools/registry.rs:455` `FunctionCallError::RespondToModel`/`Fatal` | 指数 backoff + WS→HTTPS 传输降级 + 401 重授权 + CancellationToken；重试粒度是整流重发（非断点续传） |
| 上下文压缩 | 🟢 | `core/src/compact.rs:72` `run_inline_auto_compact_task` / `:196` `run_compact_task_inner_impl` / `:255` `remove_first_item`<br>`core/src/compact_remote_v2.rs:56` `run_inline_remote_auto_compact_task` / `:201` `trim_function_call_history_to_fit_context_window`<br>`core/src/session/turn.rs:151` `run_pre_sampling_compact` / `:303` `run_auto_compact` | 本地 summarization 压缩 + 远程 v1/v2 按 provider 能力分流；多级裁剪（function output 截断 → 移除条目 → 触发 compact） |
| Checkpoint 回滚 | 🟢 | `core/src/session/handlers.rs:450` `thread_rollback(num_turns)`<br>`core/src/session/rollout_reconstruction.rs` `reconstruct_history_from_rollout`<br>`core/src/context_manager/history.rs:224` `drop_last_n_user_turns`<br>`rollout/src/recorder.rs:75` `RolloutRecorder`（append-only JSONL） | rollout 追加日志 + 回退 N 轮重放；支持 fork/resume；**非任意点快照**，仅空闲时允许回滚 |

---

## 考点 ③ 工具编排（3 子项）🟢 强（循环检测部分）

| 子项 | 判定 | 关键文件:行 | 备注 |
|------|:---:|------|------|
| 并行调用 | 🟢 | `core/src/session/turn.rs:1842` `FuturesOrdered` 收集 tool_future<br>`core/src/session/turn.rs:1769` `drain_in_flight`<br>`core/src/tools/parallel.rs:113` `handle_tool_call_with_source`（`tokio::spawn`）<br>`core/src/tools/parallel.rs:88` `supports_parallel`（RwLock 读写锁降级串行） | 真并发执行 + 按序回填；普通 tool_call 无并发上限（无 semaphore） |
| 循环检测 | 🟡 | `core/src/guardian/review.rs:580` `guardian_rejection_circuit_breaker`<br>`core/src/guardian/tests.rs:87`（连续 3 次拒绝熔断）<br>`core/src/session/turn.rs:301-320`（token 触顶触发 auto_compact 兜底） | **无通用"同工具反复调用"去重**；仅 guardian 熔断 + token 预算兜底，注释承认是乐观假设 |
| 动态授权 | 🟢 | `core/src/tools/orchestrator.rs:132` `run` / `:487-549` `PermissionRequest` hooks<br>`core/src/tools/sandboxing.rs:70` `with_cached_approval`<br>`core/src/mcp_tool_call.rs:1855-1863` `ApprovedForSession` 会话级缓存 | 会话级"批准一次后续免提示" + 沙箱拒绝升级重试 + hooks 可脚本化授权；无风险分级 |

---

## 考点 ③ 续 · 渐进式技能加载 Find Skills 🟢 亮点（双层，同属 JD 第 3 条）

| 子项 | 判定 | 关键文件:行 | 备注 |
|------|:---:|------|------|
| 技能发现 | 🟢 | `core-skills/src/loader.rs:488` `discover_skills_under_root`（BFS 扫 `SKILL.md`，受 `MAX_SCAN_DEPTH`/`MAX_SKILLS_DIRS_PER_ROOT` 限制）<br>`core-skills/src/loader.rs:163` `load_skills_from_roots` | 启动全量扫描发现；app-server 有 `skills_watcher.rs` 做文件监听补足增量 |
| 摘要常驻 + 预算保护 | 🟢 | `core-skills/src/render.rs:62` `render_available_skills_body`（只渲染 name+description+locator）<br>`core/src/context/available_skills_instructions.rs:10` | **只注入摘要目录，不灌全文**；2% context budget 保护，超预算截断 |
| 技能内容按需加载 | 🟢 | `core-skills/src/injection.rs:58` `build_skill_injections`（被 mention 才 `read_file_text(SKILL.md)` 读全文）<br>`core-skills/src/injection.rs:144` `collect_explicit_skill_mentions`（`$SkillName` mention + `UserInput::Skill`）<br>`ext/skills/src/tools/list.rs`、`read.rs`（`skills.list`/`skills.read` MCP 工具） | progressive disclosure 设计意图明确；无语义向量检索技能（仅显式 mention + 模型自选） |
| 工具级 Find Skills（BM25） | 🟢 | `core/src/tools/handlers/tool_search.rs:69` `ToolSearchHandler`（BM25 搜索）<br>`core/src/tools/spec_plan.rs:839-859` `append_tool_search_executor`（`ToolExposure::Deferred` → search entries）<br>`core/src/tools/spec_plan.rs:457`（Deferred 工具不进 `prompt.tools`） | `defer_loading:true` 的工具不进 prompt，经 `tool_search` 检索后暴露 `LoadableToolSpec` |

---

## 考点 ④ Function Calling / Tool Use / ReAct 🟢 强

| 子项 | 判定 | 关键文件:行 | 备注 |
|------|:---:|------|------|
| Tool schema 定义注入 | 🟢 | `tools/src/tool_spec.rs:17` `enum ToolSpec`（Function/Namespace/ToolSearch/ImageGen/WebSearch/Freeform）<br>`tools/src/responses_api.rs:26` `ResponsesApiTool`（name/desc/strict/defer_loading/parameters:JsonSchema）<br>`core/src/client.rs:732` `create_tools_json_for_responses_api` | strict=true 校验标 TODO 未实现（`responses_api.rs:29`） |
| tool_calls 解析/分发/回填 | 🟢 | `core/src/tools/router.rs:96` `build_tool_call`<br>`core/src/tools/router.rs:170` `dispatch_tool_call_with_terminal_outcome`<br>`core/src/session/turn.rs:1774` `drain_in_flight` → `record_conversation_items`<br>`core/src/tools/parallel.rs:186` `failure_response` | 完整闭环：流式 tool_call → 解析 → spawn 执行 → 结果回填（含成功/失败/中止三种 payload） |
| ReAct 落地 | 🟡 | `core/src/session/turn.rs:204` `run_turn` 主 `loop`<br>`core/src/session/turn.rs:322` `needs_follow_up` 决定继续/终止<br>`core/src/session/turn.rs:2182` `ReasoningSummaryDelta` | **走 OpenAI Responses API 原生 reasoning**，非自研 Thought/Action/Observation 文本协议；本地不做 ReAct prompt 工程 |

---

## 考点 ⑤ 多 Agent 通信（Mailbox / 类 A2A）🟢 真进程内邮箱

| 子项 | 判定 | 关键文件:行 | 备注 |
|------|:---:|------|------|
| Mailbox 消息投递 | 🟢 | `core/src/session/input_queue.rs:29` `InputQueue`（`mailbox_pending_mails: VecDeque<InterAgentCommunication>` + `tokio::watch`）<br>`protocol/src/protocol.rs:677` `InterAgentCommunication { author, recipient, other_recipients, content, encrypted_content, trigger_turn }`<br>`core/src/agent/control.rs:166` `send_inter_agent_communication` | 进程内 channel；支持 trigger_turn 立即唤醒（followup_task）或入队等下轮（send_message）；支持多播 + 加密 |
| 消息工具入口 | 🟢 | `core/src/tools/handlers/multi_agents_v2/message_tool.rs:59` `handle_message_string_tool` | `send_message` / `followup_task` 统一入口 |
| Agent 派生与拓扑 | 🟢 | `core/src/agent/control/spawn.rs:103` `spawn_agent_with_metadata`（父子 spawn 边）<br>`core/src/agent/control/spawn.rs:232` `reserve_spawn_slot`（并发/深度限制）<br>`core/src/agent/control.rs:268` `resolve_agent_reference`（按 AgentPath 解析任意活跃 agent） | 真"对等消息"（可发兄弟/祖先），但拓扑以层级 spawn 树为主干 |
| Agent 身份与加密 | 🟢 | `agent-identity/src/lib.rs`（ed25519 私钥 + JWT/JWKS + curve25519 消息加密）<br>`protocol/src/agent_path.rs:15` `AgentPath`（`/root/...` 层级路径） | 身份层完整；为跨 agent 加密消息提供密码学基础 |
| spawn 拓扑持久化 | 🟢 | `agent-graph-store/src/store.rs:10`（`upsert_thread_spawn_edge` / BFS `list_thread_spawn_descendants`，SQLite） | 边带 Open/Closed 生命周期 |
| ⚠️ 跨网络 A2A | 🔴 | — | **非跨进程/跨网络协议**；所有 agent 必须在同一 `ThreadManager` 进程内；无独立消息总线/服务发现 |
| external-agent-* 是什么 | ℹ️ | `external-agent-sessions/src/lib.rs`（导入别的 CLI 会话历史）<br>`external-agent-migration/src/lib.rs`（Claude Code 配置迁移到 Codex） | **与运行时通信无关**，是导入/迁移工具 |

---

## 考点 ⑦ 多模型集成 🟡 单协议（OpenAI Responses API）

| 子项 | 判定 | 关键文件:行 | 备注 |
|------|:---:|------|------|
| Provider 抽象 | 🟢 | `model-provider/src/provider.rs:99` `trait ModelProvider`<br>`model-provider/src/provider.rs:188` `create_model_provider`（Bedrock 走专用，其余通用）<br>`model-provider-info/src/lib.rs:85` `ModelProviderInfo` | 抽象清晰，但 **`WireApi` 仅 `Responses` 一值**，`chat` 已废弃报错（`model-provider-info/src/lib.rs:46-48`） |
| 内置后端 | 🟢 | `model-provider-info/src/lib.rs:415` `built_in_model_providers`（openai/amazon-bedrock/ollama/lmstudio）<br>`model-provider-info/src/lib.rs:481` `create_oss_provider`<br>`model-provider-info/src/lib.rs:448` `merge_configured_model_providers`（用户 config 扩展） | 内置 4 个；用户可在 `config.toml` 加任意 OpenAI 兼容后端 |
| 模型目录管理 | 🟢 | `models-manager/src/manager.rs:79` `trait ModelsManager`（`list_models` + 刷新策略）<br>`models-manager/src/manager.rs:33` `ModelsEndpointClient`（远程 `/models` + ETag 缓存）<br>`models-manager/src/cache.rs`（`models_cache.json`，TTL 300s） | Bedrock 用静态 catalog；OpenAI 兼容用远程拉取 |
| 本地模型 | 🟢 | `ollama/src/lib.rs:23` `ensure_oss_ready` / `:63` `ensure_responses_supported`（≥0.13.4 支持 Responses）<br>`lmstudio/src/lib.rs:13` `ensure_oss_ready`<br>`core/src/config/mod.rs:2315` `resolve_oss_provider` | ollama/lmstudio 一等公民，有健康检查/模型拉取 |
| ⚠️ 原生 Claude/Gemini | 🔴 | — | **未内置**；全仓 grep 无命中；只能靠其 OpenAI 兼容 endpoint 间接接入，原生 Messages/Gemini API 不支持 |

---

## 考点 ⑥ RAG 全链路 🔴 全无（Codex 最大缺口）

| 子项 | 判定 | 证据 | 备注 |
|------|:---:|------|------|
| 向量检索 | 🔴 | `file-search/src/cli.rs:7`（Fuzzy matches filenames）<br>`file-search/src/lib.rs:9-15`（用 `nucleo` 模糊匹配**文件路径名**，非向量）<br>`memories/write/src/control.rs:32`、`storage.rs:82`（`read_dir` 全量读 memory 文件夹） | pgvector/qdrant/milvus/chromadb/pinecone **0 命中**；embedding 仅 2 处无关英文注释 |
| Rerank | 🔴 | `rerank`/`cross-encoder`/`re_rank` 全仓 **0 命中** | 唯一 "rank" 是 `state/src/runtime/memories.rs:418` 的 `usage_count DESC`，非相关性重排 |
| Chunk 策略 | 🔴 | `chunk` 命中均为命令输出截断（`tools/context.rs:310` `chunk_id`、`apply_patch.rs:173`）、流式 delta、测试 fixture | 无 token/语义/滑窗/父子块等任何文档切分策略 |
| Query Rewrite | 🔴 | `hyde`/`query_rewrite`/`query expansion`/`multi query` 全仓 **0 命中** | 无查询改写/扩展/子查询分解 |

> 📌 **RAG 缺口详见 [`GAPS-codex-cannot-teach.md`](./GAPS-codex-cannot-teach.md) 与 [`06-rag-pipeline.md`](./06-rag-pipeline.md)**——这一整块必须靠外部资料 + 动手实验补齐。

---

## 考点 ① 框架实战 / ⑧ 开源项目

| 子项 | 判定 | 说明 |
|------|:---:|------|
| ① 自研编排 | 🟢 | Codex 本体即自研编排工业范例；另有 `workflow-orchestrator-poc/`（Guazi Workflow 混合编排器 POC，shell + gate） |
| ① LangGraph | 🔴 | Codex 未使用；需独立学习，见 [`01-agent-framework.md`](./01-agent-framework.md) |
| ① LlamaIndex | 🔴 | Codex 未使用；需独立学习 |
| ⑧ 自有开源项目 | 🔴 | Codex 是别人（OpenAI）的项目；候选人需自建，见 [`08-open-source-project.md`](./08-open-source-project.md) |

---

## 📊 总统计

| 维度 | 数量 |
|------|------|
| 面试考点总数 | 8（+ RAG 4 子项） |
| Codex 🟢 强覆盖 | 5 个考点（①②③④⑤） |
| Codex 🟡 部分覆盖 | 1 个考点（⑦ 多模型，单协议） |
| Codex 🔴 无覆盖 | 2 个考点（⑥ RAG、⑧ 自有项目）+ LangGraph/LlamaIndex + 跨网络 A2A + 原生 Claude/Gemini + 通用循环去重 + 自研 ReAct 文本协议 |

> 💡 这张表说明：**Codex 是「自研编排 Agent Loop + 工具 + 多 Agent 通信」的最佳教科书，但「RAG + 多协议多模型 + 框架生态 + 自有产出」需要另谋出路。**
