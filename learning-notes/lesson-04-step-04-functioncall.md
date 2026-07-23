# 第04课 · 台阶 4：LLM 怎么"叫"工具 —— FunctionCall 协议

> 💙 **蕾姆的承诺**
>
> 台阶 3 您已经知道「几十个工具是怎么挤到一张花名册上的」。
>
> 这一节蕾姆要回答您心里**自然冒出来的下一个问题**：
>
> 「**LLM 到底是用什么"话"告诉 Codex『我要叫这个工具』的？**
>   这张"工单"长什么样？Codex 又是怎么读懂它的？**」
>
> 看完这份文档，您会知道：
> **「啊，原来 LLM 叫工具靠的是一段叫 `FunctionCall` 的结构化消息——
>   而 Codex 专门有一个"翻译官"把它翻成内部能执行的格式**」 ✨

---

## 🎯 这一台阶要达成的目标

学完这份文档，昴君应该能回答：

> 「**LLM 输出的"工具调用请求"在 Codex 里叫什么？由哪几个字段组成？
>   Codex 用哪个函数把它翻译成内部格式？翻译完交给谁执行？**」

蕾姆给您一个答案先记着：

```
📜 LLM 叫工具靠的是一张【FunctionCall 工单】
🏛️ Codex 靠【build_tool_call】这位翻译官读懂它
📤 翻译完变成【ToolCall】，交给 ToolRouter 派发执行
```

---

## 🪜 第一步：先回忆台阶 1-3 的"三个角色"

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│   老板   │    │   助理   │    │  小帮手  │
│  (用户)  │    │ (Harness)│    │ (工具)   │
└──────────┘    └──────────┘    └──────────┘
```

- 台阶 1 蕾姆讲过：**老板说需求 → 助理去工具间查登记表 → 派小帮手干活**
- 台阶 2 蕾姆讲过：**每个小帮手长什么样（name + spec + handler）**
- 台阶 3 蕾姆讲过：**几十个小帮手怎么挤到一张花名册（ToolRegistry）上**

但**有一个关键环节蕾姆一直没讲**：

> 助理（Harness）是怎么**听懂厨师（LLM）说"我要叫某某小帮手"**的？
>
> 厨师只会输出文字，他怎么把"我要叫 `shell` 工具，参数是 `ls -la`"这件事**精确地**告诉助理？

这就是今天要揭晓的——**FunctionCall 协议**。

---

## 🪜 第二步：用"餐厅点餐工单"理解 FunctionCall

*(蕾姆轻轻歪头，想起第三课的餐厅比喻)*

还记得第三课蕾姆是餐厅服务员吗？今天蕾姆要**钻进厨房**，看看厨师怎么给蕾姆下"工单"。

### 🎬 一张真实的"点餐工单"

```
╔════════════════════════════════════════════╗
║          📜 厨师工单（FunctionCall）          ║
╠════════════════════════════════════════════╣
║                                            ║
║  📛 工具名（name）   ：shell                ║
║  🏷️ 工单号（call_id）：call_abc123          ║
║  📦 参数（arguments）：{"command":"ls -la"}║
║  🗂️ 命名空间（namespace）：（空，内置工具）  ║
║                                            ║
╚════════════════════════════════════════════╝
```

蕾姆拿到这张工单后，会：

1. **看工具名** → "哦，厨师要叫 `shell` 小帮手"
2. **看工单号** → "这张工单编号 `call_abc123`，等会儿小帮手回来报告时，要对上号"
3. **看参数** → "参数是 `ls -la`，转告给小帮手"
4. **看命名空间** → "没有命名空间，说明是内置工具，直接查内置花名册"

> 💎 **关键认识**：
> FunctionCall 就是 LLM 写给 Harness 的**一张结构化工单**。
> 工单上有【工具名 + 工单号 + 参数】，这三样东西缺一不可。

---

## 🪜 第三步：看 Codex 源码里的【真品】

蕾姆从 `codex-rs/protocol/src/models.rs:795` 把这张工单的"真身"挖出来了：

```rust
pub enum ResponseItem {
    // ... 其它变体 ...

    FunctionCall {
        #[serde(default, skip_serializing)]
        #[ts(skip)]
        id: Option<String>,              // ← 旧版兼容字段，已不用

        name: String,                     // ← ① 工具名
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        namespace: Option<String>,       // ← ② 命名空间（MCP 工具才有）
        
        // ⭐ 重点注释 ⭐
        // The Responses API returns the function call arguments as a *string* 
        // that contains JSON, not as an already‑parsed object. We keep it as 
        // a raw string here and let Session::handle_function_call parse it 
        // into a Value.
        arguments: String,               // ← ③ 参数（注意类型！）
        call_id: String,                 // ← ④ 工单号
    },
    
