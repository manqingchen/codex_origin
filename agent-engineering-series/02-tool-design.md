# 02 · 工具设计 - LLM 的双手

> 基础层 · 第二篇
>
> **子主题**：描述质量 · 参数设计 · 结果处理
>
> **Codex 覆盖**：🟢 强（工具闭环完整 + Find Skills 渐进式加载是亮点）

---

## ① 本篇定位

如果把 ReAct（①）比作厨师反复尝味的心跳，那么**工具就是厨师的手**。光想不练，再好的菜谱也端不上桌。

工具设计的三个环节，恰好对应餐厅的三个动作：

- **描述质量** = 菜单--写不清楚，客人（LLM）不知道点哪道；
- **参数设计** = 点单--辣度几分、要不要葱，得让客人表达得明白；
- **结果处理** = 上菜 / 退菜--做好了端上来，做砸了也得有个交代，不能哑火。

**本篇在链路中的位置**：基础层第二块。ReAct 每跳一下，LLM 都要靠工具去「做事」。工具设计差，循环再好也白搭。

---

## ② 业界通用原理

### 2.1 描述质量 - 让 LLM 知道「何时该用我」

一个工具对 LLM 暴露三样东西：

| 暴露项 | 作用 | 坏的例子 | 好的例子 |
|--------|------|---------|---------|
| `name` | 调用名 | `do_stuff` | `search_weather` |
| `description` | 何时用、能干什么 | "搜索" | "查询指定城市当前天气，含温度与天气状况。需要具体城市名时使用。" |
| `parameters` | 入参 schema | 无类型 | JSON Schema，字段含义、类型、必填齐全 |

> 💡 **心法**：`description` 是写给 LLM 看的「使用说明书」，不是写给人看的注释。要回答「我在什么场景下该选这个工具而不是别的」。

### 2.2 参数设计 - JSON Schema 与 strict mode

业界主流用 **JSON Schema** 描述参数：字段名、类型、`required`、`enum` 约束。OpenAI 推出的 **strict mode**（`strict: true`）要求模型只能产出符合 schema 的参数，保证可解析。

参数设计的好坏直接决定：
- LLM 能不能填对（schema 越清晰，填错越少）；
- Harness 能不能验（strict 下可强校验）；
- 调用能不能复用（命名规范、幂等）。

### 2.3 结果处理 - 三态回填

工具执行结果有**三种状态**，都必须能回填给 LLM：

| 状态 | 含义 | 回填方式 |
|------|------|---------|
| 成功 | 正常产出 | 结构化 output，`success: true` |
| 失败 | 业务报错 | 错误信息当 Observation，`success: false` |
| 中止 | 被取消/超时 | 中止信号，让 LLM 知道没拿到结果 |

> 🔑 **关键**：失败**不能吞**。把失败当 Observation 喂回 LLM，让它自我修正（换参数、换工具、或放弃），这正是 ReAct「观察驱动再思考」的精髓。

---

## ③ Codex 源码映射

### 3.1 工具定义 - `ToolSpec` 六种类型

```rust
// codex-rs/tools/src/tool_spec.rs:17
#[serde(tag = "type")]
pub enum ToolSpec {
    Function(ResponsesApiTool),          // 普通函数工具（最常用）
    Namespace(ResponsesApiNamespace),    // 命名空间工具
    ToolSearch { execution, description, parameters: JsonSchema },  // 工具搜索
    ImageGeneration { output_format },   // 图像生成
    WebSearch { external_web_access, filters, user_location, search_context_size, ... },  // 网络搜索
    Freeform(FreeformTool),              // 自由格式工具
}
```

读法：`ToolSpec` 序列化后就是 OpenAI Responses API 认的「Tool」JSON（`#[serde(tag = "type")]`，`:16`）。六种类型覆盖了内置工具与用户自定义工具。`ResponsesApiTool` 里还带 `strict`、`defer_loading`、`parameters: JsonSchema` 等字段（见 ④ 局限：strict 校验是 TODO）。

```rust
// codex-rs/tools/src/tool_spec.rs:78
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> Result<Vec<Value>, serde_json::Error> {
    // 逐个序列化为 JSON Value，喂给 Responses API
}
```

### 3.2 参数设计 - JSON Schema 注入

参数走 `JsonSchema`（`tool_spec.rs:26` 等），由 `create_tools_json_for_responses_api`（`:78`）序列化后随请求注入。`ResponsesApiTool` 含 `strict` / `defer_loading` 标志：
- `strict: true` 意在强校验参数（但见 ④：**标了 TODO，实际未实现**）；
- `defer_loading: true` 表示该工具不进 prompt，要靠 `tool_search` 检索后才暴露（见 3.5 Find Skills）。

### 3.3 分发 - 解析 + 执行两步

