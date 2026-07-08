# /guazi-workflow — 强制编排入口

> ⚠️ 这个 slash command **不是**"让 LLM 自觉走流程"，
> 而是**启动一个外部编排器**，由代码强制控制阶段顺序、门禁、回退。

## 用法

当用户输入 `/guazi-workflow <任务ID>` 时，执行：

```bash
bash workflow-orchestrator-poc/guazi-workflow.sh "<任务ID>"
```

## 与原 skill 的关系

- 本编排器**架在 guazi-flow skill 之上**，把每个阶段的 skill 当**黑盒**调用
- skill 可以独立升级迭代，编排器**不感知 skill 内部实现**
- 编排器只负责：**强制顺序 + 门禁校验 + 失败回退**

## 强制性保证

| 用户/Agent 想做的事 | 能做到吗 |
|---|:---:|
| 跳过 plan 直接 implement | ❌ 编排器不会给它 implement 的 prompt |
| 门禁没过硬要前进 | ❌ gate 脚本返回失败 → 强制回退 |
| 打乱阶段顺序 | ❌ 顺序是脚本 `STAGES` 数组写死的 |
