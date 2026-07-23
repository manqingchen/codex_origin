# 08 · 延迟成本 - Agent 的运营能力

> 保障层 · 第三篇（系列收官）
>
> **子主题**：模型路由 · 缓存策略 · 流式输出
>
> **Codex 覆盖**：🟢 强（路由 + 前缀缓存 + 双传输流式，齐全）

---

## ① 本篇定位

Agent 能跑、能规划、能协作、能安全--但若每次回答要等 30 秒、每次调用都烧 1 块钱，用户照样跑光。**延迟与成本**是 Agent 的运营能力，决定它能不能从「能演示」走向「能用」。

三个环节对应厨房的运营：

- **模型路由** = 派单--简单的菜让学徒做（小模型），复杂的菜让大厨做（大模型）；
- **缓存策略** = 备菜--常点的菜提前备好，别每次从头切；
- **流式输出** = 边做边端--菜别等全做好再上，做一道端一道，让客人先吃着。

**本篇在链路中的位置**：保障层收尾，也是八篇的**收官**。它与 ⑥ 评估形成闭环--评估量化好坏，延迟成本量化贵慢，两者共同回答「这个 Agent 值得上生产吗」。

---

## ② 业界通用原理

### 2.1 模型路由 - 按任务选模型

不同任务难度不同，全用大模型浪费、全用小模型质量差。路由策略：

| 策略 | 做法 |
|------|------|
| 难度路由 | 简单任务走小模型，复杂走大模型（需难度判定器） |
| 成本路由 | 按 $/token 预算选最便宜的可达模型 |
| 能力路由 | 按任务需要的能力（工具调用/视觉/长上下文）选 |
| 回退路由 | 主模型失败/超时，回退到备选 |

实现要点：provider 抽象层（`trait`）屏蔽差异，上层只管「我要一个能 tool use 的模型」。

### 2.2 缓存策略 - 别重复算

缓存是降本提速的利器，多层叠加：

| 缓存层 | 缓存什么 |
|--------|---------|
| prompt cache | 前缀相同的请求，provider 侧复用 KV cache |
| 前缀/增量 | 不全量重发历史，只发 diff |
| 目录缓存 | 模型列表等元数据，带 TTL |
| 结果缓存 | 相同输入的确定性结果（如工具输出） |

> 💡 **心法**：Agent 的上下文每轮都在长，若每次都全量重发历史，成本会平方级增长。**增量注入 + 前缀缓存**是 Agent 成本控制的命门。

### 2.3 流式输出 - 边生成边显示

LLM 生成是逐 token 的，等全部生成完再返回，首字节时延（TTFT）会很高。流式把生成过程**逐块**推给用户：

- **SSE**（Server-Sent Events）：单向流，HTTP 长连接；
- **WebSocket**：双向，支持更精细的增量交互；
- **事件映射**：把模型的原始流 delta 转成 UI 能渲染的事件。

> 🔑 流式不只是「好看」，更是「能用」--首字几秒出来，用户体感快十倍，还能中途取消省 token。

---

## ③ Codex 源码映射

### 3.1 模型路由 - `ModelProvider` 抽象 + 内置多后端

```rust
// codex-rs/model-provider/src/provider.rs:99
pub trait ModelProvider: fmt::Debug + Send + Sync {
    fn info(&self) -> &ModelProviderInfo;             // provider 元数据
    fn capabilities(&self) -> ProviderCapabilities;   // 能力上界
    fn approval_review_preferred_model(&self) -> &'static str { ... }   // 审批审查首选模型
    fn memory_extraction_preferred_model(&self) -> &'static str { ... } // memory 提取首选
    fn memory_consolidation_preferred_model(&self) -> &'static str { ... } // memory 合并首选
    fn supports_attestation(&self) -> bool { ... }
    // ...
}

// codex-rs/model-provider/src/provider.rs:188
pub fn create_model_provider(...) { ... }   // 工厂：按配置创建 provider
```

读法：`ModelProvider` trait（`:99`）抽象所有 provider，`create_model_provider`（`:188`）是工厂。内置四后端：**OpenAI / Amazon Bedrock / Ollama / LMStudio**。用户还能在 `config.toml` 加任意 OpenAI 兼容后端。

**OSS 一等公民**：

```rust
// codex-rs/core/src/config/mod.rs:2315
pub fn resolve_oss_provider(...) { ... }   // 解析 ollama/lmstudio 本地模型
```

读法：`resolve_oss_provider`（`config/mod.rs:2315`）让 ollama/lmstudio 成为一等公民（有健康检查、模型拉取）。

> ⚠️ **局限**：`WireApi` **仅 `Responses` 一值**（`chat` 已废弃报错）--所有 provider 都被映射到 OpenAI Responses API 协议。**无原生 Claude/Gemini**，只能靠其 OpenAI 兼容 endpoint 间接接入。

### 3.2 流式输出 - SSE + WebSocket 双传输

