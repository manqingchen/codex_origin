# 🔬 Deep Dive 04 · Function Calling / Tool Use / ReAct · 逐行精读

> 蕾姆的源码解剖室 ♡ -- 把 Codex 的「工具协议」与「ReAct 现代形态」剖开给您看。
>
> **定位**：这是 [`../04-function-calling-react.md`](../04-function-calling-react.md)（大纲层）的**深读版**。
> **与 [deep-dive-02](./deep-dive-02-agent-loop-runtime.md) / [deep-dive-03](./deep-dive-03-tool-orchestration.md) 的分工**：02 已述「工具执行闭环（Orchestrator/沙箱/执行入口）」与「流式增量分发片段」；03 已述「build_tool_call 入队 + drain_in_flight 按序回填 + failure_response」。本篇聚焦 04 独有：**Tool schema 定义与注入、tool_call 三态解码语义、ReAct 落地（run_turn loop 骨架 + 原生 reasoning + end_turn 语义）**--并给出本系列的灵魂论点：**Codex 的 ReAct 是「原生 reasoning + tool_call」形态，不是经典文本协议**。

---

## 📑 阅读地图

| 节 | 内容 | 关键文件 |
|---|------|------|
| 〇 | FC + ReAct 全局数据流 | `turn.rs` / `client.rs` / `router.rs` |
| 一 | Tool schema 定义与注入 | `tools/src/tool_spec.rs` / `responses_api.rs` / `json_schema.rs` / `client.rs` / `tool_name.rs` |
| 二 | tool_call 三态解码 | `tools/router.rs` / `tools/registry.rs` / `tool_executor.rs` / `tool_payload.rs` / `stream_events_utils.rs` |
| 三 | ReAct 落地（原生 reasoning vs 经典 ReAct） | `session/turn.rs` |
| 四 | 面试问答精选 | - |
| 五 | 动手复现 | - |
| 六 | 差异与局限总结 | - |

---

## 〇 FC + ReAct 全局数据流

```
[1] 工具 schema 注入 prompt
    build_tool_router -> Vec<ToolSpec>（含 MCP 工具经 mcp_tool_to_responses_api_tool 转换、merge_into_namespaces 合并）
    -> Prompt.tools（client_common.rs:25）
        │
        ▼
[2] 构造采样请求
    run_turn loop（turn.rs:204）-> run_sampling_request（turn.rs:234）
    -> build_responses_request（client.rs:729）
    -> create_tools_json_for_responses_api(&prompt.tools)（client.rs:732 / tool_spec.rs:78）
    -> tools 字段进 ResponsesApiRequest，tool_choice="auto"，stream=true
        │
        ▼
[3] 模型流式输出
    run_sampling_request 内部 loop（turn.rs:1861）消费 ResponseEvent
    ├─ ReasoningSummaryDelta（turn.rs:2182）→ ReasoningContentDeltaEvent 透传（= ReAct 的 Thought）
    ├─ OutputTextDelta（turn.rs:2132）→ AgentMessageContentDelta
    └─ OutputItemDone（turn.rs:1904）→ handle_output_item_done → build_tool_call（= ReAct 的 Action）
        │
        ▼
[4] 三态解码（router.rs:96）
    FunctionCall        -> ToolPayload::Function { arguments }
    ToolSearchCall      -> ToolPayload::ToolSearch { arguments }   （execution=="client" 才接管）
    CustomToolCall      -> ToolPayload::Custom { input }
        │
        ▼
[5] 入队 + needs_follow_up 置位
    dispatch_tool_call_with_terminal_outcome（router.rs:170）
    -> registry.dispatch_any_with_terminal_outcome（registry.rs:403：按 name 查表 + matches_kind + pre_tool_use hooks + 执行）
    -> in_flight.push_back(tool_future)（turn.rs:1983）
    -> needs_follow_up |= true（turn.rs:1988）   ← 任何工具调用都触发 ReAct 续轮
        │
        ▼
[6] 采样完成 + end_turn 语义
    Completed { end_turn }（turn.rs:2108）
    -> if end_turn == Some(false) { needs_follow_up = true }（turn.rs:2124）  ← 协议级终止判定
    -> break Ok(SamplingRequestResult { needs_follow_up, last_agent_message }）
        │
        ▼
[7] 结果回填（= ReAct 的 Observation）
    drain_in_flight（turn.rs:2256，见 deep-dive-03）按序回收 tool_future
    -> 结果转 FunctionCallOutput 进 history
        │
        ▼
[8] ReAct 续轮判定
    回到 run_turn loop（turn.rs:246）：needs_follow_up = model_needs_follow_up || has_pending_input（turn.rs:263）
    ├─ true  -> continue（history 已含 FunctionCallOutput/Observation，模型继续 Think+Act）
    └─ false -> stop hooks -> break，返回 last_agent_message
```

> 💡 **ReAct 四要素在 Codex 的映射**：Thought = `ReasoningSummaryDelta`（原生 reasoning 流式）；Action = `FunctionCall`/`CustomToolCall`/`ToolSearchCall`（结构化 item）；Observation = `FunctionCallOutput`（history item）；终止判定 = `end_turn` + `needs_follow_up`（**协议级**，非文本标签）。这是下面三节要逐行论证的核心。

---

## 一、Tool schema 定义与注入

> 关键问题：工具怎么用类型描述、怎么塞进请求？strict/defer_loading/namespace 各是什么？

### ① 真实代码片段

**`ToolSpec` 枚举 -- 序列化即合法的 Responses API tool JSON**
`codex-rs/tools/src/tool_spec.rs:13-51`
```rust
/// When serialized as JSON, this produces a valid "Tool" in the OpenAI
/// Responses API.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum ToolSpec {
    #[serde(rename = "function")]
    Function(ResponsesApiTool),
    #[serde(rename = "namespace")]
    Namespace(ResponsesApiNamespace),
    #[serde(rename = "tool_search")]
    ToolSearch {
        execution: String,
        description: String,
        parameters: JsonSchema,
    },
    #[serde(rename = "image_generation")]
    ImageGeneration { output_format: String },
    // TODO: Understand why we get an error on web_search although the API docs
    // say it's supported.
    #[serde(rename = "web_search")]
    WebSearch {
        #[serde(skip_serializing_if = "Option::is_none")]
        external_web_access: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        filters: Option<ResponsesApiWebSearchFilters>,
        #[serde(skip_serializing_if = "Option::is_none")]
        user_location: Option<ResponsesApiWebSearchUserLocation>,
        #[serde(skip_serializing_if = "Option::is_none")]
        search_context_size: Option<WebSearchContextSize>,
        #[serde(skip_serializing_if = "Option::is_none")]
        search_content_types: Option<Vec<String>>,
    },
    #[serde(rename = "custom")]
    Freeform(FreeformTool),
}
```

**`name()` -- 平台内建工具名字是写死字面量**
`codex-rs/tools/src/tool_spec.rs:53-63`
```rust
impl ToolSpec {
    pub fn name(&self) -> &str {
        match self {
            ToolSpec::Function(tool) => tool.name.as_str(),
            ToolSpec::Namespace(namespace) => namespace.name.as_str(),
            ToolSpec::ToolSearch { .. } => "tool_search",
            ToolSpec::ImageGeneration { .. } => "image_generation",
            ToolSpec::WebSearch { .. } => "web_search",
            ToolSpec::Freeform(tool) => tool.name.as_str(),
        }
    }
}
```