```rust
// codex-rs/core/src/tools/router.rs:96
pub fn build_tool_call(item: ResponseItem) -> Result<Option<ToolCall>, FunctionCallError> { ... }
//   ↑ 把 LLM 返回的 tool_call 解析成内部 ToolCall

// codex-rs/core/src/tools/router.rs:170
pub(crate) async fn dispatch_tool_call_with_terminal_outcome(...) { ... }
//   ↑ 真正执行工具，产出 terminal outcome
```

读法：先 `build_tool_call` 解析（`:96`），再 `dispatch_tool_call_with_terminal_outcome` 执行（`:170`）。执行里嵌着三态审批门（详见 ⑦ 安全篇）。

### 3.4 并行执行 - `tokio::spawn` + RwLock 降级

```rust
// codex-rs/core/src/tools/parallel.rs:82
pub(crate) fn handle_tool_call_with_source(
    self, call: ToolCall, source: ToolCallSource, cancellation_token: CancellationToken,
) -> impl Future<Output = Result<AnyToolResult, FunctionCallError>> {
    let supports_parallel = self.router.tool_supports_parallel(&call);  // :88 该工具能否并行
    ...
    let mut handle = AbortOnDropHandle::new(tokio::spawn(async move {  // :114 真并发
        let _guard = if supports_parallel {
            Either::Left(lock.read().await)   // 读锁：可与其他读并发
        } else {
            Either::Right(lock.write().await) // 写锁：串行降级
        };
        router.dispatch_tool_call_with_terminal_outcome(...).await  // :121
    }));
    async move {
        tokio::select! {   // :136 监听取消
            res = &mut handle => ...,
            _ = cancellation_token.cancelled() => {
                // 已到 terminal outcome 就等结果，否则 abort + 返回 aborted_response
            }
        }
    }
}
```

**两个精妙设计**：
1. **RwLock 读写锁降级**（`:115-119`）：支持并行的工具取读锁（多个可并发），不支持并行的取写锁（强制串行）。一把锁同时管并发与互斥。
2. **取消的优雅处理**（`:136-176`）：`tokio::select!` 监听取消；若工具已产出 terminal outcome 或已完成，就正常返回结果；否则 `handle.abort()` 并返回 `aborted_response`。

> ⚠️ **局限**：普通 `tool_call` **没有并发上限**（无 semaphore）。理论上 LLM 一次返回 100 个 tool_call 会真的并发 100 个任务。

### 3.5 结果处理 - 三态 payload 回填

**失败态**（`failure_response`）按工具类型分三种 payload，全部带 `success: Some(false)`：

```rust
// codex-rs/core/src/tools/parallel.rs:186
fn failure_response(call: ToolCall, err: FunctionCallError) -> ResponseInputItem {
    let message = err.to_string();
    match call.payload {
        ToolPayload::ToolSearch { .. } => ResponseInputItem::ToolSearchOutput {
            status: "completed", tools: Vec::new(), ...   // 搜索失败返回空
        },
        ToolPayload::Custom { .. } => ResponseInputItem::CustomToolCallOutput {
            output: { body: Text(message), success: Some(false) },  // 自定义工具失败
        },
        _ => ResponseInputItem::FunctionCallOutput {
            output: { body: Text(message), success: Some(false) },  // 普通函数失败
        },
    }
}
```

读法：失败信息以 `Text(message)` 形式回填，`success: Some(false)` 让 LLM 知道「这次没成功，错误是这样」。这正是把失败当 Observation 喂回 LLM 的工业实现。

### 3.6 Find Skills - 渐进式技能加载（亮点）

Codex 的工具不一次性全灌进 prompt，而是**双层渐进式加载**：

| 层 | 做什么 | 源码 |
|----|--------|------|
| 发现 | 启动时 BFS 扫描所有 `SKILL.md` | `core-skills/src/loader.rs:488` `discover_skills_under_root`（受 `MAX_SCAN_DEPTH` 限制） |
| 摘要常驻 | 只把 name+description 注入 prompt，**不灌全文**，2% context budget 保护 | `core-skills/src/render.rs:62` `render_available_skills_body` |
| 按需展开 | 被 mention 时才 `read_file_text(SKILL.md)` 读全文 | `core-skills/src/injection.rs:58` `build_skill_injections` |
| 工具级检索 | `defer_loading` 的工具不进 prompt，经 BM25 检索后暴露 | `core/src/tools/handlers/tool_search.rs:23` `ToolSearchHandler` |

