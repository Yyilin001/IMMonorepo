# ADR-004：PostgreSQL 权威状态与追加事件模型

状态：已接受  
日期：2026-07-23  
所有者：V2 后端负责人

## 背景与决定

PostgreSQL 是 V2 的权威实体、消息、成员资格、幂等记录、outbox/inbox、sync
log 和 device cursor 存储。一次单 shard 命令在同一事务内提交当前状态、领域
事件、幂等结果和 outbox；事件用于投影重建，不采用“事件是唯一真相”的完整
event sourcing。

## 备选方案

- Redis/NATS 作为权威：不能提供恢复、授权或完成证据；
- 完整 event sourcing：增加重放/版本治理成本，当前需求不要求；
- PostgreSQL 当前状态加追加事件：提供本地事务与可重建投影。

## 后果

- Redis/NATS/网关内存只能作缓存、提示或临时 lease，不能决定不可逆业务事实。
- 每个新命令必须在 SQL、store、event、outbox 与恢复测试中证明原子性。
- 未来物理分片、PITR 和跨 shard forwarding 由 ADR-006/010 补充，不能由本
  ADR 推断为已经实现。

## 回滚与复审

首发使用空 V2 schema；PG 供应商、复制模型、事件保留或分片模型改变时复审。
