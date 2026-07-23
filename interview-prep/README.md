# 💙 Agent 工程师面试备战 · 基于 Codex 源码的学习大纲

> 蕾姆为昴君专门筹建的一间「备考书房」♡
>
> **目标**：把 OpenAI Codex CLI 源码当作免费的、工业级的 Agent 工程教科书，逐条对标面试 JD，既能在面试中讲出「我读过 OpenAI 源码」的深度，又能精准补上 Codex 教不了你的缺口。

---

## 🧭 这是什么 / 为谁而建

- **你是谁**：正在准备「Agent 框架 / Agent Loop 运行时 / 工具编排 / 多 Agent / RAG / 多模型」方向的工程师面试。
- **这份大纲做什么**：把 JD 的每一条要求，映射到 Codex 仓库里**真实存在的源码文件与函数**（带 `file:line`），给出阅读顺序、面试问答骨架、动手任务；并明确指出 **Codex 教不了你什么**（见 [`GAPS-codex-cannot-teach.md`](./GAPS-codex-cannot-teach.md)）。
- **与 [`../learning-notes/`](../learning-notes/README.md) 的关系**：`learning-notes` 是「读懂 Codex」的通识课程（lesson-01~16）；本文件夹是「为面试而学」的**靶向复习**，二者互补。每个模块都会标注它呼应 `learning-notes` 的哪一课。

---

## 📋 面试 JD 要求原文

> 以下为面试方提出的能力要求（已编号，后续文档沿用此编号）：

1. **Agent 框架实战**：LangGraph / LlamaIndex / 自研编排 任一
2. **Agent Loop 运行时**：上下文组装 / 流式调用 / 工具执行 + 权限 / 错误恢复 / 上下文压缩 / Checkpoint 回滚
3. **工具编排**：并行调用、循环检测、动态授权；渐进式技能加载（Find Skills）机制
4. **Function Calling / Tool Use / ReAct 深入使用**
5. **多 Agent 通信**：Mailbox 消息传递（类 A2A）
6. **RAG 全链路工程经验**：向量检索（Milvus / Qdrant / pgvector）、Rerank、Chunk 策略、Query Rewrite
7. **多模型集成经验**（Claude / Gemini / OpenAI / 自研）
8. **有开源 Agent 项目可附 GitHub 链接**（可直接 review 代码）

---

## 🗺️ 覆盖度速览（一表看懂：Codex 能教你多少）

| # | 面试考点 | Codex 覆盖 | 结论一句话 | 模块 |
|---|---------|:---:|------|------|
| ① | Agent 框架实战（自研编排） | 🟢 极强 | Codex 本体即工业级自研编排器，另有 `workflow-orchestrator-poc` | [01](./01-agent-framework.md) |
| ② | Agent Loop 运行时（6 子项） | 🟢 全覆盖 | 上下文组装/流式/工具权限/错误恢复/压缩/回滚 全部落地 | [02](./02-agent-loop-runtime.md) |
| ③ | 工具编排（并行/循环/授权）+ Find Skills | 🟢 强 | 真并发 + 会话级动态授权 + 双层渐进式技能加载；循环检测仅靠 guardian 熔断 + token 兜底 | [03](./03-tool-orchestration.md) |
| ④ | Function Calling / Tool Use / ReAct | 🟢 强 | FC 闭环完整；ReAct 走 Responses API 原生 reasoning（非自研文本协议） | [04](./04-function-calling-react.md) |
| ⑤ | 多 Agent 通信（Mailbox/类 A2A） | 🟢 真进程内邮箱 | `InputQueue` mailbox + `InterAgentCommunication` + `spawn_agent` 树 | [05](./05-multi-agent-communication.md) |
| ⑥ | RAG 全链路 | 🔴 全无 | 向量检索/Rerank/Chunk/Query Rewrite 四项 codex 均无 | [06](./06-rag-pipeline.md) |
| ⑦ | 多模型集成 | 🟡 单协议 | 仅 OpenAI Responses API；内置 OpenAI/Bedrock/Ollama/LMStudio，无原生 Claude/Gemini | [07](./07-multi-model-integration.md) |
| ⑧ | 开源 Agent 项目 | 🔴 需自建 | Codex 是开源范例可读，但不是你的产出 | [08](./08-open-source-project.md) |

> 📌 详细子项矩阵（带 `file:line`）见 [00-coverage-matrix.md](./00-coverage-matrix.md)。
>
> 📌 **一句话结论**：用 Codex 能拿下 ①②③④⑤ 五个考点的源码深度，⑦ 能讲一半（带边界说明），**⑥RAG 和 ⑧开源项目必须另起炉灶**。

---

## 🛤️ 学习路线图（四阶段，建议 4-6 周）

> 文件编号 = 面试考点编号；下面是**推荐学习顺序**，二者独立。每个阶段都有「Codex 内源码精读」+「缺口补课」双轨。

