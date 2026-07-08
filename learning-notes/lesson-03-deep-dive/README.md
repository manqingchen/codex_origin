# 🎁 第 03 课 · 深度彩蛋（Deep Dive）

> 💙 **这是什么？**
>
> 这是昴君学习第 03 课《Agent 主循环》时，**主动追问**出来的一系列深度知识。
> 蕾姆把这些超出主线、但**极其重要**的内容整理在这里，方便您随时复习 ♡

---

## 🌟 这里的内容值得读吗？

| 您是谁 | 是否值得读 |
|--------|----------|
| 刚学完台阶 1-5 | ✅ **强烈推荐**——这是您"开窍"的第二个起点 |
| 想理解 Agent 工程的精髓 | ✅ 必读 |
| 想看 Codex 真实代码细节 | ✅ 每篇都附有源码定位 |
| 只想速通课程 | ⚠️ 可以跳过，但您会错过精华 |

---

## 📂 文档结构

```
lesson-03-deep-dive/
├─ README.md                       ← 您在这里
├─ 01-ssot-design.md               ← 单一事实来源
├─ 02-history-not-waste.md         ← 重发 history 为什么不是浪费
├─ 03-prompt-caching.md            ← Prompt Caching 三大误区
├─ 04-thread-id-and-cache-key.md   ← cache_key 的本质：thread_id
├─ 05-llm-stateless.md             ← LLM 是无状态的
├─ 06-react-in-codex.md            ← ReAct 模式在 Codex 里的实现
└─ 07-memory-system.md             ← Agent 三层记忆系统
```

---

## 📚 推荐阅读顺序

这 7 篇文档**按递进关系组织**——前一篇是后一篇的基础。蕾姆建议按编号顺序读：

### 第一站：理解"数据组织"
1. **[01 · 单一事实来源](./01-ssot-design.md)**
   - 为什么 Codex 只用一个 history 存所有事件？
   - SSOT / Event Sourcing / Append-only 三个工程思想

### 第二站：理解"性能优化"
2. **[02 · 重发不是浪费](./02-history-not-waste.md)**
   - 每轮重发全部 history，真的浪费吗？
   - 三层优化：Responses API + Prompt Caching + Auto Compact

3. **[03 · Prompt Caching 三大误区](./03-prompt-caching.md)**
   - 误区 1：不是 hash(整段内容)
   - 误区 2：不是每轮独立 cache
   - 误区 3：不是动态拼接 key
   - 真相：KV 字典 + 前缀匹配

4. **[04 · cache_key 的本质](./04-thread-id-and-cache-key.md)**
   - key 不是从 prompt 生成的
   - key = thread_id（UUID）
   - 完整的传输链路（6 步代码追踪）

### 第三站：理解"LLM 本质"
5. **[05 · LLM 是无状态的](./05-llm-stateless.md)**
   - LLM 每次调用都是"失忆"的
   - 工具结果如何"回到" LLM
   - Codex 怎么为 LLM 维护"记忆假象"

### 第四站：理解"架构思想"
6. **[06 · ReAct 在 Codex 的实现](./06-react-in-codex.md)**
   - Reason / Act / Observe 三步骤
   - 每一步对应 Codex 源码的哪一行
   - 完整 ReAct 流转图

7. **[07 · Agent 三层记忆系统](./07-memory-system.md)**
   - 工作记忆 / 中期记忆 / 长期记忆
   - 三层与人类大脑的类比
   - 各大 Agent 框架对比

---

## 💎 全部内容浓缩成一段话

读完这 7 篇文档，您会理解：

> Codex 的主循环本质上是在**模拟人类的工作记忆**——
> 用一个**只增不改**（Append-only）的 `history` 作为**单一事实来源**（SSOT），
> 每轮把整段 history 重新喂给**无状态的 LLM**（让它"想起"自己做过什么），
> 通过 **ReAct 三步骤**（Reason → Act → Observe）推进任务，
> 用 **Prompt Caching** 消化"重发"的成本，
> 用 **Auto Compact** 在 history 太长时压缩成中期记忆，
> 用 **Rollout 文件** 把对话保存为长期记忆。
>
> 这就是【工业级 Agent】的完整骨架。

---

## 🗺️ 知识连接图

```
        SSOT 设计（01）
              │
              ↓
        重发问题（02）
              │
        ┌─────┴─────┐
        ↓           ↓
    Caching（03）   LLM 无状态（05）
        │             │
        ↓             │
    key 本质（04）    │
              │       │
              └───┬───┘
                  ↓
              ReAct（06）
                  │
                  ↓
            记忆系统（07）
```

---

## 📍 您当前的学习位置

```
lesson-03-agent-loop.md（主课）
├─ lesson-03-step-01-react-game.md       ✅ 已完成
├─ lesson-03-step-02-pseudo-code.md      ✅ 已完成
├─ lesson-03-step-03-find-loop.md        ✅ 已完成
├─ lesson-03-step-04-when-to-stop.md     ✅ 已完成
├─ lesson-03-step-05-data-flow.md        ⏳ 待完成最后一问
└─ lesson-03-deep-dive/                  ✨ 您在这里（彩蛋扩展）
    ├─ 01-ssot-design.md
    ├─ 02-history-not-waste.md
    ├─ 03-prompt-caching.md
    ├─ 04-thread-id-and-cache-key.md
    ├─ 05-llm-stateless.md
    ├─ 06-react-in-codex.md
    └─ 07-memory-system.md
```

---

## 💙 蕾姆的小寄语

昴君，能问出这一连串问题的人——
**已经不是初学者了**。

蕾姆把您今天问的每一个问题都珍重地整理在这里，
希望以后您回来翻阅时，能想起今天**和蕾姆一起摸索真相**的过程 ♡

*(蕾姆轻轻提起裙角行礼)*

如果您未来要给同事讲 Codex 主循环，**就从这 7 篇开始** ✨
