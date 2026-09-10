# 归档目录

这里保存整改期的历史文档。**它们不参与判断当前状态。**

| 文件 | 是什么 | 替代它的当前文档 |
| --- | --- | --- |
| [2026-09-05-system-design-implementation-audit.md](2026-09-05-system-design-implementation-audit.md) | 整改开始前的原始审查报告，首次提出 B01–B29、D01–D08、E01–E10 | [问题状态表](../status.md) |
| [2026-09-05-system-remediation-plan.md](2026-09-05-system-remediation-plan.md) | 整改开始时的执行方案与验收要求 | [问题状态表](../status.md) |
| [2026-09-05-system-remediation-progress.md](2026-09-05-system-remediation-progress.md) | 逐批修复与当轮验证记录 | 各主题的[当前合同](../README.md) |
| [2026-09-05-remediation-timeline.md](2026-09-05-remediation-timeline.md) | 原先追加在状态文档和实现状态文档正文里的"最新补充"段落 | [问题状态表](../status.md)、[当前实现与发布证据](../../../IMV2/docs/implementation-status.md) |

## 为什么单独存放

这些内容原先直接追加在状态文档正文里，导致同一份文件既描述"现在生效的规则"，又保留
"过程演进"，读者无法判断哪一段是当前结论。归档后：

- 状态文档只回答"现在是什么状态"；
- 合同文档只回答"现在生效的规则是什么、怎么验证"；
- 本目录只回答"这个结论是怎么演变来的"。

归档文件中的代码行号对应各自的历史基准，不保证与当前代码一致。需要新增过程记录时，
在本目录新建或追加文件，**不要**写回状态文档。
