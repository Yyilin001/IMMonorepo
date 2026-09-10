# 群已读回执与读者列表的 owner 栅栏

2026-09-06，B27 房间迁移前置修复。覆盖房间 owner 上的群回执单条/批量写入，以及读者候选分页。

## 已复现的问题

路由层原来只按 shard 选物理库，单条操作不传 epoch，批量合并后只保留 shardID。PostgreSQL 群回执快速路径直接按语句快照查成员和回执，没有阻断 owner epoch 变化；读者候选分页也未核对所选 owner。真实双库的普通群/大群中，单条和批量都在旧 owner 上记录成功，读者列表也接受旧 owner，六个场景共 10 个失败断言。

## 路由与事务

新增 required-route owner 能力和每行携带 route 的批次输入。路由层继续按物理库合并最多 128 条请求，每条都保留 shard/epoch，不以第一条 route 替代其他房间。Gateway 单库与多 owner 两种组装都使用此入口。读者候选每一页都传入原选 route，control 仍负责身份和隐私过滤。

带 owner 校验的单条写入复用一行批量实现，和批量调用使用同一套操作/用户游标 advisory locks。每个物理事务按既有固定顺序取得 advisory locks，再按 room UUID 排序对所有存在的目标房间取 FOR SHARE 锁。共享锁允许多个回执事务并发，同时阻止 owner 更新；它不是只阻止主键变化的 FOR KEY SHARE。

从加锁语句实际返回的 room/shard/epoch 计算每行的 ownerIsValid。缺失房间明确为 false，不因下一条语句恰好看见后来创建的同 ID 房间而放行。锁持续到事务提交；取得锁期间发生的 epoch 更新必须被实际返回行观察。

原有集合 SQL 批量推进单调游标和写操作回执，只允许 ownerIsValid 的新行进入 eligible，并在结果判定中优先返回 owner_changed，早于旧回执成功或冲突。返回类型使用 V2ReadReceiptStoreError.ownerChanged，失败行不改变其游标或回执，合法行正常提交。参数数量增加后 prepared statement 名称升级为 v2，未修改 PostgreSQL schema。

基础设施异常仍抛出并回滚该物理事务。跨物理库批次本来就不具备全局原子性，其他 owner 可能已完成，重试依靠原 operationID。普通领域错误继续逐行返回，不能因其中一条 owner 过期而回滚其他合法行。

候选分页在其 owner 事务内先取得 room 共享锁、核对 shard/epoch，再读取消息和成员上下文及候选。control 身份/隐私读取在 owner 事务结束后进行，不持锁跨库。Gateway 写入和分页都将 ownerChanged 映射为既有 UNAVAILABLE、retryable=true。

## 性能与边界

每个带 owner 校验的物理批次增加一次有界 room 加锁查询，仍使用集合写入，不逐行拆成事务。单条走同一条锁路径；相比旧的无房间锁群热路径，可能增加与消息/成员更新的等待。已验证并发和锁顺序，未做新的吞吐/延迟负载验收。

不带 route 的底层方法保留旧的房间本地行为，生产 Gateway 群路径使用新能力。新旧混合 writer 的在线切换仍需明确排空窗口；不能把未升级的本地原语当作支持 owner 迁移的 writer。

私聊的 notGroup 分类也先核对所选 owner，但其后 reciprocal projection 仍在既有 control/user 路径执行。本批不宣称建立了该后续 control 事务与远端 room 的跨库迁移原子边界；这仍属于完整迁移与用户投影交接的开放范围。用户偏好写入不进入房间 owner。

## 验证与剩余工作

修复前 1 项测试 / 6 场景失败，10 issues。首轮修复后 7 项测试 / 3 套件通过，包含旧缓存新写/回执/读取、十次并发幂等、错误/未知 owner、无 owner profile、等待共享锁期间 epoch 改变和新 epoch 重放。扩展回归 8 项测试 / 3 套件通过，最终 **126 项测试 / 11 套件**通过。混合批次、单条与批量竞争、control 隐私过滤、多房间消息并发及日志见[证据清单](../../docs/reviews/verification-records.md#20260906-read-receipt-owner)。

PostgreSQL 25、protocol 25、SQLite 173/5 不变。通用发送/批量/fast append、其他读取与后台工作仍需统一 owner 检查；完整历史、回执、私聊投影、审核任务、D05 阻断与审计、转发/媒体、outbox 的复制、核验、切换及失败恢复仍待完成。

迁移须先 fence 旧 owner，再复制和切换 route；只修改 control route 不足以阻止仍与旧库 epoch 一致的旧缓存。没有新增主动 cache 失效、透明重路由、实际 TLS/App/生产迁移验收。B27 及相关 B04/B06/B11 仍保持开放。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](send-message-owner-fence-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。
