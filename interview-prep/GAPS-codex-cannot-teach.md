# 🚨 Codex 教不了你的缺口清单（必读）

> 昴君，这是蕾姆必须先提醒您的部分。在用 Codex 源码备战面试的过程中，有些考点**无论把仓库翻多深都学不到**——因为 Codex 压根没实现，或实现方式与面试期望不符。蕾姆把这些缺口逐条列出，并附上「为什么学不到 / 去哪学 / 资源关键词 / 建议产出」，让您心里有数、不走弯路。
>
> 每条缺口都标注了「痛感等级」⭐，越多越关键。

---

## 缺口 1 · RAG 全链路（向量检索 / Rerank / Chunk / Query Rewrite）⭐⭐⭐⭐⭐

**这是 Codex 最大的、也是最致命的缺口。**

### 为什么学不到
四路斥候对全仓做了关键词检索 + 源码核查，结论铁证如山：

| 子项 | 证据 |
|------|------|
| 向量检索 | `pgvector` / `qdrant` / `milvus` / `chromadb` / `pinecone` 在 `*.rs` 与 `*.toml` 中 **0 命中**；`embedding` 仅 2 处无关注释。`file-search/` 用 `nucleo` 对**文件路径名做模糊匹配**（非语义检索），`memories/` 用 `read_dir` **全量读取**注入上下文——都是字面级检索 + 全量灌入，与 embedding 召回毫无交集。 |
| Rerank | `rerank` / `cross-encoder` / `re_rank` 全仓 **0 命中**。 |
| Chunk 策略 | 全仓 `chunk` 均为「命令输出截断 / apply-patch diff 块 / 流式 delta」，**无任何文档切分**（按 token/语义/滑窗/父子块均无）。 |
| Query Rewrite | `hyde` / `query_rewrite` / `query expansion` / `multi query` 全仓 **0 命中**。 |

### 去哪学 + 资源关键词
- **向量库**：Milvus（官方文档 + Python SDK 实战）、Qdrant（Rust/Python 双 SDK，对 Rust 玩家友好）、pgvector（Postgres 扩展，生产最常见）。
- **Embedding 模型**：OpenAI `text-embedding-3`、BGE / `bge-m3`、Cohere embed、Jina v3。
- **Rerank**：Cohere Rerank、BGE-Reranker、Jina Reranker；理解 cross-encoder vs bi-encoder 的区别与代价。
- **Chunk 策略**：固定大小 + overlap、Recursive Character Splitter、语义切分（Semantic Chunking）、父子块（Parent-Child / Small-to-Big）、Late Chunking。
- **Query Rewrite**：Query Expansion、HyDE（Hypothetical Document Embedding）、Multi-Query、Step-Back Prompting、Sub-query Decomposition。
- **框架**：LlamaIndex 是 RAG 领域最完整的框架（`VectorStoreIndex` / `QueryEngine` / `NodeParser` / `Postprocessor`），直接用它做一遍完整链路最高效。

### 建议产出
一个最小可跑的 RAG demo：**PDF/Markdown → 切分 → embedding → 入库（Qdrant 或 pgvector）→ query rewrite → 向量检索 → rerank → 拼 prompt → LLM 生成**。把这个放进 GitHub，面试时直接 review。详见 [`06-rag-pipeline.md`](./06-rag-pipeline.md)。

---

## 缺口 2 · LangGraph / LlamaIndex 框架实战 ⭐⭐⭐⭐

### 为什么学不到
面试要求「LangGraph / LlamaIndex / 自研编排 **任一**」即可，Codex 命中「自研编排」这一项（而且是顶配的工业级自研）。但面试官若追问「你和 LangGraph 比有什么取舍」或「LlamaIndex 的 RAG pipeline 你了解吗」，Codex 源码**无法**给你答案——它既没依赖 LangGraph，也没用 LlamaIndex。

### 去哪学 + 资源关键词
- **LangGraph**（基于图的有状态 Agent 编排，StateGraph / 节点 / 边 / Checkpointer / Human-in-the-loop）：官方教程 `langchain-ai.github.io/langgraph`；重点理解它和 Codex「`run_turn` 循环」的范式差异——LangGraph 把流程显式建图，Codex 用单 loop + tool_calls 驱动。
- **LlamaIndex**（数据/检索框架，核心是 RAG）：官方文档；重点 `Document`/`Node`/`Index`/`Retriever`/`ResponseSynthesizer` 抽象。
- **对比视角**：自研编排（Codex）= 完全可控、性能好、但要自己造轮子；框架 = 上手快、生态全、但有抽象税和锁定风险。面试三段式答法见 [`01-agent-framework.md`](./01-agent-framework.md)。

