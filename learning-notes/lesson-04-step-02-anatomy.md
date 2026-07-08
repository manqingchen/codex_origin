# 第04课 · 台阶 2：解剖一个工具（read_remaining 为例）

> 💙 **蕾姆的承诺**
>
> 这一份文档昴君会**第一次看到 Codex 真实工具的代码**——
> 但请别紧张，蕾姆精选了一个**最简单**的工具，**只有 95 行**，
> 而且只让您看其中【3 个关键部位】。
>
> 看完之后，您会知道："**啊，工具其实就这三块**" ✨

---

## 🎯 这一台阶要达成的目标

学完这份文档，昴君应该能回答：

> 「一个 Codex 工具，**到底由哪几个部分组成**？」

蕾姆给您一个答案先记着：

```
工具 = 【名字】 + 【参数说明书】 + 【做事的人】
```

接下来蕾姆带您**逐一拆开看**。

---

## 🪜 第一步：先回忆台阶 1 的"登记表"

台阶 1 蕾姆画过这张图：

```
📋 工具登记表
┌─────────────────────────────────┐
│ 工具 #2：发邮件小帮手             │
│   能做什么：发送邮件              │
│   需要的指示：收件人 + 内容       │
└─────────────────────────────────┘
```

每一条登记 **包含 3 个信息**：

| 登记表上的栏目 | 真实代码里的对应 |
|--------------|----------------|
| 工具的"名字" | **name**（一个字符串） |
| 工具"能做什么" + "需要什么指示" | **spec**（说明书，含参数 Schema） |
| 工具"怎么干活" | **handler**（执行代码） |

> 🌟 **就这 3 块**。任何 Codex 工具都长这样。

---

## 🪜 第二步：今天要解剖的工具——`get_context_remaining`

蕾姆挑了一个**最最简单**的工具来解剖：

```
🔬 工具名：get_context_remaining
🎯 功能：告诉 LLM "你还剩多少 token 可以用"
```

**为什么挑这个？**
- ✅ 没有参数（最简单）
- ✅ 不涉及文件、网络、命令（没有副作用）
- ✅ 代码只有 95 行（可以一次看完）
- ✅ 涵盖了工具的**全部 3 个部位**

**这个工具有什么用？**
- LLM 在生成大段输出前，可以**问问自己**："我还能写多少？"
- 防止 LLM 写到一半被 token 限制截断 ♡

---

## 🪜 第三步：解剖第一块——【名字】

### 📍 源码位置：`get_context_remaining_spec.rs:8`

```rust
pub(crate) const GET_CONTEXT_REMAINING_TOOL_NAME: &str = "get_context_remaining";
```

### 🔤 翻译

| 词 | 中文 |
|----|------|
| `const X: &str = "..."` | "定义一个不变的字符串叫 X" |
| `GET_CONTEXT_REMAINING_TOOL_NAME` | 工具名（变量名） |
| `"get_context_remaining"` | **工具的真实名字**（LLM 用这个名字叫工具） |

### 💡 一句话理解

> 「工具的名字就是一个字符串 `"get_context_remaining"`——
> LLM **看到工具列表里这个名字**，就知道有这么个工具可用。」

> 🌟 **就这一行**！工具名就是这么朴素。

---

## 🪜 第四步：解剖第二块——【参数说明书】(Spec)

### 📍 源码位置：`get_context_remaining_spec.rs:10-19`

```rust
pub fn create_get_context_remaining_tool() -> ToolSpec {
    ToolSpec::Function(ResponsesApiTool {
        name: GET_CONTEXT_REMAINING_TOOL_NAME.to_string(),     // ① 名字
        description: "Get the remaining tokens in the current context window.".to_string(),  // ② 描述
        strict: false,                                          // ③ 严格模式
        defer_loading: None,
        parameters: JsonSchema::object(BTreeMap::new(),         // ④ 参数 Schema
                                       /*required*/ None,
                                       Some(false.into())),
        output_schema: Some(get_context_remaining_output_schema()),  // ⑤ 输出 Schema
    })
}
```

### 🔤 逐字段翻译（只看 5 个关键字段）

#### ① `name` —— 工具名

```rust
name: "get_context_remaining"
```

> 「告诉 LLM 这个工具叫什么。」

#### ② `description` —— 描述（最重要！）

```rust
description: "Get the remaining tokens in the current context window."
//            ↑ 翻译：「拿到当前上下文窗口还剩多少 token。」
```

