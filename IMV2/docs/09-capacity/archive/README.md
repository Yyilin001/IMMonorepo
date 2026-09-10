# 容量归档

这里保存被后续修订取代的阶段性压测记录。**它们不参与判断当前容量结论。**

| 归档文件 | 被谁取代 |
| --- | --- |
| [direct-1500-stability-boundary-2026-08-21](direct-1500-stability-boundary-2026-08-21.md) | [R29 梯度](../direct-room-log-50000-gradient-r29-2026-08-27.md)、[R51 配置隔离与 soak](../direct-room-log-50000-profile-isolation-r51-2026-08-28.md) |
| [direct-1500-steady-900-admission-isolation-2026-08-21](direct-1500-steady-900-admission-isolation-2026-08-21.md) | [R29 梯度](../direct-room-log-50000-gradient-r29-2026-08-27.md) |
| [direct-room-log-credit-batch-benchmark-2026-08-20](direct-room-log-credit-batch-benchmark-2026-08-20.md) | [hot direct room credit 灰度](../hot-direct-room-credit-rollout-2026-08-22.md) |
| [direct-room-log-strict-steady-capacity-2026-08-21](direct-room-log-strict-steady-capacity-2026-08-21.md) | [R29 梯度](../direct-room-log-50000-gradient-r29-2026-08-27.md) |
| [direct-room-log-tail-latency-ab-2026-08-26](direct-room-log-tail-latency-ab-2026-08-26.md) | [R29 梯度](../direct-room-log-50000-gradient-r29-2026-08-27.md)、[R34 共享帧 A/B](../direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md) |
| [empty-direct-projection-ab-2026-08-21](empty-direct-projection-ab-2026-08-21.md) | [R29 梯度](../direct-room-log-50000-gradient-r29-2026-08-27.md)、[R34 共享帧 A/B](../direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md) |
| [shard-only-preflight-ab-2026-08-21](shard-only-preflight-ab-2026-08-21.md) | [ADR-006 路由与迁移](../../00-foundation/ADR-006-routing-and-migration.md)、[ADR-010 容量与灾备](../ADR-010-capacity-and-disaster-recovery.md) |
| [direct-room-log-50000-checkpoint-r44-2026-08-28](direct-room-log-50000-checkpoint-r44-2026-08-28.md) | [R51 配置隔离与 soak](../direct-room-log-50000-profile-isolation-r51-2026-08-28.md) |

## 当前容量证据

判断当前容量能力只看这三处，不要引用本目录：

- [standard-100k](../standard-100k.md)：100k 成员配置与压测合同。
- [R29](../direct-room-log-50000-gradient-r29-2026-08-27.md)、[R34](../direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md)、[R51](../direct-room-log-50000-profile-isolation-r51-2026-08-28.md)：当前引用的实测报告。
- [implementation-status](../../implementation-status.md)：能力矩阵与未覆盖项。

## 维护规则

同一测量出现新修订时，把被取代的旧报告移到本目录，并在这里登记取代它的文档；
不要删除，也不要让两份报告同时留在当前目录里。
