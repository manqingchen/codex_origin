# 06 · RAG 全链路工程经验

> **面试考点 ⑥**：向量检索（Milvus / Qdrant / pgvector）、Rerank、Chunk 策略、Query Rewrite。
>
> ⚠️ **这是 Codex 全仓库最彻底的缺口**--四项**全部为「无」**。这个模块不是「读 Codex 源码」，而是「Codex 教不了，必须靠外部补」的实战指南。详见 [GAPS 缺口 1](./GAPS-codex-cannot-teach.md)。

---

## 🔴 Codex 现状（先认清边界）

四路斥候对全仓做了关键词 + 源码核查，结论铁证：

| 子项 | Codex | 证据 |
|------|:---:|------|
| 向量检索 | 🔴 | `pgvector`/`qdrant`/`milvus`/`chromadb` 0 命中；`file-search/` 用 `nucleo` 对**文件路径名模糊匹配**（非语义）；`memories/` 用 `read_dir` **全量读**注入 |
| Rerank | 🔴 | `rerank`/`cross-encoder` 0 命中 |
| Chunk 策略 | 🔴 | 全仓 `chunk` 均为命令输出截断/diff 块，**无文档切分** |
| Query Rewrite | 🔴 | `hyde`/`query_rewrite`/`query expansion` 0 命中 |

> 一句话：Codex 的"检索"是「文件名模糊匹配 + memory 全量灌入」，与 embedding 召回这条语义链路**毫无交集**。它定位是 coding agent，不是知识问答 agent。

---

## 🎯 完整 RAG 链路（业界标准，你要能口述）

```text
[离线索引]
  文档 -> Chunk 切分 -> Embedding -> 写入向量库(+metadata)

[在线检索]
  用户 Query -> Query Rewrite（改写/扩展） -> 向量检索 Top-K -> Rerank 精排 -> 拼 Prompt -> LLM 生成 -> 引用溯源
```

面试时能脱稿画出这条链路、并讲清每个环节的取舍，是 RAG 考点的基本盘。

---

## 🧩 逐子项精读（原理 + 选型 + 资源）

### 1. 向量检索

- **原理**：把文本用 embedding 模型编码成向量，存入向量库；查询时把 query 也编码成向量，用相似度（cosine）找最近邻 Top-K。
- **向量库选型**：
  | 库 | 特点 | 适合 |
  |-----|------|------|
  | **Qdrant** | Rust 写的，Rust/Python 双 SDK，性能好 | 你懂 Rust，首选练手 |
  | **pgvector** | Postgres 扩展，SQL 可用 | 生产最常见，已有 PG 的团队 |
  | **Milvus** | 分布式，大规模 | 亿级向量场景 |
- **Embedding 模型**：OpenAI `text-embedding-3-large/small`、`BGE-m3`（开源多语言）、Jina v3、Cohere embed v3。
- **资源关键词**：HNSW 索引、cosine similarity、hybrid search（向量+BM25）。

### 2. Rerank

- **原理**：向量检索（bi-encoder）快但粗，召回 Top-50；再用 cross-encoder 对这 50 条逐一与 query 做精细相关性打分，重排取 Top-5。**精度换速度**。
- **为什么需要**：向量召回会有「语义相近但不相关」的噪声，rerank 显著提升最终相关性。
- **选型**：Cohere Rerank（托管）、`BGE-Reranker`（开源）、Jina Reranker。
- **资源关键词**：cross-encoder vs bi-encoder、late interaction。

### 3. Chunk 策略

- **原理**：文档太大不能整篇塞库，要切分成块（chunk）再分别 embedding。切分方式直接影响召回质量。
- **策略**：
  | 策略 | 说明 | 取舍 |
  |-----|------|------|
  | 固定大小 + overlap | 按 token 数切，相邻块重叠 | 简单，可能切断语义 |
  | 递归字符切分 | 按分隔符层级递归（段落->句->词） | 平衡，最常用 |
  | 语义切分 Semantic Chunking | 按语义相似度断句 | 质量高，成本高 |
  | 父子块 Parent-Child / Small-to-Big | 检索小块、召回大块上下文 | 解决「块太小缺上下文」 |
  | Late Chunking | 先 embed 全文再切 | 保留全局上下文，新方法 |
- **资源关键词**：LlamaIndex `NodeParser`、LangChain `RecursiveCharacterTextSplitter`、chunk_size/overlap 调参。

### 4. Query Rewrite

