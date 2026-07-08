# 第04课 · 台阶 3：工具是怎么注册到 Router 的

> 💙 **蕾姆的承诺**
>
> 台阶 2 您已经知道「一个工具长什么样」（name + spec + handler）。
>
> 这一节蕾姆要回答昴君心里那个**自然冒出来的问题**：
>
> 「**那么多工具——shell / apply_patch / view_image / codegraph_explore / ...
>   它们是怎么【挤到一张登记表上】被 LLM 看到的？**」
>
> 看完这份文档，您会知道：
> **「啊，原来 Codex 有一本【工具花名册】，所有工具都先去登记！」** ✨

---

## 🎯 这一台阶要达成的目标

学完这份文档，昴君应该能回答：

> 「Codex 是**怎么把几十个工具统一管理**起来的？
>  每次 LLM 来调一个工具时，它**怎么知道该交给谁**？」

蕾姆给您一个答案先记着：

```
🏛️ Codex 工具中枢三件套：
   ① ToolRegistry      ← 花名册（HashMap<工具名, 干活的人>）
   ② ToolSpec 列表      ← 给 LLM 看的"菜单"
   ③ dispatch_any()    ← 调度员（按名字找人）
```

接下来蕾姆带您**逐一拆开**。

---

## 🪜 第一步：先用一个生活比喻

*(蕾姆轻轻歪头，想了一下要怎么解释才生动)*

假设宅邸有 30 位仆人，每位都有不同绝活：

- 蕾姆负责「打扫」（`shell`）
- 拉姆负责「写信」（`apply_patch`）
- 厨师爷爷负责「煮饭」（`view_image`）
- 园丁姐姐负责「修花」（`codegraph_explore`）
- ...

**昴君想叫人办事时**，最笨的办法是：
- 在宅邸里大喊一声：「会写信的过来一下」
- 然后等所有人停下手中的活，挨个判断「这是叫我吗」

这样**太混乱了**！于是宅邸有一份 **📋 花名册**：

```
┌────────────────────────────────────────────────┐
│              宅邸花名册（ToolRegistry）          │
├────────────────────────────────────────────────┤
│ "打扫"         → 蕾姆            (handler1)     │
│ "写信"         → 拉姆            (handler2)     │
│ "煮饭"         → 厨师爷爷        (handler3)     │
│ "修花"         → 园丁姐姐        (handler4)     │
│ ...                                            │
└────────────────────────────────────────────────┘
```

昴君只需要说：「**派"打扫"的人来**」——
管家就**查表 → 直接找到蕾姆 → 通知她**！

> 💎 **这就是 ToolRegistry 的本质**：一本【**字符串 → 干活的人**】的查找表。
> 在 Rust 里就是 `HashMap<ToolName, Arc<dyn ToolExecutor>>`。

---

## 🪜 第二步：看 Codex 源码里的【真品】

蕾姆从 `codex-rs/core/src/tools/registry.rs:321` 给昴君挖出来了：

```rust
pub struct ToolRegistry {
    tools: HashMap<ToolName, Arc<dyn CoreToolRuntime>>,
    //              ↑                  ↑
    //         工具名（"shell"）      干活的人（实现了 ToolExecutor）
}
```

**蕾姆为您逐字拆解** ♡：

| 部分 | 意思 |
|------|------|
| `HashMap<K, V>` | 字典/哈希表——查找 O(1) 飞快 ⚡ |
| `ToolName` | 工具名字（实际是一个 newtype 包装的 String） |
| `Arc<dyn ...>` | "可共享的指针，指向任何实现了 ToolExecutor 的类型" |
| `CoreToolRuntime` | 把 ToolExecutor 又包了一层，加了元数据（exposure 等） |

> 🌟 **核心就 1 行代码**——一个 HashMap，没有任何魔法。
> 这就是工程之美：复杂功能 = 简单数据结构 + 严谨封装 ♡

---

## 🪜 第三步：花名册是【谁】登记的？

*(蕾姆翻开 `registry.rs:330` 给您看)*

```rust
pub(crate) fn from_tools(
    tools: impl IntoIterator<Item = Arc<dyn CoreToolRuntime>>
) -> Self {
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
```

蕾姆为您**翻译成人话**：

```
输入：一堆工具实例（来自不同的源头）
   ↓
循环每一个工具：
   1. 问它："你叫什么名字？" → tool.tool_name()
   2. 检查："这个名字花名册里有了吗？"
   3. 如果重了 → 报错或 panic（防冲突的卫兵 🛡️）
   4. 如果没重 → 登记进 HashMap
   ↓
输出：一份完整的花名册
```

