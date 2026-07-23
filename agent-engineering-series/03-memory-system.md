# 03 · Memory 记忆 - Agent 的脑子

> 基础层 · 第三篇
>
> **子主题**：三层结构 · 摘要压缩 · 向量检索
>
> **Codex 覆盖**：🟡 部分（摘要压缩一流；**向量检索全无**，是 Codex 最大的能力缺口之一）

---

## ① 本篇定位

Agent 若没有记忆，每句话都像失忆症患者--前脚说完后脚忘。记忆让 ReAct（①）的每一轮观察、工具（②）的每一次结果，都能累积成上下文。

记忆分三层，像厨房的三个地方：

- **工作记忆** = 砧板--当前正在用的食材（当前 prompt 上下文）；
- **短期记忆** = 便签--这一锅菜的过程记录（会话历史）；
- **长期记忆** = 档案柜--上次做菜的经验（持久化、跨会话）。

**本篇在链路中的位置**：基础层收尾。它把 ① 的循环、② 的工具结果都「存起来」，是进阶层（规划、多 Agent）能站在肩膀上的前提。

---

## ② 业界通用原理

### 2.1 三层记忆结构

| 层 | 内容 | 生命周期 | 典型实现 |
|----|------|---------|---------|
| 工作记忆 | 当前喂给 LLM 的 prompt | 单次推理 | 系统提示 + 历史 + 工具结果拼装 |
| 短期记忆 | 本轮会话的完整历史 | 单次会话 | 消息列表，可裁剪/压缩 |
| 长期记忆 | 跨会话的知识、偏好、事实 | 永久 | 向量库 / 知识图谱 / 持久化日志 |

### 2.2 摘要压缩 - 当上下文要爆

会话越长，短期记忆越胖，迟早撞 token 上限。业界两种策略：

- **截断**：丢掉最旧的消息（粗暴，丢信息）；
- **摘要压缩**：用 LLM 把旧历史「总结成一段摘要」，保留要点（聪明，但多花一次模型调用）。

工业级做法是**多级裁剪**：先截断 function output（工具输出最占地方）-> 再移除整条历史 -> 最后触发整体摘要。

### 2.3 向量检索 - 长期记忆怎么召回

长期记忆不能全灌进 prompt（会爆），得**按需召回**：

```text
用户问 -> embedding(query) -> 向量库 top-k 相似 -> rerank 精排 -> 拼进 prompt
```

四件套：**embedding 模型 + 向量库（pgvector/Qdrant/Milvus）+ rerank + chunk 策略**。这是 RAG 的基石，也是 Agent 长期记忆的标配。

> 💡 **心法**：工作记忆管「现在」，短期记忆管「这次」，长期记忆管「一直」。前两层 Codex 做得很好，第三层--它没做。

---

## ③ Codex 源码映射

### 3.1 工作记忆 - 组装当前 prompt

```rust
// codex-rs/core/src/context_manager/history.rs:111
pub(crate) fn for_prompt(mut self, input_modalities: &[InputModality]) -> Vec<ResponseItem> {
    self.normalize_history(input_modalities);   // 去掉不适合的 item；不带图时剥离图片
    self.items
}
```

```rust
// codex-rs/core/src/session/turn.rs:1001
pub(crate) fn build_prompt(...) { ... }
// codex-rs/core/src/session/mod.rs:2871
pub(crate) async fn build_initial_context(...) { ... }
```

读法：`for_prompt`（`:111`）把历史 `normalize` 后交给 `build_prompt`（`turn.rs:1001`）。`normalize` 会丢掉不适合发送的 item、在不支持图像时剥离图片。`build_initial_context`（`mod.rs:2871`）负责初始上下文构建。

> **增量注入**：Codex 用 `reference_context_item` 做 **diff 增量注入**，而非每次全量重发历史（详见 ⑧ 延迟篇的缓存策略）。

### 3.2 短期记忆 - 会话历史与会话级回退

会话历史存在 `context_manager` 里，`history.rs` 提供 normalize / record / 回退：

```rust
// codex-rs/core/src/context_manager/history.rs:224
pub(crate) fn drop_last_n_user_turns(&mut self, num_turns: u32) { ... }
//   ↑ 丢弃最近 N 轮用户消息（回退用）
```

token 估算用**字节启发式**（不是 tokenizer 精确计数）：

```rust
// codex-rs/core/src/context_manager/history.rs:132
// Estimate token usage using byte-based heuristics from the truncation helpers.
// This is a coarse lower bound, not a tokenizer-accurate count.
pub(crate) fn estimate_token_count(&self, turn_context: &TurnContext) -> Option<i64> { ... }
```

> ⚠️ 注释自承「coarse lower bound, not a tokenizer-accurate count」--字节估算（约 4 字节/token）偏粗，可能低估。