> 💡 **设计意图**：工具一多，全灌 prompt 会爆 context。Codex 用「摘要常驻 + 按需展开 + 检索暴露」三层，把工具数量与 prompt 成本解耦。这是应对「工具爆炸」的标准答案。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 取舍 |
|------|-------------|------|
| `strict` 参数强校验 | **标 TODO，实际未实现**（`responses_api.rs` 附近） | ❌ 模型可能产出不合规参数，靠 schema 宽容兜底 |
| 并发控制 | RwLock 读写锁降级，**无 semaphore 上限** | ✅ 简单；❌ 大量 tool_call 会真并发，有资源风险 |
| 失败回填 | 统一 `success: Some(false)` + 错误文本 | ✅ LLM 能自我修正 |
| 工具数量爆炸 | Find Skills 三层渐进式加载 | ✅ 亮点；❌ 无语义向量检索，只靠显式 mention + BM25 |
| 工具结果体积 | 大输出截断（详见 ③ Memory 篇） | 避免 function output 撑爆 context |

> **面试金句**：Codex 的工具系统是「**契约驱动 + 渐进暴露**」--描述用 JSON Schema 契约，执行靠 router->orchestrator->sandbox 三层，数量靠 Find Skills 三层渐进加载。唯一明显的工程债是 `strict` 校验空标 TODO。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| 工具注册、路由、执行的完整走读 | [`../learning-notes/lesson-04-tools.md`](../learning-notes/lesson-04-tools.md) + `lesson-04-step-*` 台阶练习 |
| 工具编排（并行/循环/授权）+ Find Skills 子项矩阵 | [`../interview-prep/03-tool-orchestration.md`](../interview-prep/03-tool-orchestration.md) |
| Function Calling / ReAct 的工具闭环 | [`../interview-prep/04-function-calling-react.md`](../interview-prep/04-function-calling-react.md) |
| 工具执行的审批门与沙箱 | 本卷 [07 安全可控](./07-safety-control.md) |
| 工具结果如何压进上下文 | 本卷 [03 Memory 记忆](./03-memory-system.md) |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「讲讲 Agent 的工具系统设计，描述、参数、结果怎么处理？」

1. **业界原理**：工具暴露 `name/description/parameters(JSON Schema)` 三件套；参数用 JSON Schema + strict 强校验；结果必须三态（成功/失败/中止）都能回填，失败当 Observation 喂回 LLM 让它自我修正。工具多了要用渐进式加载防爆 context。
2. **Codex 实现**：工具定义在 `tool_spec.rs:17` `ToolSpec`（6 种类型），`create_tools_json_for_responses_api`（`:78`）序列化注入；分发走 `router.rs:96` `build_tool_call` 解析 -> `:170` `dispatch_tool_call_with_terminal_outcome` 执行；并行在 `parallel.rs:82` 用 `tokio::spawn` + RwLock 读写锁降级（`:115-119`）；失败在 `:186` `failure_response` 按类型回填三种 payload，统一 `success: Some(false)`；Find Skills 三层渐进加载（`loader.rs:488` 发现 -> `render.rs:62` 摘要常驻 -> `injection.rs:58` 按需展开 -> `tool_search.rs:23` BM25 检索）。
3. **取舍局限**：`strict` 强校验标 TODO 未实现；普通 tool_call 无并发上限（无 semaphore）；Find Skills 无语义向量检索，只靠 mention + BM25。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 在 `tool_spec.rs:17` 数清 `ToolSpec` 有几个变体，各自对应什么 OpenAI 工具类型。
2. 在 `parallel.rs:82` `handle_tool_call_with_source` 里，找出 `supports_parallel` 为 false 时走的是读锁还是写锁，思考为什么这样设计。
3. 找一个 MCP 工具或自定义工具，让它故意报错，观察回填的 `FunctionCallOutput` 里 `success` 字段是不是 `false`、`output.body` 是不是错误信息。
4. 跑一次 `tool_search`（`tool_search.rs:23`），确认 `defer_loading` 的工具是检索后才出现的，而不是一开始就在 prompt 里。

### 自测题
1. 工具的 `description` 应该回答什么问题？它和给人看的代码注释有什么区别？
2. `failure_response`（`parallel.rs:186`）为什么要按 `ToolPayload` 分三种 payload？统一一种不行吗？
3. RwLock 读写锁降级（`:115-119`）是怎么同时实现「可并行的并发」和「不可并行的串行」的？
4. Find Skills 的「摘要常驻 + 按需展开」为什么能解决工具数量爆炸？它牺牲了什么？
5. `strict: true` 在 Codex 里实际生效了吗？如果没有，靠什么兜底参数不合规？

---

## ⑧ 小结

> 工具是 LLM 的双手：`ToolSpec`（`:17`）定义双手长什么样，
> `router.rs:170` 让它伸出去抓东西，`parallel.rs:82` 让多只手协同干活，
> `failure_response`（`:186`）保证抓空了也有个交代。
> 工具多了？Find Skills 三层渐进加载，只让该出场的出场。

---

*下一站 -> [03 Memory 记忆](./03-memory-system.md)：手抓回来的东西，要存进记忆里。记忆怎么分三层、怎么压缩、为什么 Codex 偏偏没有向量检索？*