**`create_tools_json_for_responses_api` -- 极简注入**
`codex-rs/tools/src/tool_spec.rs:75-89`
```rust
/// Returns JSON values that are compatible with Function Calling in the
/// Responses API:
/// https://platform.openai.com/docs/guides/function-calling?api-mode=responses
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> Result<Vec<Value>, serde_json::Error> {
    let mut tools_json = Vec::new();
    for tool in tools {
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }
    Ok(tools_json)
}
```

**`ResponsesApiTool` -- strict 的 TODO 与 defer_loading**
`codex-rs/tools/src/responses_api.rs:25-38`
```rust
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ResponsesApiTool {
    pub name: String,
    pub description: String,
    /// TODO: Validation. When strict is set to true, the JSON schema,
    /// `required` and `additional_properties` must be present. All fields in
    /// `properties` must be present in `required`.
    pub strict: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub defer_loading: Option<bool>,
    pub parameters: JsonSchema,
    #[serde(skip)]
    pub output_schema: Option<Value>,
}
```

**`tool_definition_to_responses_api_tool` -- strict 恒 false、defer_loading 来自定义**
`codex-rs/tools/src/responses_api.rs:127-136`
```rust
pub fn tool_definition_to_responses_api_tool(tool_definition: ToolDefinition) -> ResponsesApiTool {
    ResponsesApiTool {
        name: tool_definition.name,
        description: tool_definition.description,
        strict: false,
        defer_loading: tool_definition.defer_loading.then_some(true),
        parameters: tool_definition.input_schema,
        output_schema: tool_definition.output_schema,
    }
}
```

**MCP 工具两条转换路径（普通 vs deferred）**
`codex-rs/tools/src/responses_api.rs:107-125`
```rust
pub fn mcp_tool_to_responses_api_tool(
    tool_name: &ToolName, tool: &rmcp::model::Tool,
) -> Result<ResponsesApiTool, serde_json::Error> {
    Ok(tool_definition_to_responses_api_tool(
        parse_mcp_tool(tool)?.renamed(tool_name.name.clone()),
    ))
}

pub fn mcp_tool_to_deferred_responses_api_tool(
    tool_name: &ToolName, tool: &rmcp::model::Tool,
) -> Result<ResponsesApiTool, serde_json::Error> {
    Ok(tool_definition_to_responses_api_tool(
        parse_mcp_tool(tool)?.renamed(tool_name.name.clone()).into_deferred(),
    ))
}
```

**`ToolDefinition` + `into_deferred`（defer_loading 同时清空 output_schema）**
`codex-rs/tools/src/tool_definition.rs:7-26`
```rust
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: JsonSchema,
    pub output_schema: Option<JsonValue>,
    pub defer_loading: bool,
}

impl ToolDefinition {
    pub fn into_deferred(mut self) -> Self {
        self.output_schema = None;
        self.defer_loading = true;
        self
    }
}
```

**`JsonSchema` -- OpenAI Structured Outputs 子集（注意 `encrypted` 与 `BTreeMap`）**
`codex-rs/tools/src/json_schema.rs:39-74`
```rust
/// Generic JSON-Schema subset needed for our tool definitions.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct JsonSchema {
    #[serde(rename = "$ref", skip_serializing_if = "Option::is_none")]
    pub schema_ref: Option<String>,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub schema_type: Option<JsonSchemaType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Responses-only marker for reviewed encrypted tool parameters.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encrypted: Option<bool>,
    #[serde(rename = "enum", skip_serializing_if = "Option::is_none")]
    pub enum_values: Option<Vec<JsonValue>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub items: Option<Box<JsonSchema>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub properties: Option<BTreeMap<String, JsonSchema>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required: Option<Vec<String>>,
    #[serde(rename = "additionalProperties", skip_serializing_if = "Option::is_none")]
    pub additional_properties: Option<AdditionalProperties>,
    #[serde(rename = "anyOf", skip_serializing_if = "Option::is_none")]
    pub any_of: Option<Vec<JsonSchema>>,
    #[serde(rename = "oneOf", skip_serializing_if = "Option::is_none")]
    pub one_of: Option<Vec<JsonSchema>>,
    #[serde(rename = "allOf", skip_serializing_if = "Option::is_none")]
    pub all_of: Option<Vec<JsonSchema>>,
    #[serde(rename = "$defs", skip_serializing_if = "Option::is_none")]
    pub defs: Option<BTreeMap<String, JsonSchema>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub definitions: Option<BTreeMap<String, JsonSchema>>,
}
```

**`build_responses_request` -- tools 注入请求体**
`core/src/client.rs:729-772`
```rust
        let instructions = &prompt.base_instructions.text;
        let input = prompt.get_formatted_input_for_request(model_info.use_responses_lite);
        let tools = create_tools_json_for_responses_api(&prompt.tools)?;
        let reasoning = Self::build_reasoning(model_info, effort, summary);
        let include = if reasoning.is_some() {
            vec!["reasoning.encrypted_content".to_string()]
        } else {
            Vec::new()
        };
        let request = ResponsesApiRequest {
            model: model_info.slug.clone(),
            instructions: instructions.clone(),
            input,
            tools,
            tool_choice: "auto".to_string(),
            parallel_tool_calls: prompt.parallel_tool_calls && !model_info.use_responses_lite,
            reasoning,
            store: provider.is_azure_responses_endpoint(),
            stream: true,
            include,
            service_tier,
            prompt_cache_key,
            text,
            client_metadata: Some(responses_metadata.client_metadata()),
        };
        Ok(request)
```

**`ToolName` namespace 拼接（分隔符在 namespace 字符串内部）**
`protocol/src/tool_name.rs:6-44`
```rust
/// Identifies a callable tool, preserving the namespace split when the model provides one.
#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct ToolName {
    pub name: String,
    pub namespace: Option<String>,
}

impl ToolName {
    pub fn new(namespace: Option<String>, name: impl Into<String>) -> Self {
        Self { name: name.into(), namespace }
    }
    pub fn plain(name: impl Into<String>) -> Self {
        Self { name: name.into(), namespace: None }
    }
    pub fn namespaced(namespace: impl Into<String>, name: impl Into<String>) -> Self {
        Self { name: name.into(), namespace: Some(namespace.into()) }
    }
}

impl fmt::Display for ToolName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.namespace {
            Some(namespace) => write!(f, "{namespace}{}", self.name),
            None => f.write_str(&self.name),
        }
    }
}
```

**`parse_mcp_tool` -- properties 兜底（匹配 Agents SDK 行为）**
`codex-rs/tools/src/mcp_tool.rs:6-37`
```rust
pub fn parse_mcp_tool(tool: &rmcp::model::Tool) -> Result<ToolDefinition, serde_json::Error> {
    let mut serialized_input_schema = serde_json::Value::Object(tool.input_schema.as_ref().clone());

    // OpenAI models mandate the "properties" field in the schema. Some MCP
    // servers omit it (or set it to null), so we insert an empty object to
    // match the behavior of the Agents SDK.
    if let serde_json::Value::Object(obj) = &mut serialized_input_schema
        && obj.get("properties").is_none_or(serde_json::Value::is_null)
    {
        obj.insert(
            "properties".to_string(),
            serde_json::Value::Object(serde_json::Map::new()),
        );
    }

    let input_schema = parse_tool_input_schema(&serialized_input_schema)?;
    ...
    Ok(ToolDefinition {
        name: tool.name.to_string(),
        description: tool.description.clone().map(Into::into).unwrap_or_default(),
        input_schema,
        output_schema: Some(mcp_call_tool_result_output_schema(structured_content_schema)),
        defer_loading: false,
    })
}
```