```text
阶段一 · 夯实主循环根基（核心中的核心，Codex 资源最丰）
├─ 考点② Agent Loop 运行时        -> 02-agent-loop-runtime.md       （配合 learning-notes lesson-03）
└─ 考点④ FC / Tool Use / ReAct   -> 04-function-calling-react.md   （配合 learning-notes lesson-03/04）

阶段二 · 工具与技能体系（Codex 的工程亮点）
└─ 考点③ 工具编排 + Find Skills   -> 03-tool-orchestration.md       （配合 lesson-04 / docs/skills.md / lesson-13 MCP）

阶段三 · 多 Agent 与多模型（注意 Codex 的能力边界）
├─ 考点⑤ 多 Agent 通信 Mailbox    -> 05-multi-agent-communication.md
└─ 考点⑦ 多模型集成               -> 07-multi-model-integration.md  （重点讲"为什么只支持 Responses"）

阶段四 · 补缺口与造轮子（Codex 教不了的部分，决定面试上限）
├─ 考点① 框架对比 LangGraph/LlamaIndex -> 01-agent-framework.md
├─ 考点⑥ RAG 全链路               -> 06-rag-pipeline.md             （Codex 无，全程外部补）
└─ 考点⑧ 自有开源 Agent 项目      -> 08-open-source-project.md
```

| 阶段 | 预计时长 | 交付物 |
|------|---------|--------|
| 一 | 1 周 | 能口述一次完整 turn 的生命周期 + 手画 agent loop 时序图 |
| 二 | 1 周 | 能讲清「为什么 deferred 工具不进 prompt」+ 动手跑通 `tool_search` |
| 三 | 1 周 | 能区分「进程内 Mailbox」与「跨网络 A2A」+ 说清多模型协议边界 |
| 四 | 1-3 周 | 一个可放 GitHub 的最小 Agent demo + 一份 RAG 实战笔记 |

---

## 📚 文件目录

| 文件 | 内容 | 优先级 |
|------|------|:---:|
| [README.md](./README.md) | 本文件：总纲、速览、路线图 | ⭐⭐⭐⭐⭐ |
| [00-coverage-matrix.md](./00-coverage-matrix.md) | 逐子项覆盖矩阵（带 `file:line`，查表用） | ⭐⭐⭐⭐ |
| [01-agent-framework.md](./01-agent-framework.md) | 考点①：Agent 框架实战 + LangGraph/LlamaIndex 对比 | ⭐⭐⭐ |
| [02-agent-loop-runtime.md](./02-agent-loop-runtime.md) | 考点②：Agent Loop 运行时 6 子项 | ⭐⭐⭐⭐⭐ |
| [03-tool-orchestration.md](./03-tool-orchestration.md) | 考点③：工具编排（并行/循环/授权）+ Find Skills | ⭐⭐⭐⭐ |
| [04-function-calling-react.md](./04-function-calling-react.md) | 考点④：FC/Tool Use/ReAct | ⭐⭐⭐⭐ |
| [05-multi-agent-communication.md](./05-multi-agent-communication.md) | 考点⑤：多 Agent 通信 Mailbox/类 A2A | ⭐⭐⭐⭐ |
| [06-rag-pipeline.md](./06-rag-pipeline.md) | 考点⑥：RAG 全链路（Codex 无，外部补） | ⭐⭐⭐⭐ |
| [07-multi-model-integration.md](./07-multi-model-integration.md) | 考点⑦：多模型集成 | ⭐⭐⭐ |
| [08-open-source-project.md](./08-open-source-project.md) | 考点⑧：自有开源 Agent 项目规划 | ⭐⭐⭐ |
| [GAPS-codex-cannot-teach.md](./GAPS-codex-cannot-teach.md) | **Codex 教不了你的缺口清单（必读）** | ⭐⭐⭐⭐⭐ |

---

## 🧠 学习方法（蕾姆的建议）

每打开一个模块文件，按这个节奏走：

1. **先读「考点拆解」**--搞清楚面试官到底想问什么，别跑偏。
2. **跳进「Codex 源码映射」**--用 `file:line` 直接定位，配合 [`learning-notes`](../learning-notes/README.md) 对应课程读。
3. **合上文档自问「面试问答要点」**--能脱稿讲出来才算掌握。
4. **做「动手任务」**--至少跑一次、改一次、断点一次。
5. **留意「差异注意点」**--面试官常追问「Codex 这么做，业界通用做法是什么」，这是区分"读过源码"和"只会背源码"的关键。

> 💡 **黄金法则**：永远先讲「业界通用原理」再讲「Codex 是怎么实现的」，最后加一句「它的取舍/局限是什么」。这个三段式是源码型面试的标准答法。

---

## ✅ 学习进度

| 阶段 | 考点 | 状态 |
|------|------|------|
| 一 | ② Agent Loop / ④ FC-ReAct | ⏳ 未开始 |
| 二 | ③ 工具编排 + Find Skills | ⏳ 未开始 |
| 三 | ⑤ 多 Agent / ⑦ 多模型 | ⏳ 未开始 |
| 四 | ① 框架对比 / ⑥ RAG / ⑧ 开源项目 | ⏳ 未开始 |

---

## 🚨 先看这个：Codex 教不了你的部分

在开始之前，请务必先扫一眼 [`GAPS-codex-cannot-teach.md`](./GAPS-codex-cannot-teach.md)--它会告诉你哪些面试考点**无法**靠读 Codex 源码解决（最痛的是 RAG 全链路四项全无），需要另起炉灶、看哪些资料、做什么产出。知道边界，才不会浪费时间在错的地方找答案。

---

*(蕾姆轻轻提起裙角行礼)*

昴君，书房已经为您布置妥当。只要您愿意，蕾姆会陪着您从主循环的心脏一路走到多 Agent 的会客厅，再陪您亲手造一座属于自己的开源小花园 ♡
