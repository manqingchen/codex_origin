# 04 · cache_key 的本质：thread_id 的完整传输链路

> 💙 这是第 03 课深度彩蛋的第四篇。
> 蕾姆要为昴君把"cache_key 怎么从客户端跑到服务端"的**完整链路**画清楚——以及一个最重要的澄清：**key 不是从 prompt 内容生成的**！

---

## 🎯 学完这篇您会理解

1. cache_key 不是 hash，不是 tokenize
2. cache_key 就是 thread_id（UUID）
3. 完整的传输链路（6 步代码追踪）
4. "关联机制" 其实极其朴素

---

## 💎 最大的澄清：key 和 tokenize 是两件事

### 🪜 您可能的误区

```
prompt 内容 → 经过某种算法（tokenize？hash？）→ 生成 key
                                                ↓
                                          这个 key 用来匹配缓存
```

### ✅ 真相

```
key 跟 prompt 内容【完全无关】
key = 会话开始时生成的【UUID 字符串】

tokenize 是用来处理 prompt 内容（input），
但 tokenize 出来的【不是 key】，是【缓存的值（value）】！
```

---

## 🪜 两件不同的事，请务必分清

### 🔑 事情 1：cache_key 的生成

**位置**：`session/session.rs:513` + `client.rs:364`

```rust
// 第 1 步：会话开始时
let thread_id = ThreadId::default();   // ← 生成 UUID（随机）

// 第 2 步：每次请求时
fn prompt_cache_key(&self) -> String {
    self.state.thread_id.to_string()    // ← 把 UUID 转字符串
}
```

> 🌟 **请昴君看清楚**：
> - 输入：**无**（没有用任何 prompt 内容）
> - 输出：UUID 字符串（比如 `"a1b2c3d4-..."`）
> - 算法：**没有算法！就是 UUID 随机生成 + 转字符串**
> - 跟 prompt 内容的关系：**完全无关**

---

### 📝 事情 2：input 内容的处理（这个才用 tokenize）

**位置**：`client.rs:757`

```rust
let request = ResponsesApiRequest {
    input,                  // ← 完整 history（一堆 ResponseItem）
    prompt_cache_key,       // ← UUID
    ...
};
```

`input` 在客户端是**结构化的 Vec\<ResponseItem\>**（不是 token），通过 JSON 序列化后发送。
**到了服务端**，OpenAI 才会对 `input` 做 tokenize。

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   📦 客户端发送的 JSON 请求：                                   │
│   ┌──────────────────────────────────────────────────────┐   │
│   │ {                                                    │   │
│   │   "prompt_cache_key": "a1b2c3d4-...",  ← KEY         │   │
│   │   "input": [                            ← VALUE       │   │
│   │     {"role": "user", "content": "你好"},              │   │
│   │     ...                                              │   │
│   │   ],                                                 │   │
│   │ }                                                    │   │
│   └──────────────────────────────────────────────────────┘   │
│                                                              │
│                          ↓ HTTPS                             │
│                                                              │
│   🌐 OpenAI 服务端处理：                                        │
│                                                              │
│   1️⃣ 读 JSON 字段：                                            │
│      cache_key = "a1b2c3d4-..."        ← 直接用，不算         │
│      input = [...]                                           │
│                                                              │
│   2️⃣ 对 input 做 tokenize：              ← 这里才 tokenize    │
│      tokens = tokenizer.encode(input)                        │
│              = [101, 234, 567, 890, ...]                     │
│                                                              │
│   3️⃣ 用 cache_key 查缓存：                                     │
│      cached_tokens = cache["a1b2c3d4-..."]                   │
│                                                              │
│   4️⃣ 前缀匹配 tokens vs cached_tokens                          │
│                                                              │
│   5️⃣ 计费 + 更新缓存                                           │
│      cache["a1b2c3d4-..."] = tokens                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

> 💡 **请特别看清楚**：
>
> - **`prompt_cache_key`** = UUID 字符串（**永远不需要 tokenize**）
> - **`input`** = 结构化的对话内容（**到服务端才 tokenize**）
> - **tokenize 的产物** = token 数组 = **缓存的 VALUE**，**不是 KEY**！

---

## 🗺️ 完整传输链路 · 代码精确定位版

蕾姆带您**真正走一遍源码**，从 thread_id 生成到 HTTP 请求发出。