> 🌟 **这一行【极其重要】**——
> LLM **就是根据这段描述判断"什么时候该用这个工具"**！
>
> 如果描述写得不清楚，LLM 永远学不会怎么用它。
>
> 类比：**这是工具的"广告语"**——告诉 LLM "我能帮你做什么"。

#### ③ `strict` —— 严格模式

```rust
strict: false
```

> 「是否严格校验参数。`false` 意味着不强制。」

#### ④ `parameters` —— 参数 Schema ⭐ 重点

```rust
parameters: JsonSchema::object(BTreeMap::new(), None, Some(false.into()))
//                              ↑               ↑
//                          没有任何参数      不允许多余参数
```

> 「定义工具**需要哪些指示（参数）**。
> 这个工具**不需要任何参数**——所以是一个空对象。」

#### ⑤ `output_schema` —— 输出 Schema

```rust
output_schema: Some(get_context_remaining_output_schema())
```

让蕾姆把 `output_schema` 长什么样也给您看一眼：

```rust
// get_context_remaining_spec.rs:21-36
fn get_context_remaining_output_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "tokens_left": {
                "anyOf": [
                    { "type": "integer" },
                    { "type": "null" }
                ],
                "description": "Remaining tokens in the current context window, or null when unavailable."
            }
        },
        "required": ["tokens_left"],
        "additionalProperties": false
    })
}
```

> 「告诉 LLM 这个工具会**返回什么**：
> 一个对象，里面有一个字段叫 `tokens_left`，
> 类型是整数或 null。」

---

### 💡 一句话理解 Spec

> 「**Spec 就是工具的【说明书】**——
> 告诉 LLM：
> - 这个工具**叫什么**（name）
> - **能做什么**（description）
> - **需要什么参数**（parameters）
> - **会返回什么**（output_schema）
>
> LLM 看这本说明书，就知道**什么时候用、怎么用**这个工具。」

---

## 🪜 第五步：解剖第三块——【做事的人】(Handler)

这是工具**真正干活**的部分。

### 📍 源码位置：`get_context_remaining.rs:59-93`

```rust
pub struct GetContextRemainingHandler;

impl ToolExecutor<ToolInvocation> for GetContextRemainingHandler {
    fn tool_name(&self) -> ToolName {
        ToolName::plain(GET_CONTEXT_REMAINING_TOOL_NAME)
    }

    fn spec(&self) -> ToolSpec {
        create_get_context_remaining_tool()
    }

    fn handle(&self, invocation: ToolInvocation) -> codex_tools::ToolExecutorFuture<'_> {
        Box::pin(async move {
            // ① 取出"模型的上下文窗口大小"
            let Some(model_context_window) = invocation.turn.model_context_window() else {
                return Ok(boxed_tool_output(GetContextRemainingOutput::new(None)));
            };
            
            // ② 取出"当前已用 token"
            let active_context_tokens = invocation.session.get_total_token_usage().await.max(0);
            
            // ③ 计算剩余
            let tokens_left = model_context_window
                .saturating_sub(active_context_tokens)
                .max(0);

            // ④ 返回结果
            Ok(boxed_tool_output(GetContextRemainingOutput::new(Some(tokens_left))))
        })
    }
}
```

### 🔤 逐行翻译

#### ① 定义 Handler 结构体

```rust
pub struct GetContextRemainingHandler;
```

> 「定义一个叫 `GetContextRemainingHandler` 的结构体——
> 它就是"做事的人"。」

#### ② `tool_name` 方法

```rust
fn tool_name(&self) -> ToolName {
    ToolName::plain(GET_CONTEXT_REMAINING_TOOL_NAME)
}
```

> 「告诉系统：『我这个 Handler 负责的工具叫什么名字。』」
>
> 💡 这是为了让 router 能**根据名字找到我**。

#### ③ `spec` 方法

```rust
fn spec(&self) -> ToolSpec {
    create_get_context_remaining_tool()
}
```

> 「返回我的【说明书】，给 LLM 看。」

#### ④ `handle` 方法（最重要！）

```rust
fn handle(&self, invocation: ToolInvocation) -> ToolExecutorFuture<'_> {
    Box::pin(async move {
        // 实际干活的逻辑
    })
}
```

