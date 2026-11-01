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

[本机时间点恢复脚本](../../scripts/test_v2_postgres_pitr.py)另外创建两个私有 Unix socket
实例，安装当前 schema，使用不包含 WAL 的物理 base backup 与独立归档。移除原实例后，
恢复实例仅从归档读取 WAL，在数据库时钟选定的时间点暂停，核对完整审计行、排除目标时间后
提交的行，再结束恢复并验证新写入。备份清单和所需 WAL 由 `pg_verifybackup` 校验。
脚本不连接现有数据库；报告保存版本、文件摘要、恢复位置、保留与排除的记录和清理结果。

从仓库根目录运行；输出目录必须尚不存在，`--pg-bin` 指向 PostgreSQL 16 的完整工具目录：

```sh
python3 IMV2/scripts/test_v2_postgres_pitr.py \
  --pg-bin /opt/homebrew/opt/postgresql@16/bin \
  --output-dir build/reports/pitr-local
```

[2026-11-01 本机证据](../../../docs/verification/postgres-pitr-20261101.json)记录
schema78 的物理备份与归档恢复通过，保留两条目标前记录、排除一条目标后记录并成功继续写入。
此次小样本恢复阶段为 0.653 秒，计时包含本机复制、恢复启动、目标核对和首次提交；
生产事故发现、远程传输与密钥取回不在该计时内。

部署仍须完成生产规模、跨区域归档、密钥恢复、故障转移路由及故障期间持续写入演练，
并批准 RPO/RTO。以上本机证据不解除这些发布门槛。恢复流程依据 PostgreSQL 16 的
[持续归档](https://www.postgresql.org/docs/16/continuous-archiving.html)、
[恢复目标](https://www.postgresql.org/docs/16/runtime-config-wal.html#RUNTIME-CONFIG-WAL-RECOVERY-TARGET)
与[备份校验](https://www.postgresql.org/docs/16/app-pgverifybackup.html)合同。