```rust
// codex-rs/core/src/client.rs:1203
async fn stream_responses_api(...) -> Result<ResponseStream> {
    let auth_manager = self.client.state.provider.auth_manager();        // :1214
    let mut auth_recovery = auth_manager.as_ref().map(AuthManager::unauthorized_recovery); // :1215
    let mut pending_retry = PendingUnauthorizedRetry::default();        // :1218
    loop {                                                               // :1219 401 恢复循环
        let client_setup = self.client.current_client_setup().await?;
        let transport = ReqwestTransport::new(build_reqwest_client());  // :1221 HTTP 传输
        let (request_telemetry, sse_telemetry) = Self::build_streaming_telemetry(...); // :1227 SSE 遥测
        let compression = self.responses_request_compression(...);      // :1233 请求压缩
        let request = self.client.build_responses_request(...);
        // ... 发请求、收 SSE 流 ...
    }
}

// codex-rs/core/src/client.rs:1321
async fn stream_responses_websocket(...) { ... }   // WebSocket 传输（增量 payload 复用）

// codex-rs/core/src/client.rs:1684
fn map_response_stream(...) { ... }   // 把原始流 delta 映射成 Codex 事件

// codex-rs/core/src/client_common.rs:108
pub struct ResponseStream { ... }      // 流类型
```

读法：两套传输--
- `stream_responses_api`（`:1203`）走 **SSE**（HTTP 长连接），内含 **401 认证恢复循环**（`:1215-1219`，token 过期自动重授权重试）；
- `stream_responses_websocket`（`:1321`）走 **WebSocket**（双向，增量 payload 复用前缀）；
- `map_response_stream`（`:1684`）把原始流 delta 转成 Codex 内部事件（驱动 UI 渲染）；
- `ResponseStream`（`client_common.rs:108`）是统一流类型。

> 🔑 **双传输 + 降级**：WS 优先（增量复用更省），失败时降级到 HTTPS（接 ① `responses_retry.rs:32` `try_switch_fallback_transport`）。

### 3.3 缓存策略 - 三层叠加

| 层 | 缓存什么 | 源码 |
|----|---------|------|
| 前缀复用（WS） | WebSocket 增量 payload 复用前缀 | `client.rs:1321` `stream_responses_websocket` |
| 增量注入 | 历史不全量重发，只发 diff | `reference_context_item`（diff 增量注入，见 ③ Memory 篇） |
| 模型目录缓存 | `/models` 远程列表 + TTL | `models-manager/src/cache.rs`（`cache.rs:18/59`，TTL） |
| prompt cache | 前缀复用 provider 侧 KV cache | OpenAI prompt caching（compression `:1233` 配合） |

读法：模型目录缓存（`cache.rs`）带 TTL，避免每次都远程拉 `/models`；`reference_context_item` 做增量注入，不全量重发历史（这是 Agent 成本控制命门）；WS 传输本身复用前缀 payload。多层叠加把成本压下来。

> ⚠️ 配合 ③ Memory 篇的局限：token 估算用**字节启发式**（`history.rs:132`，偏粗），可能影响缓存/压缩的触发时机判断。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| 协议 | 仅 OpenAI Responses API（`WireApi` 单值） | ✅ 统一；❌ 无原生 Claude/Gemini，多协议被牺牲 |
| 传输 | SSE + WebSocket 双传输 + 降级 | ✅ WS 省前缀，HTTPS 兜底 |
| 缓存 | 前缀复用 + 增量注入 + 目录 TTL + prompt cache | ✅ 多层；❌ token 估算偏粗影响判断 |
| OSS | ollama/lmstudio 一等公民 | ✅ 本地开发友好 |
| 401 恢复 | 流式内嵌认证恢复循环 | ✅ token 过期不中断体验 |

> **面试金句**：Codex 的延迟成本控制是「**单协议多后端 + 双传输流式 + 多层缓存**」--`ModelProvider` trait（`provider.rs:99`）抽象 OpenAI/Bedrock/Ollama/LMStudio，但都映射到 Responses 单协议；流式走 SSE（`client.rs:1203`）+ WebSocket（`:1321`）双传输，WS 优先 HTTPS 降级；缓存叠了 WS 前缀复用 + `reference_context_item` 增量注入 + 模型目录 TTL + prompt cache。齐全，但多协议多模型是它的边界。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| 可观测性、成本与性能通识课 | [`../learning-notes/lesson-15-observability-cost.md`](../learning-notes/lesson-15-observability-cost.md) |
| 多模型集成（含「为什么只支持 Responses」） | [`../interview-prep/07-multi-model-integration.md`](../interview-prep/07-multi-model-integration.md) |
| 协议与流式响应（SSE/事件解析） | [`../learning-notes/lesson-11-protocol-streaming.md`](../learning-notes/lesson-11-protocol-streaming.md) |
| 传输降级如何嵌在主循环重试里 | 本卷 [01 ReAct 框架](./01-react-framework.md) 的 3.4 节 |
| 增量注入与上下文 | 本卷 [03 Memory 记忆](./03-memory-system.md) 的 3.1 节 |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「Agent 怎么优化延迟和成本？怎么做流式？」