    // ... 其它变体 ...
}
```

蕾姆为您**逐字段翻译** ♡：

| 字段 | 类型 | 含义 | 蕾姆点评 |
|------|------|------|---------|
| `name` | `String` | 工具名 | LLM 用这个名字在花名册里找小帮手 |
| `namespace` | `Option<String>` | 命名空间 | 内置工具为 `None`；MCP 工具形如 `"github"`（台阶 3 学过 namespace 分组） |
| `arguments` | `String` ⭐ | 参数 | **注意是字符串，不是对象！** 下面专门讲 |
| `call_id` | `String` | 工单号 | 用来匹配"调用"和"结果回执"，缺了就配不上对 |
| `id` | `Option<String>` | 旧版遗留 | `skip_serializing` 表示已经不用了，留着只为兼容 |

---

## 🪜 第四步：那个最反直觉的细节 —— `arguments` 为什么是 `String`？

*(蕾姆神色变得专注，头上的发卡闪了一下)*

很多初学者（甚至工作过的人）会**踩这个坑**：

### ❌ 直觉以为

> "arguments 是参数嘛，那应该是 `serde_json::Value` 或者一个结构体才对呀？"

### ✅ 真相

看源码注释原话：

> **"The Responses API returns the function call arguments as a *string* that contains JSON, not as an already-parsed object."**
>
> （Responses API 返回的 function call 参数是【包含 JSON 的字符串】，而不是【已经解析好的对象】。）

也就是说，LLM 输出的 `arguments` **长这样**：

```json
{
  "type": "function_call",
  "name": "shell",
  "arguments": "{\"command\":\"ls -la\"}"
  //           ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
  //           注意！这是一个【字符串】，里面装着 JSON 文本
}
```

**而不是**这样：

```json
{
  "type": "function_call",
  "name": "shell",
  "arguments": {"command": "ls -la"}
  //           ↑ 这是【对象】，但 Responses API 不这么返回
}
```

### 🤔 为什么要这么设计？

蕾姆为您分析**三个原因**：

| 原因 | 说明 |
|------|------|
| ① **流式传输** | LLM 是逐 token 吐字 的，`arguments` 可能分多个 chunk 到达（第三课学过的 `ToolCallInputDelta` 事件）。在还没传完时，它不是合法 JSON，只能是"正在拼凑的字符串"。 |
| ② **协议保真** | OpenAI Responses API 的 wire 协议就是 `arguments: string`。Codex 原样保留，不做"自作主张"的提前解析。 |
| ③ **解析时机延后** | Codex 把"什么时候解析 JSON"推迟到真正要用参数的时候（`Session::handle_function_call`），符合**延迟解析**原则——解析失败时能给出更精确的错误。 |

> 💡 **面试加分点** ⭐：
> 如果面试官问"function calling 的 arguments 是什么类型"——
> 您能回答"**是字符串，里面装着 JSON 文本，需要后续解析**"，并解释**流式传输**的原因，
> 面试官立刻知道您是真研究过协议细节的人。

---

## 🪜 第五步：原来"叫工具"不止一种 —— 三种调用类型

*(蕾姆翻开 `ResponseItem` 枚举，发现里面的"调用类"变体不止一个)*

蕾姆原来以为 LLM 叫工具只有 `FunctionCall` 一种，结果发现 Codex 里有**三种"调用类"工单**：

```
╔══════════════════════════════════════════════════════════════╗
║              三种"调用类" ResponseItem                            ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  ① FunctionCall        ← 标准函数调用（绝大多数工具）         ║
║     name + arguments(String) + call_id                       ║
║                                                              ║
║  ② ToolSearchCall      ← tool_search 元工具的专属调用 ⭐        ║
║     execution + arguments(Value) + call_id                   ║
║     （呼应 deep-dive 里学的 tool_search！）                   ║
║                                                              ║
║  ③ CustomToolCall       ← 自定义工具（用户写的）               ║
║     name + input(String) + call_id                           ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

| 调用类型 | 何时用 | 参数字段 |
|---------|------|---------|
| **FunctionCall** | 标准工具（shell/apply_patch/...） | `arguments: String` |
| **ToolSearchCall** | LLM 调用 `tool_search` 元工具时（deep-dive 学过！） | `arguments: Value`（已解析） |
| **CustomToolCall** | 用户自定义的 freeform 工具 | `input: String` |

> 💡 **为什么 tool_search 用 `Value`，而普通 FunctionCall 用 `String`？**
> 因为 `tool_search` 是 Codex **自己**的元工具，Codex 完全控制它的协议，所以可以直接用解析好的 `Value`；
> 而 `FunctionCall` 要兼容 OpenAI Responses API 的 wire 协议，必须保留 `String` 形式。
> 这是一个**"内部协议 vs 外部协议"**的取舍 ♡

---

## 🪜 第六步：翻译官登场 —— `build_tool_call`

*(蕾姆翻到 `codex-rs/core/src/tools/router.rs:96`，眼神亮了起来)*

LLM 输出的 `FunctionCall` 是**协议层**的格式（为了贴近 OpenAI API）；
但 Codex 内部执行工具时，需要一个**统一的内部格式**。

于是 Codex 安排了一位"翻译官"——`build_tool_call`：