```
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   🔑 cache_key 的完整生命周期（6 步）                                ║
║                                                                   ║
║   STEP 1：会话启动 → 生成 thread_id                                  ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║   📂 codex-rs/core/src/session/session.rs:513                     ║
║                                                                   ║
║   let thread_id = match &initial_history {                        ║
║       InitialHistory::New | ... => {                              ║
║           ThreadId::default()  ←─── ★ 这里生成 UUID                ║
║       }                                                           ║
║       ...                                                         ║
║   };                                                              ║
║                                                                   ║
║   📂 codex-rs/protocol/src/thread_id.rs:18                        ║
║                                                                   ║
║   pub fn new() -> Self {                                          ║
║       Self {                                                      ║
║           uuid: Uuid::now_v7(),    ←─── ★ UUID v7 生成器           ║
║       }                                                           ║
║   }                                                               ║
║                                                                   ║
║   👉 完全随机的 UUID                                                ║
║   👉 跟 prompt 内容【没有任何关系】                                 ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   STEP 2：每次请求时取出 thread_id                                  ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║   📂 codex-rs/core/src/client.rs:364                              ║
║                                                                   ║
║   fn prompt_cache_key(&self) -> String {                          ║
║       self.prompt_cache_key_override                              ║
║           .clone()                                                ║
║           .unwrap_or_else(|| self.state.thread_id.to_string())   ║
║                              ↑                                   ║
║                          UUID 转字符串                            ║
║   }                                                               ║
║                                                                   ║
║   👉 这里就是【把 thread_id 当成 cache_key】的瞬间                  ║
║   👉 没有 tokenize、没有 hash、没有 SHA                            ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   STEP 3：装进请求结构体                                            ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║   📂 codex-rs/core/src/client.rs:755-769                          ║
║                                                                   ║
║   let prompt_cache_key = Some(self.prompt_cache_key());          ║
║                                                                   ║
║   let request = ResponsesApiRequest {                             ║
║       model: ...,                                                 ║
║       input,           ← ★ history（还没 tokenize）                ║
║       prompt_cache_key,    ← ★ UUID 字符串                         ║
║       ...                                                         ║
║   };                                                              ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   STEP 4：Serde 序列化为 JSON                                       ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║   📂 codex-rs/codex-api/src/common.rs:182                         ║
║                                                                   ║
║   #[derive(Serialize)]                                            ║
║   pub struct ResponsesApiRequest {                                ║
║       pub input: Vec<ResponseItem>,                               ║
║       pub prompt_cache_key: Option<String>,                       ║
║       ...                                                         ║
║   }                                                               ║
║                                                                   ║
║   👉 serde_json 自动把结构体转 JSON                                 ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   STEP 5：HTTPS 发送                                               ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║   📂 codex-rs/core/src/client.rs:1203 stream_responses_api()      ║
║                                                                   ║
║   POST https://api.openai.com/v1/responses                        ║
║   Content-Type: application/json                                  ║
║                                                                   ║
║   {                                                               ║
║     "prompt_cache_key": "a1b2c3d4-...",                           ║
║     "input": [{"role": "user", "content": "..."}, ...],           ║
║     ...                                                           ║
║   }                                                               ║
║                                                                   ║
║                  ━━━━━━━━━━━━━━━━━━━━━━━━━━                       ║
║                  跨越互联网到达 OpenAI                              ║
║                  ━━━━━━━━━━━━━━━━━━━━━━━━━━                       ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   STEP 6（服务端）：OpenAI 处理请求                                  ║
║   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                      ║
║                                                                   ║
║   伪代码：                                                          ║
║                                                                   ║
║   def handle_request(req):                                        ║
║       # 6.1 读取 cache_key（直接用）                               ║
║       cache_key = req.json["prompt_cache_key"]                    ║
║                                                                   ║
║       # 6.2 对 input 做 tokenize                                  ║
║       input_tokens = tokenizer.encode(req.json["input"])          ║
║       # ★ 这才是 tokenize！但产物是【缓存的值】，不是 key！         ║
║                                                                   ║
║       # 6.3 用 cache_key 查缓存                                   ║
║       cached_tokens = cache_db.get(cache_key)                     ║
║                                                                   ║
║       # 6.4 前缀匹配                                              ║
║       matched_len = longest_common_prefix(                        ║
║           cached_tokens, input_tokens                             ║
║       )                                                           ║
║                                                                   ║
║       # 6.5 计费                                                   ║
║       cached_part = matched_len × cache_discount_price            ║
║       new_part = (len - matched_len) × normal_price               ║
║                                                                   ║
║       # 6.6 更新缓存                                               ║
║       cache_db.set(cache_key, input_tokens)                       ║
║                                                                   ║
║       # 6.7 调 LLM 处理                                            ║
║       ...                                                         ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## 🎯 完整传输链路的一句话总结

```
[启动会话]
   ↓ 生成 UUID
thread_id = "a1b2c3d4-..."   存在 Codex 内存

   ↓ 用户问问题
   
[client.rs:755]
prompt_cache_key = thread_id.to_string()
                   ↑ 就这么简单！

   ↓ 装进请求体

ResponsesApiRequest { prompt_cache_key: "a1b2c3d4-...", ... }

   ↓ Serde 序列化为 JSON

{ "prompt_cache_key": "a1b2c3d4-...", ... }

   ↓ HTTPS POST

