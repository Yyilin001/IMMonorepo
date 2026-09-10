# Moderation 的 owner 事务栅栏

2026-09-06，B27 房间迁移前置修复。本批覆盖普通消息屏蔽、禁言和移除成员，以及可信安全服务的消息屏蔽、冻结和解冻。

## 缺口与实现

原路由 wrapper 选择 store 后丢弃 epoch，共享物理库直接跳过 route。PostgreSQL controlRoom、redact、removeMember、mute 四个事务在取得 actor/operation 锁后，先重放本地 moderation_operations，再读取 room，没有比较所选 owner。Gateway 单库分支直接使用本地 store，内容审核 worker 的可信服务也复用该存储。

新增 V2OwnerValidatedModerationStore，普通与可信安全两个入口都必须传入所选 ownerRoute。路由选择始终保留 shard/epoch，校验显式 registry，单 shard 与同物理库多 shard 均不可绕过。Gateway 单库和多 owner 两个组装分支都使用路由 wrapper；普通命令服务和内容审核的可信服务继续共享该入口及原有连接池。原私有 selector 的同库跳过路由入口已无调用方，现一并移除。

四个底层事务在 operation advisory lock 后复用 v2RequireRoomOwner：先 FOR UPDATE 锁 room 并核对 shard/owner_epoch，再允许回执重放、当前授权及准入、业务状态、事件/outbox、审计和操作回执。等待锁期间发生的 epoch 更新也必须被观察。旧成功回执不能让旧 owner 返回权威结果；错误物理库缺少目标 room、未知 shard 等情况不会尝试另一库。

owner 校验与权限边界分开：普通调用仍不能冻结/解冻，可信调用仍只允许既有的屏蔽/冻结/解冻。可信 principal 由服务配置提供，不接受客户端传入。消息审核版本、普通角色权限、成员保护及审计保留规则维持原有合同，不把路由正确当成业务授权。

不带 route 的公开方法保留房间本地原语，生产 Gateway 两个组装分支均使用 required-route 实现。每个路由请求增加一次短 SQL 查询，回执也取得 room 锁；无吞吐/延迟压测。公共客户端协议不增加 shard 信息，ownerChanged 继续映射 UNAVAILABLE、retryable=true。

## 审核任务恢复

已有 V2ContentReviewWorker 在 moderation 抛错时不会 resolve，转而按持久重试策略排队或暂停。新增边界测试验证 ownerChanged 时稳定 operationID、违规发现已暂存、resolved/redacted 为零，以及未耗尽/耗尽时分别 retry/pause；没有把失败审核误记成完成。该单元测试证明 worker 分支，不替代审核 job 全量 owner 迁移和进程崩溃验收。

## 验证与剩余范围

修复前完整十二个场景失败，60 个断言证实旧 owner 写入；首次负向运行的两个解冻夹具约束错误单独留档，未计为该路径复现。首轮修复后 **6 项测试 / 4 套件**通过。真实双库回归覆盖普通群/大群的六种场景、无 owner profile、独立非成员安全 principal、旧 route、新命令/回执、同库多 shard 缓存、十次并发单次业务/审计提交、错误/未知 owner，以及重放等待 room 锁期间 epoch 变化。最终 **113 项测试 / 8 套件**通过；修复前失败记录及源码哈希见[证据清单](../../docs/reviews/verification-records.md#20260906-moderation-owner)。

PostgreSQL 25、protocol 25、SQLite 173/5 不变；无新迁移。Gateway 和可信审核组装已编译，三个普通网关命令有错误映射测试；没有实际 TLS/App/生产部署验收。最终回归使用本任务专用隔离 control 与两个 owner。

目前邀请、普通成员、消息编辑/撤回/reaction、群管理和 moderation 已有各自事务 owner 检查。后续[群回执栅栏批](read-receipt-owner-fence-contract.md)已覆盖群已读回执和读者候选分页；通用发送/批量/fast append、其他读取和后台任务仍需统一，私聊 control 投影迁移边界仍开放。完整成员/操作历史、D05 阻断及审计、邀请/申请、审核 jobs、转发/媒体、outbox 的复制、校验、切换和失败恢复仍待完成。

迁移必须先 fence 旧 owner，再复制和切换 route。仅修改 control route 不能使与旧库 epoch 一致的旧缓存失效；本批未增加主动缓存失效或透明重路由。B27 及相关 B04/B06/B11 的完整迁移要求保持开放。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](send-message-owner-fence-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。