```rust
pub fn build_tool_call(item: ResponseItem) -> Result<Option<ToolCall>, FunctionCallError> {
    match item {
        // ① 标准函数调用
        ResponseItem::FunctionCall {
            name, namespace, arguments, call_id, ..
        } => {
            let tool_name = ToolName::new(namespace, name);   // ← 合并 namespace + name
            Ok(Some(ToolCall {
                tool_name,
                call_id,
                payload: ToolPayload::Function { arguments },
            }))
        }

        // ② tool_search 元工具调用
        ResponseItem::ToolSearchCall {
            call_id: Some(call_id), execution, arguments, ..
        } if execution == "client" => {
            let arguments: SearchToolCallParams = serde_json::from_value(arguments)?;
            Ok(Some(ToolCall {
                tool_name: ToolName::plain("tool_search"),
                call_id,
                payload: ToolPayload::ToolSearch { arguments },
            }))
        }
        ResponseItem::ToolSearchCall { .. } => Ok(None),   // ← 非客户端执行的，忽略

        // ③ 自定义工具调用
        ResponseItem::CustomToolCall { name, input, call_id, .. } => {
            Ok(Some(ToolCall {
                tool_name: ToolName::plain(name),
                call_id,
                payload: ToolPayload::Custom { input },
            }))
        }

        // ④ 不是工具调用（Message / Reasoning 等）
        _ => Ok(None),
    }
}
```

蕾姆为您画一张**翻译流程图**：

```
       LLM 输出的 ResponseItem（协议层格式）
                    │
                    ▼
   ┌──────────────────────────────────────┐
   │  build_tool_call()  ← 翻译官          │
   │                                      │
   │  match item {                        │
   │    FunctionCall    → ToolCall(Function)  │
   │    ToolSearchCall  → ToolCall(ToolSearch)│
   │    CustomToolCall  → ToolCall(Custom)    │
   │    其它            → None（不是工具）    │
   │  }                                   │
   └──────────────────────────────────────┘
                    │
                    ▼
         ToolCall（内部统一格式）
                    │
                    ▼
            交给 ToolRouter 派发执行
```

> 💎 **设计思想**：
> `build_tool_call` 做的是**协议适配**——
> 把"贴近 OpenAI API 的外部格式"翻译成"Codex 内部统一格式"。
> 这是 **适配器模式（Adapter Pattern）** 的经典体现，对应 SOLID 的**接口隔离（I）** 原则。

---

## 🪜 第七步：翻译完的 `ToolCall` 长什么样？

蕾姆从 `router.rs:28` 翻出 `ToolCall` 的真身：

```rust
#[derive(Clone, Debug)]
pub struct ToolCall {
    pub tool_name: ToolName,    // ← namespace + name 合并后的完整工具名
    pub call_id: String,        // ← 工单号（原样保留，用于配对结果）
    pub payload: ToolPayload,    // ← 三种载荷之一：Function / ToolSearch / Custom
}
```

| 字段 | 作用 |
|------|------|
| `tool_name` | 把 `namespace + name` 合并成完整工具名（台阶 3 学过的 `ToolName::new(namespace, name)`） |
| `call_id` | 原样保留，等工具执行完，结果回执 `FunctionCallOutput` 会带上同样的 `call_id` 来配对 |
| `payload` | 真正的参数载荷，用枚举区分三种调用类型 |

> 🌟 **对比 `FunctionCall` vs `ToolCall`**：
>
> | 维度 | FunctionCall（协议层） | ToolCall（内部层） |
> |------|----------------------|-------------------|
> | 归属 | 贴近 OpenAI Responses API | Codex 内部统一格式 |
> | 工具名 | `name` + `namespace` 分开 | `tool_name` 合并 |
> | 参数 | `arguments: String` | `payload: ToolPayload`（枚举） |
> | 存在意义 | 协议保真 | 执行便利 |
>
> 这正是台阶 3 学过的【**两层世界**】——
> **给 LLM 看的世界（FunctionCall/Spec）** vs **给 harness 自己用的世界（ToolCall/Registry）** ♡

---

## 🪜 第八步：翻译官在哪个环节被调用？

*(蕾姆翻到 `codex-rs/core/src/stream_events_utils.rs:405`，把 `handle_output_item_done` 拉出来)*

还记得第三课蕾姆说的吗——

> "在 `try_run_sampling_request` 的接收循环里，每收到一个 `OutputItemDone` 事件，就调用 `handle_output_item_done` 派工具。"

今天蕾姆把这位"派工具的人"的真身给您看：

