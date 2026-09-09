# 消息编辑、撤回与 reaction 的 owner 事务栅栏

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
- 最终 **87 项测试 / 7 套件**通过，见[证据清单](evidence/20260906-message-mutation-owner/manifest.json)，覆盖网关错误映射、已有消息业务语义、普通成员栅栏、邀请/审批/恢复和历史迁移链。

验证使用专用 PostgreSQL 16.13、本地 Swift 6.3.3；双库测试中 owner profile 表为空，编辑使用 control 身份。Gateway 已编译；不是实际 TLS 客户端或部署验收。PostgreSQL 25、protocol 25、SQLite 173/5 不变。

## 尚未关闭的迁移问题

本批没有复制房间、执行 cutover 或创建迁移执行器。迁移必须先 fence 旧 owner，再复制完整历史并切换 control route；只更新 control route 无法阻止仍持旧缓存且与旧库 epoch 一致的请求。栅栏错误目前依赖现有路由缓存过期/重试机制，未新增主动失效或透明重路由。

普通成员、邀请和本批三类消息变更已具备各自事务 owner 检查；后续[群管理栅栏批](group-capability-owner-fence-contract.md)已覆盖公告/置顶/权限/成员角色。后续[moderation 栅栏批](moderation-owner-fence-contract.md)已覆盖普通管理和可信安全操作。通用发送（含批量/fast append）、read receipt、事件读取和其他后台任务仍需逐项统一。完整历史、邀请/申请/回执、D05 旧操作阻断与审计、转发/媒体、outbox 的复制、核验和失败恢复仍待完成。B27 保持实施中，相关 B04/B06/B11 的完整迁移证据仍开放。

后续补充：群已读回执及读者候选分页已接入[共享 owner 栅栏](read-receipt-owner-fence-contract.md)。私聊后续 control 投影、其他路径与完整迁移仍以该合同的剩余范围为准。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](send-message-owner-fence-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。