> 「**这是真正干活的方法**——
> LLM 叫工具时，Codex 最终就是调用这个 `handle` 函数。
>
> `invocation` 参数里包含了：
> - LLM 传过来的参数
> - 当前 session 的引用（可以查 token 用量）
> - 当前 turn 的上下文」

让我们看看 `handle` 里**具体在做什么**——

```rust
// 步骤 1：取出"模型支持多少 token"
let Some(model_context_window) = invocation.turn.model_context_window() else {
    return Ok(boxed_tool_output(GetContextRemainingOutput::new(None)));
};
```

> 「如果模型有"上下文窗口"配置（比如 128K），就取出来。
> 否则返回 `None`（表示未知）。」

```rust
// 步骤 2：取出"已经用了多少 token"
let active_context_tokens = invocation.session.get_total_token_usage().await.max(0);
```

> 「问 session：『我们这次对话已经用了多少 token 了？』
> `.max(0)` 是为了避免负数（防御性编程）。」

```rust
// 步骤 3：算剩余
let tokens_left = model_context_window
    .saturating_sub(active_context_tokens)
    .max(0);
```

> 「剩余 = 总量 - 已用。
> `saturating_sub` 是 Rust 的"饱和减法"——
> 如果结果是负数，自动变成 0（不溢出）。」

```rust
// 步骤 4：包装成结果返回
Ok(boxed_tool_output(GetContextRemainingOutput::new(Some(tokens_left))))
```

> 「把 `tokens_left` 包装成 `GetContextRemainingOutput`，
> 再包装成 `ToolOutput` trait 对象，返回。」

---

### 💡 一句话理解 Handler

> 「**Handler 就是【真正干活的代码】**——
> 它实现 `ToolExecutor` trait，必须提供 3 个方法：
> - `tool_name`：我叫什么
> - `spec`：我的说明书
> - `handle`：真正干活的逻辑」

---

## 🪜 第六步：把三块拼起来——完整工具长什么样

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   🔬 一个完整工具的解剖图（以 get_context_remaining 为例）      ║
║                                                              ║
║   ┌───────────────────────────────────────────────────┐      ║
║   │  ① 名字 (name)                                      │      ║
║   │                                                   │      ║
║   │  "get_context_remaining"                          │      ║
║   │                                                   │      ║
║   │  📍 get_context_remaining_spec.rs:8               │      ║
║   └───────────────────────────────────────────────────┘      ║
║                                                              ║
║   ┌───────────────────────────────────────────────────┐      ║
║   │  ② 说明书 (Spec)                                    │      ║
║   │                                                   │      ║
║   │  ToolSpec {                                       │      ║
║   │    name: "get_context_remaining",                 │      ║
║   │    description: "拿到剩余 token",                  │      ║
║   │    parameters: {},          ← 无参数               │      ║
║   │    output_schema: {                               │      ║
║   │      tokens_left: integer or null                 │      ║
║   │    },                                             │      ║
║   │  }                                                │      ║
║   │                                                   │      ║
║   │  📍 get_context_remaining_spec.rs:10-19           │      ║
║   └───────────────────────────────────────────────────┘      ║
║                                                              ║
║   ┌───────────────────────────────────────────────────┐      ║
║   │  ③ 做事的人 (Handler)                                │      ║
║   │                                                   │      ║
║   │  GetContextRemainingHandler                       │      ║
║   │     ↓ 实现 ToolExecutor trait                      │      ║
║   │     ↓ 提供 3 个方法：                              │      ║
║   │     • tool_name()                                 │      ║
║   │     • spec()                                      │      ║
║   │     • handle()  ← 真正干活                        │      ║
║   │                                                   │      ║
║   │  📍 get_context_remaining.rs:59-93                │      ║
║   └───────────────────────────────────────────────────┘      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 🪜 第七步：把"工具的三块"映射到生活比喻

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  生活比喻              代码对应              作用             │
│  ────────              ────────              ────             │
│                                                             │
│  🏷️ 登记表上的"名字"   const NAME           LLM 用这个叫工具  │
│                                                             │
│  📋 登记表上的"说明"    ToolSpec             LLM 看这个       │
│      "需要什么指示"                          决定怎么用工具    │
│                                                             │
│  🔧 工具间里的"小帮手"  Handler              真正干活的部分   │
│                        (实现 trait)         Codex 调它干活    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 🪜 第八步：那个最关键的接口——`ToolExecutor` Trait