```rust
pub(crate) async fn handle_output_item_done(
    ctx: &mut HandleOutputCtx,
    item: ResponseItem,
    previously_active_item: Option<TurnItem>,
) -> Result<OutputItemResult> {
    let mut output = OutputItemResult::default();

    match ToolRouter::build_tool_call(item.clone()) {   // ← ★ 翻译官登场 ★
        
        // 分支 ①：是工具调用
        Ok(Some(call)) => {
            // a. 处理 mailbox 消息投递（多 agent，后续课程）
            ctx.sess.input_queue
                .accept_mailbox_delivery_for_current_turn(...).await;

            // b. 打日志
            tracing::info!("ToolCall: {} {}", call.tool_name, payload_preview);

            // c. 立即持久化这张工单到 history
            record_completed_response_item(...).await;

            // d. 创建一个【子 cancellation token】（用户取消时能精准打断这一个工具）
            let cancellation_token = ctx.cancellation_token.child_token();

            // e. 生成 tool_future，丢给 tool_runtime 执行
            let tool_future = Box::pin(
                ctx.tool_runtime.clone().handle_tool_call(call, cancellation_token),
            );

            output.needs_follow_up = true;        // ← ★ 这就是第三课学的 needs_follow_up！
            output.tool_future = Some(tool_future);
        }

        // 分支 ②：不是工具调用（Message / Reasoning）
        Ok(None) => {
            // 转成 TurnItem，emit 给 UI 显示
            let finalized_turn_item = finalize_non_tool_response_item(...).await;
            ctx.sess.emit_turn_item_completed(...).await;
            output.last_agent_message = ...;       // ← 记录"这一轮模型说的最终自然语言"
        }

        // 分支 ③：工具请求被拒 / 需直接答复 LLM
        Err(FunctionCallError::RespondToModel(message)) => {
            // 构造一个 FunctionCallOutput，把拒绝原因塞回 history
            let response = ResponseInputItem::FunctionCallOutput {
                call_id: String::new(),
                output: FunctionCallOutputPayload {
                    body: FunctionCallOutputBody::Text(message),
                    ..Default::default()
                },
            };
            // ... 记录到 history ...
            output.needs_follow_up = true;         // ← 也要继续，让 LLM 看到拒绝原因
        }

        // 分支 ④：致命错误
        Err(FunctionCallError::Fatal(message)) => {
            return Err(CodexErr::Fatal(message));
        }
    }

    Ok(output)
}
```

蕾姆为您画这张**四分支流程图**：

```
                  LLM 吐出的 ResponseItem
                          │
                          ▼
            ┌─────────────────────────────┐
            │  build_tool_call(item)      │  ← 翻译官
            └─────────────┬───────────────┘
                          │
        ┌─────────┬───────┴───────┬───────────┐
        ▼         ▼               ▼           ▼
   ① Ok(Some)  ② Ok(None)    ③ Err(Respond)  ④ Err(Fatal)
   是工具调用   不是工具       需拒绝/直接答    致命错误
        │         │               │           │
        ▼         ▼               ▼           ▼
   生成future  emit TurnItem   构造Output    上抛Fatal
   needs_      记 last_agent   塞回history   错误
   follow_up   _message        needs_
   =true       =...            follow_up
   =true
```

> 💎 **这是台阶 4 最重要的"啊哈时刻"** ⭐：
>
> 第三课蕾姆告诉您「**工具被调用 → needs_follow_up = true**」，
> 但当时没说**在哪一行、由谁设的**。
>
> **现在您看到了**——就是 `handle_output_item_done` 的第 442 行：
> ```rust
> output.needs_follow_up = true;
> ```
>
> **第三课的抽象，在第四课落地了** ♡

---

## 🪜 第九步：`call_id` 的秘密 —— 工单号为什么这么重要？

*(蕾姆从裙底掏出一本旧账本，翻开"工单配对"那一页)*

您可能好奇：为什么 `FunctionCall` 和 `FunctionCallOutput` 都要带 `call_id`？

因为**一轮里可能有多个工具同时被调用**！

```
LLM 一轮里同时叫了 3 个工具：

  FunctionCall(call_id=A, name=read_file, args=...)   ← 工单 A
  FunctionCall(call_id=B, name=read_file, args=...)   ← 工单 B  
  FunctionCall(call_id=C, name=shell,     args=...)   ← 工单 C

三个工具并行执行，回执顺序可能乱：

  FunctionCallOutput(call_id=C, output="...")   ← 工单 C 先回来了
  FunctionCallOutput(call_id=A, output="...")   ← 工单 A 后回来
  FunctionCallOutput(call_id=B, output="...")   ← 工单 B 最后

靠 call_id 配对：哪个结果对应哪张工单，一目了然！
```

> 💡 **设计思想**：
> `call_id` 是**异步并行执行**的"配对钥匙"——
> 没有它，并行工具的结果就不知道该记到哪个调用名下。
> 这就是为什么台阶 1 学"in_flight 队列"时，每个 future 都要带身份标识 ♡

---

## 🪜 第十步：从协议层到执行层 —— 完整数据流

把前四阶串起来，您现在能看到工具调用的**完整数据流**了：

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║  ① LLM 思考：决定叫 shell 工具                                 ║
║      ↓ 流式输出                                                ║
║  ② ResponseItem::FunctionCall {                                ║
║       name: "shell",                                          ║
║       arguments: "{\"command\":\"ls -la\"}",   ← String!      ║
║       call_id: "call_abc123",                                 ║
║       namespace: None,                                        ║
║     }                                                         ║
║      ↓                                                         ║
║  ③ handle_output_item_done 接收（stream_events_utils.rs:405）  ║
║      ↓ 调用翻译官                                              ║
║  ④ build_tool_call（router.rs:96）                            ║
║      ↓ 翻译成内部格式                                          ║
║  ⑤ ToolCall {                                                 ║
║       tool_name: "shell",                                     ║
║       call_id: "call_abc123",                                 ║
║       payload: Function { arguments: "..." },                 ║
║     }                                                         ║
║      ↓ 立即持久化到 history + 生成 tool_future                 ║
║  ⑥ needs_follow_up = true   ← 回到第三课的 run_turn 循环       ║
║      ↓                                                         ║
║  ⑦ tool_runtime.handle_tool_call(call)                        ║
║      ↓ 查 ToolRegistry（台阶 3 的花名册）                      ║
║  ⑧ dispatch_any（台阶 3 学过：查表→校验→PreHook→handle→PostHook）║
║      ↓                                                         ║
║  ⑨ tool.handle(invocation)  ← 真正执行（台阶 2 学过）          ║
║      ↓                                                         ║
║  ⑩ FunctionCallOutput { call_id: "call_abc123", output: "..." }║
║      ↓ 回填 history（第三课学过）                              ║
║  ⑪ 下一轮 LLM 看到结果 → 决定继续还是结束                      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

