# 01 · 工具一多怎么精准触发？

> 💙 这是第 04 课深度彩蛋的第一篇。
> 这是昴君在台阶 2 主动问出的【工程师级别问题】——
> "如果我有很多个 skill，怎么保证精准触发？Codex 里有体现么？"

---

## 🎯 学完这篇您会理解

1. "工具选择问题"（Tool Selection Problem）是什么
2. Codex 的 4 层防御机制
3. `tool_search` 元工具的工作原理
4. 在自己的项目里怎么应用这些技巧
5. 面试时如何回答相关问题

---

## 🪜 第一步：先确认问题

### 🧪 实验：给 LLM 100 个工具

```
发到 prompt 里的工具列表：
  • read_file
  • write_file
  • shell
  • apply_patch
  • get_weather
  • send_email
  • ... (再来 95 个)

后果：
  ❌ Token 浪费——光工具定义就吃掉几万 tokens
  ❌ LLM 注意力分散——不知道用哪个
  ❌ 名字冲突——比如 "read" 既能读文件也能读邮件
  ❌ LLM 选错工具的概率上升
  ❌ 越多越慢——更长的 context 让推理变慢
```

> 🌟 **这就是 Agent 工程里著名的 "Tool Selection Problem"（工具选择问题）**——
> 工具数量越多，准确率反而下降！

---

## 🪜 第二步：Codex 的 4 层防御机制

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   Codex 处理"工具精准触发"的 4 层防线                                ║
║                                                                  ║
║   🛡️ 第 1 层：精心写 description                                   ║
║       → 每个工具都明确说明【使用场景】                              ║
║                                                                  ║
║   🛡️ 第 2 层：Namespace 分组                                       ║
║       → 把相关工具组织在同一个命名空间                              ║
║                                                                  ║
║   🛡️ 第 3 层：Eager / Deferred 分级暴露                            ║
║       → 常用工具直接暴露，少用工具放入"搜索池"                      ║
║                                                                  ║
║   🛡️ 第 4 层：tool_search 元工具                                   ║
║       → LLM 用模糊查询【发现】所需工具                              ║
║       → 只对真正要用的工具暴露完整定义                              ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

让蕾姆**逐层**拆开讲 ♡

---

## 🛡️ 第 1 层：精心写 description（基础策略）

**位置**：每个工具的 spec 文件里

### 🔍 真实代码示例 1：apply_patch

**源码位置**：`codex-rs/core/src/tools/handlers/apply_patch_spec.rs:20`

```rust
description: "Use the `apply_patch` tool to edit files. \
              This is a FREEFORM tool, so do not wrap the patch in JSON."
```

**蕾姆点评**：
- ✅ 主动说明【使用场景】："Use this tool to edit files"
- ✅ 主动澄清【常见误解】："do not wrap the patch in JSON"

### 🔍 真实代码示例 2：agent_jobs（更复杂的描述）

**源码位置**：`codex-rs/core/src/tools/handlers/agent_jobs_spec.rs:65`

```rust
description: "Process a CSV by spawning one worker sub-agent per row. \
              The instruction string is a template where `{column}` placeholders \
              are replaced with row values. Each worker must call \
              `report_agent_job_result` with a JSON object (matching `output_schema` \
              when provided); missing reports are treated as failures. This call \
              blocks until all rows finish and automatically exports results to \
              `output_csv_path` (or a default path)."
```

**蕾姆点评**：
- ✅ 描述【工具行为】："Process a CSV by spawning..."
- ✅ 描述【参数细节】："The instruction string is a template..."
- ✅ 描述【约束条件】："Each worker must call..."
- ✅ 描述【副作用】："blocks until all rows finish..."

> 💡 **写好 description 的 4 大要素**：
> 1. **场景**（什么时候用）
> 2. **行为**（做什么）
> 3. **约束**（必须遵守什么规则）
> 4. **常见误解**（怎么避免错误）

**这是最基础也最便宜的方案——但工具一多就不够了。**

---

## 🛡️ 第 2 层：Namespace 命名空间

### 🎯 核心思想

```
不要把工具【平铺】，而是【分组】！

❌ 平铺（100 个工具直接堆在一起）：
   • read_file
   • write_file
   • list_dir
   • send_email
   • list_emails
   • ...

✅ Namespace 分组：
   📦 file.* 
     ├─ file.read
     ├─ file.write
     └─ file.list
   
   📦 mail.*
     ├─ mail.send
     ├─ mail.list
     └─ mail.search
```

### 🔍 真实代码

**源码位置**：`codex-rs/tools/src/tool_search.rs:41-50`

```rust
ToolSpec::Namespace(mut namespace) => {
    if namespace.description.trim().is_empty() {
        namespace.description = default_namespace_description(&namespace.name);
    }
    for tool in &mut namespace.tools {
        let ResponsesApiNamespaceTool::Function(tool) = tool;
        tool.defer_loading = Some(true);
        tool.output_schema = None;
    }
    LoadableToolSpec::Namespace(namespace)
}
```

