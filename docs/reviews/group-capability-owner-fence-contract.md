# 公告、置顶、权限与成员角色的 owner 事务栅栏

2026-09-06，B27 房间迁移前置修复。覆盖四类群管理命令，不代表完整房间迁移已完成。

## 已复现的问题

V2RoutedGroupCapabilitiesStore 原来在选择 store 后丢弃 route epoch，共享物理库时直接跳过路由。PostgreSQL 四类操作均先读取幂等回执，再锁 room，也未比较实际 owner。成员角色还会在取得操作锁之前因 self-target 返回 alreadyInDesiredState。

在真实双库测试中，control 为 epoch 1、目标 owner 为 epoch 0，普通群和大群的公告、置顶、角色权限和成员角色都发生了实际提交；8 个场景共 32 个失败断言检查旧 owner 的操作回执、room 状态和序号。不是编译失败或仅检查调用参数。

## 实现边界

新增 V2OwnerValidatedGroupCapabilitiesStore，四个方法的 ownerRoute 都为必传参数。路由 wrapper 保留完整 route 并校验显式注册表，单 shard 与多个 shard 共用一库均不可绕过。Gateway 单库和多 owner 的组装都使用路由能力；复用现有 PostgreSQL 连接池，未增加跨库事务。

操作事务遵循以下顺序：actor/operation advisory lock → room FOR UPDATE 并核对 shard/owner_epoch → 已有回执或业务分支 → 当前成员/权限、revision、admission → 原有原子消息控制状态、room event、outbox、回执。复用消息变更批的 v2RequireRoomOwner；等待 room 锁后再核对实际返回行。

成功回执及 self-role 的提前返回同样经过栅栏。所选 owner 不匹配、未知 shard 或误配物理库不会触达另一个 owner。已成功操作在当前 owner 上仍可返回旧结果；新操作保留既有授权和 revision 条件。公共领域命令和协议没有增加路由字段；Gateway ownerChanged 使用已有 UNAVAILABLE、retryable=true。

不带 route 的底层方法继续作为房间本地原语存在，生产 Gateway 两个组装分支均进入带 route 的实现。owner 检查增加一次短 SQL 查询，回执重放也取得 room 锁；没有做吞吐或额外网络延迟压测。组管理权限校验仍以当前 owner 成员/角色为依据，本批不改变账号停用的全局一致性合同。

## 验证与剩余工作

修复前 1 项测试 / 8 场景失败，32 issues。首轮修复后 **5 项测试 / 3 套件**通过。修复后覆盖旧缓存新命令与回执、同库多 shard、十次并发只提交一次、错误 shard/数据库、未知 registry、self-role 提前返回，以及重放等待 room 锁时 epoch 变化后拒绝。最终 **93 项测试 / 7 套件**通过，日志见[证据清单](../../docs/reviews/verification-records.md#20260906-group-capability-owner)。

PostgreSQL 25、protocol 25、SQLite 173/5 不变；无 schema 迁移。测试使用专用 loopback PostgreSQL，本批最终回归包含独立 control 与两个 owner。生产入口已编译，网关命令测试不等同实际 TLS/App 或生产部署。

普通成员、邀请、编辑/撤回/reaction 及本批群管理命令现具备各自 owner 栅栏。后续[moderation 栅栏批](moderation-owner-fence-contract.md)已覆盖普通管理和可信安全操作。通用发送（含批量/fast append）、read receipt、读取及其他后台任务仍需统一。完整成员历史、回执、邀请/申请、D05 审计与旧操作阻断、转发/媒体、outbox 的复制、校验、切换与失败恢复仍开放。

迁移必须先 fence 旧 owner，再复制和切换 control route；仅修改 control route 无法使仍与旧库 epoch 一致的缓存请求失效。当前错误使用已有缓存过期与重试，不新增透明重路由。B27 及相关 B04/B06/B11 的完整迁移要求继续实施中。

后续补充：群已读回执及读者候选分页已接入[共享 owner 栅栏](read-receipt-owner-fence-contract.md)。私聊后续 control 投影、其他路径与完整迁移仍以该合同的剩余范围为准。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](message-send-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。