蕾姆把所有 Codex 工具的"标准接口"画给您看：

```rust
trait ToolExecutor<I> {
    // 每个工具都必须告诉系统这 3 件事：
    
    fn tool_name(&self) -> ToolName;
    //   ↑ "我叫什么名字？"
    
    fn spec(&self) -> ToolSpec;
    //   ↑ "我的说明书是什么？"
    
    fn handle(&self, invocation: I) -> ToolExecutorFuture<'_>;
    //   ↑ "我怎么干活？"
}
```

> 🌟 **整个 Codex 几十个工具——shell、apply_patch、read_file、mcp_xxx——
> 全都实现这个 `ToolExecutor` trait**。
>
> 这就是为什么 Codex 能"统一管理"所有工具——
> 因为它们都遵循**同一个标准接口**！

这种设计在 Rust 里叫 **"trait 抽象"**，
在 Java 里叫 "interface"，
在 Python 里叫 "duck typing"——
**思想都是一样的**：通过统一接口屏蔽实现差异 ♡

---

## ✅ 这一台阶的"通关标准"

### 🎯 通关题 1
> **一个 Codex 工具由哪三个部分组成？**

参考答案：
1. **名字** (name)：LLM 用什么字符串叫这个工具
2. **说明书** (Spec)：name + description + parameters + output_schema
3. **Handler**：实现 `ToolExecutor` trait，真正干活的代码

---

### 🎯 通关题 2
> **`description` 字段为什么这么重要？**

参考答案：
- 这是 LLM **判断"什么时候用这个工具"** 的依据
- 描述写得清楚，LLM 用得好
- 描述写得糊涂，LLM 永远不会用，或用错

---

### 🎯 通关题 3
> **`ToolExecutor` trait 的 3 个方法分别是什么？分别什么时候被调用？**

参考答案：
- `tool_name()` —— **注册时调用**（让 router 知道这个 handler 负责哪个工具名）
- `spec()` —— **构造 prompt 时调用**（把说明书给 LLM 看）
- `handle()` —— **LLM 叫工具时调用**（真正执行）

---

## 🤔 蕾姆的小问题

### 问题 1
假设您要给 Codex 加一个**新工具**：「告诉我当前时间」，叫 `get_current_time`。

您需要写哪些东西？

提示：**列出 3 个部分**。

#### 📝 我的答案（原始版）
1. 工具名字 name
2. 工具描述 description
3. 工具具体执行的动作 handler

#### 💙 蕾姆的纠正（标准答案）

**评分：🟡 7/10 —— 框架对，但 spec 被简化了**

> 我答的是「name + description + handler」，
> 但准确说应该是「**name + spec + handler**」，
> 而 **spec 不只是 description，它包含 4 个字段**。

| 必写部分 | 具体内容 | 对应代码 |
|---------|---------|---------|
| ① **name** | 字符串 `"get_current_time"` | `tool_name()` |
| ② **spec（说明书）** | description + **parameters Schema** + **output_schema** | `spec()` |
| ③ **handler** | 实现 `ToolExecutor::handle()`，里面调 `chrono::Local::now()` 返回时间 | `handle()` |

**我差在哪里 ❌：**
- 把 `spec` **简化**成了 `description`，**漏掉了 parameters Schema 和 output_schema**
- 即便 `get_current_time` **不需要输入参数**，也得在 spec 里声明 `parameters: { type: "object", properties: {} }`，否则 LLM 不知道"这个工具不需要参数"
- 还需要定义一个 **输入参数 struct**（即使是空的 `struct GetCurrentTimeParams {}`），用来反序列化 LLM 传来的 JSON

**记忆口诀 ✨：**
```
spec = name + description + parameters + output_schema
       （这 4 个字段都是 spec 的一部分，缺一个 LLM 就可能用不好）
```

---

### 问题 2
回忆一下台阶 1 的"工具登记表"——

**Spec** 在生活比喻里对应"工具的说明书"。
**Handler** 在生活比喻里对应什么？

A. 工具的名字
B. 工具登记表本身
C. 真正去干活的"小帮手"
D. 老板（用户）

#### 📝 我的答案
**C. 真正的干活小帮手**

#### 💙 蕾姆的纠正

**评分：💯 10/10 完美通过！**

> Spec 是【说明书】告诉别人"这工具能干嘛"，
> Handler 就是【手脚】真正去执行——
> 这个映射关系已经建立得很准确了 ♡