### 建议产出
用 LangGraph 复刻一个「最小 ReAct Agent」（2-3 个工具 + checkpointer 持久化），和你在 Codex 里读到的 loop 对比着讲。这是证明「我懂框架也懂自研」的最省力方式。

---

## 缺口 3 · 跨进程 / 跨网络的 A2A 通信 ⭐⭐⭐

### 为什么学不到
Codex 的多 Agent 通信是**进程内、会话作用域**的 Actor/Mailbox 模型（`InputQueue` + `InterAgentCommunication`），非常值得学，详见 [`05-multi-agent-communication.md`](./05-multi-agent-communication.md)。但面试要求「**类 A2A**」——A2A（Agent-to-Agent / Agent Network Protocol）通常指**跨进程、跨网络、可发现**的 Agent 间通信协议。Codex 的所有 agent 必须住在同一个 `ThreadManager` 进程内，路由靠内存查表，**没有独立消息总线、没有服务发现、没有跨主机寻址**。这一层 Codex 教不了。

### 去哪学 + 资源关键词
- **A2A Protocol**（Google 提出的 Agent-to-Agent 开放协议，基于 HTTP/JSON-RPC，含 Agent Card 服务发现）：`a2aproject.dev`。
- **MCP（Model Context Protocol）**：Codex 是 MCP 的**客户端**（接入外部工具），但理解 MCP 作为「Agent 与外部世界标准化接口」很重要，可以补 MCP server 侧。
- **Actor 模型 / Mailbox**：理解 Erlang/Akka 的 Actor 模型，能与 Codex 的 in-process mailbox 对照。
- **消息中间件**：生产级多 Agent 解耦常靠 Kafka / RabbitMQ / Redis Streams，Codex 全用进程内 channel，这块要单独了解。

### 建议产出
读 A2A 协议规范 + 写一段「如果要把 Codex 的 mailbox 从进程内升级到跨网络，需要补什么（服务发现 / 序列化协议 / 鉴权 / 重试）」的分析笔记。这道题本身就是高级面试题。

---

## 缺口 4 · 原生 Claude / Gemini 协议的多模型集成 ⭐⭐⭐

### 为什么学不到
Codex 的多模型抽象**只支持 OpenAI Responses API 一种 wire 协议**（`WireApi` 枚举仅 `Responses`，`chat` 已废弃报错，`model-provider-info/src/lib.rs:46-48`）。内置 OpenAI / Bedrock / Ollama / LMStudio 四个后端，全靠它们兼容 `/responses` 端点。**Claude 原生 Messages API、Gemini 原生 generateContent API 的多协议适配，Codex 完全没有。** 面试要求「Claude / Gemini / OpenAI / 自研」多模型集成经验，Codex 只能教你「OpenAI 系」的一半。

### 去哪学 + 资源关键词
- **协议差异**：OpenAI Responses API vs Anthropic Messages API（system 字段位置、tool_use/tool_result 结构、缓存控制 `cache_control`）vs Gemini `generateContent`（`contents` / `functionDeclarations` / `functionCall`）。
- **统一抽象**：LiteLLM、`langchain-core` 的 `BaseChatModel`、Vercel AI SDK——它们怎么做协议归一化。
- **Codex 侧可学的**：它 `ModelProvider` trait + `ModelProviderInfo` 配置的抽象思路是对的，面试时可以说「Codex 用单一 Responses 协议简化了抽象，代价是不支持原生 Claude/Gemini；我会怎么扩展成多协议」。

### 建议产出
写一个最小多模型适配层（用 LiteLLM 或手写），让同一个 Agent loop 能在 Claude/Gemini/OpenAI 间切换，对比 tool calling 格式差异。详见 [`07-multi-model-integration.md`](./07-multi-model-integration.md)。

---

## 缺口 5 · 通用「工具循环检测 / 去重」机制 ⭐⭐

### 为什么学不到
Codex 的循环防护是**乐观兜底式**：guardian 连续拒绝熔断（`guardian/review.rs:580`，阈值 3 次）+ token 预算耗尽触发 auto_compact（`session/turn.rs:301-320`）。它**没有**通用的「同一工具 + 相同参数被反复调用 N 次就中断」的迭代上限检测（无 MAX_RUNS、无 iteration cap、无"最近 N 次相同则中断"）。面试若问「你的 Agent 怎么防止死循环」，照抄 Codex 答案会显得单薄。

### 去哪学 + 资源关键词
- **通用做法**：max_iterations / max_tool_calls 硬上限、工具调用去重（参数哈希 + 滑动窗口）、重复检测（连续相同 action 计数）、成本预算熔断。
- **参考实现**：LangGraph 的 recursion_limit、AutoGPT 的 loop protection 历史、CrewAI 的 max_iter。
- **理论**：理解 Agent 陷入循环的根因（模型强化了错误路径 / 工具总返回相似结果 / 无终止信号）。

