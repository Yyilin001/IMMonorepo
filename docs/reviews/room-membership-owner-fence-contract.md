# 普通成员变更的 owner 事务栅栏（B27 迁移前置）

2026-09-06。网关普通加人/移除现在将所选 route 的 shard/epoch 传入真实成员事务。完整房间迁移仍为开放工作，不能仅凭邀请链路的 epoch 检查开放迁移。

## 已确认的问题

此前 `V2RoutedRoomMembershipStore` 仅返回按 shard 选择的 store，丢弃 route epoch；共享物理库时还直接跳过 route。成员事务只读取 room_shard_id 来定位 admission，不核对所选 shard/epoch，且在锁房间之前重放旧回执。单库 Gateway 组装直接使用本地 store，绕过路由层。

真实双库负向回归中，control route 已是 epoch 1、实际 owner 仍为 epoch 0，普通群和大群均接受移除操作，写入成员回执和事件。此路径必须在房间迁移前补齐，否则旧 owner 的迟到普通成员变更能绕过邀请审批已有的栅栏。

## 修复边界

`changeControlValidated` 增加必传 ownerRoute。路由存储保留所选 route 与 store，和 control 身份快照一起传入 owner；同物理库或单 shard 配置也获取 route，不按拓扑跳过 epoch。Gateway 的单库分支现在同样组装路由成员存储。

成员事务按以下顺序执行：

1. 取得 actor/operation advisory lock。
2. 锁定目标 room 行，核对实际 shard/owner_epoch。
3. 检查 D05 旧操作阻断与幂等回执。
4. 新操作执行当前身份、成员角色、revision、容量及 admission 校验。
5. 在同一事务提交成员区间、事件、outbox 和回执。

房间锁内已读取的 room 状态继续供后续写入使用，不以第二次无锁读取替换。等待房间锁时 epoch 改变也必须重新判断返回行。owner 不匹配或该物理库没有目标房间时抛 ownerChanged；不查询或写入另一 owner。Gateway 映射为现有 `UNAVAILABLE`、retryable=true，不引入新 wire 错误码或泄漏 shard 信息。

成功操作的重放也先通过 owner 栅栏。匹配的当前 owner 仍可在原 actor 已失权后返回原结果，但新操作必须经过当前身份/角色授权。旧 route 不得仅凭本地成功回执冒充当前 owner。

底层 `.change` 保留房间本地原语语义；生产 Gateway 通过上述路由入口调用。邀请审批继续在外层取得 owner 栅栏，调用同一事务内的静态成员函数；锁顺序仍是操作锁在房间锁之前。该共享函数不再打开第二个事务，也不在持有 owner 事务时跨库读取 control。

## 迁移前提与剩余工作

本修复不执行数据复制或 route cutover。迁移必须先阻断旧 owner 写入，再复制完整历史并切换 control route；仅改变 control route、不先 fence 旧 owner，无法阻止仍持旧缓存的请求在旧 epoch 上工作。

当前仓库没有完整房间迁移执行器。编辑/撤回/reaction 已由后续[消息变更栅栏批](message-mutation-owner-fence-contract.md)补齐；群能力已由后续[群管理栅栏批](group-capability-owner-fence-contract.md)补齐；moderation 已由后续[事务栅栏批](moderation-owner-fence-contract.md)补齐；通用发送（包括批量与 fast append）、read receipt 等其他房间路径尚未统一 owner epoch 栅栏。还需处理后台任务、完整成员历史、邀请/申请/成员回执、D05 审计与旧 operation 阻断、事件/outbox、转发与媒体的迁移清单、校验、切换和失败恢复。B27 保持实施中；这也是相关 B04/B06/B11 保留与迁移验证的依赖。

修复前 1 项测试 / 2 个参数场景均失败，共 8 个断言发现旧 owner 已发生业务写入。修复后首轮 8 项测试 / 3 套件通过；最终 78 项测试 / 7 套件通过。包括普通群/大群、十次并发幂等、旧缓存的新操作及重放、当前身份、错误/未知 owner、请求等待期间 epoch 变化及新 epoch 重试；另覆盖 Gateway 命令错误映射、远端群创建、既有成员冻结受众、三库邀请、原子审批、D05 旧操作阻断和七条历史迁移链。Gateway 组装已编译，未部署真实网关。

本批 PostgreSQL schema 25、protocol 25、SQLite 173/5 均不变。验证记录见[本批证据](../../docs/reviews/verification-records.md#20260906-membership-owner-fence)。真实网络客户端、完整房间跨物理复制、进程崩溃和生产迁移尚未执行。

后续补充：群已读回执及读者候选分页已接入[共享 owner 栅栏](read-receipt-owner-fence-contract.md)。私聊后续 control 投影、其他路径与完整迁移仍以该合同的剩余范围为准。

后续补充：普通发送的单条、私聊冷/暖批量与大群集合事务现已补 owner 校验，见[发送栅栏合同](message-send-contract.md)。后台转发导入、来源/其他读取、control 身份/策略隔离和完整迁移交接仍开放。
