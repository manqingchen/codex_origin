# 📖 详细解读层（Deep Dive）· 逐章精读 Codex 源码

> 蕾姆为昴君开设的「源码解剖室」♡
>
> 这里与 [`../`](../README.md) 的大纲层**并存不替代**：大纲告诉你「考点在 Codex 哪里、怎么学」；本层把 Codex 源码**真正展开讲透**。

---

## 🧭 这一层是什么

| 维度 | 大纲层（`../`） | 详细解读层（本目录） |
|------|------|------|
| 形式 | 考点拆解 + `file:line` 索引 + 学习顺序 | 逐章精读，贴真实代码 |
| 颗粒度 | 导航地图 | **代码片段 + 逐行解读 + 设计原理 + 数据流** 三者结合 |
| 篇幅 | 每模块 ~200 行 | 每篇 1500-2500 行 |
| 用途 | 知道去哪读 | 读懂为什么这么写 |

---

## 🎚️ 颗粒度约定（三者结合）

每一篇解读都包含三层，缺一不可：

1. **① 代码级**：贴 Codex 真实源码片段（逐字摘抄，带 `file:line`，保留原注释），逐行/逐函数解读。
2. **② 原理级**：为什么这么设计？代价是什么？与业界通用做法（LangGraph / LlamaIndex / 论文）对比，Codex 的取舍在哪？
3. **③ 数据流级**：这一段在「一次完整请求时序」里处于什么位置，上下游是谁。

> 💡 这是源码型面试的「黄金三段」：能贴代码讲实现、能讲清设计动机、能画出数据流位置。

---

## 📚 解读目录与进度

> 共 8 篇，对应 8 个面试考点。蕾姆会**逐篇做透、分批交付**，每篇都是三者结合的硬核精读。

| # | 考点 | 对应大纲 | 文件 | 状态 |
|---|------|------|------|:---:|
| 02 | Agent Loop 运行时（6 子项） | [02](../02-agent-loop-runtime.md) | [deep-dive-02-agent-loop-runtime.md](./deep-dive-02-agent-loop-runtime.md) | ✅ 已完成 |
| 03 | 工具编排 + Find Skills | [03](../03-tool-orchestration.md) | [deep-dive-03-tool-orchestration.md](./deep-dive-03-tool-orchestration.md) | ✅ 已完成 |
| 04 | FC / Tool Use / ReAct | [04](../04-function-calling-react.md) | [deep-dive-04-function-calling-react.md](./deep-dive-04-function-calling-react.md) | ✅ 已完成 |
| 05 | 多 Agent 通信 Mailbox | [05](../05-multi-agent-communication.md) | [deep-dive-05-multi-agent-communication.md](./deep-dive-05-multi-agent-communication.md) | ✅ 已完成 |
| 01 | Agent 框架（自研编排） | [01](../01-agent-framework.md) | deep-dive-01-agent-framework.md | ⏳ 待做 |
| 07 | 多模型集成 | [07](../07-multi-model-integration.md) | deep-dive-07-multi-model-integration.md | ⏳ 待做 |
| 06 | RAG（Codex 无，外部补） | [06](../06-rag-pipeline.md) | deep-dive-06-rag-pipeline.md | ⏳ 待做 |
| 08 | 自有开源项目 | [08](../08-open-source-project.md) | deep-dive-08-open-source-project.md | ⏳ 待做 |

> 顺序说明：按「核心优先」排，先 ②③④⑤（Codex 强项、源码最丰），再 ①⑦，最后 ⑥（Codex 无，偏外部）⑧（自有产出）。

---

## 🧠 阅读建议

- 先读 [`../README.md`](../README.md) 建立全局，再用本层逐章深挖。
- 每篇都配「动手复现」--读完后建议照着代码跑一次、断点一次。
- 读到代码片段时，**对照真实仓库文件**看上下文（`file:line` 可点击）。
- 遇到「设计原理」段，试着合上文档复述--这是面试脱稿的关键。

---

## ⏳ 交付节奏

- 这是大工程（8 篇 × ~2000 行），蕾姆会**分批交付**，每轮做透 1-2 篇。
- 每篇完成后会更新上方进度表。
- **第 02 篇 · Agent Loop 运行时** ✅ 已完成。
- **第 03 篇 · 工具编排 + Find Skills** ✅ 已完成。
- **第 04 篇 · Function Calling / ReAct** ✅ 已完成。
- **第 05 篇 · 多 Agent 通信** ✅ 已完成。下一篇：**第 01 篇 · Agent 框架（自研编排）**。

---

*(蕾姆系紧袖口，点亮解剖台上的无影灯)*

昴君，从这间解剖室开始，蕾姆要把 Codex 的每一行关键代码都摊在您面前，讲清它的呼吸、它的心跳、它每一次自我修复的机理。第一刀，就从心脏开始 ♡