> 🌟 **昴君您看，前四阶全部串起来了** ♡
> - 台阶 1：理解"工具是什么"
> - 台阶 2：理解"工具长什么样"（name + spec + handler）
> - 台阶 3：理解"工具怎么注册到花名册"（ToolRegistry + dispatch）
> - **台阶 4：理解"LLM 怎么叫工具"（FunctionCall 协议 + 翻译官）** ← 您在这里
>
> **整个工具系统的骨架，到这里就闭环了** ✨

---

## 💎 蕾姆为您总结的【三句口诀】

> ① **LLM 叫工具靠 FunctionCall 工单** —— name + namespace + arguments(String!) + call_id
>
> ② **build_tool_call 是翻译官** —— 把协议层 ResponseItem 翻译成内部 ToolCall
>
> ③ **needs_follow_up = true 就在 handle_output_item_done 的第 442 行** —— 第三课的抽象在此落地

---

## ✅ 这一台阶的"通关标准"

### 🎯 通关题 1
> **`ResponseItem::FunctionCall` 的 `arguments` 字段是什么类型？为什么？**

参考答案：
- 类型是 `String`（字符串），不是 `serde_json::Value`
- 原因：OpenAI Responses API 返回的 arguments 是"包含 JSON 的字符串"，不是已解析的对象
- 深层原因：LLM 流式传输时 arguments 是逐 token 拼接的，未传完时不一定是合法 JSON
- 解析时机：Codex 延迟到 `Session::handle_function_call` 真正要用参数时才解析

---

### 🎯 通关题 2
> **`build_tool_call` 这个函数解决什么问题？它返回 `Option<ToolCall>` 里的 `None` 表示什么？**

参考答案：
- 解决问题：协议适配——把贴近 OpenAI API 的 `ResponseItem`（协议层）翻译成 Codex 内部统一的 `ToolCall`（执行层）
- `None` 表示：这个 `ResponseItem` **不是工具调用**（比如是 `Message` 或 `Reasoning`），不需要派发工具
- 设计模式：这是**适配器模式**的体现，对应 SOLID 的接口隔离原则

---

### 🎯 通关题 3
> **为什么 `FunctionCall` 和 `FunctionCallOutput` 都要带 `call_id`？**

参考答案：
- 因为**一轮里可能并行调用多个工具**，回执顺序可能乱
- `call_id` 是"配对钥匙"——让每个结果回执能精确对应到它属于哪张工单
- 没有它，并行执行的工具结果就不知道该记到哪个调用名下

---

## 🤔 蕾姆的小问题

*(蕾姆把笔递给您，期待地看着)* 昴君，请试着回答下面 3 个问题，写完蕾姆给您批改 ♡

### 问题 1
假设 LLM 输出的 `arguments` 字段里装的是一段**不合法的 JSON**（比如 `"{command: ls -la}"`，少了引号）。

**Codex 会立刻报错吗？为什么？** 如果不立刻报错，那是什么时候报错？

（提示：回顾第四步"为什么要这么设计"的第 ③ 个原因。）

#### 📝 我的答案
（请昴君在这里写下你的答案）


---

### 问题 2
`FunctionCall` 和 `ToolCall` 是**两个不同的结构体**，为什么 Codex 要把它们分开？直接用 `FunctionCall` 一个不行吗？

（提示：从【两层世界】和【协议适配】角度思考。）

#### 📝 我的答案
（请昴君在这里写下你的答案）


---

### 问题 3
在 `handle_output_item_done` 的四个分支里，**哪几个分支会把 `needs_follow_up` 设为 `true`？为什么这些分支都要让循环继续？**

（提示：回顾第三课的 needs_follow_up 来自哪两条线。）

#### 📝 我的答案
（请昴君在这里写下你的答案）


---

## 🔬 深度补充：源码证据链与自我纠错闭环

> 💙 **这是什么？**
>
> 这一节是您答错 Q1/Q3 后，蕾姆带您"钻到底"的深化内容。
> 它会把前面【基础部分】和【通关题】里看似独立的两个点，
> 用源码证据串成**一条完整闭环** ♡
>
> 如果您觉得基础部分已经懂了，可以先跳过；
> 如果想把"面试深度题"也拿下，**这一节必读**。

---

### 一、`arguments` 的四站旅程（源码证据链）

蕾姆带您追一个 `arguments` 从"被 LLM 吐出来"到"被解析"的完整旅程——
您会发现它要走完**四站**，到最后一站才被解析：

