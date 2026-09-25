# 静态房间归属与持久发送授权

项目尚未上线，首版不提供在线数据迁移。房间迁移准备/冻结、用户分片复制/双写/切换/回滚/源清理及其运维入口已删除。数据库直接使用当前 `im-v2-current-53` 全新建库合同，无历史升级脚本。

[删除前设计与实现记录](https://github.com/Yyilin001/IMMonorepo/blob/f0aa8699/docs/reviews/room-owner-migration-contract.md)仅供追溯，不再作为 B27 或 D07 的关闭条件。保留此文档路径以承接已有授权证据链接。

## 当前归属

部署前配置房间和用户逻辑分片到物理存储的映射。房间请求保留 owner/epoch，并在实际存储事务中校验，拒绝错库或失效的路由。用户同步、个人事件和设备撤销只使用当前归属，不读取迁移回退桶或写入第二个迁移目标。

当前 control 来源的关系、拉黑、偏好与资料通知仍须投递到用户存储；这是普通业务投递，保留来源身份去重。房间消息接受、成员资格、容量和幂等事实继续由 owner 事务提交。

## 持久发送授权

跨库控制连接断开后，owner 事务可能仍在执行。因此保留已复现故障所需的持久授权，不以删除迁移功能为由删除授权保护。

1. 控制库按房间、发送者、client message ID 固定授权身份，绑定请求摘要、接收者、owner/epoch、代次及控制事实。单条、批量、转发均先登记并提交授权。
2. owner 在消息事务内检查授权身份和代次，原子写入消息结果与不可变回执。接受、业务拒绝和代次中止有明确终态；重试不重复扣额度或生成效果。
3. 撤权入口在相应排他锁内停止新授权并排空已有授权，再提交拉黑、关系移除、陌生人权限或账号停用。临时内存权限快照不能替代持久授权。
4. 控制库只依据 owner 的确定回执释放 held；连接失败、超时或进程退出不能当作未提交。Gateway 有界恢复任务可重启、重复执行并拒绝旧代次结果。
5. 媒体尚未就绪时不登记转发授权；实际接受时重新检查媒体状态及有效期。迟到请求必须仍经过原身份和代次判断。
6. 接受事实、授权回执和拒绝标记继续保留。B11 的容量/保留策略单独评估，不增加未经要求的迁移状态机，也不直接按任意期限删除幂等依据。

### 当前控制权限写者清点（2026-09-20）

本次按 V2DirectSendControlPolicyFence 实际读取的六张控制表核对应用写者、修改字段及运行组装；范围为当前 IMV2Server/Sources，不把测试夹具或管理员直接 SQL 视为已接入的应用接口。

| 控制事实 | 当前应用写者 | 锁与持久排空 |
| --- | --- | --- |
| 拉黑、好友关系 | [PostgresV2SocialRelationshipStore](../../IMV2Server/Sources/IMV2Server/PostgresV2SocialRelationshipStore.swift) 的 changeUserBlock / changeRelationship | 用户对排他锁内 drain(pair)，再变更关系/拉黑；Gateway 注入协调器 |
| 陌生人权限 | [PostgresV2DirectMessagingStore](../../IMV2Server/Sources/IMV2Server/PostgresV2DirectMessagingStore.swift) 的 setStrangerMessagePermission | 偏好排他锁内 drain(user)，再写偏好；分片路由交 controlStore，不交 owner store |
| 账号停用与 profile.state | [V2AccountDisableService](../../IMV2Server/Sources/IMV2Server/V2AccountDisableService.swift) | account-state 排他锁内 drain(user)，再写停用记录、暂停资料及吊销凭据；Operator 注入协调器 |
| 新账号资料 | [V2PasswordAccountStore](../../IMV2Server/Sources/IMV2Server/V2PasswordAccountStore.swift) | 服务端生成新 UUID 并插入资料；不是既有账号权限撤销入口 |
| 展示资料更新 | [PostgresV2ProfileUpdateStore](../../IMV2Server/Sources/IMV2Server/PostgresV2ProfileUpdateStore.swift)、[V2PublicIdentityAccountStore](../../IMV2Server/Sources/IMV2Server/V2PublicIdentityAccountStore.swift) | 修改名字/头像/资料修订，不修改 state、special 状态或收发权限，无需为展示变更撤销发送授权 |
| 特殊账号类型、状态及收发开关 | 当前应用无写入 special_accounts 的入口；[V2SpecialAccountMessagingService](../../IMV2Server/Sources/IMV2Server/V2SpecialAccountMessagingService.swift) 读取设置、写消息操作与审计 | 不能把“当前没有应用写者”解释成该表不可变或支持管理员在线直接修改 |

上述应用撤权入口的实际排空/缺失协调器/owner 不可达测试见[写者证据](verification-records.md#20260920-direct-authorization-policy-writers)。特权 SQL、外部部署系统对特殊账号设置的修改不在这批证据内；若增加在线管理入口，必须先阻止对应账号的新授权登记、排空 held，再修改控制事实。当前部署的进程故障与恢复组合仍单独验收，不因写者清点完成而关闭 D07。


## 验证与剩余范围

既有证据包括[普通发送](verification-records.md#20260920-direct-automatic-authorization)、[转发](verification-records.md#20260920-forward-automatic-authorization)、[进程强杀恢复](verification-records.md#20260920-direct-authorization-process-crash)、[撤权先完成](verification-records.md#20260920-forward-revocation-first)、[媒体窗口](verification-records.md#20260920-forward-media-window)和[Gateway 生命周期](verification-records.md#20260920-authorization-gateway-lifecycle)。历史记录中的迁移场景已取消；其余证据仍需按代码版本和部署范围解释。

当前剩余问题以[治理清单](status.md)为准。原邀请路由、授权/幂等/准入、终态保留及生产部署证据分别验收，不要求完成在线搬迁。