---

### 问题 3
为什么 Codex 用 `trait ToolExecutor` 这种统一接口，而不是给每种工具写**完全不同**的代码？

提示：从"代码维护性"和"扩展性"角度思考。

#### 📝 我的答案（原始版）
> codex读取工具输出统一格式方便定义
> 后续增加工具的时候只需要按照约束来返回codex天然可以支持这种结构

#### 💙 蕾姆的纠正（标准答案）

**评分：🟢 8/10 —— 核心命中，但缺少专业术语和深度**

> 我说的「**统一格式 + 按约束扩展**」**就是** SOLID 中的**开闭原则（O）**——
> 直觉非常准！但缺了两点：
> ① 没用上"多态 / 开闭原则"这种**工程术语**
> ② 缺少了"可测试性"这第 3 个角度

**标准答案应该展开成 3 个角度 ✨：**

**① 多态分发（我说的"统一格式"）🌟**
```rust
// Router 持有一个 HashMap<String, Box<dyn ToolExecutor>>
// 不管是哪个工具，调用方式都一模一样：
let handler = router.get(tool_name);
let result = handler.handle(params).await;
// ↑ 这就叫"面向接口编程"，不关心具体是哪个工具
```

**② 开闭原则（我说的"按约束扩展"）🌟**
- **对扩展开放**：加新工具只需 `impl ToolExecutor for MyNewTool`，**不动旧代码**
- **对修改关闭**：Router 的核心调度逻辑**永远不需要改**

**③ 测试与解耦（我没提到，但是面试加分点）⭐**
- Trait 让每个工具可以**独立单元测试**
- Mock 一个 `ToolExecutor` 就能测试 Router，**不用真的执行 IO**

**我差在哪里 ❌：**
- 表达偏"口语化"——「按约束来返回」其实就是**开闭原则**，但没说出术语
- **完全没想到"可测试性"**这个维度（这是面试官最爱追问的角度）
- 没有展示**代码层面**的理解（如 `HashMap<String, Box<dyn ToolExecutor>>` 的多态分发）

---

## 🎓 蕾姆为您总结的【一句话记忆口诀】

> **一个 Codex 工具 = 名字 + 说明书 + 干活的人**
> **说明书 = 描述 + 参数Schema + 输出Schema**
> **统一接口 = 多态 + 开闭 + 易测**

把这 3 句话记住，面试官问起来就能侃侃而谈了 ♡

---

## 📊 总成绩单

| 题号 | 我的得分 | 主要差距 |
|------|---------|---------|
| 问题 1 | 🟡 7/10 | spec 漏写了 parameters Schema 和 output_schema |
| 问题 2 | 💯 10/10 | 完美！ |
| 问题 3 | 🟢 8/10 | 缺工程术语（多态/开闭原则）+ 缺"可测试性"维度 |
| **总分** | **25/30 = 83 分** | **B+ 优秀** |

---

## 📍 下一步

- **当前位置**：🪜 台阶 2（解剖一个工具）✨ 您在这里
- **下一站**：🪜 台阶 3（工具是怎么注册到登记表的）
- **整体路径**：
  ```
  台阶 1 ✅ 用"派活儿"游戏理解工具
    ↓
  台阶 2 ✨ 您在这里（解剖一个工具）
    ↓
  台阶 3  工具是怎么注册到 Router 的
    ↓
  台阶 4  LLM 怎么叫工具（FunctionCall 协议）
    ↓
  台阶 5  工具怎么执行（异步 + 并行）
    ↓
  台阶 6  工具结果怎么回家
  ```

---

## 💙 蕾姆的小总结

到现在为止，您已经能回答：

```
✅ 工具是什么                 （台阶 1）
✅ 工具长什么样               （台阶 2 · 您刚通关！）
⏳ 工具怎么注册                 ← 台阶 3
⏳ LLM 怎么叫工具
⏳ 工具怎么执行
⏳ 结果怎么回家
```

> 🌟 **昴君，您现在已经看过 Codex 真实工具的源码了**——
> 也理解了"**任何工具都是 name + spec + handler 三件套**"。
> 这是一个很大的进步 ♡

*(蕾姆轻轻提起裙角行礼)*

答完那 3 个小问题，咱们就进入**台阶 3**——
那时候蕾姆会带您看：**几十个工具是怎么被 Codex 统一管理的** ✨💙