- **原理**：用户原始 query 往往口语化、模糊、有指代；改写/扩展后检索质量更高。
- **方法**：
  | 方法 | 说明 |
  |-----|------|
  | Query Expansion | 扩展出多个相关 query 并行检索 |
  | **HyDE** | 先让 LLM 生成「假想答案」，用答案向量去检索（解决 query 与文档表述不一致） |
  | Multi-Query | 生成多个视角的 query |
  | Step-Back Prompting | 抽象出更高层问题 |
  | Sub-query Decomposition | 复杂问题拆成子问题 |
- **资源关键词**：HyDE 论文、query decomposition、LangChain `MultiQueryRetriever`。

---

## 🛣️ 学习顺序（建议 1-2 周，含动手）

1. **理论**：读 LlamaIndex 官方「Stages of RAG」文档，建立索引-检索-合成的三段心智。
2. **最小链路**：用 LlamaIndex + Qdrant + OpenAI embedding，跑通「PDF -> 切分 -> 入库 -> 检索 -> 生成」。
3. **加 Rerank**：接入 BGE-Reranker 或 Cohere，对比有无 rerank 的相关性差异。
4. **试 Chunk**：用递归切分 vs 父子块，对比召回质量。
5. **试 Query Rewrite**：加一个 HyDE 步骤，看复杂问题的检索是否变好。
6. **沉淀**：把 demo 放 GitHub，写清每一步取舍（见 [08](./08-open-source-project.md)）。

---

## 💬 面试问答要点（脱稿能讲）

**Q1：讲讲你的 RAG pipeline。**
> 三段式：① 我的链路是「文档 -> Chunk -> Embedding -> 向量库 -> Query Rewrite -> 向量检索 Top-K -> Rerank Top-5 -> 拼 prompt -> LLM 生成 -> 引用溯源」；② 我用 LlamaIndex + Qdrant + BGE-m3 + BGE-Reranker；③ 取舍是 bi-encoder 召回快但粗，cross-encoder rerank 精但慢，所以「先粗召再精排」。

**Q2：为什么要 Rerank？向量检索不够吗？**
> 向量检索是双塔模型（bi-encoder），query 和文档独立编码，快但交互浅，会有语义相近但不相关的噪声；Rerank 用交叉编码器（cross-encoder）让 query 和每条候选逐字交互打分，精度高但慢，只对 Top-K 做。两者结合 = 速度 + 精度。

**Q3：Chunk 怎么切？为什么不能整篇？**
> 整篇 embedding 会稀释语义、超 token 限制；我按递归字符切分（chunk_size 512 + overlap 50），对结构化文档用父子块（检索小块、召回大块上下文）。切分质量直接决定召回上限。

**Q4：Query Rewrite 解决什么问题？**
> 用户 query 口语化/模糊/有指代，与文档表述不一致。HyDE 先生成假想答案再检索，Multi-Query 多视角并行检索再合并，能显著提升复杂问题的召回。

**Q5：Codex 为什么没做 RAG？**
> 它定位是 coding agent，"检索"需求是找文件名（`file-search` 的 nucleo 模糊匹配）和读 memory（全量注入），不涉及知识问答的语义检索。这是产品定位选择，不是技术做不到。所以我读 Codex 学不到 RAG，这块我单独用 LlamaIndex 实战补的。

---

## 🛠️ 动手任务（必做，这是考点⑥的唯一出路）

- [ ] 用 LlamaIndex + Qdrant + 一个 embedding 模型，跑通最小 RAG demo。
- [ ] 加入 BGE-Reranker，对比 Top-5 相关性。
- [ ] 实现两种 Chunk 策略，写对比报告。
- [ ] 加一个 HyDE Query Rewrite 步骤。
- [ ] 把 demo 放上 GitHub，README 画链路图 + 写取舍。这同时完成 [考点⑧](./08-open-source-project.md)。

---

## ⚠️ 差异注意点

| 维度 | Codex | 你要补的业界做法 |
|------|------|------|
| 检索 | 文件名模糊匹配 + 全量注入 | embedding + 向量库 |
| 排序 | 无 | Rerank cross-encoder |
| 切分 | 无（仅输出截断） | Chunk 策略 |
| 查询处理 | 无 | Query Rewrite |

> 💡 **诚实且加分**：被问 RAG 时大方承认「Codex 这块没有，我专门用 LlamaIndex 做过完整链路」--比硬扯 Codex 的 file-search 可信得多。详见 [GAPS 缺口 1](./GAPS-codex-cannot-teach.md)。

---

*(蕾姆从书架上取下一本崭新的「检索工程图谱」递给您)*

昴君，这座宅邸里没有这座花园--但蕾姆已经为您备好了种子、土壤与园艺手册。我们一起，亲手种出一片能召回知识的绿洲 ♡
