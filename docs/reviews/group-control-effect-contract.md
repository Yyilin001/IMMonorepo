# B06 群管理效果：源版本与后续恢复约束

更新：2026-09-06。此文件区分已实现的源事件、权限保留修复与尚未实现的消费和快照迁移合同；B06 仍为实施中。

## 已实现的源事件变化

`PostgresV2GroupCapabilitiesStore.commit` 在持有 room lock 的提交事务中，把分配的 `room_sequence` 同时写入事件列和事件 JSON。置顶、公告、角色权限、成员角色共用这一入口。分发给各用户的 `user_sync_sequence` 只是该用户的消费位置，不能替代该源版本。房间日志和个人分发必须保留同一 sourceEventID 与事实内容。

权限操作的幂等比较已改为解析后的权限集合。`jsonb::text` 会改变 JSON 格式，不能拿它与请求编码器的文本直接比较。相同 operationID 下，room、role、expectedRevision 或权限集合变化仍然冲突。

源字段修复只为新提交事件补充字段，旧客户端可以忽略它；未改写既有事件、共享分发正文或已签发的快照。后续权限保留修复将 PostgreSQL 升至 schema 18，protocol 23 和 SQLite schema 不变；尚未部署。

## 尚待修复的消费路径

| 对象 | 当前实现问题 | 需要保留的版本与状态 |
| --- | --- | --- |
| 置顶 | 服务端和 ClientKit 已按已知源 room sequence 比较并保留 unpin 负状态；客户端四路消费共享持久摘要，旧库不再把个人游标当源版本 | 服务端见[置顶快照合同](pin-snapshot-contract.md)，客户端迁移、快照和 receipts 见[置顶效果合同](pin-effect-contract.md)；永久缺源序号、已丢失负事实和完整成员代次仍需权威恢复 |
| 公告 | ClientKit 已按 revision 排序、持久去重并拒绝同版本冲突，旧库未知源序号保存为 NULL；服务端快照已比较 revision 并保留空状态 | 个人/预览/房间/快照共用 reducer，旧暂存快照重新导入；历史身份缺证据和完整保留策略仍有限制，见[公告效果合同](announcement-effect-contract.md) |
| 角色权限 | ClientKit 已独立按角色 revision 排序、持久保存空集合并校验来源；缺失角色不再回退默认权限 | 个人/预览/房间/快照已共享 reducer，旧正权限行及暂存快照迁移已实现；缺失角色的持久基线恢复、执行器和 App 重试已接通，真实链路验收仍待完成，见[角色效果合同](role-policy-effect-contract.md)及[状态与重试合同](role-policy-recovery-ui-contract.md) |
| 成员角色 | 服务端当前角色快照已按目标成员的 membership revision 排序并拒绝同版本冲突；客户端及成员移除/重入后旧角色恢复仍待修复 | 当前角色证据见[成员角色快照合同](member-role-snapshot-contract.md)；仍需逐成员 add/remove 负状态、统一消费与授权代次，不能用房间最后一次变更替代 |

统一 reducer 必须同时覆盖个人流、房间预览、持久房间流和 snapshot shadow。effect claim、物化状态、cursor 在同一事务内提交。重复事实可以推进当前消费流的 cursor；同版本不同事实不能静默覆盖。对象版本和 effect receipts 必须随授权后的 snapshot bank 一起切换，内部元数据表不得触发全量 UI 紧急刷新。

## 历史与保留：不能跳过的前置问题

1. 旧群管理事件正文没有 source room sequence。旧客户端保存的 `room_sequence` 可能来自个人游标，不能作为可信回填来源。仍保留的权威 room event 列可以用于受控恢复；丢失源证据时必须走明确的代次/基线恢复合同，不能猜测。
2. 已签发快照、分发共享正文和 sourceEventID 绑定的摘要不能原地改写。增加强制字段之前必须处理旧 reader、旧 staging 和历史 payload；新客户端直接拒绝所有旧事件会破坏升级。
3. 权限回执过期导致显式空策略丢失的路径已修复：schema 18 的 `group_role_policies` 保存持久标记，resolver 和三处批量消息 SQL 均改用当前策略。真实 GC、单条与预热批量授权、迁移回填和历史缺口回滚已通过验证，见 [权限保留合同](group-policy-retention.md) 和 [20 项测试证据](evidence/20260906-group-policy-retention/manifest.json)。客户端现已独立保存空策略版本；旧库缺失角色仍需当前态恢复。
4. 服务端现保留新消费的取消置顶负事实并按已知源序号排序；此前已经丢失的负事实不能从最新正状态推断，两条缺源序号的旧事实仍无法证明真实顺序。需要历史回放/权威基线以及源 writer 和投影 worker 的统一切换安排，见[置顶快照合同](pin-snapshot-contract.md)。
5. 旧 SQLite 已丢失空策略的独立 role revision 时，不能仅清空本地 sync token 来获取完整基线。protocol 24 现已提供 `require_snapshot`，ClientKit 通过 `requestSnapshotRebuild()` 持久请求个人基线；服务端即使 ACK 未落后于保留起点也会 stage snapshot，重复请求复用待完成 reset。旧 token 缺失的普通续拉行为不变，live bank 和 outbox 保留到受控切换。该基础通路已验证，群 reducer 迁移触发、旧数据修复和独立房间日志基线仍未实现，见[个人基线恢复合同](personal-snapshot-rebuild.md)。
6. 角色权限恢复还需当前有效策略读取，不能依赖不完整的入群历史。现已实现领域基线、PostgreSQL 单一读取点的两类角色策略与当前成员检查，以及不缓存的 owner 前后复核；protocol 25 已接通认证网关、生产组装和客户端传输，客户端各角色 reducer、完整观察点及本地持久恢复栅栏已实现，自动 runner 和 App 生命周期已接通，[暂停反馈与显式重试入口](role-policy-recovery-ui-contract.md)已接通，完整链路及人工交互验收仍待完成，见[权限基线合同](group-policy-baseline-contract.md)。基线 revision 是完整策略的观察点，不能伪造为两类角色的历史修改事件。

## 下一批验收

- 各对象 preview→personal / personal→preview、重复、乱序、同版本冲突及重启；源 room sequence 与房间 envelope 不一致要拒绝。
- 各 role 独立更新、非空→空→旧非空乱序、幂等回执过期后的权限仍为显式空。
- 成员离开、重新加入、角色变化和 snapshot reset 的组合，不能因旧角色事实恢复已撤销权限。
- 旧库和已暂存快照升级、缺源历史、房间授权撤销、重新导入，并绑定数据库结构与测试证据。