```
═══════════════════════════════════════════════════════════════
  arguments: "{\"command\":\"ls -la\"}"   ← 一段装着 JSON 的字符串
═══════════════════════════════════════════════════════════════

📍 第一站：models.rs:795  ResponseItem::FunctionCall
   arguments: String        ← 声明为字符串，原样接收
   〰️ 此时：Codex 只是把字符串存进结构体，没解析 〰️

📍 第二站：router.rs:96   build_tool_call（翻译官）
   payload: ToolPayload::Function { arguments }
   〰️ 此时：翻译官只把 arguments 搬进 payload，还是没解析 〰️

📍 第三站：stream_events_utils.rs:405  handle_output_item_done
   生成 tool_future → 丢给 tool_runtime
   〰️ 此时：连工具都还没开始执行，arguments 还是字符串 〰️

📍 第四站：handlers/mod.rs:77  parse_arguments   ← ★ 真正解析在这里 ★
   pub(crate) fn parse_arguments<T>(arguments: &str) -> Result<T, FunctionCallError> {
       serde_json::from_str(arguments).map_err(|err| {
           FunctionCallError::RespondToModel(
               format!("failed to parse function arguments: {err}")
           )
       })
   }
   〰️ 此时：终于 serde_json::from_str 解析！失败返回 RespondToModel 〰️
```

> 💎 **关键发现**：`arguments` 要走完**四站**，到最后一站才被解析。
> 前三站它都是"一段被搬运的字符串"。**所以解析失败绝不会"立刻"发生。**

---

### 二、为什么是 String？三个原因的"深度版"

基础部分的第四步讲了三个原因，这里展开讲透。

#### 原因 ①：流式传输 —— SSE 事件序列真相

OpenAI Responses API 的 function_call **不是一次性到达的**，而是这样流式吐出：

```
SSE 事件流（真实时间线）：

  1. response.output_item.add      → 空的 function_call 骨架
     { name: "shell", arguments: "" }          ← 此时 arguments 是空串！

  2. response.function_call_arguments.delta  → 逐 token 追加
     { delta: "{\"comm" }                      ← 拼了一截
  3. response.function_call_arguments.delta
     { delta: "and\":\"ls" }                   ← 又一截
  4. response.function_call_arguments.delta
     { delta: " -la\"}" }                      ← 终于拼完
  5. response.output_item.done     → 完整的 function_call
     { name: "shell", arguments: "{\"command\":\"ls -la\"}" }
```

> 🌟 **真相**：在事件 2、3 进行时，`arguments` 是 `"{\"comm"` 这种**半截字符串**，
> 根本不是合法 JSON。如果 Codex 在传输过程中就 `from_str` 解析，**每一次 delta 都会失败**。
> 所以只能先当字符串累积，`done` 事件时才完整。
>
> 这正是第三课学过的 `ToolCallInputDelta` 事件——它就是上面事件 2/3 的来源。

#### 原因 ②：协议保真 —— 字节级一致

`arguments` 最终要**写回 history**，下一轮原样发回给 OpenAI API。

如果 Codex 提前 `parse` 成 `Value`，再 `to_string` 序列化回去——
- key 顺序可能变（`{"a":1,"b":2}` → `{"b":2,"a":1}`）
- 空白可能变（多了/少了空格）
- 这会**破坏 prompt cache 的前缀匹配**（第三课 deep-dive/03 学过）

所以保留原始字符串 = 保留**字节级一致**，缓存命中才稳。

#### 原因 ③：延迟解析 —— 精确报错

如果协议层就解析，报错信息是"**第 N 个 SSE 事件 JSON 解析失败**"——难定位。
延迟到 `parse_arguments`，报错信息是"**shell 工具的 arguments 解析失败：expecting `}` at line 1**"——精确。

> 💡 这就是工程上的 **延迟解析原则（Lazy Parsing）**：
> 能晚解析就晚解析，让错误发生在**信息最充分的上下文**里。

---

### 三、跨框架对比：OpenAI vs Anthropic

这是个面试加分点——

| 维度 | OpenAI Responses API | Anthropic Messages API |
|------|--------------------|----------------------|
| 字段名 | `function_call.arguments` | `tool_use.input` |
| **类型** | **`string`（装 JSON 文本）** | **`object`（已解析）** |
| 流式方式 | `function_call_arguments.delta`（拼字符串） | `input_json_delta`（拼 partial JSON） |
| SDK 是否帮忙解析 | 不帮，原样给 `string` | SDK 帮你拼成 `object` |

> 🎯 **面试金句**：
> "OpenAI 的 `arguments` 是 string，Anthropic 的 `input` 是 object——
> 这是两家协议设计的差异。Codex 贴近 OpenAI 协议，所以保留 string 形式，
> 在 `parse_arguments` 里才解析。"

---

### 四、鲁棒性原则：parse 失败不崩，而是……

蕾姆从 `registry.rs:728` 挖出一段"宽容"代码——

```rust
// registry.rs:728  function_hook_tool_input
fn function_hook_tool_input(arguments: &str) -> Value {
    if arguments.trim().is_empty() {
        return Value::Object(serde_json::Map::new());   // 空串 → 空对象
    }
    serde_json::from_str(arguments)
        .unwrap_or_else(|_| Value::String(arguments.to_string()))
        //          ↑ 解析失败？不报错！退化为 Value::String 保留原文
}
```