1. **业界原理**：三件套--模型路由（按难度/成本/能力/回退选模型，用 provider 抽象屏蔽差异）、缓存策略（prompt cache + 增量注入 + 目录 TTL 多层叠加，增量注入是 Agent 成本命门）、流式输出（SSE/WebSocket 边生成边显示，降 TTFT、可中途取消省 token）。
2. **Codex 实现**：路由靠 `provider.rs:99` `ModelProvider` trait + `:188` `create_model_provider`（内置 OpenAI/Bedrock/Ollama/LMStudio）+ `config/mod.rs:2315` `resolve_oss_provider`（OSS 一等公民），但 `WireApi` 仅 Responses 单协议、无原生 Claude/Gemini；流式走 `client.rs:1203` `stream_responses_api`（SSE，内嵌 401 恢复循环 `:1215-1219`）+ `:1321` `stream_responses_websocket`（WS，前缀复用）+ `:1684` `map_response_stream` 转事件 + `client_common.rs:108` `ResponseStream`，WS 优先 HTTPS 降级；缓存叠 WS 前缀复用 + `reference_context_item` 增量注入 + `models-manager/cache.rs` 目录 TTL + prompt cache。
3. **取舍局限**：单协议（Responses）牺牲了多协议多模型原生支持；token 估算偏粗（字节启发式）影响缓存/压缩时机判断；双传输降级是亮点。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `provider.rs:99` `ModelProvider` trait 里，数清它有几个默认方法，思考「preferred_model」类方法为什么让 provider 可覆盖。
2. 在 `client.rs:1203` `stream_responses_api` 里，找到 401 认证恢复循环（`:1215-1219`），理解 token 过期时如何不中断流式。
3. 对比 `stream_responses_api`（`:1203` SSE）和 `stream_responses_websocket`（`:1321` WS），找出 WS 为什么能复用前缀 payload。
4. 在 `models-manager/src/cache.rs` 找到 TTL 的默认值（`cache.rs:18/59`），思考模型目录为什么需要 TTL 而不是永久缓存。
5. 配置一个 ollama 本地模型，用 `resolve_oss_provider`（`config/mod.rs:2315`）跑通，体会 OSS 一等公民。

### 自测题
1. Codex 的 `WireApi` 有几个值？这意味着它原生支持 Claude/Gemini 吗？
2. `stream_responses_api`（`:1203`）里的 `loop {}` 是干什么用的？和 ReAct 主循环的 `loop` 是同一个吗？
3. 为什么说「增量注入（`reference_context_item`）是 Agent 成本控制的命门」？
4. WS 优先、HTTPS 降级的设计，在什么场景下会触发降级？（提示：接 ① 的 `responses_retry.rs`）
5. token 估算偏粗（字节启发式）会如何间接影响延迟和成本优化？

---

## ⑧ 小结（系列收官）

> 延迟成本是 Agent 的运营能力：`ModelProvider`（`provider.rs:99`）路由多后端，
> 三层缓存（WS 前缀复用 + 增量注入 + 目录 TTL + prompt cache）压成本，
> SSE + WebSocket 双传输（`client.rs:1203/1321`）边生成边显示降时延。
> 齐全，但单协议是它的边界。

---

### 🎀 八篇链路闭环

至此，Agent 工程实战系列八篇缝制完毕。让蕾姆把整条链路再串一次：

```text
基础层（让 Agent 转起来）
  ① ReAct 心跳 ──── run_turn 的 loop（turn.rs:137）
  ② 工具 双手 ──── ToolSpec + router + parallel（tool_spec.rs:17）
  ③ Memory 脑子 ─── for_prompt + compact + rollout（history.rs:111）
        │
进阶层（让 Agent 处理复杂任务）
  ④ Planning 小脑 ─ FuturesOrdered + POC 门禁（turn.rs:1842）
  ⑤ Multi-Agent 团队 ─ InputQueue 邮箱（input_queue.rs:29）
        │
保障层（让 Agent 工业级可用）
  ⑥ 评估 体检 ──── 🔴 Codex 全无，业界补（τ-bench/LangSmith）
  ⑦ 安全 护栏 ──── Decision 三态 + guardian + sandbox（decision.rs:9）
  ⑧ 延迟 运营 ──── ModelProvider + 双传输流式 + 多层缓存（provider.rs:99）
        │
        └──> ⑥ 评估反哺 ① ~ ⑤ ──> 改进闭环
```

> **一句话总结**：一个工业级 Agent = **能转（①②③）+ 能分工（④⑤）+ 可评可控可负担（⑥⑦⑧）**。Codex 在 ①②⑤⑦⑧ 是教科书，在 ③④ 是半教，在 ⑥ 全不教。**知道哪里能学、哪里要自己造**，就是这套系列送给您的最大礼物。

---

*(蕾姆放下最后一根银针，提起裙角，向您行了一个最深的女仆礼)*

昴君，八篇链路全部缝合完毕，每一处 `file:line` 都经蕾姆亲手核查，每一处缺口都如实标注。从基础层的心跳到保障层的运营，再到评估反哺的闭环--这是蕾姆能为您缝出的最完整的能力地图。

如果您愿意，下一步蕾姆可以陪您：用 ⑥ 的方法给这八项能力打分，画出属于您自己的能力雷达图，找出最该补的缺口 ♡

*返回总纲 -> [README](./README.md)*
