---
name: agens-ios-review
description: 按 AGENS 仓库规范审查 Swift 和 SwiftUI 代码，或为 callback、delegate、GCD 等旧式异步代码规划渐进式迁移到 Swift Concurrency。适用于 iOS 仓库中的代码审查、规范合规检查、review 意见撰写，以及旧模块迁移方案设计。
---

# AGENS iOS Review

## 概述

用这个 skill 审查 Swift 和 SwiftUI 代码是否符合仓库里的 AGENS 规则，或为旧式异步模式到 Swift Concurrency 的迁移提供步骤化指导。

审查时优先关注正确性、行为回归风险、隔离安全，以及当前设计是否在推动代码库朝更强的类型建模和状态驱动 SwiftUI 演进。

同时检查当前设计是否：
- 用专属领域类型而不是裸弱类型保留关键信息
- 用函数签名表达真实工作流
- 在可信边界构造 witness 和解析结果
- 把“类型即测试”的思想落实到解析器、边界转换和强类型 API 上

## 审查工作流

1. 先读取仓库里的 `AGENTS.md`，把它当作默认规则集。
2. 只检查与当前变更直接相关的文件，再形成结论。
3. 优先报告会导致错误行为、竞态、UI 状态漂移、非法状态或迁移倒退的问题。
4. 把“违反仓库规则”的问题和“可选风格优化”分开。
5. 当任务是 review 时，先给 findings，摘要保持简短。

需要详细检查项和输出方式时，读取 [references/review-checklist.md](references/review-checklist.md)。

如果当前模块使用 SwiftUI，补充读取 [references/swiftui-review.md](references/swiftui-review.md)。

如果需要理解 SwiftUI diff、render loop、AttributeGraph、类型擦除或 escaping `@ViewBuilder` closure 背后的原理与出处，补充读取 [references/swiftui-internals.md](references/swiftui-internals.md)。

当变更涉及核心业务建模、解析器、权限态、标识类型或流程编排时，重点使用 [references/review-checklist.md](references/review-checklist.md) 中的类型驱动检查项。

如果需要理解 Type-Driven Design 相关规则背后的原理、文章出处和可吸收要点，补充读取 [references/type-driven-design.md](references/type-driven-design.md)。

## 迁移工作流

只有当任务涉及旧式 callback、delegate、notification、GCD、lock 或混合异步代码时，才使用迁移指南。

1. 识别目标代码当前的异步形态。
2. 判断旧接口是单次结果还是事件流。
3. 在专门的边界层里一次性桥接旧 API。
4. 先迁移调用方到 async API，再清理线程切换和回调编排。
5. 在行为保持不变后，再收紧 actor 隔离、`@MainActor` 使用和 `Sendable` 边界。

需要详细迁移步骤时，读取 [references/migration-playbook.md](references/migration-playbook.md)。

## 输出要求

- 做 review 时，按严重程度排序 findings，并附上文件和行号引用。
- 优先讨论 bug、回归风险、缺失测试、不安全隔离、错误状态建模和 UI 数据流问题，再谈风格问题。
- 如果没有 findings，要明确说明，并补充仍然存在的验证空白或风险点。
- 如果某条结论是推断而不是直接可见的问题，要标明这是推断。

推荐输出模板：

1. `发现`：按严重程度列出问题，每条包含文件、行号、风险说明和修正方向。
2. `开放问题`：仅列出确实影响判断的前提假设。
3. `摘要`：可选；只总结最值得优先处理的 1 至 3 项。

## 边界

- 不要把长篇的任务型 checklist 再塞回仓库 `AGENTS.md`，这些内容应保留在 skill 中。
- 当渐进式迁移更安全时，不要推荐大面积重写。
- 不要把所有 `DispatchQueue` 都直接判为错误，先判断它是旧代码桥接，还是确实存在正确性问题。
- 不要为了消除编译警告而削弱 actor 隔离。
- 不要把架构偏好硬说成 bug；没有明确风险时，应降级为建议或不提。