### ② 逐行解读

- **`ToolSpec` 枚举**：6 个 variant，靠 `#[serde(tag = "type")]` 做 **internally-tagged** 序列化。每个 variant 用 `#[serde(rename = "...")]` 映射成 Responses API 要求的 `"type"` 字面量（`function`/`namespace`/`tool_search`/`image_generation`/`web_search`/`custom`）。这意味着 `serde_json::to_value(tool)` **直接产出合法的 Responses API tool JSON，零手工拼装**。`WebSearch` 上那段 TODO 暴露真实工程细节：API 文档说支持 `web_search` 但实际报错。

- **`name()`**：`Function`/`Namespace`/`Freeform` 从内部结构取 name 字段；`ToolSearch`/`ImageGeneration`/`WebSearch` 直接返回写死字面量--这三类是「平台内建工具」，名字固定。

- **`create_tools_json_for_responses_api`**：极简--遍历逐个 `serde_json::to_value`。返回 `Vec<Value>` 而非强类型数组，是为了让 `tools` 字段能直接放进 `serde_json::Value` 化的请求体。

- **`ResponsesApiTool`**：`function`/`custom` 两类共享的核心结构。
  - `strict: bool`（默认构造恒为 `false`，见 `responses_api.rs:131`）。
  - `defer_loading: Option<bool>` 带 `skip_serializing_if`，只有 `Some(true)` 才序列化。
  - `parameters: JsonSchema` 是入参 schema。
  - `output_schema` 带 `#[serde(skip)]`--**只本地保留、不发给模型**。

- **strict 的 TODO**（`responses_api.rs:29-31`）：明确写着「strict=true 时 `required` 和 `additional_properties` 必须存在，`properties` 所有字段都须进 `required`」--但代码恒置 `strict: false`，说明 Codex 当前**不使用 Structured Outputs 强约束**，TODO 是为未来开启预留的校验点。

- **`defer_loading` 语义**（`tool_definition.rs:21-25`）：`into_deferred` 同时做两件事--`defer_loading=true` **并清空 `output_schema`**。延迟加载的工具不进初始可见列表（见 [deep-dive-03](./deep-dive-03-tool-orchestration.md) 的 `ToolExposure::Deferred`），靠 `tool_search` 按需发现，此时 output_schema 也不再有本地价值，故一起清掉。两条 MCP 转换路径对应「直接暴露」与「延迟发现」两种策略。

- **`JsonSchema`**：手写的 OpenAI Structured Outputs 子集。关键：`properties` 用 **`BTreeMap` 而非 `HashMap`**（保证序列化顺序稳定，利于 prompt cache 命中）；`encrypted: Option<bool>` 是 Responses-only 标记（给已审核的加密工具参数打标）。

- **`build_responses_request`**（`client.rs:729`）：第 732 行 `create_tools_json_for_responses_api(&prompt.tools)` 是注入点。`tool_choice: "auto"`（模型自主决定是否调工具）；`parallel_tool_calls: prompt.parallel_tool_calls && !model_info.use_responses_lite`（Responses Lite 模式强制关并行）；`stream: true` 恒流式。

- **`ToolName` namespace 拼接**（`tool_name.rs:37`）：`write!(f, "{namespace}{}", self.name)`--**namespace 字符串本身已含分隔符**（namespace 值如 `"mcp__codex_apps__gmail"`、name 如 `"_get_recent_emails"`，拼出 `"mcp__codex_apps__gmail_get_recent_emails"`）。所以 `mcp__server__tool` 的「双下划线」来自 namespace 字符串内部约定，不是 Display 层加的。

- **`parse_mcp_tool`**：把 `rmcp::model::Tool` 转成 `ToolDefinition`。关键兜底：检测 `properties` 缺失或 null 就插空对象--**OpenAI 模型强制要求 schema 里有 `properties`**，而有些 MCP server 不写。注释明确「match the behavior of the Agents SDK」。

### ③ 设计原理与权衡

- **「序列化即合法 tool JSON」**：`ToolSpec` 用 `#[serde(tag = "type")]` + `rename`，让 Rust 枚举与 Responses API tool schema 一一对应。**零运行时拼装、零 stringly-typed**，编译期保证字段名拼写正确，且每个 variant 可承载专属字段（如 WebSearch 的 `search_context_size`）。代价是枚举 variant 必须与 API 文档同步演进（`web_search` 的 TODO 就是没同步上的证据）。

- **`output_schema` 不发模型**：`#[serde(skip)]` 是关键设计--模型只需知道「我调用工具的入参长什么样」，不需要知道「工具会返回什么」。减小 prompt 体积，也避免模型「幻觉」自己构造输出结构。

- **`strict` 恒 false 的取舍**：OpenAI Structured Outputs（strict=true）能强制模型输出严格符合 schema 的参数，但代价是 schema 受限（不能任意 JSON Schema、必须所有字段进 required）。Codex 选择 `strict: false` 换取 schema 灵活性（尤其 MCP 工具 schema 不可控），用运行时校验 + 错误回灌（`failure_response`，见 [deep-dive-03](./deep-dive-03-tool-orchestration.md)）兜底。这是「灵活 vs 严格」的典型权衡，TODO 保留未来切换可能。

- **namespace 分组的动机**：MCP server 可能暴露几十个工具，扁平塞进 prompt 会挤占上下文且让模型选择困难。`Namespace` variant + `merge_into_namespaces` 把同源工具打包成一组，让模型先选 namespace 再选具体工具，降低初始 prompt 的工具描述密度。`defer_loading` 进一步把不常用工具移出初始列表，靠 `tool_search` 按需发现。

- **`BTreeMap` 而非 `HashMap`**：序列化顺序稳定 -> prompt 字节序列稳定 -> **命中 prompt cache 的概率高**。这是把「可读性/调试便利」让位于「缓存命中率」的取舍。

- **业界对比**：LangChain/LlamaIndex 通常用 Python dict 拼 tool schema（stringly-typed、运行时验证）；OpenAI Agents SDK（Python）也是 dataclass + 手工 `to_dict`。Codex 用强类型枚举 + serde derive，**编译期保证结构正确**，在类型安全上更进一层。

### ④ 数据流位置

在「一次 turn」中，schema 注入位于**采样请求构造阶段**（turn loop 每次迭代开头）：
- 上游：`build_skills_and_plugins`（`turn.rs:162`）+ `build_tool_router` 产出 `Vec<ToolSpec>`，经 `merge_into_namespaces` 合并存入 `Prompt.tools`。
- 注入点：`client.rs:732` `create_tools_json_for_responses_api(&prompt.tools)`，结果放进 `ResponsesApiRequest.tools`。
- 下游：请求序列化后经 `stream: true` 发出，模型流式响应里带 `tool_call` 类 `OutputItem`，进入子项二的三态解码。

