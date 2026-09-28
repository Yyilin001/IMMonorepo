# 前台同库转发的来源与目标 owner 栅栏

对应 B04/B27。Gateway 的前台转发必须保留每个来源房间和目标房间的持久 shard/epoch；同物理库只是执行位置，不能跳过目录或 owner 检查。

## 当前账户 HTTP 路径

current59/protocol37 的生产转发由账户父计划承接；`V2OwnerAwareForwardPlanPort` 按冻结的稳定子身份调用源 RoomRef recover/prepare、目标 RoomRef import 和源 RoomRef recordReceipt。control 元数据事务不接触房间事实，不跨 owner 共享 SQL 事务。原结果查询先于当前成员授权，但所有调用仍经过精确 activation fence；归属变更/结果不明不能转换为永久业务拒绝。

worker 重建后先核对已有 processing 子块，不重新生成身份；取消只关闭未交接子块或由源权威证明尚未 export 的配对。已 export 配对继续核对目标最小原回执。父最终摘要与有序完整结果绑定，禁止已核对子结果回退为 pending。账户提交/恢复均为有界 HTTP，旧无截止 TLS 转发停止准入。

下面保留原同库执行器的 owner 栅栏分析，作为内部原语约束；它不再描述当前 App 的生产提交入口。

## 原同库执行器的路由和批量处理

`V2RoutedForwardMessagesService` 先批量解析所有房间路由。目录故障、未知配置 owner 不允许扫描其他数据库或回退默认库。部分房间不存在时，保留原有有界点查及逐对 NOT_FOUND 行为。

全部请求房间同库时，仍一次调用本地服务，保留一次来源集合查询和服务内有界目标并发。混合拓扑继续按目标、连续同库来源片段处理，并保持来源 × 目标的结果顺序。跨物理库仍使用已有 export/inbox 协议和 pending/paused 聚合。

路由注册表只接受显式实现 `V2OwnerValidatedForwardMessagesHandling` 的 owner；本地服务的写依赖要求 `V2OwnerValidatedForwardMessageWriteStore`，不能以默认实现丢弃来源路由。Gateway 本地和分库组装都使用该路径，复用原 PostgreSQL writer 的缓存、额度 actor 和投影配置。

## 各阶段的事务边界

每个阶段取得对应房间的锁后，比较所选 shard/epoch 与实际 rooms 行；缺行、错误 shard 或过期 epoch 均拒绝。多房间锁按 UUID 排序取得，避免反向转发形成相反锁序。

| 阶段 | 锁和检查 | 拒绝时的持久状态 |
| --- | --- | --- |
| 查询既有转发结果、补记缺失结果 | 来源与目标房间 FOR UPDATE，随后锁操作记录 | 不新增或修复操作记录 |
| 批量读取来源内容 | 所有来源房间 FOR SHARE，同事务执行原集合查询 | 不把 owner 变化误报为消息不存在 |
| 获取稳定 target client ID | pair advisory lock 后，来源与目标 FOR UPDATE，再读/建操作记录 | 本次事务无新记录 |
| 接受目标消息、重放发送回执 | message operation lock 后，来源与目标 FOR UPDATE；随后执行原来源受众/版本/内容/附件授权和目标接受流程 | 本次消息接受事务回滚；先前已提交的 client ID 保留 |
| 补记结果 message ID | 新事务中重新锁来源与目标，验证后更新操作记录 | 已接受消息保留，result 仍未补记，允许当前 owner 重试修复 |

不跨服务 await 持有这些数据库锁，也没有跨库事务。仅验证目标 owner 的普通发送接口拒绝包含 forwardedFrom 的请求；前台转发必须同时提供来源房间和两端路由。

## 重试和迁移边界

命令开始时 owner 失配抛出 retryable ownerChanged；某个独立来源/目标对在执行期间失配，沿原逐对错误合同返回 UNAVAILABLE，其他已提交对不回滚。重试保留原 operation、source revision 和 target client UUID；已接受消息可补回结果，不生成第二条消息。历史结果仍可在源内容变化后重放，但先验证当前两端 owner。

前台操作表可修复结果，故不能照搬跨库 completed/rejected 终态证据的无写读取捷径。旧 owner 必须先被栅栏阻止，再发布 control 路由切换；仅更新 control 而让旧 owner epoch 和旧缓存仍相符，不能阻止旧写。

完整房间历史复制、活跃转发操作和 export/inbox 承接、用户投影后处理的跨事务交接、缓存失效/重新发现 owner、全局内容封禁和终态清理继续开放。本地 epoch 恢复只用于一次性测试，不是生产迁移步骤。该批不关闭 B04/B27。

## 验证

旧实现真实双库反例在来源/目标 epoch 两个场景中产生 6 个失败断言：均错误接受转发并创建操作记录。新增测试覆盖旧缓存、新命令与重放、错误 shard/数据库、实际等锁期间 epoch 更新，以及读取后/接受后两端 owner 变化的四种组合。恢复检查稳定 client ID、八次并发重试及源版本变化后的结果读取；既有反向转发新增显式 owner 模式。

最终 **184 项测试 / 14 套件**通过、退出 0。首次修复构建发现局部查询函数缺少 @Sendable，补齐后进行最终回归；失败编译日志保留。最终运行和源码哈希见[证据清单](../../docs/reviews/verification-records.md#20260906-local-forward-owner)。PostgreSQL 25、protocol 25、SQLite 173/5 未改变。真实 TLS/App、多 Gateway 负载、Linux 和完整迁移仍待验收。