### 3.3 长期记忆 - 持久化与回放（但非语义召回）

Codex 的「长期记忆」是**追加式日志 + 回放**，不是向量库：

```rust
// codex-rs/rollout/src/recorder.rs:75
pub struct RolloutRecorder { ... }   // append-only JSONL 日志

// codex-rs/core/src/session/handlers.rs:450
pub async fn thread_rollback(sess: &Arc<Session>, sub_id: String, num_turns: u32) { ... }
//   ↑ 回退 N 轮

// codex-rs/core/src/session/rollout_reconstruction.rs:94
pub(super) async fn reconstruct_history_from_rollout(...) { ... }
//   ↑ 从 rollout 日志重建历史（resume / fork 用）
```

读法：`RolloutRecorder`（`recorder.rs:75`）把每一步追加到 JSONL；`thread_rollback`（`handlers.rs:450`）能回退 N 轮；`reconstruct_history_from_rollout`（`rollout_reconstruction.rs:94`）能从日志重建历史以支持 resume/fork。

> ⚠️ **这是「会话回放」不是「语义记忆」**：它能恢复「上次说到哪」，但不能回答「我半年前问过类似的吗」。且回滚**只在空闲时允许**，非任意点快照。

### 3.4 摘要压缩 - 多级裁剪（Codex 的强项）

Codex 的压缩分**本地内联**与**远程**两路，按 provider 能力分流：

```rust
// codex-rs/core/src/compact.rs:68
pub(crate) fn should_use_remote_compact_task(provider: &ModelProviderInfo) -> bool {
    provider.supports_remote_compaction()   // provider 支持就走远程压缩
}

// codex-rs/core/src/compact.rs:72
pub(crate) async fn run_inline_auto_compact_task(...) -> CodexResult<()> {
    let prompt = turn_context.compact_prompt().to_string();  // 构造压缩 prompt
    let input = vec![UserInput::Text { text: prompt, ... }];
    run_compact_task_inner(..., CompactionTrigger::Auto, ...).await?  // :86
}

// codex-rs/core/src/compact.rs:125
async fn run_compact_task_inner(...) { ... }   // 核心实现

// codex-rs/core/src/compact.rs:261
history.remove_first_item();   // 多级裁剪中「移除最旧条目」
```

压缩的触发点嵌在主循环里（接 ① ReAct 篇）：

```rust
// codex-rs/core/src/session/turn.rs:783
async fn run_pre_sampling_compact(...) { ... }   // 采样前预压缩
// codex-rs/core/src/session/turn.rs:891
async fn run_auto_compact(...) { ... }            // 采样后 token 触顶时压缩
```

**多级裁剪顺序**（来自 `compact.rs` 与 `compact_remote_v2.rs`）：
1. 截断 function output（工具输出最占地方）；
2. `remove_first_item`（`:261`）移除最旧条目；
3. 触发整体摘要压缩（本地 `run_inline_auto_compact_task` 或远程 v2）。

> ✅ 这是教科书级的多级裁剪：先丢最该丢的（大块工具输出），再丢旧条目，最后才摘要。比无脑截断聪明得多。

---

### 3.5 向量检索 - 🔴 Codex 全无（最大缺口）

这是 Codex Memory 的硬伤。蕾姆实地核查的结论：

| 子项 | 业界做法 | Codex 实际 | 证据 |
|------|---------|-----------|------|
| embedding | 用模型把文本转向量 | 🔴 无 | 全仓 grep `embedding` 仅 2 处无关英文注释 |
| 向量库 | pgvector / Qdrant / Milvus / Chroma / Pinecone | 🔴 0 命中 | 全仓 0 命中 |
| rerank | cross-encoder 重排 | 🔴 0 命中 | `rerank`/`cross_encoder` 全仓 0 命中 |
| chunk 策略 | token/语义/滑窗/父子块切分 | 🔴 无 | `chunk` 命中均为命令输出截断、流式 delta、测试 fixture |
| query rewrite | hyde / multi-query / 子查询分解 | 🔴 0 命中 | `hyde`/`query_rewrite` 全仓 0 命中 |

Codex 现有的「类似检索」其实是**伪检索**：

- `file-search` crate 用 `nucleo` **模糊匹配文件路径名**（不是内容语义检索）；
- `memories` 用 `read_dir` **全量读取** memory 文件夹（不是向量召回）。