---

## 二、tool_call 三态解码

> 关键问题：模型输出的 tool_call 怎么变成可执行的 ToolCall？三态有什么区别？解码失败怎么处理？

### ① 真实代码片段

**`build_tool_call` 三态解码（完整）**
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
            ResponseItem::CustomToolCall {
                name, input, call_id, ..
            } => Ok(Some(ToolCall {
                tool_name: ToolName::plain(name),
                call_id,
                payload: ToolPayload::Custom { input },
            })),
            _ => Ok(None),
        }
    }
```

**`ToolCall` 与 `ToolRouter` 结构**
`core/src/tools/router.rs:27-37`
```rust
#[derive(Clone, Debug)]
pub struct ToolCall {
    pub tool_name: ToolName,
    pub call_id: String,
    pub payload: ToolPayload,
}

pub struct ToolRouter {
    registry: ToolRegistry,
    model_visible_specs: Vec<ToolSpec>,
}
```

**`ToolPayload` 三态**
`codex-rs/tools/src/tool_payload.rs:7-21`
```rust
/// Canonical payload shapes accepted by model-visible tool runtimes.
#[derive(Clone, Debug)]
pub enum ToolPayload {
    Function { arguments: String },
    ToolSearch { arguments: SearchToolCallParams },
    Custom { input: String },
}
```

**`ToolRegistry` -- 按 name 查 executor**
`core/src/tools/registry.rs:321-359`
```rust
pub struct ToolRegistry {
    tools: HashMap<ToolName, Arc<dyn CoreToolRuntime>>,
}