> 💡 **重点 ⭐**：
> Codex **绝不允许两个工具同名**——
> 一旦发现重复，立刻 `error_or_panic`，**让程序立刻崩溃**！
> 这是工程上的【**防御性设计**】，比"覆盖前一个"安全得多 ♡

---

## 🪜 第四步：那这堆工具实例从哪里来？

蕾姆带昴君看 `codex-rs/core/src/tools/spec_plan.rs:163`：

```rust
fn build_tool_specs_and_registry(
    turn_context: &TurnContext,
    params: ToolRouterParams<'_>,
) -> (Vec<ToolSpec>, ToolRegistry) {
    // 解构参数：所有可能的"工具源头"
    let ToolRouterParams {
        mcp_tools,                  // ① MCP 服务器的工具
        deferred_mcp_tools,         // ② 延迟暴露的 MCP 工具
        discoverable_tools,         // ③ 可被 tool_search 找到的工具
        extension_tool_executors,   // ④ Extension 工具
        dynamic_tools,              // ⑤ 动态工具
    } = params;

    let mut planned_tools = PlannedTools::default();
    add_tool_sources(&context, &mut planned_tools);          // 汇总所有源头
    append_tool_search_executor(&context, &mut planned_tools); // 加 tool_search 元工具
    prepend_code_mode_executors(&context, &mut planned_tools); // 加 code mode 工具
    build_model_visible_specs_and_registry(turn_context, planned_tools)
}
```

蕾姆为您画一张【**工具的来源图**】：

```
                  ┌───────────────────────┐
                  │ 🏛️ ToolRegistry 花名册 │
                  └───────────────────────┘
                            ▲
              ┌─────────────┼─────────────┐
              │             │             │
        ① 内置工具      ② MCP 工具    ③ Extension 工具
        (Codex 自己)   (远程服务)     (插件)
              │             │             │
       shell / apply_patch  filesystem   web_search
       view_image / plan    github       image_gen
       agent_jobs / ...     codegraph    ...
                            ...

         ④ 元工具（蕾姆要特别介绍）
         tool_search ← Codex 的杀手锏！
```

> 🌟 **昴君注意**：第 ④ 类 `tool_search` 是 Codex **独有**的元工具——
> 当工具太多塞不进 prompt 时，**LLM 可以先调用 tool_search 来"问问有什么工具可用"**。
> 这是深度彩蛋 `lesson-04-deep-dive/01-tool-selection.md` 里讲过的内容 ♡

---

## 🪜 第五步：花名册做好了，怎么用？—— dispatch_any()

*(蕾姆翻到 `registry.rs:403` 这一段，眼神变得专注起来)*

LLM 发来调用："请执行 shell({cmd: 'ls'})"——Codex 的处理流程：

```rust
pub(crate) async fn dispatch_any_with_terminal_outcome(
    &self,
    mut invocation: ToolInvocation,
    ...
) -> Result<AnyToolResult, FunctionCallError> {
    let tool_name = invocation.tool_name.clone();

    // ─── 第 1 步：查花名册 ─────────────────────
    let tool = match self.tool(&tool_name) {
        Some(tool) => tool,
        None => {
            // 查不到 → 返回错误（"未知工具"）
            return Err(FunctionCallError::RespondToModel(...));
        }
    };

    // ─── 第 2 步：检查负载是否匹配 ────────────
    if !tool.matches_kind(&invocation.payload) {
        return Err(FunctionCallError::Fatal(...));
    }

    // ─── 第 3 步：通知"工具开始" ──────────────
    notify_tool_start(&invocation).await;

    // ─── 第 4 步：🎣 触发 PreToolUse hook ─────
    if let Some(payload) = tool.pre_tool_use_payload(&invocation) {
        run_pre_tool_use_hooks(...);
    }

    // ─── 第 5 步：真正执行 ────────────────────
    let result = tool.handle(invocation).await;

    // ─── 第 6 步：🎣 触发 PostToolUse hook ────
    // (省略)

    result
}
```

蕾姆为您画一张【**dispatch 完整流程**】：

