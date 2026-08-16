# ADR-010：容量目标、fenced admission 与灾难恢复

状态：待容量、运维与安全负责人批准  
日期：2026-07-23  
所有者：容量与运维负责人

## 背景与决定候选

room admission 与 shard admission lease 基元已存在；`standard` profile 的
100,000 成员仅是 admission 上限，绝非性能承诺。规范要求记录安全 cluster
budget、非重叠 allocation fence、Push budget、SLO、RPO/RTO、PITR 与恢复演练。
这些数值及实际部署拓扑尚未批准或测量。

## 备选方案

- 以成员数或小房间基准外推：不能证明高频群或故障恢复，拒绝采用；
- 在 worker 超载后 terminal skip：破坏投递正确性，拒绝采用；
- admission-time reservation + 实测 profile + PITR/replay 演练：作为唯一可发布路径。

## 批准后的门槛、回滚与复审

在 `docs/09-capacity/` 记录 topology/workload/阈值；实现全局 worker credit、
监控告警、PITR restore 与 replay runbook；执行 100k、gateway/worker/PG，以及启用时
NATS hint 的故障实验。Redis 不属于当前 V2 correctness path。报告失败时降低 profile，
不以配置值继续发布。任何容量、SLO、RPO/RTO
或存储拓扑变化均复审。

## 当前可重复的恢复证据

`IMV2/scripts/test_v2_postgres_logical_restore.sh` 在独立 PostgreSQL 卷中安装
`IMV2/sql/schema.sql`，写入 durable replay audit record，生成 `im_v2` custom-format
logical dump，删除 schema 后恢复该 dump，并验证当前结构与审计行。
该回归也在本机 V2 隔离验证入口中执行。

这是开发环境的**本机逻辑恢复**证据，不是 PITR 证明：它不覆盖 WAL archive、时间点
选择、跨区域副本、密钥恢复、生产数据规模、批准的 RPO/RTO 或故障期间持续写入。
这些仍是 ADR 批准前的发布阻断项。