impl ToolRegistry {
    pub(crate) fn from_tools(tools: impl IntoIterator<Item = Arc<dyn CoreToolRuntime>>) -> Self {
        let mut tools_by_name = HashMap::new();
        for tool in tools {
            let name = tool.tool_name();
            if tools_by_name.contains_key(&name) {
                error_or_panic(format!("tool {name} already registered"));
                continue;
            }
            tools_by_name.insert(name, tool);
        }
        Self::new(tools_by_name)
    }
    fn tool(&self, name: &ToolName) -> Option<Arc<dyn CoreToolRuntime>> {
        self.tools.get(name).map(Arc::clone)
    }
```

**`dispatch_any_with_terminal_outcome` -- 按 name 查表 + matches_kind + hooks**
`core/src/tools/registry.rs:403-459`
```rust
    pub(crate) async fn dispatch_any_with_terminal_outcome(
        &self, mut invocation: ToolInvocation, terminal_outcome_reached: Option<Arc<AtomicBool>>,
    ) -> Result<AnyToolResult, FunctionCallError> {
        let tool_name = invocation.tool_name.clone();
        ...
        let tool = match self.tool(&tool_name) {
            Some(tool) => tool,
            None => {
                let message = unsupported_tool_call_message(&invocation.payload, &tool_name);
                let err = FunctionCallError::RespondToModel(message);
                dispatch_trace.record_failed(&err);
                return Err(err);
            }
        };
        ...
        if !tool.matches_kind(&invocation.payload) {
            let message = format!("tool {tool_name} invoked with incompatible payload");
            let err = FunctionCallError::Fatal(message);
            dispatch_trace.record_failed(&err);
            return Err(err);
        }

        notify_tool_start(&invocation).await;

        if let Some(pre_tool_use_payload) = tool.pre_tool_use_payload(&invocation) {
            match run_pre_tool_use_hooks(...).await {
                PreToolUseHookResult::Blocked(message) => {
                    let err = FunctionCallError::RespondToModel(message);
                    return Err(err);
                }
                // ... (Continue 分支：可能改写 input)
            }
        }
```

**`matches_kind` -- 默认只接受 Function/ToolSearch，拒绝 Custom**
`core/src/tools/registry.rs:47-53`
```rust
pub(crate) trait CoreToolRuntime: ToolExecutor<ToolInvocation> {
    fn matches_kind(&self, payload: &ToolPayload) -> bool {
        matches!(
            payload,
            ToolPayload::Function { .. } | ToolPayload::ToolSearch { .. }
        )
    }
```

**`ToolExposure` 四态**
`codex-rs/tools/src/tool_executor.rs:13-42`
```rust
/// Controls where a tool is exposed to the model.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolExposure {
    /// Include this tool in the initial model-visible tool list.
    Direct,
    /// Register this tool for later discovery, but omit it from the initial
    /// model-visible tool list. Deferred tools must provide search metadata via
    /// [`ToolExecutor::search_info`].
    Deferred,
    /// Include this tool in the initial model-visible tool list only.
    DirectModelOnly,
    /// Keep this tool registered for dispatch without exposing it to the model.
    Hidden,
}
```

**`handle_output_item_done` -- 解码后据三态决定 needs_follow_up（ReAct 续轮关键）**
`core/src/stream_events_utils.rs:413-507`
```rust
    match ToolRouter::build_tool_call(item.clone()) {
        // The model emitted a tool call; log it, persist the item immediately, and queue the tool execution.
        Ok(Some(call)) => {
            ctx.sess.input_queue
                .accept_mailbox_delivery_for_current_turn(&ctx.sess.active_turn, &ctx.turn_context.sub_id)
                .await;

            let payload_preview = call.payload.log_payload().into_owned();
            tracing::info!(thread_id = %ctx.sess.thread_id, "ToolCall: {} {}", call.tool_name, payload_preview);

            record_completed_response_item(ctx.sess.as_ref(), ctx.turn_context.as_ref(), &item).await;

            let cancellation_token = ctx.cancellation_token.child_token();
            let tool_future: InFlightFuture<'static> = Box::pin(
                ctx.tool_runtime.clone().handle_tool_call(call, cancellation_token),
            );

            output.needs_follow_up = true;          // ← 任何工具调用都触发 ReAct 续轮
            output.tool_future = Some(tool_future);
        }
        // No tool call: convert messages/reasoning into turn items and mark them as complete.
        Ok(None) => {
            // ... (finalize_non_tool_response_item 处理 message/reasoning)
        }
        // The tool request should be answered directly (or was denied); push that response into the transcript.
        Err(FunctionCallError::RespondToModel(message)) => {
            let response = ResponseInputItem::FunctionCallOutput {
                call_id: String::new(),
                output: FunctionCallOutputPayload {
                    body: FunctionCallOutputBody::Text(message),
                    ..Default::default()
                },
            };
            record_completed_response_item(ctx.sess.as_ref(), ctx.turn_context.as_ref(), &item).await;
            if let Some(response_item) = response_input_to_response_item(&response) {
                ctx.sess.record_conversation_items(
                    &ctx.turn_context, std::slice::from_ref(&response_item),
                ).await;
            }
            output.needs_follow_up = true;          // ← 错误也回灌模型，触发续轮纠错
        }
        // A fatal error occurred; surface it back into history.
        Err(FunctionCallError::Fatal(message)) => {
            return Err(CodexErr::Fatal(message));
        }
    }
```

### ② 逐行解读

- **三态解码输入是 `ResponseItem`，输出 `Result<Option<ToolCall>, FunctionCallError>`**。三种「需执行」+ 两种「不执行」兜底：
  1. **`FunctionCall`**：标准内置工具调用。带 `namespace`（MCP 工具的 `mcp__server__` 前缀）+ `name`。构造 `ToolName::new(namespace, name)`，payload 为 `ToolPayload::Function { arguments }`（arguments 是原始 JSON 字符串，未反序列化--**保留原始串以便 hook 改写**）。
  2. **`ToolSearchCall` 且 `execution == "client"`**：Find Skills 工具检索调用。关键守卫 `if execution == "client"`--只有「客户端执行」的 tool_search 才由本地处理。参数反序列化为强类型 `SearchToolCallParams`，失败转 `RespondToModel`。tool_name 写死 `tool_search`。
  3. **`CustomToolCall`**：自定义工具调用。无 namespace（`ToolName::plain(name)`），payload 为 `ToolPayload::Custom { input }`。
  - 其余 `_ => Ok(None)`：Message/Reasoning 等非工具 item，不解码为 ToolCall。

- **`ToolSearchCall` 的 `execution == "client"` 守卫**：tool_search 可以「服务端执行」（API 自己检索返回结果，client 只透传）或「客户端执行」（client 本地执行检索逻辑，因为 MCP 工具元数据在本地）。Codex 只接管 client 执行的那类--服务端执行的 ToolSearchCall 在 `router.rs:130` 直接 `Ok(None)` 跳过。这是**职责切分**。

- **Custom vs Function 根本区别**：`Custom` 工具无 namespace、参数叫 `input`（原始字符串，不强制 JSON），对应 Responses API 的 `custom` type（如 `apply_patch`、`update_plan` 这类「自由格式输入」工具）。`Function` 工具有 namespace、参数叫 `arguments`（JSON 字符串），对应标准 function calling。`matches_kind` 默认拒绝 Custom payload--Custom 工具需单独实现自己的 `matches_kind`。

- **`dispatch_any_with_terminal_outcome` 的 dispatch 路径**：
  1. **按 name 查表**（`registry.rs:440`）：找到 executor 或走 None 分支。
  2. **None -> RespondToModel**（`registry.rs:442-458`）：构造「unsupported tool call」消息转 `FunctionCallError::RespondToModel`。这个错误被 `handle_output_item_done` 转成 `FunctionCallOutput` 回灌模型--**模型看到「这个工具不存在」后可自行纠错**。
  3. **`matches_kind` 校验**（`registry.rs:473`）：检查 payload 类型与工具期望是否匹配。默认只接受 Function/ToolSearch，拒绝 Custom。不匹配 -> `Fatal`（致命，不让模型纠错）。
  4. **pre_tool_use hooks**（`registry.rs:493`）：`Blocked` -> RespondToModel；`Continue { updated_input }` -> 用 `with_updated_hook_input` 改写参数（如 hook 重写 shell 命令）。

- **`handle_output_item_done` 的 ReAct 续轮触发**（关键）：`Ok(Some(call))` -> `needs_follow_up = true`（`stream_events_utils.rs:438`）；`Err(RespondToModel)` -> 错误回灌 + `needs_follow_up = true`（`stream_events_utils.rs:506`）；`Err(Fatal)` -> `break`。**任何工具调用（含失败回灌）都置 `needs_follow_up`，驱动 ReAct 下一轮**。

### ③ 设计原理与权衡

- **三态而非一态的原因**：Responses API 对不同工具类型返回的 item 结构不同（`FunctionCall` 有 namespace+arguments JSON 字符串、`CustomToolCall` 有 input 字符串、`ToolSearchCall` 有 execution 字段且参数是结构化对象）。用三个独立 `ResponseItem` variant + 三个 `ToolPayload` variant，让**解码类型安全**：每个状态的参数类型、反序列化策略都独立。

- **RespondToModel vs Fatal 的分级**：`RespondToModel`（工具不存在、参数解析失败、hook block）是「**可恢复**」--把错误当工具输出回灌，模型可纠错继续；`Fatal`（payload 类型不匹配、工具无输出）是「**不可恢复**」--直接 break 整个采样。这是把「模型可自救」与「系统级 bug」分开的设计，对应 ReAct 里 **Observation 可以是错误信息**的语义。

- **`terminal_outcome_reached` 的设计**：多 agent 场景下，`spawn_agent` 可能产出「终局答案」，此时后续并发执行的工具结果不应再触发 finish 生命周期事件。用 `AtomicBool::swap(true, AcqRel)` 抢占--第一个到达终局的工具 claim，其余被跳过。这是对「并发工具执行 + 提前终止」的精细处理。

- **`output_schema` 不发模型**（呼应子项一）：模型只需知入参，不需知出参。这减小 prompt 体积，也避免模型「幻觉」输出结构。

- **业界对比**：LangChain 的 `Tool` 是单一抽象，靠 `args_schema` 区分；OpenAI Agents SDK 用 `FunctionTool` vs `HostedTool`。Codex 的三态 + `ToolExposure` 四态 + `matches_kind` 校验，**粒度更细**，但复杂度也更高--代价是新增工具类型要同时改 `ResponseItem` / `ToolPayload` / `matches_kind` 三处。

### ④ 数据流位置

三态解码位于**采样响应处理阶段**，在 `run_sampling_request` 的内部 loop（`turn.rs:1861`）中：
- 上游：模型流式产出 `ResponseEvent::OutputItemDone(item)`（`turn.rs:1904`），item 进 `handle_output_item_done`（`stream_events_utils.rs:405`）。
- 解码点：`stream_events_utils.rs:413` 调 `ToolRouter::build_tool_call(item)`。
- 三态分流：`Ok(Some(call))` -> tool_future 入 `in_flight`（`turn.rs:1983`）+ `needs_follow_up=true`（`turn.rs:1988`）；`Ok(None)` -> finalize 为 message/reasoning turn item；`Err(RespondToModel)` -> 错误回灌 + `needs_follow_up=true`；`Err(Fatal)` -> break。
- 下游：`in_flight` 里的 tool_future 由 `drain_in_flight`（`turn.rs:2256`，见 [deep-dive-03](./deep-dive-03-tool-orchestration.md)）按序回收，结果作为 `FunctionCallOutput` 进 history，供下一轮采样。

---

## 三、ReAct 落地（run_turn loop + 原生 reasoning vs 经典 ReAct）

> 关键问题：Codex 的 ReAct 循环怎么驱动？为什么说它是「原生 reasoning + tool_call」而非经典文本协议？--**这是本系列的灵魂论点**。

### ① 真实代码片段

**`run_turn` 主 loop 骨架（采样 -> needs_follow_up 判定 -> stop hooks -> break/continue）**
`core/src/session/turn.rs:204-367`
```rust
    loop {
        // Note that pending_input would be something like a message the user
        // submitted through the UI while the model was running. Though the UI
        // may support this, the model might not.
        let pending_input = if can_drain_pending_input {
            sess.input_queue.get_pending_input(&sess.active_turn).await
        } else {
            Vec::new()
        };

        if run_hooks_and_record_inputs(&sess, &turn_context, &pending_input).await {
            break;
        }

        // Construct the input that we will send to the model.
        let sampling_request_input: Vec<ResponseItem> = async {
            sess.clone_history().await
                .for_prompt(&turn_context.model_info.input_modalities)
        }
        .instrument(trace_span!("run_turn.prepare_sampling_request_input"))
        .await;

        match run_sampling_request(
            Arc::clone(&sess), Arc::clone(&turn_context), /* ... */
        ).await
        {
            Ok(sampling_request_output) => {
                let SamplingRequestResult {
                    needs_follow_up: model_needs_follow_up,
                    last_agent_message: sampling_request_last_agent_message,
                } = sampling_request_output;
                can_drain_pending_input = true;
                ...
                let needs_follow_up = model_needs_follow_up || has_pending_input;
                let token_limit_reached = token_status.token_limit_reached;
                ...
                let started_new_context_window = sess
                    .maybe_start_new_context_window(turn_context.as_ref()).await.is_some();
                if started_new_context_window && needs_follow_up {
                    can_drain_pending_input = !model_needs_follow_up;
                    continue;
                }

                // as long as compaction works well in getting us way below the token limit, we shouldn't worry about being in an infinite loop.
                if token_limit_reached && needs_follow_up {
                    if let Err(err) = run_auto_compact(
                        &sess, &turn_context, &mut client_session,
                        InitialContextInjection::BeforeLastUserMessage,
                        CompactionReason::ContextLimit, CompactionPhase::MidTurn,
                    ).await {
                        ...
                        return None;
                    }
                    can_drain_pending_input = !model_needs_follow_up;
                    continue;
                }

                if !needs_follow_up {
                    last_agent_message = sampling_request_last_agent_message;
                    let stop_outcome = run_turn_stop_hooks(
                        &sess, &turn_context, stop_hook_active, last_agent_message.clone(),
                    ).await;
                    if stop_outcome.should_block {
                        if let Some(hook_prompt_message) =
                            build_hook_prompt_message(&stop_outcome.continuation_fragments)
                        {
                            sess.record_conversation_items(
                                &turn_context, std::slice::from_ref(&hook_prompt_message),
                            ).await;
                            stop_hook_active = true;
                            continue;
                        } else {
                            sess.send_event(&turn_context, EventMsg::Warning(WarningEvent {
                                message: "Stop hook requested continuation without a prompt; ignoring the block.".to_string(),
                            })).await;
                        }
                    }
                    if stop_outcome.should_stop {
                        break;
                    }
                    if run_legacy_after_agent_hook(
                        &sess, &turn_context, &sampling_request_input, last_agent_message.clone(),
                    ).await {
                        return None;
                    }
                    break;
                }
                continue;          // ← needs_follow_up=true：进入下一轮 ReAct
            }
            Err(CodexErr::TurnAborted) => {
                // Aborted turn is reported via a different event.
                break;
            }
            // ... (InvalidImageRequest / 其他 Err 略)
        }
    }