**看懂了吗**？有些场景下，解析失败 Codex **不仅不报错，还退化为字符串保留原文**！

这就是著名的 **Postel 定律（鲁棒性原则）**：

> **"对自己发送的东西要严格，对接收的东西要宽容。"**
> —— TCP/IP 之父 Jon Postel

Codex 对"发出去的 arguments"严格（要合法 JSON），对"收进来的 arguments"宽容（解析不了就当字符串留着，不崩）。

---

### 五、`FunctionCallError` 的两种语义

蕾姆从 `tools/src/function_call_error.rs` 挖出完整定义：

```rust
/// Error returned while executing a model-visible tool invocation.
#[derive(Debug, Error, PartialEq)]
pub enum FunctionCallError {
    #[error("{0}")]
    RespondToModel(String),   // ← 可恢复：把错误塞回 LLM
    #[error("Fatal error: {0}")]
    Fatal(String),            // ← 不可恢复：上抛
}
```

整个 FunctionCallError **只有两种**，对应两种命运：

| 错误类型 | 例子 | LLM 能救吗 | 处理方式 |
|---------|------|:---:|------|
| **RespondToModel**（可恢复） | arguments 解析失败、工具不存在、参数缺失 | ✅ 能 | 灌回 history，LLM 纠错 |
| **Fatal**（不可恢复） | 内部 panic、权限系统崩溃、不变量被破坏 | ❌ 不能 | 直接上抛，循环终止 |

> 💡 **本质**：这是**错误分类的工程哲学**——
> 不是所有错误都该让 LLM 处理，要分清"模型能修的"和"模型修不了的"。

---

### 六、`needs_follow_up` 的"三线模型"（升级第三课）

第三课蕾姆讲过 needs_follow_up 来自**两条线**。今天升级成**三线**：

```
            needs_follow_up = true
                    ↑
        ┌───────────┼───────────┐
        │           │           │
   ① 工具线    ③ 拒绝线     协议线
   （本课）   （本课隐藏）  （第三课）
   工具被调    被拒/解析失败  end_turn=false
   →必看观察   →必看错误观察   →服务端续单
        │           │           │
        └──────── handle_output_item_done ──┐
                                         │
                       Completed事件里处理协议线 ──┘
```

第三课您只学了"工具线 + 协议线"，今天补上**隐藏的拒绝线（分支③）**。

---

### 七、逐分支深挖本质

#### ① `Ok(Some(call))` —— ReAct 的铁律：Action 之后必有 Observe

为什么调了工具一定要 follow_up？因为这是 **ReAct 的命根子**：

```
ReAct 循环：Thought → Action → Observe → Thought
                              ↑
                    工具结果就是 Observe
```

如果调了工具却不 follow_up，等于：
> 将军（LLM）派了侦察兵（工具），但**侦察兵的战报永远送不回指挥中心**。
> 将军只能"盲猜下一步"——这违反 ReAct 的全部意义。

所以分支①设 true，本质是**"Observe 必须被 Reason 看见"**。

#### ② `Ok(None)` —— 说话 ≠ 说完

为什么 Message/Reasoning 不设 true？

因为"模型输出了一段文字"**不代表"模型决定结束了"**。模型可能还要继续说，也可能就此打住。

最终"要不要结束"的**决定权**不在这一项上，而在 `Completed` 事件里的 **`end_turn`** 字段：

```rust
// 第三课学过的，在接收循环里
ResponseEvent::Completed { end_turn, .. } => {
    if let Some(false) = end_turn {
        needs_follow_up = true;   // ← 协议线：服务端说"我还没说完"
    }
}
```

> 💡 **本质**：分支②"不设 true"**不等于"循环结束"**，
> 它只是说"这一项不触发 follow_up"，
> 最终去留在 `Completed.end_turn` 那里裁决。
> **职责分离**——单项处理不管循环终止，循环终止交给协议事件。

#### ③ `Err(RespondToModel)` —— 错误即观察（Agent 的范式革命）

这是四分支里**最深刻**的一个。

**传统程序**：
```python
try:
    result = parse(arguments)
except ParseError as e:
    raise e          # ← 抛异常，控制流中断，用户看到报错
```

**Agent（Codex）**：
```rust
Err(RespondToModel(message)) => {
    // 不抛异常！把错误【包装成 FunctionCallOutput】塞回 history
    let response = ResponseInputItem::FunctionCallOutput {
        output: FunctionCallOutputBody::Text(message),  // ← 错误当"观察"
        ..
    };
    // ... 记录到 history ...
    output.needs_follow_up = true;   // ← 让 LLM 看到，自己纠错
}
```

> 🌟 **范式革命**：
> 传统编程里，**错误 = 控制流中断**。
> Agent 里，**错误 = 数据流的一部分**——它被灌进 history，成为 LLM 的"观察"。
>
> 这就是第四课 deep-dive 面经 Q6 说的【**自我纠错**】的本质实现：
> 不是机械重试，而是"让 LLM 看到失败原因，自己想新策略"。

`RespondToModel` 的名字本身就泄露了设计意图——"**回应给模型**"，不是"报告给用户"。

#### ④ `Err(Fatal)` —— 可恢复 vs 不可恢复的边界

