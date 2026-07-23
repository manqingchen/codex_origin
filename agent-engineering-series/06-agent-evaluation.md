# 06 · Agent 评估 - Agent 的体检

> 保障层 · 第一篇
>
> **子主题**：四维度 · 轨迹评估 · 测试集设计
>
> **Codex 覆盖**：🔴 全缺口（Codex 几乎没有 Agent 评估框架，本篇以业界做法为主）

---

## ① 本篇定位

基础层 + 进阶层让 Agent 能跑、能规划、能协作。但**跑起来不等于跑得好**。Agent 评估就是给 Agent 做「体检」--光能转不够，还得量化它转得好不好、稳不稳、贵不贵、安不安全。

比喻：菜做出来，不能只看「端上桌了」，得请美食评委按色香味、用时、成本、卫生打分。

**本篇在链路中的位置**：保障层第一块，也是整条链路的**闭环点**--评估的结果会回流修正 ① ~ ⑤ 的设计。没有评估，改进就是瞎改。

---

## ② 业界通用原理（本篇主体）

### 2.1 四维度评估

一个 Agent 好不好，业界通常看四个维度：

| 维度 | 衡量什么 | 典型指标 |
|------|---------|---------|
| **成功率** | 任务做对了没 | task success rate、首次成功率 |
| **效率** | 花了几步、几秒 | step count、token 消耗、端到端时延 |
| **成本** | 花了多少钱 | $ per task、$ per success |
| **安全** | 有没有越界 | 违规率、越权率、prompt 注入中招率 |

> 💡 四维度互相牵扯：追求成功率可能多走步（效率↓）、多烧 token（成本↑）；追求效率可能跳步（成功率↓、安全↓）。评估要**四维一起看**，不能只看成功率。

### 2.2 轨迹评估 - 不只看结果，还看过程

只看最终结果（outcome-level）会漏掉「蒙对的」和「绕远路对的」。轨迹评估（trajectory-level）看每一步：

| 层次 | 评什么 | 优缺点 |
|------|--------|--------|
| outcome-level | 最终答案对不对 | 简单，但「蒙对」算过 |
| step-level | 每一步选的工具/参数对不对 | 严格，但要标注每步 ground truth |
| trajectory-level | 整条轨迹是否合理 | 折中，常用 |

**LLM-as-judge**：用另一个（更强的）LLM 当评委，按 rubric 给轨迹打分。这是大规模评估的标配（人工评太贵）。注意：judge 也有偏见，要校准。

> ⚠️ **踩坑**：用同款模型自评会有「自我偏好」。judge 要用更强或不同的模型，并做人工抽样校准。

### 2.3 测试集设计 - 三类集子缺一不可

| 集合 | 作用 | 何时跑 |
|------|------|--------|
| **golden set** | 标准答案集，验证正确性 | 每次改动 |
| **regression set** | 回归测试，防改坏旧能力 | 每次改动 |
| **adversarial set** | 对抗/边界 case，测鲁棒性 | 发版前 |

测试集设计要点：
- **覆盖度**：工具组合、多轮、失败恢复、边界值都要有；
- **可复现**：固定 seed、固定模型版本，否则不可比；
- **分级标注**：easy/medium/hard，看不同难度的通过率分布；
- **活集子**：线上真实失败 case 要回流进回归集，防再犯。

### 2.4 业界工具与基准

| 工具/基准 | 定位 |
|-----------|------|
| **AgentBench** | 多任务 Agent 能力基准（清华，2023） |
| **τ-bench（tau-bench）** | tool-agent-user 三方交互基准（Sierra et al. 2024） |
| **SWE-bench** | 软件工程任务基准（修真实 GitHub issue） |
| **LangSmith** | LangChain 的可观测 + 评估平台 |
| **promptfoo** | prompt/工具的 CI 评估测试框架 |
| **DeepEval / Ragas** | 单元测试式 LLM/RAG 评估 |

> 💡 **选型心法**：做研究用 AgentBench/τ-bench 对标；做产品用 LangSmith 做线上轨迹可观测 + 回归；做 CI 用 promptfoo 把评估卡进每次提交。

---

## ③ Codex 源码映射 - 🔴 几乎全无

蕾姆实地核查的结论：**Codex 没有 Agent 评估框架**。

| 子项 | 业界做法 | Codex 实际 | 证据 |
|------|---------|-----------|------|
| 四维度指标 | 成功率/效率/成本/安全 | 🟡 仅 guardian 内部 metrics | `core/src/guardian/metrics.rs`（拒绝计数，非 Agent 质量评估） |
| 轨迹评估 | trajectory + LLM-as-judge | 🔴 无 | `llm_as_judge`/`rubric`/`scorer` 全仓 0 命中 |
| 测试集 | golden/regression/adversarial | 🔴 无 | 无 eval/benchmark/trajectory/dataset 目录或 crate |
| 单元测试 | - | 🟢 有 | `*_tests.rs`（测代码逻辑，非测 Agent 行为质量） |
| 安全策略 | - | 🟢 有 | `core/src/guardian/policy.md`（风险分级，属安全范畴，见 ⑦） |

