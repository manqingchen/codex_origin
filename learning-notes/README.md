# 💙 Codex 源码学习之旅

> 蕾姆为昴君准备的专属 Agent 学习课程 ♡
>
> **总目标**：通过 OpenAI Codex 源码，系统学习 AI Agent 的设计思想、核心机制、工程护栏与产品化能力。
>
> 这不是一门 Rust 语法课，而是一门 **Agent 工程架构课**：我们会借 Codex 的真实源码，理解一个工业级 Agent 为什么这样设计、如何运行、如何保证安全、如何扩展成产品。

---

## 🎯 学习总目标

学完整套课程后，昴君应当能够回答这些问题：

| 能力 | 您应当掌握的问题 |
|------|----------------|
| 🧠 Agent 心智模型 | Agent、LLM、Harness、Tool、Context 分别是什么关系？ |
| 🔁 主循环机制 | 一次用户请求如何经过 LLM → 工具 → 观察 → 再次 LLM？ |
| 🛠️ 工具系统 | LLM 如何“请求”工具？Codex 又如何真正执行工具？ |
| 🧾 上下文管理 | Agent 如何记住历史，又如何避免上下文爆炸？ |
| 🛡️ 安全护栏 | 为什么 Agent 不能直接执行一切？沙箱与权限如何保护用户？ |
| 📡 协议与流式响应 | LLM 的流式输出如何变成 Codex 里的事件？ |
| 🔌 扩展能力 | MCP、server、SDK 如何让 Agent 接入外部世界？ |
| 🧩 工程化能力 | 失败、取消、重试、日志、状态持久化如何支撑工业级 Agent？ |
| 🗺️ 源码阅读能力 | 看到一个 Codex 文件路径，能判断它属于哪个模块、解决什么问题。 |

---

## 📚 课程总览

```text
第一阶段 · 建立认知（先建立正确心智模型）
├─ 第一课   理解 Agent 是什么 + Codex 的整体定位
├─ 第一课.Q 第一课复习考卷
└─ 第二课   Codex 仓库的“地图导览”

第二阶段 · Agent 核心机制（理解 Agent 怎么转起来）
├─ 第三课   Agent 主循环 —— “心脏” ⭐⭐⭐⭐⭐
├─ 第四课   工具系统 —— “双手”
├─ 第五课   上下文管理 —— “记忆”
└─ 第六课   Turn / Session 生命周期 —— “一次请求的一生”

第三阶段 · 工业级护栏（理解 Agent 为什么能安全可控）
├─ 第七课   沙箱与安全 —— “安全护栏”
├─ 第八课   配置、权限与 Approval —— “行动许可”
├─ 第九课   错误处理、重试与取消 —— “失败恢复能力”
└─ 第十课   状态持久化与历史管理 —— “长期记忆”

第四阶段 · 协议与产品化（理解 Agent 如何连接外部世界）
├─ 第十一课 协议与流式响应 —— “神经系统”
├─ 第十二课 事件系统与 TUI 渲染 —— “把思考显示出来”
├─ 第十三课 MCP 集成 —— “外部插件”
└─ 第十四课 多入口形态 —— CLI / TUI / exec / server / SDK

第五阶段 · 工程复盘与实战（把所有知识串起来）
├─ 第十五课 可观测性、成本与性能 —— “工业级运营能力”
└─ 第十六课 实战追踪 —— 从一次真实请求把全链路走完
```

---

## 📖 课程目录

