# 群投递模式与 100k 容量门槛

状态：当前代码合同；尚无生产容量批准。
最后审阅：2026-08-16

## 不可变投递模式

群在创建时按成员数确定 delivery mode，数据库禁止后续切换：

| 创建时成员数 | mode | 普通消息正确性路径 |
| --- | --- | --- |
| `1...5,000` | `standard_fanout` | 冻结成员受众 → room outbox → planner → per-user sync projection |
| `5,001...100,000` | `large_group_hybrid` | 单份有序 room event → 已授权客户端 cursor pull |

Hybrid 普通消息不做全员 fan-out；只有显式 mention 等可靠目标进入 fan-out。群创建仍须让全部
初始成员获得房间可见性，因此 100k 创建是一次有界但昂贵的 bootstrap，不代表普通消息也承担
100k 写放大。配置中的 `100000` 是拒绝边界，不是吞吐或 SLO 声明。

## 运行时硬边界

| 配置 | 当前语义 |
| --- | --- |
| `IM_V2_MAX_ELIGIBLE_MEMBERS` | 命令提交前拒绝超出 profile 的受众 |
| `IM_V2_MAX_FANOUT_UNITS_PER_WINDOW` | 限制持久化目标数，不是 socket/Push 数 |
| `IM_V2_MAX_OUTSTANDING_FANOUT_UNITS` / `...PLANS` | 新写入前限制 durable backlog |
| `IM_V2_MAX_ENUMERATION_PAGE_SIZE` | 限制一次 membership enumeration/completion unit |
| `IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE` | 限制一次 lease claim；不扩大提交事务 |
| `IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` | co-located target 原子提交上限，当前最大 128 |
| `IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` | remote target 批次上限，当前最大 256 |
| `IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY` | remote target/control 重叠提交上限，当前最大 2 |
| `IM_V2_MAX_PLANNER_CONCURRENCY` / `...DELIVERY_CONCURRENCY` | 单进程 worker 并发；PostgreSQL lease 是跨副本 fence |
| `IM_V2_DURABLE_RETRY_*` | 有界退避；耗尽进入 `paused`，禁止 terminal skip |
| PostgreSQL pool limits | 必须同时容纳前台命令/sync 与配置的 durable workers |

准入容量在 source transaction 内预留。实时连接、NATS 和 Push 都不能替代 inbox、sync sequence、
sync log、completion unit 或 lease token。

## 正常回归覆盖

`bash scripts/run_v2_postgres_integration.sh` 默认执行 100k audience 的分页 planning shape：

- page size 为 1,000；
- 精确产生 100 个 completion units；
- 精确产生 100,000 个去重 delivery targets；
- interruption regression 证明 committed page 后可恢复，partial page 完整回滚。

这只证明形状、边界与可恢复性，不证明吞吐。

## 显式高成本回归

以下命令只允许对一次性 PostgreSQL 环境执行。它们会创建大量 durable rows，不属于每次提交的
普通门禁。

### Hybrid 100k 普通消息与 mention

```sh
IMV2_RUN_HYBRID_100K_CAPACITY=1 \
  V2_TEST_PACKAGES=IMV2Server \
  V2_SERVER_TEST_FILTER=acceptsOneHundredThousandMemberHybridRoomWithoutGlobalFanout \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
    -e IMV2_RUN_HYBRID_100K_CAPACITY=1 \
    -e V2_TEST_PACKAGES=IMV2Server \
    -e V2_SERVER_TEST_FILTER=acceptsOneHundredThousandMemberHybridRoomWithoutGlobalFanout \
    swift-tests
```

断言普通消息只有 room log、零 global fan-out，并且一个显式 mention 只产生一个可靠目标。

### Hybrid 100k 原子创建

```sh
docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_HYBRID_100K_GROUP_CREATE=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=createsOneHundredThousandMemberHybridRoomAtomically \
  swift-tests
```

断言房间、100,000 memberships、操作结果和 bootstrap plan 的原子一致性。

### 100k durable fan-out drain 与崩溃恢复

```sh
docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_100K_DELIVERY_SOAK=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=drainsOneHundredThousandMemberAudienceExactly \
  swift-tests

docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_100K_CRASH_RECOVERY_SOAK=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=recoversOneHundredThousandMemberAudienceAfterEveryCompletionUnitInterruption \
  swift-tests
```

这些回归用于证明通用 durable pipeline 的恰好一次投影、lease recovery 与 admission release；
它们不允许把 100k `standard_fanout` 作为新群产品模式。

## 生产批准必须提交的报告

1. PostgreSQL 版本/规格、gateway/worker 副本、region、room/user shard 分布和全部配置值；
2. 群数、成员数、消息率、payload 分布、在线设备比例、重连/重复发送与 sync pull 率；
3. acceptance p50/p95/p99、durable completion age、sync lag、backlog peak、paused/retry/lease expiry；
4. PostgreSQL CPU、IO、WAL、lock wait、连接池与拒绝行为；
5. gateway/worker kill、PostgreSQL 暂不可用/故障转移、NATS 丢失/分区、设备撤销中同步；
6. 容量负责人批准的 pass/fail 阈值和失败时的降级 profile。

缺少报告、阈值失败或拓扑变化时必须降低 admission profile；不得引用旧本机单次耗时、线性
外推或单元测试作为 100k 生产承诺。
