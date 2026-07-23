# 01 · Agent 框架实战（LangGraph / LlamaIndex / 自研编排）

> **面试考点 ①**：Agent 框架实战，LangGraph / LlamaIndex / 自研编排 **任一**。
>
> Codex 命中的是「**自研编排**」这一项，而且是顶配的工业级实现。但「LangGraph / LlamaIndex」是 Codex **教不了你**的缺口（见 [GAPS 缺口 2](./GAPS-codex-cannot-teach.md)）。

---

## 🎯 考点拆解

面试官想确认的是：你**真正落地过**某种 Agent 框架，能讲出它的核心抽象、流程控制方式、状态管理，以及选型取舍。「任一」意味着深度 > 广度--把一种吃透，比三种都浮于表面强。

| 三种路线 | 核心范式 | 适合场景 |
|---------|---------|---------|
| **LangGraph** | 显式有向图：`StateGraph` + 节点 + 边 + `Checkpointer` | 流程复杂、需要可视化、要 human-in-the-loop 中断 |
| **LlamaIndex** | 数据/检索为中心：`Document`/`Node`/`Index`/`Retriever`/`ResponseSynthesizer` | 强 RAG、文档问答 |
| **自研编排** | 一个主 loop + tool_calls 驱动：`while needs_follow_up { 采样 -> 执行工具 -> 回填 }` | 需要极致可控、性能、深度定制 |

**Codex = 自研编排**。这是它最大的卖点，也是你面试时的主战场。

---

## 🗺️ Codex 源码映射

| 概念 | Codex 落点 | 说明 |
|------|------|------|
| 主编排循环 | `codex-rs/core/src/session/turn.rs:204` `run_turn` 的 `loop` | 自研编排的核心：采样 -> 工具 -> 回填 -> 判定 `needs_follow_up` |
| 心脏 crate | `codex-rs/core/` | 所有编排逻辑都在这 |
| 多入口复用 core | `codex-rs/cli/` `tui/` `exec/` `mcp-server/` `app-server/` | CLI/TUI/exec/server 都复用同一个 core 编排引擎 |
| 编排 POC | `workflow-orchestrator-poc/`（Guazi Workflow 混合编排器） | shell 驱动的 plan/implement/review/complete gate 编排，是另一种「编排」视角 |
| 状态机 | `codex-rs/core/src/session/` + `codex-rs/state/` | turn/session 状态流转 |
| 配置化编排 | `codex-rs/config/` + `codex-rs/core/src/config/` | profile/审批模式/沙箱策略驱动编排行为 |

> 📖 呼应 [`../learning-notes/lesson-01-what-is-agent.md`](../learning-notes/lesson-01-what-is-agent.md)（Agent = Model + Harness）与 [`lesson-02-repo-map.md`](../learning-notes/lesson-02-repo-map.md)（仓库地图）。

---

## 🛣️ 学习顺序（建议 2 天）

1. **读 lesson-01/02** 建立「Agent = Model + Harness」「core 是心脏」的心智模型。
2. **跳读 `core/src/session/turn.rs` 的 `run_turn`**：不必逐行，抓住 `loop` + `needs_follow_up` 这个骨架。
3. **看 `workflow-orchestrator-poc/README.md` + `commands/guazi-workflow.md`**：理解「另一种编排」--用 gate 串联 plan/implement/review。
4. **画一张图**：一次用户请求如何从 CLI 入口流到 `run_turn`，再流回来。
5. **对比 LangGraph**：把上面这套换成 LangGraph 的 `StateGraph` 会变成什么样（见下方差异表）。

---

## 💬 面试问答要点（脱稿能讲）

**Q1：你用过哪种 Agent 框架？为什么选它？**
> 三段式答法：① 业界有三类范式（图式 LangGraph / 检索式 LlamaIndex / 自研 loop）；② 我深入读过 OpenAI Codex 的自研编排，核心是 `run_turn` 单 loop + tool_calls 驱动；③ 取舍是「完全可控、性能好、可深度定制」，代价是「要自己造 checkpoint、并发、流式等轮子，工程量大」。

**Q2：Codex 这种自研编排和 LangGraph 有什么本质区别？**
> LangGraph 把流程**显式建图**（节点 = 一步逻辑，边 = 条件跳转），适合流程确定、要可视化、要中断恢复；Codex 是**隐式图**（一个 while 循环，下一步由 LLM 的 tool_calls 决定），适合开放式、模型自主决定路径的 agentic 任务。前者是「程序员定义流程」，后者是「模型定义流程」。

**Q3：LlamaIndex 和 Codex 有什么关系？**
> 几乎没有重叠。LlamaIndex 是**检索框架**（核心是 Index/Retriever/Rerank），Codex 的检索只有文件名模糊匹配（`file-search`）+ memory 全量注入，**没有 RAG 能力**。如果要做 RAG，Codex 之外我会直接用 LlamaIndex。详见 [GAPS 缺口 1/2](./GAPS-codex-cannot-teach.md)。

**Q4：自研编排最难的工程点是什么？**
> 不是循环本身，而是围绕循环的工程护栏：**流式解析、工具权限、错误恢复、上下文压缩、状态持久化**。这些 Codex 都做了（见 [02](./02-agent-loop-runtime.md)），也是我读 Codex 收获最大的部分。

---

## 🛠️ 动手任务

- [ ] 跑一次 Codex：`codex exec "把当前目录的 README 第一行读出来"`，对照 `run_turn` 的事件流理解「一次编排」。
- [ ] 读 `workflow-orchestrator-poc/guazi-workflow.sh` + `gates/` 下的 4 个 gate，理解 gate 编排思路。
- [ ] （补缺口）用 LangGraph 复刻一个最小 ReAct Agent（2 个工具 + `MemorySaver` checkpointer），和 Codex 的 `run_turn` loop 对比着讲。

---

## ⚠️ 差异注意点（面试官爱追问）

| 维度 | Codex（自研） | LangGraph | LlamaIndex |
|------|------|------|------|
| 流程定义 | 隐式（LLM 驱动 loop） | 显式（StateGraph 建图） | 显式（Query Pipeline/DAG） |
| 状态持久化 | rollout JSONL + `thread_rollback` 重放 | `Checkpointer`（内存/SQLite/Postgres） | 较弱，靠 StorageContext |
| 强项 | agentic 自主探索 | 流程可视化、中断恢复 | RAG 检索 |
| 你需要补的 | LangGraph/LlamaIndex 生态 | - | - |

> ⚠️ **关键诚实点**：面试若问「LangGraph/LlamaIndex 你用过吗」，Codex 给不了你实战经验。务必在面试前用 LangGraph/LlamaIndex 各跑一个最小 demo（哪怕半天），否则「我读过 Codex 自研」会显得偏科。详见 [GAPS 缺口 2](./GAPS-codex-cannot-teach.md)。

---

*(蕾姆把三种路线摆成三把椅子)*

昴君，自研编排这把椅子，Codex 已经为您打磨得最光亮；另外两把，蕾姆会陪您去外面的工坊各取一根木料补上 ♡