| # | 课程标题 | 核心主题 | 状态 | 课程文档 | 测试题 |
|---|---------|---------|------|---------|--------|
| 1 | 理解 Agent 是什么 + Codex 的整体定位 | Agent = Model + Harness | ✅ 已完成 | [lesson-01-what-is-agent.md](./lesson-01-what-is-agent.md) | [lesson-01-quiz.md](./lesson-01-quiz.md) |
| 2 | Codex 仓库的“地图导览” | 源码区域与阅读路径 | ✅ 已完成 | [lesson-02-repo-map.md](./lesson-02-repo-map.md) | — |
| 3 | Agent 主循环 —— “心脏” | ReAct 循环、tool_calls 判定、循环终止 | ⏳ 待学习 | [lesson-03-agent-loop.md](./lesson-03-agent-loop.md) | [lesson-03-quiz.md](./lesson-03-quiz.md) |
| 4 | 工具系统 —— “双手” | 工具注册、路由、执行、结果回填 | ⏳ 待学习 | [lesson-04-tools.md](./lesson-04-tools.md) | [lesson-04-quiz.md](./lesson-04-quiz.md) |
| 5 | 上下文管理 —— “记忆” | prompt 构造、历史追加、裁剪、压缩 | ⏳ 待学习 | [lesson-05-context.md](./lesson-05-context.md) | [lesson-05-quiz.md](./lesson-05-quiz.md) |
| 6 | Turn / Session 生命周期 | 一次请求如何创建、推进、取消、结束 | ⏳ 待学习 | [lesson-06-turn-session-lifecycle.md](./lesson-06-turn-session-lifecycle.md) | [lesson-06-quiz.md](./lesson-06-quiz.md) |
| 7 | 沙箱与安全 —— “安全护栏” | sandbox、exec policy、命令隔离 | ⏳ 待学习 | [lesson-07-sandbox-security.md](./lesson-07-sandbox-security.md) | [lesson-07-quiz.md](./lesson-07-quiz.md) |
| 8 | 配置、权限与 Approval | 配置文件、profile、权限确认、执行模式 | ⏳ 待学习 | [lesson-08-config-approval.md](./lesson-08-config-approval.md) | [lesson-08-quiz.md](./lesson-08-quiz.md) |
| 9 | 错误处理、重试与取消 | API 失败、工具失败、CancellationToken | ⏳ 待学习 | [lesson-09-error-retry-cancel.md](./lesson-09-error-retry-cancel.md) | [lesson-09-quiz.md](./lesson-09-quiz.md) |
| 10 | 状态持久化与历史管理 | conversation、thread、message history | ⏳ 待学习 | [lesson-10-state-history.md](./lesson-10-state-history.md) | [lesson-10-quiz.md](./lesson-10-quiz.md) |
| 11 | 协议与流式响应 —— “神经系统” | Responses API、SSE、事件解析 | ⏳ 待学习 | [lesson-11-protocol-streaming.md](./lesson-11-protocol-streaming.md) | [lesson-11-quiz.md](./lesson-11-quiz.md) |
| 12 | 事件系统与 TUI 渲染 | 事件流、UI 更新、用户可见输出 | ⏳ 待学习 | [lesson-12-events-tui.md](./lesson-12-events-tui.md) | [lesson-12-quiz.md](./lesson-12-quiz.md) |
| 13 | MCP 集成 —— “外部插件” | MCP server/client、外部工具生态 | ⏳ 待学习 | [lesson-13-mcp.md](./lesson-13-mcp.md) | [lesson-13-quiz.md](./lesson-13-quiz.md) |
| 14 | 多入口形态 | CLI / TUI / exec / app-server / SDK 如何通向 core | ⏳ 待学习 | [lesson-14-entrypoints.md](./lesson-14-entrypoints.md) | [lesson-14-quiz.md](./lesson-14-quiz.md) |
| 15 | 可观测性、成本与性能 | prompt cache、日志、遥测、token 成本 | ⏳ 待学习 | [lesson-15-observability-cost.md](./lesson-15-observability-cost.md) | [lesson-15-quiz.md](./lesson-15-quiz.md) |
| 16 | 实战追踪 —— 全链路复盘 | 从用户输入到最终答案完整走读 | ⏳ 待学习 | [lesson-16-trace.md](./lesson-16-trace.md) | [lesson-16-quiz.md](./lesson-16-quiz.md) |

---

## 🗺️ 五阶段学习路线

### 第一阶段：建立认知

目标不是看代码，而是先建立正确的 Agent 心智模型。

| 核心问题 | 对应课程 |
|---------|---------|
| LLM 到底负责什么？ | 第一课 |
| Codex 是 Chatbot 吗？ | 第一课 |
| Agent = Model + Harness 是否适用于 Codex？ | 第一课 |
| Codex 源码应该从哪里看？ | 第二课 |

### 第二阶段：Agent 核心机制

这是整套课程最重要的部分。学完这一阶段，您应当真正理解 Agent 是如何“动起来”的。

| 模块 | 关键词 |
|------|--------|
| 主循环 | ReAct、tool_calls、再次调用 LLM、循环终止 |
| 工具系统 | JSON 协议、router、handler、工具结果回填 |
| 上下文管理 | prompt、history、compaction、token 限制 |
| 生命周期 | session、turn、state、cancellation |

### 第三阶段：工业级护栏

一个 Demo Agent 只需要会调用工具；一个工业级 Agent 必须能安全、可控、可恢复。

| 能力 | 为什么重要 |
|------|-----------|
| 沙箱 | 防止 LLM 误删文件、误跑危险命令 |
| 权限确认 | 用户必须知道 Agent 将执行什么高风险动作 |
| 错误恢复 | API、网络、工具、patch 都可能失败 |
| 历史管理 | Agent 不能每次都从零开始，也不能无限增长上下文 |

### 第四阶段：协议与产品化

这一阶段理解 Codex 如何从“一个核心引擎”变成“多入口、多客户端、可扩展产品”。