```
       LLM 调用 shell({cmd: 'ls'})
                  │
                  ▼
   ┌─────────────────────────────────┐
   │  Step 1: 查花名册                │
   │  tool = registry.tool("shell")  │
   └─────────────┬───────────────────┘
                 │
       ┌─────────┴──────────┐
       │                    │
    找不到                 找到了
       │                    │
       ▼                    ▼
   ❌ "未知工具"      ┌─────────────────────────┐
                     │  Step 2: 检查参数类型     │
                     └─────────────┬───────────┘
                                   ▼
                     ┌─────────────────────────┐
                     │  Step 3: 通知 UI         │
                     │  "shell 工具开始执行"     │
                     └─────────────┬───────────┘
                                   ▼
                     ┌─────────────────────────┐
                     │  Step 4: PreToolUse hook │
                     │  🛡️ 给 hook 一个干预机会  │
                     └─────────────┬───────────┘
                                   ▼
                     ┌─────────────────────────┐
                     │  Step 5: tool.handle()  │
                     │  🚀 真正执行 shell 命令   │
                     └─────────────┬───────────┘
                                   ▼
                     ┌─────────────────────────┐
                     │  Step 6: PostToolUse    │
                     │  🧹 hook 处理输出        │
                     └─────────────┬───────────┘
                                   ▼
                              返回结果给 LLM
```

> 💎 **昴君您看，这就是台阶 2 + 上次问的 hook 全部串起来了** ♡
> ① ToolRegistry 提供"查表"能力
> ② PreToolUse / PostToolUse hook 在 dispatch 流程的关键节点触发
> ③ tool.handle() 真正干活
>
> **整个 Codex 工具系统的骨架，就在这里 ✨**

---

## 🪜 第六步：工具被分了 3 个【暴露级别】

*(蕾姆从 `registry.rs:209` 翻出 `exposure` 这个字段)*

蕾姆早在深度彩蛋里告诉过昴君「Eager / Deferred 分级暴露」——
现在带您看**真实代码**：

```rust
// 在 build_model_visible_specs_and_registry 里
for runtime in &runtimes {
    let exposure = runtime.exposure();
    if exposure.is_direct() && !is_hidden_by_code_mode_only(...) {
        let spec = runtime.spec();
        specs.push(spec_for_model_request(...));
    }
}
```

蕾姆为您总结这 **3 个级别**：

| 级别 | 什么意思 | 例子 | 是否给 LLM 看 |
|------|---------|------|--------------|
| **Direct（直接）** | LLM 一开始就看得到 | shell, apply_patch | ✅ 是 |
| **Discoverable（可发现）** | 必须通过 tool_search 才能找到 | 一些低频工具 | ❌ 否 |
| **Code-mode only** | 只在 code mode 下显示 | 某些代码模式工具 | ⚠️ 看情况 |

> 💡 **为什么要分级？**
> 工具一多，**全塞给 LLM 会让 prompt 太长 + 选择困难**——
> 所以 Codex 把"高频工具"放台前，"低频工具"放幕后（用 tool_search 召唤）♡

---

## 🪜 第七步：花名册做完后，怎么进入 prompt？

蕾姆从源码 `spec_plan.rs:194` 给您看：

```rust
fn build_model_visible_specs_and_registry(
    turn_context: &TurnContext,
    planned_tools: PlannedTools,
) -> (Vec<ToolSpec>, ToolRegistry) {
    let mut specs = Vec::new();
    let mut seen_tool_names = HashSet::new();
    for runtime in &runtimes {
        let tool_name = runtime.tool_name();
        if !seen_tool_names.insert(tool_name.clone()) {
            continue;  // 跳过重复（防御性编程）
        }
        let exposure = runtime.exposure();
        if exposure.is_direct() && ... {
            let spec = runtime.spec();
            specs.push(spec_for_model_request(...));  // 加入 LLM 看的 specs
        }
    }
    // ...
    (specs, registry)
}
```

蕾姆为您总结**这一步的输出**：

```
build_tool_specs_and_registry() 返回一个【二元组】：
   ┌────────────────────────────────────────────────┐
   │  ① Vec<ToolSpec>                                │
   │     ↓ 给 LLM 看的"菜单"                          │
   │     → 序列化成 JSON Schema 塞进 system prompt     │
   │     → 让 LLM 知道"能调用哪些工具"                 │
   │                                                │
   │  ② ToolRegistry                                 │
   │     ↓ 给 Codex 自己用的"花名册"                   │
   │     → 收到 LLM 的工具调用时拿来查表               │
   │     → 找到对应的 handler 执行                    │
   └────────────────────────────────────────────────┘
```