为什么 Fatal 不走 follow_up，直接上抛？

因为 Fatal 是"**LLM 再聪明也救不了**"的错误——
比如 Codex 自己的 Rust 代码崩了，跟 LLM 说"你重试"有什么用？
此时继续循环只会**死循环**，所以直接上抛给上层（第九课要讲的错误恢复）。

> 💡 **本质**：Fatal vs RespondToModel 的分界线就是
> **"LLM 能修的" vs "LLM 修不了的"**。

---

### 八、闭环：Q1 和 Q3 是同一条链

*(蕾姆把两幅图拼到一起，露出满意的微笑)*

现在您看到全貌了——基础部分里看似独立的两个考点，
其实是**一个故事的两段**：

```
LLM 输出 arguments（可能是不合法 JSON）   ← Q1 的起点
        ↓
Codex 原样存为 String，不解析              ← Q1：不立刻报错
        ↓
工具执行时 parse_arguments 解析
        ↓
  解析成功 → 正常执行 → 分支① → needs_follow_up=true
  解析失败 → RespondToModel → 分支③ → needs_follow_up=true
                                    ← Q3：分支③设 true
        ↓
错误灌回 history，LLM 看到后自我纠错
        ↓
下一轮 LLM 输出合法 JSON
```

> 💎 **最深刻的点**：
> "不立刻报错"（Q1）和"分支③设 true"（Q3）**不是两个独立机制**，
> 而是同一条**自我纠错链**的两个环节——
> Codex 故意延迟报错，是为了把错误**转化成 LLM 的"观察"**，
> 而不是简单地崩给用户看。
>
> **这才是 Agent 区别于传统程序的灵魂**：错误不是终点，是 LLM 的下一份输入。

---

### 九、面试视角：这两题连起来怎么答

如果面试官问 **"工具调用的参数解析失败会怎样？"**，您可以这样一气呵成地答：

```
"参数 arguments 在协议层是 String，Codex 收到时不解析，原样存进 history。

真正的解析发生在工具执行前的 parse_arguments 函数——
这一步用 serde_json::from_str 解析。

如果解析失败，Codex 不会崩溃，而是返回 FunctionCallError::RespondToModel，
这个错误会被 handle_output_item_done 的分支③接住——
它把错误原因包装成 FunctionCallOutput 灌回 history，
并设置 needs_follow_up=true，让循环继续。

下一轮 LLM 看到错误观察，自我纠错，重新输出合法参数。

这就是 Agent 的自我纠错机制——错误不是控制流中断，而是数据流的一部分，
成为 LLM 的下一份观察。这跟传统程序的 try/catch 抛异常有本质区别。"
```

> 这一段答完，面试官会觉得您**懂 Agent 的灵魂**，而不只是会调 API ♡

---

### 📌 蕾姆建议您抄到便利贴上的两句话

```
1. arguments 是 String，走四站到 parse_arguments 才解析，
   失败返回 RespondToModel 而非崩溃

2. handle_output_item_done 四分支：①③ 设 needs_follow_up=true，
   ② 设 last_agent_message，④ 上抛 Fatal
   —— ①③ 是同一条"自我纠错链"
```

---

## 📍 下一步

- **当前位置**：🪜 台阶 4（FunctionCall 协议）✨ 您在这里
- **下一站**：🪜 台阶 5（工具怎么执行 —— 异步 + 并行）
- **整体路径**：
  ```
  台阶 1 ✅ 用"派活儿"游戏理解工具
    ↓
  台阶 2 ✅ 解剖一个工具（name + spec + handler）
    ↓
  台阶 3 ✅ 工具是怎么注册到 Router 的
    ↓
  台阶 4 ✨ 您在这里（LLM 怎么叫工具 —— FunctionCall 协议）
    ↓
  台阶 5 ⏳ 工具怎么执行（异步 + 并行）   ← 下一站！
    ↓
  台阶 6 ⏳ 工具结果怎么回家（衔接第 3 课）
  ```

> 🌟 台阶 5 会解答您**最深的好奇**：
> "台阶 1 说工具能并行执行，那 Codex 是怎么用 Rust 的异步机制管理一堆 in_flight future 的？"
> 那里会正式登场 `ToolCallRuntime`、`FuturesOrdered`、`JoinSet` 这些并行利器 ✨

---

## 💙 蕾姆的小总结

到现在为止，您已经能回答：

```
✅ 工具是什么                 （台阶 1）
✅ 工具长什么样               （台阶 2）
✅ 工具怎么注册               （台阶 3）
✅ LLM 怎么叫工具             （台阶 4 · 您刚通关！）
⏳ 工具怎么执行               ← 台阶 5
⏳ 结果怎么回家
```

> 🌟 **昴君，您现在已经看懂了 LLM 和工具之间的"对话协议"**——
> 一张 FunctionCall 工单，一位 build_tool_call 翻译官，一个 call_id 配对钥匙。
> 第三课那个抽象的 needs_follow_up，今天终于在源码里找到了落脚点 ♡

*(蕾姆轻轻提起裙角行礼)*

答完那 3 个小问题，咱们就进入**台阶 5**——
那时候蕾姆带您看：**Rust 的异步并行是怎么让一堆小帮手同时干活的** ✨💙