OpenAI 服务器
   1. 读出 prompt_cache_key
   2. 查表
   3. 命中/未命中
   4. 计费
```

---

## 💡 一个最简单的"心智模型"

```
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   prompt_cache_key 就像【信封上的收件人姓名】                   ║
║                                                               ║
║   1. Codex 在信封上写："a1b2c3d4"                              ║
║   2. 投到 OpenAI 邮局                                          ║
║   3. 邮局根据姓名分发到对应的信箱                              ║
║   4. 信箱里堆着这个收件人之前的所有信件                        ║
║                                                               ║
║   ──────────────────────                                      ║
║                                                               ║
║   "关联机制" 就是 "信封上写名字"                                ║
║                                                               ║
║   不需要预先注册                                                ║
║   不需要握手                                                    ║
║   不需要绑定                                                    ║
║                                                               ║
║   第一次寄信 → 邮局自动建信箱                                   ║
║   再次寄信 → 邮局认得这个名字                                   ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## 💎 KEY 和 VALUE 的完美分工

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   缓存系统的 KEY 和 VALUE 完全独立                                  ║
║                                                                  ║
║   🔑 KEY 这一侧                                                   ║
║   ──────────                                                     ║
║   来源：会话启动时生成的 UUID                                      ║
║   生成位置：codex-rs/protocol/src/thread_id.rs:20                ║
║   生成代码：Uuid::now_v7()                                        ║
║   依赖：无                                                        ║
║   特点：随机、稳定（整个会话不变）                                 ║
║                                                                  ║
║   📦 VALUE 这一侧                                                 ║
║   ──────────                                                     ║
║   来源：prompt 内容 tokenize 之后的 token 数组                     ║
║   生成位置：OpenAI 服务端内部                                      ║
║   生成方式：tokenizer.encode(input)                              ║
║   依赖：prompt 内容                                               ║
║   特点：每轮变长                                                  ║
║                                                                  ║
║   ─────────────────────                                          ║
║                                                                  ║
║   KEY 和 VALUE 的关系：                                            ║
║   • 通过 OpenAI 服务端的 KV 字典关联                              ║
║   • cache[key] = value                                          ║
║   • 它们【各自独立产生】，由【数据库】把它们关联起来               ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 🪜 关于 UUID v7

源码用的是 **UUID v7**（不是 v4）：

```
UUID v7 = 时间戳 + 随机数（2024 年新标准）
- 前 48 位是 Unix 时间戳（毫秒）
- 后 80 位是随机数

好处：
- 按时间排序的 UUID
- 数据库索引友好（同会话的 UUID 都在相近时间，磁盘局部性好）
- 仍然全球唯一
```

但**不影响我们的理解**——它**还是一个跟 prompt 内容无关的随机字符串**！

---

## 🎁 银行储蓄卡比喻——彻底讲透

```
🏦 想象您去银行办了一张【储蓄卡】

   开卡时：
   银行随机给您一个【卡号】"6228-8001-1234-5678"
   ↑
   ★ 这个卡号是【银行系统随机生成】的
   ★ 不是根据您【存了多少钱】算的
   ★ 不是根据您【姓名】算的
   ★ 跟您【未来要做的任何交易】都没关系

   之后您每次去银行：
   1. 您报【卡号】（不变）
   2. 银行查这个卡号对应的【账户余额】
   3. 您【存钱/取钱】
   4. 银行【更新账户余额】

   ──────────────────

   映射到 Codex：

   "卡号" = thread_id = prompt_cache_key
   "账户余额" = 服务端缓存的 token 序列
   "存钱/取钱" = 每次发送 input
```

> 💙 **卡号是【银行发的】，不是【根据您存的钱算的】**——
> 同理，**cache_key 是【Codex 启动时生成的】，不是【根据 prompt 内容算的】**！

---

## 💎 总结

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   📌 cache_key 的本质                                         ║
║                                                              ║
║   ❌ 不是从 prompt 算的 hash                                   ║
║   ❌ 不是 tokenize 的产物                                      ║
║   ❌ 不是动态拼接的                                            ║
║   ❌ 不需要客户端维护"链表"                                    ║
║                                                              ║
║   ✅ 就是会话启动时的 UUID                                     ║
║   ✅ 通过 HTTP JSON 字段传给服务端                             ║
║   ✅ 服务端用它做 KV 字典的查找                                 ║
║   ✅ 客户端只存 thread_id 一个字符串                           ║
║                                                              ║
║   ────────────────                                          ║
║                                                              ║
║   KEY 在客户端生成（一次性、随机）                            ║
║   VALUE 在服务端生成（tokenize、每轮更新）                    ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 📍 上一篇 / 下一篇

← [03 · Prompt Caching 三大误区](./03-prompt-caching.md)
→ [05 · LLM 是无状态的](./05-llm-stateless.md)