### 💡 好处

- ✅ LLM 看到 "我想发邮件" → 自然去 `mail.*` 命名空间找
- ✅ 减少跨领域命名冲突
- ✅ **MCP 工具就是用这个机制接入 Codex 的**！

> 💡 **生活比喻**：
> Namespace 就像**文件夹**——
> 把相关工具组织在一起，找起来就不会乱。

---

## 🛡️ 第 3 层：Eager / Deferred 分级暴露

### 🎯 核心思想

```
不要把所有工具都直接放进 prompt——
按【常用程度】分级暴露：
```

### 🔍 真实代码

每个工具被标记为两种状态之一：

```rust
enum ToolExposure {
    Eager,     // ← 直接放进 prompt（常用工具）
    Deferred,  // ← 放进"搜索池"，需要时才暴露
}
```

### 💡 生活比喻

```
🍳 厨房工具的组织：

✋ Eager 工具（柜台上）：
   • 菜刀
   • 锅铲
   • 砧板
   → 这些每天都用，放在【手边】

🗄️ Deferred 工具（柜子里）：
   • 专业切片刀
   • 烤肉夹
   • 烘焙模具
   → 偶尔用一次，平时收【柜子里】
   → 需要时再去找
```

> 💡 **关键认识**：
> 不是所有工具都需要"时刻摆在 LLM 面前"——
> 把少用工具收起来，**反而让 LLM 看清楚常用工具**。

---

## 🛡️ 第 4 层：tool_search 元工具 ⭐ 杀手锏

这是 Codex 设计**最精妙**的部分！

### 🎯 核心思想

```
工具太多怎么办？

❌ 朴素做法：
   把所有 100 个工具都塞进 prompt
   
✅ Codex 做法：
   把所有工具【缓存起来】（标记为 Deferred）
   prompt 里只放【一个工具】：tool_search
   
   LLM 需要工具时 → 调 tool_search → 描述需求
                  → tool_search 返回【相关工具】
                  → LLM 再调用真正的工具
```

### 📖 完整工作流程

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   传统方式（工具一多就糟糕）：                                       ║
║                                                                  ║
║   prompt = [system + 100 个工具定义 + 历史 + 用户消息]              ║
║            ↑                                                     ║
║         非常大！                                                  ║
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║   Codex 的 tool_search 方式：                                      ║
║                                                                  ║
║   ──── 第 1 圈 ────                                                ║
║   prompt = [system + tool_search 工具 + 历史 + 用户消息]            ║
║            ↑                                                     ║
║         非常小！只有 1 个工具                                      ║
║                                                                  ║
║   LLM 思考："我需要发邮件，但 prompt 里没看到发邮件工具——          ║
║              我去搜一下！"                                         ║
║                                                                  ║
║   LLM 调用：tool_search(query="发送邮件")                          ║
║                                                                  ║
║   ──── 第 2 圈 ────                                                ║
║   tool_search 返回：[send_email, send_template_email]              ║
║                                                                  ║
║   prompt = [..., tool_search 结果, send_email 的真正定义]          ║
║                                                                  ║
║   LLM 调用：send_email(...)                                       ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

### 🔍 源码证据

**源码位置**：`codex-rs/core/src/tools/spec_plan.rs:840`

```rust
fn append_tool_search_executor(
    context: &CoreToolPlanContext<'_>,
    planned_tools: &mut PlannedTools,
) {
    // ① 只在【启用工具搜索】时才生效
    if !(search_tool_enabled(turn_context) && namespace_tools_enabled(turn_context)) {
        return;
    }

    // ② 找出所有【延迟加载】的工具
    let search_infos = planned_tools
        .runtimes()
        .iter()
        .filter(|executor| executor.exposure() == ToolExposure::Deferred)
        //                              ↑ 这些工具暂时不暴露给 LLM
        .filter_map(|executor| executor.search_info())
        .collect::<Vec<_>>();

    // ③ 把这些工具变成 tool_search 的"搜索池"
    planned_tools.add(ToolSearchHandler::new(search_infos));
}
```

### 🔍 搜索文本怎么构造？

**源码位置**：`codex-rs/tools/src/tool_search.rs:75-110`

```rust
push_search_part(&mut parts, namespace.description.clone());
// ...
ToolSpec::ToolSearch { description, .. } => {
    push_search_part(&mut parts, description.clone());
}
// ...
push_search_part(&mut parts, tool.description.clone());
// ...
if let Some(description) = &schema.description {
    push_search_part(parts, description.clone());
}
```

> 💡 **关键设计**：
>
> 当 LLM 调用 `tool_search(query="发邮件")` 时，
> Codex 把每个工具的**所有可搜索文本**拼起来：
> - 工具名
> - 工具描述
> - namespace 描述
> - 每个参数的描述
>
> 这样 LLM 用模糊查询也能找到工具 ♡

