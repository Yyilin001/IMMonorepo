# 文档入口

仓库文档分三层，读的时候按层走，不要跨层找答案。

## 第一层：当前状态（只有三份）

| 想知道 | 看这里 |
| --- | --- |
| 系统由哪些组件组成、消息怎么流动、有哪些不变量 | [当前系统架构](current-system-map.md) |
| 现在有哪些能力、证据到什么等级、协议与 schema 政策 | [当前实现与发布证据](../IMV2/docs/implementation-status.md) |
| 哪些问题还开着、关闭条件是什么 | [当前问题状态表](reviews/status.md) |

这三份文件是唯一被允许回答"现在是什么样"的地方。它们**不保留时间线**：任何
"最新补充"式的追加都应写进归档目录，而不是追加进状态文档。

## 第二层：当前合同

每个主题的权威设计合同在 [合同索引](reviews/README.md) 里按主题列出。改代码前先在那里
找到对应合同；改完代码要同步更新同一份合同，而不是新写一份。

## 第三层：历史归档

三个归档目录保存被后续修订取代的内容。它们提供决策来源，**不参与判断当前状态**，
其中的代码行号和版本号也不保证与当前一致：

| 归档目录 | 内容 |
| --- | --- |
| [`reviews/archive/`](reviews/archive/README.md) | 整改期的原始审查、修复方案、逐批验证记录与被替换的旧结论 |
| [`09-capacity/archive/`](../IMV2/docs/09-capacity/archive/README.md) | 被后续修订取代的阶段性压测报告 |
| [`00-foundation/archive/`](../IMV2/docs/00-foundation/archive/README.md) | 编号冲突或未登记的历史设计文档 |

## 其他入口

- [应用级弱网架构提案](proposals/application-weak-network-design.md)与[实施任务计划](proposals/application-weak-network-implementation-plan.md)：结合当前源码的目标设计；基础组件与个人资料链路已接入，完整差距见[实施状态](proposals/application-weak-network-progress.md)，全量能力尚未验收。
- [会话偏好与收藏的恢复合同](proposals/personal-preference-operation-contract.md)：RoomRef 权威回执、公共任务 journal、队首冻结与投影版本保护。
- [ADR 登记册](../IMV2/docs/ADR-REGISTER.md)：设计决定与批准状态。
- [开放风险登记表](../IMV2/docs/10-operations/residual-risk-register.md)：外部发布缺口与关闭条件。
- [验证运行记录索引](reviews/verification-records.md)：每条结论对应的本机运行记录与复现命令。
- [iOS 应用](../IMApp/README.md)、[V2 网关](../IMV2Server/README.md)：本机运行与配置说明。

## 提交前

```sh
bash scripts/check_v2_document_links.sh
```

文档链接必须为零断链；该检查已包含在 `scripts/verify_v2.sh` 总门禁中。
