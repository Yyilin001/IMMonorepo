# 消息编辑、撤回与 reaction 的 owner 事务栅栏

## 当前普通编辑／撤回执行合同（current57，protocol35）

普通编辑和撤回使用 [MessageMutationOperation](../../IMV2Core/Sources/IMV2Core/MessageMutationOperation.swift) 的冻结执行 envelope，必填首次提交截止、稳定原操作身份和 expected revision。POST `/v2/rooms/:room/message-mutations/edit`、`/withdraw` 返回绑定 identity/fingerprint 的最小原回执；POST 同前缀 `/operations/recover` 执行 query 或 closeIfAbsent。正文不进入永久回执，也不由回执获得展示 lease。

[永久执行器](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2MessageMutationOperationStore.swift) 在 operation advisory lock 与 RoomRef activation fence 内先查原回执，再验证不存在的新操作截止与当前领域权限。首次窗口最多十分钟。领域 revision、事件、outbox 与 `message_mutation_receipts` 在同一事务提交；关闭共锁，永久拒绝／关闭不能被迟到原请求越过。内层领域写显式复用已绑定事务，不能另发 BEGIN/COMMIT。新操作的 admission rateLimited/unavailable 返回绑定原 identity/fingerprint 的 deferred 调度提示；HTTP 分别使用 429/503，存在 retryAfterMilliseconds 时同时返回向上取整秒数的 Retry-After。提示不是执行、拒绝或关闭证明。

旧 `message_edit_operations`／`message_withdrawal_operations` 和 housekeeping 删除路径已移除；永久结果仅含消息 ID、结果 revision、room sequence、event ID、解决时间及 typed rejection。成功原回执不以当前成员资格或当前正文覆盖。HTTP 限 edit 1 MiB、withdraw/recover 4 KiB，no-store，持久账号边缘预算 cost 3。无冻结截止的旧 TLS mutation 入口不再执行。以下为迁移前 owner fence 背景。


2026-09-06，B27 房间迁移前置修复。完整房间迁移仍未实现，本合同只覆盖三类消息变更。

## 问题与修复

此前路由存储选择物理 store 后丢弃 route epoch，共享物理库时跳过路由。底层消息事务在锁房间前直接重放操作回执，也没有核对所选 owner。真实双库负向测试中，control 已选择 epoch 1、owner 仍为 epoch 0，普通群和大群的编辑、撤回及 reaction 都提交成功；六个场景合计触发 22 个失败断言。

三类路由存储现在都保留完整 route，并通过各自必传 ownerRoute 的内部能力协议调用 PostgreSQL store。即使只有一个 shard，或多个逻辑 shard 共用一个物理库，也查询路由并检查显式注册表。Gateway 的单库和多 owner 两个组装分支均使用这些入口，复用已有连接池。

事务顺序为：actor/operation advisory lock → room 行 FOR UPDATE → 比较实际 shard/owner_epoch → 回执重放或当前业务授权/准入 → 消息、事件、outbox 和回执提交。房间行锁一直持有到事务结束，排队请求在取得锁后核对更新后的 epoch。缺失房间、错误 shard 或 epoch 不匹配抛出 ownerChanged，Gateway 返回现有 UNAVAILABLE、retryable=true。错误响应不暴露 owner 配置，也不回退其他数据库。

已成功的旧 operation 同样先通过 owner 栅栏，不能用旧 owner 的回执冒充当前结果。匹配当前 owner 时仍返回原幂等结果，不重复业务效果。编辑沿用原有 control 身份快照，在进入 owner 事务前完成读取；没有新增持锁跨库查询。撤回/reaction 原有授权规则保持既有实现。

底层不带 route 的 public 方法保留房间本地原语，生产 Gateway 使用 owner 验证入口。通用栅栏读取两个 owner 字段，后续业务仍复用既有查询读取其余 room 状态；因此每个路由调用增加一次短 SQL 查询，成功回执重放也需取得 room 锁。已验证并发幂等和锁等待行为，尚未做额外吞吐/延迟压测。