> 📌 **结论**：Codex 的记忆是「**会话级压缩 + 日志回放**」，没有「**跨会话语义召回**」。要做 RAG 式长期记忆，必须另起炉灶。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| 三层结构 | 工作记忆 + 会话历史 + rollout 日志 | ✅ 前 two 层完整；长期层只是日志，非语义记忆 |
| 摘要压缩 | 本地 + 远程分流，多级裁剪 | ✅ 教科书级；❌ 压缩本身也烧一次模型调用 |
| token 估算 | 字节启发式（4 字节/token） | ❌ 偏粗，可能低估导致压缩触发滞后 |
| 长期记忆 | append-only 日志 + 回放 | ✅ 支持 resume/fork/回退；❌ 不能语义召回 |
| 向量检索 | 🔴 完全没有 | ❌ 无法做 RAG、无法跨会语义召回 |
| 回滚粒度 | 回退 N 轮重放，非任意点快照 | 仅空闲时允许，非事务级 |

> **面试金句**：Codex 的 Memory 是「**压缩一流、检索为零**」。它的强项是会话内的多级裁剪摘要（`compact.rs`），硬伤是没有任何向量检索能力（embedding/向量库/rerank/chunk/rewrite 全无）。长期记忆只是 rollout 日志的回放，不是语义召回。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| 上下文管理、历史裁剪、压缩的通识课 | [`../learning-notes/lesson-05-context.md`](../learning-notes/lesson-05-context.md) |
| 状态持久化与历史管理（rollout/thread） | [`../learning-notes/lesson-10-state-history.md`](../learning-notes/lesson-10-state-history.md) |
| RAG 全链路缺口（向量检索怎么补） | [`../interview-prep/06-rag-pipeline.md`](../interview-prep/06-rag-pipeline.md) |
| Codex 教不了的能力清单 | [`../interview-prep/GAPS-codex-cannot-teach.md`](../interview-prep/GAPS-codex-cannot-teach.md) |
| 压缩如何在主循环里被触发 | 本卷 [01 ReAct 框架](./01-react-framework.md) 的 3.4 节 |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「Agent 的记忆怎么设计？怎么避免上下文爆炸？」

1. **业界原理**：三层结构（工作/短期/长期），短期靠摘要压缩防爆（多级裁剪：截断工具输出 -> 移除旧条目 -> 整体摘要），长期靠向量检索按需召回（embedding + 向量库 + rerank + chunk）。长期记忆是 RAG 的基石。
2. **Codex 实现**：工作记忆 `history.rs:111` `for_prompt`（normalize 后组装）；会话历史带 `drop_last_n_user_turns`（`:224`）回退；长期是 `rollout/recorder.rs:75` `RolloutRecorder` append-only 日志 + `handlers.rs:450` `thread_rollback` 回退 N 轮 + `rollout_reconstruction.rs:94` 重建历史；压缩走 `compact.rs:68` 分流本地/远程，`run_inline_auto_compact_task`（`:72`）多级裁剪（`:261` `remove_first_item`），嵌在主循环 `turn.rs:783` 预压缩 / `:891` 触顶压缩。
3. **取舍局限**：压缩一流但 token 估算偏粗（字节启发式，`history.rs:132`）；**向量检索全无**（embedding/向量库/rerank/chunk/rewrite 全 0 命中），长期记忆只是日志回放不能语义召回，做 RAG 必须另起炉灶。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `compact.rs` 里读 `run_compact_task_inner`（`:125`），找出多级裁剪的确切顺序：先截断什么、再移除什么、最后才摘要？
2. 对比 `run_inline_auto_compact_task`（`:72`）和远程压缩（`should_use_remote_compact_task` `:68`），思考为什么按 provider 能力分流。
3. 全仓 grep `embedding|pgvector|qdrant|milvus`，亲自确认向量检索的缺口（预期：0 命中或仅注释）。
4. 看 `file-search` crate（`file-search/src/lib.rs`），确认它用的是 `nucleo` 模糊匹配文件名，而非向量检索内容。

### 自测题
1. Codex 的三层记忆里，哪一层最完整？哪一层是「伪记忆」（只是日志）？
2. `for_prompt`（`history.rs:111`）里的 `normalize_history` 做了哪两件事？
3. 多级裁剪为什么先截断 function output，而不是先移除旧消息？
4. `thread_rollback`（`handlers.rs:450`）回退 N 轮和「任意点快照」有什么区别？为什么 Codex 只在空闲时允许回滚？
5. 如果要给 Codex 加上真正的长期记忆（向量检索），至少要补哪四个组件？各自对应业界什么技术？

---

## ⑧ 小结

> Memory 是 Agent 的脑子：工作记忆（`for_prompt`）管当下，
> 会话历史管这次，rollout 日志（`recorder.rs:75`）管回放。
> 压缩靠多级裁剪（`compact.rs`）防爆，一流；
> 但向量检索全无，跨会语义召回--Codex 教不了你，得自己造。

---

*下一站 -> [04 Planning 规划](./04-planning.md)：记忆有了，但复杂任务怎么拆、怎么并行、做错了怎么重规划？基础层结束，进入进阶层。*
