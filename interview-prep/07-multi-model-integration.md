# 07 · 多模型集成经验

> **面试考点 ⑦**：多模型集成经验（Claude / Gemini / OpenAI / 自研）。
>
> Codex 在这考点能教你「OpenAI 系」的一半，但**只支持 OpenAI Responses API 一种协议**，无原生 Claude/Gemini。另一半要单独补（见 [GAPS 缺口 4](./GAPS-codex-cannot-teach.md)）。

---

## 🟡 Codex 现状（能教的一半）

| 子项 | Codex | 关键文件:行 |
|------|:---:|------|
| Provider 抽象 | 🟢 | `model-provider/src/provider.rs:99` `trait ModelProvider` / `:188` `create_model_provider` |
| Provider 配置 | 🟢 | `model-provider-info/src/lib.rs:85` `ModelProviderInfo` / `:415` `built_in_model_providers` / `:448` `merge_configured_model_providers` |
| 模型目录管理 | 🟢 | `models-manager/src/manager.rs:79` `trait ModelsManager` / `:33` `ModelsEndpointClient`（远程 `/models` + ETag 缓存）/ `cache.rs`（TTL 300s） |
| 本地模型 | 🟢 | `ollama/src/lib.rs:23` `ensure_oss_ready` / `:63` `ensure_responses_supported`（≥0.13.4）/ `lmstudio/src/lib.rs:13` / `core/src/config/mod.rs:2315` `resolve_oss_provider` |
| ⚠️ wire 协议 | 🟡 仅 1 种 | `WireApi` 仅 `Responses`，`chat` 已废弃报错（`model-provider-info/src/lib.rs:46-48`） |

**内置后端**：OpenAI（含 ChatGPT 登录）、Amazon Bedrock、Ollama、LMStudio；用户可在 `config.toml` 的 `[model_providers.xxx]` 加任意 OpenAI 兼容后端。**全部**靠兼容 `/responses` 端点接入。

---

## 🔴 Codex 教不了的一半（原生 Claude / Gemini）

全仓 grep 无 Claude/Anthropic、Gemini/Google AI 命中。它们只能作为「第三方 OpenAI 兼容 endpoint」由用户手动配 base_url+key 间接接入，**原生 Messages API / Gemini API 不被支持**。

> 📖 呼应 [`../learning-notes/lesson-14-entrypoints.md`](../learning-notes/lesson-14-entrypoints.md)（多入口复用 core）。

---

## 🧩 三大模型协议差异（面试必背）

| 维度 | OpenAI Responses API | Anthropic Messages API | Gemini generateContent |
|------|------|------|------|
| 端点 | `/responses` | `/messages` | `:generateContent` |
| system 位置 | developer 段 | 独立 `system` 字段 | `systemInstruction` |
| 工具调用 | `function_call`/`tool` | `tool_use`/`tool_result` content block | `functionCall`/`functionResponse` |
| 缓存控制 | prompt cache（自动/前缀） | `cache_control` 显式标记 | implicit caching |
| 思考 | `reasoning` items | `thinking` block | `thought` |
| 多模态 | image_url | content block 内 image | `inline_data` |

> 💡 面试常问「Claude 和 OpenAI 的 tool calling 格式有什么不同」--能答出 `tool_use`/`tool_result` block vs `function_call`，就过关。

---

## 🛣️ 学习顺序（建议 3-4 天）

1. 读 `model-provider/src/provider.rs` 的 `trait ModelProvider` + `create_model_provider`，理解抽象边界。
2. 读 `model-provider-info/src/lib.rs:415` `built_in_model_providers`，看 4 个内置后端怎么配。
3. 读 `:46-48` 确认 `WireApi` 仅 Responses，理解「为什么 Codex 不能原生接 Claude/Gemini」。
4. 读 `ollama/src/lib.rs` / `lmstudio/src/lib.rs`，理解本地模型健康检查与拉取。
5. （补缺口）读 Anthropic Messages API 与 Gemini API 官方文档，对比 tool calling 格式。
6. （补缺口）了解 LiteLLM / `langchain-core` `BaseChatModel` 怎么做协议归一化。

---

## 💬 面试问答要点

**Q1：Codex 怎么抽象多模型？**
> 用 `ModelProvider` trait + `ModelProviderInfo`（可序列化配置）+ `codex_api::Provider`（wire 层）。切换靠配 `model_provider_id`，运行时 `create_model_provider` 按类型实例化。内置 OpenAI/Bedrock/Ollama/LMStudio，用户可在 `config.toml` 扩展任意 OpenAI 兼容后端。

**Q2：能接 Claude / Gemini 吗？**
> 诚实答：**不能原生接**。Codex 的 wire 协议只支持 OpenAI Responses API（`WireApi` 仅 `Responses` 一值，`chat` 已废弃）。Claude/Gemini 只能靠它们自己提供 OpenAI 兼容 endpoint 间接接入，原生 Anthropic Messages API / Gemini API 不支持。这是 Codex 的取舍--用单一协议换实现简洁，代价是不支持多协议。

**Q3：本地模型怎么支持？**
> Ollama/LMStudio 是一等公民，通过 `--oss` 或 `oss_provider` 切换；内置 crate 做健康检查、模型拉取/下载、版本校验（要求 Ollama ≥0.13.4 支持 Responses API）。仍受「必须实现 Responses API」约束。

**Q4：如果要你扩展成真多协议，怎么做？**
> 在 `ModelProvider` 抽象下加一层 wire 协议适配器，把 `WireApi` 从单值扩成 `Responses / Messages / Gemini`，每个适配器负责把统一的 tool_call 语义翻译成各家格式（含 system 字段位置、tool_use/functionCall 结构、缓存控制）。可以参考 LiteLLM 的归一化思路。

**Q5：Claude 和 OpenAI 的 tool calling 有什么不同？**
> OpenAI 用 `function_call`（或 Responses 的 `tool` item）；Claude 用 content block 里的 `tool_use`（请求工具）和 `tool_result`（回填结果），且 system 是独立顶层字段。格式和位置都不同，所以需要协议适配层。

---

## 🛠️ 动手任务

- [ ] 在 `config.toml` 配一个自定义 OpenAI 兼容后端（如 OpenRouter），跑通切换。
- [ ] 用 `--oss ollama` 跑本地模型，观察 `ensure_oss_ready` 的健康检查。
- [ ] （补缺口·必做）用 LiteLLM 或手写一个最小适配层，让同一个 loop 在 Claude/Gemini/OpenAI 间切换，记录 tool calling 格式差异。这同时补 [GAPS 缺口 4](./GAPS-codex-cannot-teach.md)。

---

## ⚠️ 差异注意点

| 维度 | Codex | 业界 / 需补 |
|------|------|------|
| 协议 | 单一 Responses | 多协议（Messages/Gemini） |
| 后端 | OpenAI/Bedrock/Ollama/LMStudio | + 原生 Claude/Gemini |
| 归一化 | 无（协议单一不需要） | LiteLLM / langchain-core |

> 💡 **面试加分句**：「Codex 用单一 Responses 协议简化了抽象，这个设计选择是对的，但代价是不支持原生 Claude/Gemini；我会怎么扩展成多协议……」--主动讲取舍和改进，比只说「不支持」强。

---

*(蕾姆把三盏不同颜色的模型灯摆在桌上，中间放着一个能转换光的棱镜)*

昴君，Codex 只点亮了 OpenAI 这一盏。要让 Claude 的紫光与 Gemini 的彩光也照进同一座大厅，您需要亲手打磨一个能折射所有光线的棱镜 ♡