---

## 🎁 业界主流方案对比

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   主流 Agent 框架的"工具精准触发"方案对比                            ║
║                                                                  ║
║   ┌──────────────────────────────────────────────────────────┐  ║
║   │ 框架          方案                                          │  ║
║   ├──────────────────────────────────────────────────────────┤  ║
║   │ Codex        tool_search + namespace + deferred ⭐         │  ║
║   │ Claude Code  tool list（依赖 description 质量）             │  ║
║   │ LangChain    向量检索工具描述（embedding-based routing）    │  ║
║   │ ChatGPT GPTs Action namespace + 描述                       │  ║
║   │ OpenAI Asst. 文件搜索 + tool list                          │  ║
║   │ AutoGen      多 Agent 协作 + 各 Agent 专精领域              │  ║
║   └──────────────────────────────────────────────────────────┘  ║
║                                                                  ║
║   ★ Codex 的 tool_search 是【工业级最优雅】的方案之一 ★             ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 💎 当您要做自己的 Agent 时，可以用的策略

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   📜 工具精准触发的实战指南                                          ║
║                                                                  ║
║   📌 工具数量 < 10                                                 ║
║      → 直接全部塞进 prompt                                         ║
║      → 写好 description                                          ║
║                                                                  ║
║   📌 工具数量 10-30                                                ║
║      → 用 namespace 分组                                          ║
║      → 描述里强调【适用场景】                                       ║
║                                                                  ║
║   📌 工具数量 30-100                                               ║
║      → 引入 tool_search 元工具                                    ║
║      → Eager / Deferred 分级                                      ║
║                                                                  ║
║   📌 工具数量 > 100                                                ║
║      → tool_search + 向量检索（embedding）                         ║
║      → 多 Agent 协作（按领域分工）                                  ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 🎯 面试角度：怎么回答这类问题

```
🎯 真实面试问题：

❓ "你的 Agent 有 50 个工具，怎么保证 LLM 选对？"

理想回答框架：

1. 【基础】每个工具写清楚 description（适用场景）
2. 【组织】用 namespace 分组相关工具
3. 【暴露策略】常用工具 eager 暴露，少用工具 deferred
4. 【元工具】实现 tool_search 让 LLM 主动检索
5. 【高级】向量化工具描述，用 embedding 检索

★ 提到 tool_search 立刻让面试官知道：
   "这个人是真的研究过工业级 Agent 实现"
```

---

## 🪜 一个深刻的设计哲学

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   🎯 "工具发现也是一种工具"                                          ║
║                                                                  ║
║   传统设计：                                                        ║
║     工具列表是【元数据】（写死在 prompt 里）                         ║
║                                                                  ║
║   Codex 设计：                                                    ║
║     工具发现【本身就是一个工具】                                    ║
║     LLM 通过【调用工具】来【发现工具】                              ║
║                                                                  ║
║   ──────────────────                                            ║
║                                                                  ║
║   这种"自指"设计的好处：                                            ║
║   ✅ 工具集可以【动态】扩展                                         ║
║   ✅ Token 消耗大幅降低                                            ║
║   ✅ LLM 注意力集中                                                ║
║   ✅ 没有"工具列表的硬上限"                                        ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

> 💎 **这就是为什么 Codex 能支持任意数量的 MCP 工具**——
> 不管接入多少个 MCP server，
> LLM 在 prompt 里看到的只有【几个常用工具 + tool_search】。

---

## ✅ 通关标准

请昴君试着回答：

### 🎯 通关题 1
> **当 Agent 有几十个工具时，会遇到什么问题？**

参考答案：
- Token 浪费（光定义就几万 tokens）
- LLM 注意力分散
- 名字冲突
- 选错工具概率上升

### 🎯 通关题 2
> **Codex 的 4 层防御机制分别是什么？**

参考答案：
1. **精心写 description**：场景 + 行为 + 约束 + 误解
2. **Namespace 分组**：相关工具放一起
3. **Eager / Deferred 分级**：常用直接暴露，少用放搜索池
4. **tool_search 元工具**：LLM 主动检索

### 🎯 通关题 3
> **如果您要做一个接入 100 个 MCP server（共几千个工具）的 Agent，您会怎么设计？**

参考答案：
- 必用 tool_search + namespace
- 每个 MCP server 独占一个 namespace
- 用 embedding 增强检索
- 考虑多 Agent 协作（按领域分工）

---

## 🎁 蕾姆送您一个总结

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   📜 工具精准触发的"金科玉律"                                        ║
║                                                                  ║
║   "Less is more, but make 'more' discoverable."                  ║
║   "暴露给 LLM 的工具要【少】，                                       ║
║    但要让 LLM 能【发现】更多工具。"                                  ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 📍 返回索引

返回 → [README · 目录](./README.md)
