# B06 成员角色快照版本

更新：2026-09-06。服务端角色变化开始按每个目标成员的 membership revision 排序；成员离开/重入的持久负事实、客户端统一处理和旧历史恢复仍未完成。

## 当前角色事实

`V2GroupPolicySnapshotEffect` 现在解析 `group.member_role_changed`，以 `membership_revision` 为对象版本，键为 room/target。不以 `revision`、个人游标或另一个成员的版本代替。目标和房间必须为 UUID，角色限 admin/member，版本为正 Int64；可选源序号为正 Int64，可选时间非负。角色命令不能转成 owner，此限制与生产写入一致。

工作器复用已有组策略投影事务，按目标成员独立读取当前状态，较低版本不覆盖；同版本不同来源拒绝；同一来源改变版本或事实也拒绝。普通 member 角色是明确当前值，会进入快照。当前角色键兼容 Foundation/PostgreSQL 的 UUID 大小写组合，继续使用已有物理键，发现多个当前对象则拒绝。

## 尚未闭环的成员资格合同

`membership_changed` 的 add/remove 与角色变化共用房间 membership revision，但不能用房间最后一次事件来判断任意一个成员的资格：最后一次事件可能针对另一个成员。现有 remove 会删除角色投影，删除之后丢失的版本屏障不能靠本批角色比较重建。较旧 remove 与较新角色/重入的组合也需要处理，不能据本批角色事件回归宣称已修复。

下一步需要持久保存每个 room/target 的成员资格及来源版本，统一 add/remove/role 处理，并将成员负状态与授权后的 snapshot bank、客户端消费和保留清理一起设计。旧快照只保留房间最后一条 membership 观察时，不包含完整的逐成员历史；当前成员目录也不能自动提供已经离开的成员版本。没有来源证据时必须明确恢复，不能把全局最高 revision 当作每个成员的最后变化。

该后续变化还必须覆盖本人退群导致的整房间清理、重新入群、迟到其他群控制事实、旧 staging/已签发快照、房间日志和用户同步各自的代次，以及 writer/worker/readers 的统一切换。本批没有新增字段或表来声称已满足这些合同。

## 验证

最终服务端定向回归 **22 项 / 4 套件**通过。真实 PostgreSQL 覆盖两名成员的角色提交与逆序 fanout、按目标保留版本、迟到旧角色、旧大小写键、快照 build/manifest/page/ACK，以及同版本不同来源冲突后的 checkpoint 回滚；类型测试覆盖 membership revision 选择、目标身份、owner/非法角色、缺失/溢出/非法版本和源序号/时间边界。原置顶、公告、权限保留、reaction、schema 和快照合同也通过本次定向回归。

运行日志和四份源码哈希见[成员角色快照证据](evidence/20260906-member-role-snapshots/manifest.json)。没有新跑 Core、ClientKit 或 App，也不是服务端全套。diff、协议文档、schema relation coverage 通过；测试会话终态已确认，两临时库清理后 PostgreSQL 已停止。本批没有失败测试运行。成员资格组合、TLS、Linux、负载及生产切换仍未验收。

Protocol 25、PostgreSQL 18、SQLite 172/5 未改，B06 仍实施中。