## 验证

- 修复前：1 项测试、6 个参数场景失败，22 个断言证明旧 owner 上确实提交了消息变更/操作回执及序号。
- 首轮修复后：4 项测试 / 2 套件通过，包含三类命令 × 普通群/大群、旧缓存的新操作和重放、十次并发仅提交一次、错误物理库、未知 shard，以及重放等待 room 锁期间 epoch 变化后拒绝。
- 最终 **87 项测试 / 7 套件**通过，见[证据清单](../../docs/reviews/verification-records.md#20260906-message-mutation-owner)，覆盖网关错误映射、已有消息业务语义、普通成员栅栏、邀请/审批/恢复和历史迁移链。

验证使用专用 PostgreSQL 16.13、本地 Swift 6.3.3；双库测试中 owner profile 表为空，编辑使用 control 身份。Gateway 已编译；不是实际 TLS 客户端或部署验收。PostgreSQL 25、protocol 25、SQLite 173/5 不变。

## 尚未关闭的迁移问题

本批没有复制房间、执行 cutover 或创建迁移执行器。迁移必须先 fence 旧 owner，再复制完整历史并切换 control route；只更新 control route 无法阻止仍持旧缓存且与旧库 epoch 一致的请求。栅栏错误目前依赖现有路由缓存过期/重试机制，未新增主动失效或透明重路由。

普通成员、邀请和本批三类消息变更已具备各自事务 owner 检查；后续[群管理栅栏批](group-capability-owner-fence-contract.md)已覆盖公告/置顶/权限/成员角色。后续[moderation 栅栏批](moderation-owner-fence-contract.md)已覆盖普通管理和可信安全操作。通用发送（含批量/fast append）、read receipt、事件读取和其他后台任务仍需逐项统一。完整历史、邀请/申请/回执、D05 旧操作阻断与审计、转发/媒体、outbox 的复制、核验和失败恢复仍待完成。B27 保持实施中，相关 B04/B06/B11 的完整迁移证据仍开放。

后续补充：群已读回执及读者候选分页已接入[共享 owner 栅栏](read-receipt-owner-fence-contract.md)。私聊后续 control 投影、其他路径与完整迁移仍以该合同的剩余范围为准。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](send-message-owner-fence-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。

## Reaction own-key operation

current58 / protocol36 将 reaction 写入改为 [V2MessageReactionOperationCommand](../../IMV2Core/Sources/IMV2Core/MessageReactionOperation.swift) 与 [永久执行器](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2MessageReactionOperationStore.swift)。原 identity、规范化 reaction、明确 present/absent 目标、expectedReactionRevision 与首次截止共同绑定 fingerprint；首次窗口最多 24 小时，不从消息内容 revision 或聚合 count 推算自己的版本。

`GET /v2/rooms/{room}/message-reactions/{message}?reaction=...` 返回当前授权的 own-key snapshot；新提交仍验证当前成员及消息接受时的成员权限，历史 query 仅返回自己的最小原回执。`POST /v2/rooms/{room}/message-reactions/change` 和 `/operations/recover` 经过 RoomRef、body 上限、持久账号限流与 no-store。每个新 committed operation（包括已满足目标的 no-op）使 key revision 加一，重放不增加。实际集合变化的 commit 带事件序号／身份；no-op 不伪造事件。原回执不是当前集合证明，后续反向变更不会改写历史结果。

`message_reaction_key_revisions` 保留 absent tombstone 防止旧意图覆盖；`message_reaction_receipts` 保留永久 committed/rejected/closed 最小结果，与领域集合、事件和准入在同一事务提交。query、close 与提交共用 operation lock 和 activation fence。旧 `message_reaction_operations` 与 35 日 housekeeping 路径已删除；没有为无版本／无截止的旧 TLS DTO 加回退。当前范围仍不包含 redaction 或 forward 父子计划迁移。
