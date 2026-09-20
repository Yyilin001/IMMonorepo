# 用户分片部署范围

状态：2026-09-20 取消在线迁移能力。项目尚未上线，当前只支持全新数据库和固定分片配置。

保留 `IM_V2_USER_SHARD_STORES_JSON` 的逻辑桶到数据库/schema 映射，以及默认路由与用户路由覆盖。部署前完成配置，运行期间不执行在线换桶。普通个人状态投递、同步和设备撤销使用当前归属。

已删除 copy/verify、双写、cutover、rollback、retention source cleanup、相关 Operator HTTP 路由和后台任务。服务不再提供 `/internal/v2/user-shard-migrations/*` 或用户路由切换接口。

新环境直接执行 [当前 schema](../../sql/schema.sql)，不提供旧数据库升级或存量用户搬迁脚本。旧设计与旧测试记录只用于历史追溯，不代表可调用能力。当前剩余问题见[治理清单](../../../docs/reviews/status.md)。