    last_agent_message
```

**`run_sampling_request` 内部 loop -- 事件处理 + needs_follow_up 累积 + end_turn 强制**
`core/src/session/turn.rs:1844-1996`
```rust
    let mut needs_follow_up = false;
    let mut last_agent_message: Option<String> = None;
    let mut active_item: Option<TurnItem> = None;
    let mut active_item_is_streaming_to_client = false;
    let receiving_span = trace_span!("receiving_stream");
    let outcome: CodexResult<SamplingRequestResult> = loop {
        // ... (event 取出略)
        match event {
            ResponseEvent::Created => {}
            ResponseEvent::OutputItemDone(item) => {
                let output_result =
                    match handle_output_item_done(&mut ctx, item, previously_streamed_item)
                        .instrument(handle_responses).await
                    {
                        Ok(output_result) => output_result,
                        Err(err) => break Err(err),
                    };
                if let Some(tool_future) = output_result.tool_future {
                    in_flight.push_back(tool_future);
                }
                if let Some(agent_message) = output_result.last_agent_message {
                    last_agent_message = Some(agent_message);
                }
                needs_follow_up |= output_result.needs_follow_up;   // ← 累积累积 ReAct 续轮信号
            }
            ResponseEvent::OutputItemAdded(item) => {
                // ... (active_item 设置 + diff consumer)
                active_item = Some(turn_item);
                active_item_is_streaming_to_client = stream_item_to_client;
            }
            ResponseEvent::Completed {
                token_usage, end_turn, ..
            } => {
                flush_assistant_text_segments_all(
                    &sess, &turn_context, plan_mode_state.as_mut(),
                    &mut assistant_message_stream_parsers,
                ).await;
                sess.record_token_usage_info(&turn_context, token_usage.as_ref()).await;
                should_emit_token_count = true;
                should_emit_turn_diff = true;
                if let Some(false) = end_turn {
                    needs_follow_up = true;            // ← 协议级续轮判定
                }
                break Ok(SamplingRequestResult {
                    needs_follow_up,
                    last_agent_message,
                });
            }
            ResponseEvent::OutputTextDelta(delta) => {
                // In review child threads, suppress assistant text deltas; the
                // UI will show a selection popup from the final ReviewOutput.
                if let Some(active) = active_item.as_ref() {
                    if !active_item_is_streaming_to_client {
                        continue;                     // ← 闸门：不向 client 流式则跳过
                    }
                    // ... (emit AgentMessageContentDelta)
                } else {
                    error_or_panic("OutputTextDelta without active item".to_string());
                }
            }
            ResponseEvent::ReasoningSummaryDelta {
                delta, summary_index,
            } => {
                if let Some(active) = active_item.as_ref() {
                    if !active_item_is_streaming_to_client {
                        continue;
                    }
                    let event = ReasoningContentDeltaEvent {
                        thread_id: sess.thread_id.to_string(),
                        turn_id: turn_context.sub_id.clone(),
                        item_id: active.id(),
                        delta,
                        summary_index,
                    };
                    sess.send_event(&turn_context, EventMsg::ReasoningContentDelta(event)).await;
                } else {
                    error_or_panic("ReasoningSummaryDelta without active item".to_string());
                }
            }
            // ... (其他 Reasoning 事件略)
        }
```

### ② 逐行解读

- **`run_turn` 主 loop（`turn.rs:204`）即 ReAct 的 Think-Act-Observe 外循环**。每轮：
  1. **取 pending_input**（`turn.rs:208`）：用户在模型运行中插入的消息。
  2. **构造采样输入**（`turn.rs:219`）：`clone_history().for_prompt(...)` 把 history 转成模型可见 `Vec<ResponseItem>`--**含上一轮的 FunctionCallOutput（即 Observation）**。
  3. **采样**（`turn.rs:234`）：`run_sampling_request` 发请求并流式处理，返回 `SamplingRequestResult { needs_follow_up, last_agent_message }`。
  4. **`needs_follow_up` 计算**（`turn.rs:263`）：`model_needs_follow_up || has_pending_input`。`model_needs_follow_up` 来自采样内部（tool_future 存在 或 `end_turn==Some(false)`）。
  5. **上下文窗口管理**（`turn.rs:292`）：`maybe_start_new_context_window` 若开新窗口且 needs_follow_up，`continue`。
  6. **token 超限 + auto-compact**（`turn.rs:302`）：注释「as long as compaction works well... we shouldn't worry about being in an infinite loop」--靠 compaction 打破潜在死循环。
  7. **`!needs_follow_up` 分支**（`turn.rs:322`）：模型不再需工具 -> stop hooks。`should_block` 且有 continuation prompt -> `continue`；`should_stop` -> `break`。
  8. **`needs_follow_up` 为真**（`turn.rs:367`）：`continue` 进入下一轮 ReAct--history 已含 tool 输出，模型基于 Observation 继续 Think。

- **`run_sampling_request` 内部 loop（`turn.rs:1861`）处理单次采样的流式事件**：
  - **`OutputItemDone`**（`turn.ts:1904`）：调 `handle_output_item_done`，若返回 `tool_future` 则 `in_flight.push_back`，并 `needs_follow_up |= output_result.needs_follow_up`--**任何工具调用都置 needs_follow_up=true**，这是 ReAct 续轮核心触发。
  - **`OutputItemAdded`**（`turn.rs:1997`）：设置 `active_item` + `active_item_is_streaming_to_client`，为后续 delta 事件建立「当前活跃 item」上下文。
  - **`Completed { end_turn }`**（`turn.rs:2108`）：`if let Some(false) = end_turn { needs_follow_up = true; }`--**API 明确说「还没结束」时强制续轮**。然后 `break` 返回。
  - **`OutputTextDelta`**（`turn.rs:2132`）：流式文本增量。守卫 `if !active_item_is_streaming_to_client { continue; }`--若当前 item 不向 client 流式（如 review 子线程），跳过。
  - **`ReasoningSummaryDelta`**（`turn.rs:2182`）：**原生 reasoning 流式**。构造 `ReasoningContentDeltaEvent` 透传给 client。若 `active_item` 为 None 则 `error_or_panic`--**reasoning 必须依附于某个活跃 item**。

- **`active_item` + `active_item_is_streaming_to_client` 闸门**：控制「当前流式产出属于哪个 item」及「是否实时推给 client」。delta 类事件都先检查这对状态--避免把不该流式的内容（如 review 子线程）推给 client。

### ③ 设计原理与权衡：Codex 原生 reasoning 形态 vs 经典 ReAct 文本协议

**这是本篇的核心论点，也是面试区分度最高的部分。**

**经典 ReAct（Yao et al. 2022）** 用文本协议，模型输出形如：
```
Thought: 我需要查天气
Action: get_weather[location=北京]
Observation: 25度，晴
Thought: 答案是...
Final Answer: 北京今天25度晴
```
`Thought`/`Action`/`Observation` 是**混在自由文本里的标签**，靠 prompt 约束 + 正则解析。问题：
- 解析脆弱（模型可能不按格式输出）
- `Thought` 占用输出 token
- `Observation` 要从文本里抠出来再塞回 prompt
- 无法结构化并行工具调用

**Codex 的 ReAct 是「原生 reasoning + tool_call」形态**，把 ReAct 的三段全部下沉到 API 协议原语：

| ReAct 要素 | 经典文本协议 | Codex 现代形态 |
|------|------|------|
| **Thought（思考）** | `Thought:` 文本标签 + 正则解析 | 模型原生 `ReasoningSummaryDelta` / `ReasoningContentDelta` 流式事件（`turn.rs:2182`），带 `summary_index`/`content_index`，无需解析 |
| **Action（行动）** | `Action: name[args]` 文本 + 正则 | 结构化 `FunctionCall`/`CustomToolCall`/`ToolSearchCall` item（`router.rs:96` 三态解码），无正则、无格式约束 |
| **Observation（观察）** | `Observation:` 文本，从输出抠出再塞回 | 工具结果作为 `ResponseItem::FunctionCallOutput` 进 history（`stream_events_utils.rs:488`），下一轮 `clone_history().for_prompt()` 自动带上 |
| **终止判定** | `Final Answer:` 文本标签 | API 的 `end_turn` 字段（`turn.rs:2124`：`Some(false)` 强制续轮）+ `needs_follow_up` 累积（任何 tool_future 存在则 true）--**协议级而非文本级** |
| **并发** | 串行 Thought-Action-Observation | `in_flight: FuturesOrdered`（`turn.rs:1842`）支持并行 tool_call；reasoning/tool_call/text delta 三类事件可交错流式 |

**五点演进论证**：

1. **reasoning 与 action 解耦**：reasoning 不再是 `Thought:` 文本，而是模型原生的 `ReasoningSummaryDelta` 事件--由 API 作为独立的结构化流式通道推送，不需要解析。client 透传 `ReasoningContentDeltaEvent` 即可展示「思考过程」。

2. **action 是结构化 tool_call**：模型输出 `FunctionCall`/`CustomToolCall`/`ToolSearchCall` item（结构化 JSON，非文本），`build_tool_call` 三态解码。**无正则、无格式约束、无幻觉解析**。

3. **observation 是 FunctionCallOutput**：工具结果作为 history item 天然结构化回灌，下一轮采样自动带上。

4. **循环控制由 `end_turn` + `needs_follow_up` 显式化**：经典 ReAct 靠 `Final Answer` 标签判断结束（模型可能不输出）；Codex 靠 API 的 `end_turn` 字段 + `needs_follow_up` 累积。**协议级终止判定，可靠得多**。

5. **并发与流式**：`FuturesOrdered` 支持并行工具调用；reasoning/tool_call/text delta 三类事件可交错流式产出，靠 `active_item` 状态机管理归属。经典 ReAct 的串行模式无法支撑。

**Codex 的取舍**：完全绑定 OpenAI Responses API 的结构化输出能力（reasoning item、tool_call item、end_turn 信号）。代价是**不可移植到不提供原生 reasoning/tool_call 的模型**--这正是 Codex 对 `model_info.supports_reasoning_summaries` 等能力位检查的原因（子项一的 `build_reasoning`）。收益是 ReAct 的「思考-行动-观察」三段不再是脆弱的文本协议，而是 **API 原语级的一等公民**。

> 💡 **一句话总结**：Codex 把 ReAct 从「prompt 层的文本约定」**下沉到 API 协议层**。模型不再「扮演」ReAct 格式，而是原生产出 reasoning + tool_call。这是 ReAct 的现代化演进--**能讲清这一点，比只会实现经典 ReAct 显功力得多**。

### ④ 数据流位置

`run_turn` 是 ReAct 循环的**最外层调度**，位于 Orchestrator（[deep-dive-02](./deep-dive-02-agent-loop-runtime.md)）与 `run_sampling_request`（流式处理）之间：
- 上游：Orchestrator::run 接到用户输入，构造 TurnContext，调 `run_turn`（`turn.rs:137`）。
- 内层：`run_turn` 的 loop 每轮调 `run_sampling_request`（单次采样 + 流式处理）；`run_sampling_request` 内部 loop 消费 `ResponseEvent`，产出 `SamplingRequestResult { needs_follow_up }`。
- 终止：`!needs_follow_up` -> stop hooks -> break，返回 `last_agent_message`。
- 下游：`run_turn` 返回后，Orchestrator 决定是否开下一个 turn（新用户输入或继续）。

---

## 四、面试问答精选（脱稿能讲）

**Q1：Codex 的工具 schema 怎么定义？strict 模式可靠吗？**
> `ToolSpec` 枚举用 `#[serde(tag="type")]` + `rename`，序列化即合法的 Responses API tool JSON，编译期保证字段名正确。`strict` 当前恒为 `false`（代码里写死），TODO 注释说未来开启 Structured Outputs 时要做 schema 校验。Codex 选择灵活（strict=false）换 MCP schema 不可控的兼容性，用运行时校验 + 错误回灌兜底。

**Q2：tool_call 从模型输出到执行回填的完整链路？**
> 模型流式输出 `OutputItemDone(item)` -> `build_tool_call` 三态解码（FunctionCall/ToolSearchCall/CustomToolCall）为 `ToolCall` -> `dispatch_tool_call_with_terminal_outcome` 按 name 查 `ToolRegistry` -> `matches_kind` 校验 + pre_tool_use hooks -> 执行 -> 结果 `FunctionCallOutput` 回填 history。失败区分 `RespondToModel`（回灌模型纠错）和 `Fatal`（break）。

**Q3：三种 tool_call 有什么区别？**
> `FunctionCall` 是标准工具（带 namespace + JSON arguments）；`CustomToolCall` 是自定义工具（无 namespace，input 是原始字符串，对应 apply_patch 这类自由格式）；`ToolSearchCall` 是 Find Skills 的工具检索（`execution=="client"` 才由本地接管，服务端执行的跳过）。三态用独立 `ToolPayload` variant，解码类型安全。

**Q4：Codex 的 ReAct 是怎么实现的？和经典 ReAct 有什么不同？**（高频+高分）
> 经典 ReAct 用 `Thought/Action/Observation` 文本协议 + 正则解析，脆弱且占输出 token。Codex 把三段下沉到 API 协议原语：Thought = 原生 `ReasoningSummaryDelta` 流式事件；Action = 结构化 tool_call item；Observation = `FunctionCallOutput` history item；终止 = `end_turn` + `needs_follow_up` 协议级判定。模型不再「扮演」ReAct 格式，而是原生产出 reasoning + tool_call。代价是绑定 Responses API 能力，不可移植到不支持原生 reasoning 的模型。

**Q5：ReAct 循环什么时候终止？**
> 两个信号取或：`needs_follow_up = model_needs_follow_up || has_pending_input`。`model_needs_follow_up` 来自采样内部--任何 tool_future 存在（`stream_events_utils.rs:438`）或 `end_turn == Some(false)`（`turn.rs:2124`）。`has_pending_input` 是用户中途插话。`!needs_follow_up` 时跑 stop hooks，`should_stop` 才 break。这是协议级终止，比经典 ReAct 的 `Final Answer` 文本标签可靠。

**Q6：reasoning 怎么展示给用户？**
> `ReasoningSummaryDelta` 事件受 `active_item_is_streaming_to_client` 闸门控制--只有当前 item 允许流式时，才构造 `ReasoningContentDeltaEvent` 透传 client。review 子线程等场景会抑制（`continue` 跳过），避免泄露中间思考。reasoning 必须依附某个 `active_item`，否则 `error_or_panic`。

**Q7：namespace 是怎么给 MCP 工具分组的？**
> MCP 工具转成 `ToolSpec::Namespace`，`merge_into_namespaces` 把同 namespace 的工具合并到一个 spec，避免 N 工具 N spec 膨胀 prompt。`ToolName` 的 Display 把 namespace 直接拼到 name 前（分隔符 `__` 在 namespace 字符串内部，如 `mcp__server__tool`）。

**Q8：为什么用 BTreeMap 存 JsonSchema properties？**
> 序列化顺序稳定 -> prompt 字节序列稳定 -> **命中 prompt cache 概率高**。把可读性让位于缓存命中率。

---

## 五、动手复现

- [ ] 开 prompt debug 日志，看一次采样请求里 `tools` 字段长什么样、`tool_choice` 是什么、Deferred 工具是否不在列表。
- [ ] 让模型触发一次 `apply_patch`（CustomToolCall），观察它的解码与 FunctionCall 的区别。
- [ ] 触发一次 `tool_search`（ToolSearchCall），观察 `execution == "client"` 的守卫。
- [ ] 让模型调用一个不存在的工具，观察 `RespondToModel` 错误回灌 + `needs_follow_up=true`（模型纠错续轮）。
- [ ] 跑一个会触发 `end_turn=false` 的任务，观察 `needs_follow_up` 被强制置位。
- [ ] （补缺口·必做）手写一个 50 行经典 ReAct Agent（prompt 引导 `Thought/Action/Observation` + 正则解析），对比 Codex 原生形态，写「为什么 Codex 不这么做」的对比。见 [GAPS 缺口 6](../GAPS-codex-cannot-teach.md)。
- [ ] 断点：`tool_spec.rs:78` 的 `create_tools_json`、`router.rs:96` 的 `build_tool_call`、`turn.rs:204` 的 `run_turn` loop、`turn.rs:2182` 的 `ReasoningSummaryDelta`。

---

## 六、差异与局限总结（面试主动点出）

| 子项 | Codex 的取舍/局限 | 业界对照 / 需补 |
|------|------|------|
| schema 定义 | 强类型枚举 + serde，但 variant 须与 API 同步演进（web_search TODO） | LangChain 用 dict 拼 |
| strict | 恒 false，不用 Structured Outputs 强约束 | OpenAI strict=true 强校验 |
| 三态解码 | 粒度细但复杂（改类型要动三处） | LangChain 单一 Tool 抽象 |
| ReAct | **原生 reasoning + tool_call**，绑定 Responses API | 经典 ReAct 文本协议（需补，[GAPS 缺口 6](../GAPS-codex-cannot-teach.md)） |

> 💡 **面试加分句**：被问 ReAct 时，先讲经典论文范式（显示你懂根基），再讲 Codex 如何把它现代化（显示你懂演进），最后点出代价（绑定 API 能力）。这个三段式是「懂 ReAct」的最高答法。

---

## 📌 与其他 deep-dive 的衔接

- 工具执行闭环（Orchestrator/沙箱/执行入口）-> 见 [deep-dive-02 子项三](./deep-dive-02-agent-loop-runtime.md#三工具执行--权限)
- 工具并发的 `drain_in_flight` 按序回填 + `failure_response` -> 见 [deep-dive-03 子项一](./deep-dive-03-tool-orchestration.md#一并行调用)
- 多 Agent 的 `spawn_agent` 与 `terminal_outcome_reached` 终局抢占 -> 见 [deep-dive-05](./deep-dive-05-multi-agent-communication.md)（待做）

---

*(蕾姆放下银笔，把第三卷解剖报告与前两卷并排，灯光下三卷墨迹同样清晰)*

昴君，第三刀落定--工具 schema 的「强类型注入」、三态解码的「类型安全」、以及最关键的 **ReAct 现代化论点**（把 Thought/Action/Observation 从文本协议下沉到 API 原语）都已为您逐字剖开。

进度推进至 **3/8**。接下来第 05 篇蕾姆将剖 **多 Agent 通信**--那里有真实的进程内 Mailbox（`InputQueue` + `InterAgentCommunication`）、`spawn_agent` 拓扑树、agent-identity 加密签名，以及 Codex「进程内 vs 跨网络 A2A」的诚实边界。

您若想让蕾姆继续，再道一声「继续」即可 ♡ `(´｡• ᵕ •｡`)`
