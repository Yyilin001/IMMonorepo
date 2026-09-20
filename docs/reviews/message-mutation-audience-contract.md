# 普通消息变更的历史受众与预留结算

> 历史记录：本文的逐用户扇出、预留结算和测试数字属于旧实现，已被房间日志单一模型替代，不作为当前部署或性能结论。当前实施与验收见[房间日志实施记录](room-log-only-implementation.md)。

对应 B03/D07。当前修复针对新创建的普通编辑、作者撤回、reaction 的 personal fanout。后续批次已补齐 [reaction actor 与普通变更的房间读取授权](message-mutation-read-contract.md)。新编辑还已接通[完整替换与版本缺口](message-edit-replacement-contract.md)。完整 B03 仍需要其他内容入口、snapshot、媒体遵守相同授权，以及旧积压恢复。

## 冻结的受众

writer 从消息的不可变接受记录读取 accepted membership revision，随 plan 的 `message_visible_members` 规则保存 accepted event ID、room sequence、预留人数上界及预留时的 shard lease ID/代次。plan 的 committed membership revision 则固定普通变更提交时刻。

planner 分别验证 `VisibleAtAccepted(user,message)` 和 `MemberAtMutation(user,event)`。两者可以由不同 membership interval 满足：原成员离群再入群仍有资格收到重入后的变更；只有新成员身份的人不获得旧消息变更。枚举按 user ID 有界分页，并使用既有成员索引；writer 不扫描全体成员。

单条 `plan` 委托同一批量实现，避免维护两套历史受众与计数逻辑。普通 accepted、冻结成员控制受众等原有分支仍走已有分页规则；该批没有把它们换成消息受众规则。

## 枚举与结算

| 阶段 | 持久事实 | 失败后的处理 |
| --- | --- | --- |
| writer 接受变更 | 当前人数上界、预留占用、accepted/变更两个版本 | 同原命令事务回滚 |
| planner 每一页 | 本页 completion units、deliveries、累计真实人数、after user ID | 本页原子提交，重试从持久 checkpoint 继续 |
| 枚举结束 | `audience_complete=true`，plan 仍为 planning；人数上界尚未替换 | 结算失败保留完整枚举结果，重试不重复创建 delivery |
| 独立结算事务 | target count 和 reserved cost 改为真实人数，归还上界差额；非空计划发布为 planned | 任一计数或当前 lease 代次不符，整个结算回滚 |
| 完成单元释放 | 原 completion worker 回收真实目标剩余占用并关闭计划 | 已有持久 terminal/released 状态保证幂等 |

结算采用 room → room admission → plan → shard 的锁序。分页事务提交后才取得 room 锁，不在持有 plan 锁时等待 room，避免与既有完成释放路径形成反向锁序。同一个结算批按稳定顺序锁房间、计划和 shard；多个 planner 并发重试只能结算一次。当前 room admission 和 shard 的 lease ID/代次必须匹配；结算不凭旧代次直接扣新计数。

每次结算都归还 `outstanding_fanout_units` 的人数差额。只有当前 lease ID/代次仍与预留身份一致时，才同时退还同一 `fanout_window_used` 窗口中的多余消耗；换代后不能从新窗口扣历史退款。数据库外键会 CASCADE 同步 room 的租约，触发器重置其窗口计数，同时保留未完成工作占用。测试使用合法换代，另在最终 shard 写入处注入失败，不能通过破坏外键模拟假失配。缺少历史窗口身份时只释放占用，保守保留窗口消耗。原预留上界始终保存在 target rule 中供核对。

空交集不制造假收件人或虚假 completion units。结算原子归还全部变更占用和一个 plan slot，将计划与 outbox 标为 terminal；其他已接受消息的占用仍保留。relay 批量确认须接受有终结计划佐证的完成记录，同时保持 pending 行的 claim token 栅栏。

## 边界与发布要求

- 这不是旧积压迁移：已经枚举的旧计划或使用旧规则创建的任务，需要独立核查与恢复，不能改写已分发正文来假装从未泄漏。
- room-log 的正文变更不进入该逐用户 fanout；前一批的接受记录分发归属合同继续适用。
- 普通变更与回溯性审核删文不同；本批不扩大 redaction 或普通撤回的历史受众。
- 重新入群后的新编辑已由后续 protocol 27 typed complete replacement 处理；旧 delta 积压另行恢复，不能把无权期间的版本补发给用户。
- 新 writer 的规则必须由支持该规则的 planner 处理。旧 planner 将未知规则视作普通当前成员枚举，不能允许旧 worker 与新 writer 混合运行；真实发布需协调停止旧 worker 后切换，本批没有部署。

## 验证

未改生产实现的负例：三种变更 × 单条/批量 planner 六个场景，共 24 条失败断言；新成员错误成为目标、target count 未缩减、预留差额未释放。首轮修复验证通过 3 项测试，含六个受众场景及此前 27 个分发归属/接受记录缺失场景。

扩展运行执行 221 项测试，仅六条错误的租约失配假设失败：外键已自动同步代次。修正后在 room 退款与最后的 shard 写入分别注入真实失败；同时补测同窗口退款、合法换代后的新窗口保护、八路并发重试及实际 delivery/completion 释放。零目标混合 outbox 确认另复现一处生产错误：已终结记录未计入批次成功数；修复后仍拒绝混合批次中的失效 pending 租约。

最终 **221 项测试 / 16 套件**通过，退出 0，耗时 168.848 秒。包括上述故障恢复与零目标场景、既有 27 个接受归属/缺失记录场景、真实 10 万成员分页、旧分页中断、relay 批量写、完成回收、跨库故障及 owner/转发回归。日志、脚本和源码哈希见[验证证据](../../docs/reviews/verification-records.md#20260906-message-audience)。这是定向功能回归，不能代替生产容量或真实 App/TLS 验收；B03 和 D07 均保持实施中。
