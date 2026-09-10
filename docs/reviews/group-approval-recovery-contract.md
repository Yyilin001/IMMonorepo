# 遗留群审批受控恢复（D05）

2026-09-06。现有 owner 上的 D05 恢复路径已验证。协议 25 / SQLite 173+5 不变，PostgreSQL 20→21。未部署；B26/B27 及其网络、迁移组合验收没有因此关闭。

## 恢复能力

独立 `IMV2OperatorServerApp` 在已有 loopback listener 和独立 operator bearer 认证后注册：

- `POST /internal/v2/group-approvals/candidates`：`shardID`、`ownerEpoch`、`roomID`、可选 UUID `after`、`limit`（1–100）。按 `(room_id, request_id) WHERE state = 'approving'` 部分索引读取一页，返回最多 100 条及 `nextCursor`；没有常驻全历史轮询。
- `POST /internal/v2/group-approvals/recover`：恢复 `operationID`、同一 owner scope、`requestID`、期望的旧 `reviewerUserID` 与 `decisionOperationID`、封闭 reason 枚举。principal 来自 operator 配置，不由请求体指定。

只选择配置 registry 中的 owner，不接受数据库 URL，不广播或回退到控制库。owner 事务锁定 room 并检查 shard/epoch；普通账户与 Gateway 入口不注册恢复路由。成功响应 `no-store`，错误不暴露数据库细节。

## 状态与证据

锁顺序为恢复 operation → 旧成员 operation（与普通成员写相同 advisory namespace）→ room → request → 成员回执/邀请码。恢复不会添加成员、发事件或使用 admission。

| 证据 | 结果 |
| --- | --- |
| 找到确切成员 operation，room/target/add 匹配，实际 expected revision 不小于准备 revision，结果 revision/sequence 合法 | `completed`：同事务补邀请码使用量、approved 状态、实际输入 revision、原操作时间与不可变审计。申请人后来退群、审核人后来被移除/禁用不影响已提交事实。 |
| 没有 operation，且完整历史区间中不存在该申请人在准备 revision 之后的加入 | `released`：同事务写不可变审计及旧 operation 阻断记录，再退回 pending。之后必须用新 operation 走正常审批和当前权限检查。 |
| operation 绑定冲突、历史加入存在但回执缺失、revision 异常或已提交操作无法结算邀请码余额 | `quarantined`：申请和用量保持原状，只记录审计与诊断；不会根据当前成员资格猜测。 |
| 申请已不是 approving | `not_approving`：记录无业务效果的审计结果。 |

旧 B26 曾只在内存中更新 expected revision。因此准备值为 0、成员实际在 1→2 提交是可恢复情况，不能要求准备值与实际输入相等。

**历史完整性是释放判断的前提。** 当前生产代码保留 `room_memberships` 的完整历史区间，普通移除只写 `left_revision`，没有历史区间清理路径。任何已提交添加都必须留下 `joined_revision > preparedRevision`；离群不会删除该证据。缺失回执时检查这一历史事实，而非当前成员状态。已人工删减、裁剪迁移或损坏的历史不满足此前提，必须隔离调查；将来引入历史 GC 或裁剪迁移前，必须新增覆盖水位并关闭覆盖不足范围的缺失证明。

恢复本身不授予新审批权限。即使旧审核人仍有权限，操作员也只能将确定未提交的申请退回 pending，并阻断旧 operation；新操作仍由正常审批入口授权。

## 审计与迟到写入

`group_join_approval_recovery_audit` 保留恢复输入、principal、理由、结果、旧申请的 applicant/prepared revision，以及找到的成员操作 room/target/action、输入/结果 revision、sequence、event 和 plan。审计与业务转换同事务，UPDATE/DELETE 被数据库 trigger 拒绝。

`room_membership_operation_fences` 以 `(actor_user_id, operation_id)` 为主键，引用不可变恢复审计。普通成员变更、批准和拒绝入口都先检查阻断记录。阻断不随申请清理或权限恢复消失；恢复不会通过伪造成功成员回执实现取消。

同一恢复 operation 重试核对完整输入和 principal，返回原审计结果。不同操作员 operation 竞争同一旧审批，由旧成员 operation 与 request 锁串行化，只能生效一次。原恢复在 owner epoch 改变后重放仍读原审计；新的过期 scope 操作被拒绝。

## Schema 与上线条件

`20260906_group_approval_recovery.sql` 从 current-20 原子升级至 current-21，增加两张表、不可变 trigger/function 和候选部分索引，不自动修改旧 approving。上线前排空所有旧成员/审批/清理写进程，升级全部相关 owner schema；旧二进制不认识阻断记录，不能混用。

Swift 与 SQL readiness 同时检查列类型/空值约束、PK/FK、精确 CHECK 定义、不可变 trigger 的启用状态和函数体、有效的候选索引。只改版本 marker、放入同名弱约束或替换函数体不能通过。

审计和阻断没有自动 GC。D06 的申请终态保留、B27 的 owner 迁移必须同时设计这两类记录及完整成员历史的交接，不能只搬当前 roster。

## 验证

环境为 Swift 6.3.3/macOS、专用 PostgreSQL 16.13，两个独立可销毁数据库 `127.0.0.1:56440/im_remediation` 和 `im_remediation_owner2`。

最终 15 tests / 2 suites 通过，含参数化用例：

- 旧准备 revision 0，真实成员写在 revision 1 提交，申请人随后退出、原审核人被移除并禁用，恢复只补一次记账；审计保存原输入与结果。
- 4 类真实数据库状态：已提交、未提交、回执已被旧清理删除但加入/离群历史尚在、operation 绑定不匹配。后两者隔离而不释放。
- 在审计 INSERT 或退回 pending 的最终 UPDATE 后抛错，验证申请、用量、审计、阻断记录全部回滚。
- 10 路相同操作重放仅一份效果；两份不同恢复操作并发只释放一次。
- advisory barrier 让恢复停在阻断 INSERT 后，真实迟到成员请求已经执行并等待同一 operation 锁；释放 barrier 后旧请求返回幂等冲突。旧审核人重新入群并恢复 admin 后，原 revision 和改 revision 的旧操作重用仍被阻断，批准/拒绝入口也拒绝；新授权人的新操作成功。
- 两个独立 owner 中仅目标 owner 有 103 条申请，分页 100+3，锚点经恢复移出 approving 后仍不漏页；错误物理 store、未知 shard、过期 epoch 被拒绝。重建 service 后仍重放原结果。
- operator HTTP 认证、无效输入、100 条边界、owner 错误和数据库错误脱敏；未认证请求不进入 store。
- 实际 20→21 迁移保留旧申请，重复迁移失败；同名弱 CHECK、被替换的不可变函数和缺失索引都被 readiness 拒绝。
- 审批原子性、证据清理保留、配额、通用清理预算、Push、群策略及 forward 单/双库回归；7 条历史迁移链已接至 schema 21。

证据：[manifest](../../docs/reviews/verification-records.md#20260906-group-approval-recovery)。本批次未部署，未声称完成真实进程 kill/HTTPS ACK drop 或 owner 在线迁移演练；这部分仍由 B26/B27/D08/E 项继续覆盖。