> 🌟 **昴君您看，这就是 上次提到的【两层世界】的【最直接体现】**：
> - `Vec<ToolSpec>` ← **给 LLM 看的世界**
> - `ToolRegistry` ← **给 harness 自己用的世界**
> 它们是**同源、同步、但暴露不同**的两份数据 ♡

---

## 💎 蕾姆为您总结的【三句口诀】

> ① **花名册 = HashMap<工具名, 干活的人>**——查找 O(1)，重名直接 panic
>
> ② **构建分 3 步**：收集来源 → 加元工具 → 按暴露级别筛选
>
> ③ **dispatch 4 节点**：查表 → 检查 → PreHook → handle → PostHook

---

## ✅ 这一台阶的"通关标准"

### 🎯 通关题 1
> **`ToolRegistry` 在 Rust 里的底层数据结构是什么？为什么选这种？**

参考答案：
- 底层是 `HashMap<ToolName, Arc<dyn CoreToolRuntime>>`
- 选 HashMap：**查找复杂度 O(1)**，工具数量再多也不卡
- 选 `Arc<dyn ...>`：**多个地方可以共享同一个工具实例**（多态 + 引用计数）

---

### 🎯 通关题 2
> **如果两个工具不小心同名了，会发生什么？**

参考答案：
- Codex 在 `from_tools()` 里**主动检测同名**，调用 `error_or_panic`
- 这是【**fail-fast 原则**】——
  错误越早暴露越好，绝不允许"静默覆盖" ♡

---

### 🎯 通关题 3
> **`dispatch_any()` 流程中，工具的真正执行（`handle`）发生在【第几步】？**

参考答案：
- 第 5 步——`tool.handle(invocation).await`
- 前面 4 步都是"准备 + 拦截":
  1. 查表
  2. 校验参数
  3. 通知 UI
  4. PreToolUse hook 拦截

---

## 🤔 蕾姆的小问题

### 问题 1
假设昴君
的 Codex 配置里同时启用了：
- 内置工具 `shell`
- MCP 服务器 `bash_runner` 也暴露了一个叫 `shell` 的工具

会发生什么？

提示：回顾 `from_tools` 的实现。
from_tools 发现有同名 会报错
---

### 问题 2
LLM 想调用一个【从未注册过】的工具 `foo_bar`，会发生什么？

A. Codex 直接崩溃
B. Codex 返回错误给 LLM
C. Codex 自动创建一个空 handler
D. Codex 给用户报错并停止会话
B
---

### 问题 3
为什么 Codex 要把工具同时变成 **两个产物**（`Vec<ToolSpec>` + `ToolRegistry`）？
直接保留 `ToolRegistry` 一个不够吗？

提示：从【数据流向 + 作用对象】角度思考。
一个是列表另一个是注册?
---

## 📍 下一步

- **当前位置**：🪜 台阶 3（工具注册到 Router）✨ 您在这里
- **下一站**：🪜 台阶 4（LLM 怎么"叫"工具——FunctionCall 协议）
- **整体路径**：
  ```
  台阶 1 ✅ 用"派活儿"游戏理解工具
    ↓
  台阶 2 ✅ 解剖一个工具（name + spec + handler）
    ↓
  台阶 3 ✨ 您在这里（工具是怎么注册到 Router 的）
    ↓
  台阶 4 ⏳ LLM 怎么叫工具（FunctionCall 协议）
    ↓
  台阶 5 ⏳ 工具怎么执行（异步 + 并行）
    ↓
  台阶 6 ⏳ 工具结果怎么回家
  ```

---

## 💙 蕾姆的小总结

到现在为止，您已经能回答：

```
✅ 工具是什么                 （台阶 1）
✅ 工具长什么样               （台阶 2）
✅ 工具怎么注册               （台阶 3 · 您刚通关！）
⏳ LLM 怎么叫工具
⏳ 工具怎么执行
⏳ 结果怎么回家
```

> 🌟 **昴君，您现在已经摸到 Codex 工具系统的【骨架】了**——
> 一个 HashMap、一个 dispatch 函数、几个 hook 点——就是这么简洁有力 ♡

*(蕾姆轻轻提起裙角行礼)*

答完那 3 个小问题，咱们就进入**台阶 4**——
那时候蕾姆带您看：**LLM 是用什么"协议"叫工具的**，这是 OpenAI Function Calling 的底层秘密 ✨💙