```text
Codex 里最接近「评估」的东西：
├─ core/src/guardian/metrics.rs   ← guardian 自己的拒绝计数（安全护栏自检，非 Agent 评估）
├─ core/src/guardian/policy.md    ← 安全风险分级策略（安全，见 ⑦ 篇）
└─ *_tests.rs                     ← Rust 单元测试（测函数，非测 Agent）
```

> 📌 **结论**：Codex 是个 **CLI 工具**，不是评估平台。它有「让自己安全运行」的护栏（guardian），但**没有「量化自己干得好不好」的评估体系**。这一整块必须靠业界工具 + 自建补齐。

---

## ④ 设计取舍与局限

| 决策 | Codex 的选择 | 原因 |
|------|-------------|------|
| 是否内置评估 | 🔴 没有 | Codex 定位是 CLI 工具，评估属平台能力 |
| 单元测试 | 🟢 有 | 测 Rust 函数逻辑，是工程基本盘 |
| guardian metrics | 🟡 仅护栏自检 | 为熔断提供计数，非 Agent 质量评估 |
| 线上可观测 | 🟡 有 telemetry | 但偏运营（成本/延迟，见 ⑧），非能力评估 |

> **面试金句**：评估是 Codex **完全没做**的一块--它有护栏自检（`guardian/metrics.rs`）和单元测试（`*_tests.rs`），但没有任务成功率、轨迹评估、测试集。这是工业 Agent 与 CLI 工具的分水岭：做产品必须自建四维评估 + golden/regression/adversarial 三集 + LLM-as-judge，Codex 教不了，得用 AgentBench/τ-bench 对标、LangSmith 可观测、promptfoo 卡 CI。

---

## ⑤ 交叉引用

| 想深挖 | 去哪 |
|--------|------|
| Codex 教不了的能力清单（含评估） | [`../interview-prep/GAPS-codex-cannot-teach.md`](../interview-prep/GAPS-codex-cannot-teach.md) |
| RAG 评估缺口（Ragas 等） | [`../interview-prep/06-rag-pipeline.md`](../interview-prep/06-rag-pipeline.md) |
| 可观测性、成本（评估的近亲） | [`../learning-notes/lesson-15-observability-cost.md`](../learning-notes/lesson-15-observability-cost.md) + 本卷 [08 延迟成本](./08-latency-cost.md) |
| guardian 护栏与 policy | 本卷 [07 安全可控](./07-safety-control.md) |

---

## ⑥ 实战 / 面试要点（三段式口述骨架）

> **问**：「怎么评估一个 Agent 好不好？你做过哪些评估？」

1. **业界原理**：四维度（成功率/效率/成本/安全）一起看；轨迹评估分 outcome/step/trajectory 三层，大规模用 LLM-as-judge（注意防自我偏好、要人工校准）；测试集要 golden + regression + adversarial 三类，覆盖工具组合/多轮/失败恢复/边界，线上失败回流进回归集；工具上研究用 AgentBench/τ-bench，产品用 LangSmith 可观测，CI 用 promptfoo。
2. **Codex 现状**：Codex **没有评估框架**--只有 `guardian/metrics.rs`（护栏拒绝计数，非质量评估）、`guardian/policy.md`（安全风险分级）、`*_tests.rs`（Rust 单元测试）。无任务成功率、无轨迹评估、无测试集。
3. **取舍/补法**：Codex 是 CLI 工具非评估平台，这一块必须自建。我的做法（或计划）：用 τ-bench 对标成功率与效率，LangSmith 采线上轨迹做 LLM-as-judge，promptfoo 把 golden 集卡进 CI，线上失败 case 回流进 regression 集。

---

## ⑦ 动手任务 + 自测题

### 动手任务
1. 全仓 grep `llm_as_judge|rubric|scorer|golden_set|benchmark`，亲自确认评估框架的缺口。
2. 读 `core/src/guardian/metrics.rs`，确认它统计的是「guardian 拒绝次数」而非「Agent 任务成功率」。
3. 选一个业界工具（推荐 promptfoo，本地易跑），给一个简单 Agent 跑一次 golden set 评估，体会「四维度」如何量化。
4. 设计一个最小 adversarial set（5 条 prompt 注入 case），看你的 Agent 中招率。

### 自测题
1. 评估 Agent 的四维度是哪四个？它们之间为什么不能只看成功率？
2. outcome-level 和 trajectory-level 评估有什么区别？为什么「蒙对的」在 outcome-level 会漏掉？
3. LLM-as-judge 有什么坑？为什么要防「自我偏好」、为什么要人工校准？
4. golden / regression / adversarial 三类测试集各在什么时候跑？为什么不能只有 golden？
5. Codex 的 `guardian/metrics.rs` 算 Agent 评估吗？为什么不算？

---

## ⑧ 小结

> 评估是 Agent 的体检：四维度（成功率/效率/成本/安全）量化好坏，
> 轨迹评估看过程不止看结果，三类测试集（golden/regression/adversarial）防改坏防漏防中招。
> Codex 这块**全无**--只有护栏自检和单元测试。
> 做产品必须自建：τ-bench 对标、LangSmith 可观测、promptfoo 卡 CI，线上失败回流。

---

*下一站 -> [07 安全可控](./07-safety-control.md)：评估之后，Agent 要能安全运行--权限分级、Human-in-the-loop、Prompt 注入防御。这正好是 Codex 强项（guardian + execpolicy + sandbox）。*