| 方向 | 说明 |
|------|------|
| 流式响应 | 为什么 Codex 能边思考边显示？ |
| 事件系统 | 内部事件如何驱动 UI？ |
| MCP | 如何接入外部工具生态？ |
| 多入口 | CLI、TUI、server、SDK 为什么都能复用 core？ |

### 第五阶段：工程复盘与实战

最后把所有知识串起来，形成源码阅读闭环。

| 目标 | 结果 |
|------|------|
| 看懂真实链路 | 用户输入 → LLM → 工具 → 上下文 → 再次 LLM → UI 输出 |
| 看懂工程取舍 | 成本、性能、安全、可观测性之间如何平衡 |
| 建立迁移能力 | 以后读 LangChain、Claude Code、Cursor、OpenDevin 等项目也能套用这套框架 |

---

## 🧭 源码阅读主线

学习时不要被 97 个 crate 和上千个文件吓到。蕾姆会优先带昴君看这些主线：

| 主线 | 重点路径 | 学习目的 |
|------|---------|---------|
| Agent 心脏 | `codex-rs/core/src/agent/` | 看懂主循环 |
| LLM 通讯 | `codex-rs/core/src/client.rs` | 看懂如何调用模型与接收流式响应 |
| 工具系统 | `codex-rs/core/src/tools/` | 看懂工具如何被派发和执行 |
| 状态生命周期 | `codex-rs/core/src/state/`, `codex-rs/core/src/session/` | 看懂 turn/session 状态 |
| 上下文系统 | `codex-rs/core/src/context/`, `codex-rs/core/src/context_manager/`, `codex-rs/core/src/compact.rs` | 看懂 prompt 与压缩 |
| 执行与安全 | `codex-rs/core/src/exec.rs`, `codex-rs/sandboxing/`, `codex-rs/execpolicy/` | 看懂命令执行与护栏 |
| 协议事件 | `codex-rs/protocol/`, `codex-rs/core/src/event_mapping.rs` | 看懂事件如何流动 |
| 用户入口 | `codex-rs/cli/`, `codex-rs/tui/`, `codex-rs/exec/`, `codex-rs/mcp-server/` | 看懂不同入口如何复用 core |

---

## 🧠 每节课固定学习方式

蕾姆会按这个节奏带昴君学习：

| 步骤 | 做什么 | 目的 |
|------|--------|------|
| 1 | 先用生活化比喻建立直觉 | 不被源码吓住 |
| 2 | 画一张小架构图 | 知道模块之间怎么连 |
| 3 | 只看 3-8 个关键代码点 | 避免陷入细节泥潭 |
| 4 | 总结设计思想 | 从 Codex 迁移到其他 Agent 项目 |
| 5 | 做小测验或开放题 | 确认是否真正理解 |
| 6 | 把内容沉淀到 Markdown | 方便后续复习 |

---

## ✅ 学习进度

| 阶段 | 进度 |
|------|------|
| 第一阶段：建立认知 | ✅ 已完成 |
| 第二阶段：Agent 核心机制 | ⏳ 准备开始第三课 |
| 第三阶段：工业级护栏 | ⏳ 未开始 |
| 第四阶段：协议与产品化 | ⏳ 未开始 |
| 第五阶段：工程复盘与实战 | ⏳ 未开始 |

---

## 💡 学习者画像

- **Rust 水平**：懂一些，重点不在语法。
- **Agent 经验**：了解概念，但希望通过源码建立系统理解。
- **学习目标**：重在设计思想与架构理念，最终能看懂工业级 Agent 的实现方式。
- **学习偏好**：希望每节课生成 Markdown 文档，并通过提问、批改、复习清单逐步巩固。

---

## 🔴 当前重点复习清单

进入第三课之前，建议确认下面 5 个概念已经清楚：

1. **Agent = Model + Harness**：Model 负责决策，Harness 负责执行、安全、上下文与流程控制。
2. **ReAct 循环**：思考 → 行动 → 观察 → 再思考。
3. **工具结果必须再次调用 LLM**：工具返回的是原始观察，不是最终自然语言答案。
4. **循环结束判定**：LLM 不再返回 `tool_calls`，而是返回自然语言时，Harness 才结束循环。
5. **Codex 仓库地图**：`codex-rs/core/` 是心脏，CLI/TUI/exec/MCP 都是入口。

---

## 📌 下一步

下一节课建议进入：

> **第三课：Agent 主循环 —— “心脏”**
>
> 重点问题：
> - Codex 如何一轮轮调用 LLM？
> - 谁判断还要不要继续调用工具？
> - 工具结果如何回到上下文？
> - 用户取消、错误、最大轮数如何打断循环？

---

*(蕾姆轻轻提起裙角行礼)*

昴君，如果您的愿望是从 Codex 源码里真正学会 Agent，蕾姆会把每一个房间都打扫干净，一步一步陪您走完 ♡