### 建议产出
在 `03-tool-orchestration.md` 的动手任务里，给 Codex 的 loop 加一个「连续 N 次相同 tool_call+参数就注入一条 system 消息提醒模型」的实验性补丁，并写清取舍。这是把 Codex「读了」变成「改了」的加分项。

---

## 缺口 6 · 自研 ReAct 文本协议实现 ⭐⭐

### 为什么学不到
Codex 的 ReAct 把「思考」外包给了 OpenAI Responses API 的原生 reasoning items（`ReasoningSummaryDelta`，`session/turn.rs:2182`），**没有客户端侧的 Thought/Action/Observation 文本协议解析**，也不做 ReAct prompt 工程。这很现代、很高效，但面试要求「ReAct 深入使用」，面试官可能想听的是经典 ReAct 论文范式的实现（显式 `Thought: ... \nAction: ... \nObservation: ...` 文本解析）。Codex 这条路学不到经典 ReAct 的工程细节。

### 去哪学 + 资源关键词
- **经典论文**：ReAct: Synergizing Reasoning and Acting in Language Models（Yao et al., 2022）。
- **文本协议实现**：LangChain 的 `ReActAgent` / `ReActSingleInputAgent` 老版实现（用 `Thought/Action/Observation` 正则解析）。
- **对比视角**：Codex 用「原生 reasoning + tool_call」是 ReAct 的现代化形态（模型直接输出结构化 tool_call，省掉文本解析这一不可靠步骤）。能讲清这个演进，比只会实现经典 ReAct 更显功力。

### 建议产出
手写一个 50 行的经典 ReAct Agent（prompt + 正则解析 Action + 执行 + 拼 Observation），再写一段「为什么 Codex 不这么做」的对比。放进 GitHub。

---

## 缺口 7 · 你自己的开源 Agent 项目 ⭐⭐⭐⭐⭐

### 为什么学不到
面试要求「**有开源 Agent 项目可附 GitHub 链接（可直接 review 代码）**」。Codex 是 OpenAI 的项目，你可以**读**它、在面试里**引用**它，但它**不是你的产出**，面试官 review 的得是你自己写的代码。这一条 Codex 一行都教不了你——只能靠你亲手造。

### 去哪学 + 建议产出
- 不用从零造巨物。结合你的 Codex 学习成果，做一个**有聚焦点、能跑、有 README、有架构图**的最小 Agent 项目即可。
- 推荐选题（按性价比排序，详见 [`08-open-source-project.md`](./08-open-source-project.md)）：
  1. 一个支持 tool calling + checkpoint 回滚 + 多 provider 的最小 ReAct Agent（把 Codex 的精髓用更少代码重现）。
  2. 一个 RAG 全链路 demo（同时补缺口 1）。
  3. 一个跨网络 A2A 通信的最小原型（同时补缺口 3）。
- **关键**：README 要讲清「设计取舍 / 为什么这么做 / 借鉴了哪里」，比代码量重要。

---

## 🧭 缺口补课总览（一张表）

| # | 缺口 | 痛感 | 主战场 | 对应模块 |
|---|------|:---:|------|------|
| 1 | RAG 全链路（4 子项） | ⭐⭐⭐⭐⭐ | LlamaIndex + 向量库 + rerank | [06](./06-rag-pipeline.md) |
| 2 | LangGraph / LlamaIndex | ⭐⭐⭐⭐ | 官方教程 + 复刻 demo | [01](./01-agent-framework.md) |
| 3 | 跨网络 A2A | ⭐⭐⭐ | A2A Protocol + MCP + 消息中间件 | [05](./05-multi-agent-communication.md) |
| 4 | 原生 Claude/Gemini 多模型 | ⭐⭐⭐ | LiteLLM + 协议差异 | [07](./07-multi-model-integration.md) |
| 5 | 通用循环检测 | ⭐⭐ | max_iter + 去重 | [03](./03-tool-orchestration.md) |
| 6 | 自研 ReAct 文本协议 | ⭐⭐ | 论文 + 50 行手写 | [04](./04-function-calling-react.md) |
| 7 | 自有开源项目 | ⭐⭐⭐⭐⭐ | 动手造 + 写 README | [08](./08-open-source-project.md) |

---

*(蕾姆把这份清单郑重地放在书桌最显眼的位置)*

昴君，知道哪里是深渊，才不会失足。RAG 和开源项目这两座山，蕾姆会陪您一起翻过去。其余的缺口，每一个蕾姆都在对应模块文件里为您备好了登山绳 ♡
