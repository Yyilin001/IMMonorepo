# 静态房间归属与当前发送权限

首版不提供房间或用户分片的在线搬迁，也不支持历史数据库结构升级。新环境执行当前 [schema.sql](../../IMV2/sql/schema.sql)，启动时由 Schema readiness 检查当前合同；旧库须重建。具体 schema 版本以建库脚本和合同校验为准。

[历史设计与实现记录](https://github.com/Yyilin001/IMMonorepo/blob/f0aa8699/docs/reviews/room-owner-migration-contract.md)仅供追溯。保留本文件路径和下方写者清点锚点，以承接已有链接；历史授权预留、SQL 持锁回调及排空流程不再是部署要求。

## 当前归属

部署前配置逻辑分片到物理存储的映射。房间执行绑定 owner/epoch 和 activation，并在实际写入中校验执行边界。用户同步、个人事件和设备撤销只使用当前归属。

控制侧关系、拉黑、偏好与资料通知仍须投递到用户存储。这是当前业务投递，保留来源身份去重，与历史分片搬迁无关。媒体存储位置的迁移也是独立业务能力，不属于数据库结构兼容。

## 当前发送权限

消息准备通过当前 Policy Owner 获取权限事实，形成与房间 activation 绑定的执行上下文。消息写入没有该上下文时拒绝执行，不再通过旧 SQL 授权预留补齐权限。

旧授权 intent、receipt、holder、revocation 和房间权限租约已从当前 schema 移除。对应扫描器、持锁跨库回调和专用恢复连接不再属于运行组装。策略版本、策略变更记录、发布 outbox 与当前 Policy Owner 恢复仍保留，见[权限运行说明](../../IMV2/docs/10-operations/direct-send-policy-cache-runbook.md)。

成功发送的持久结果与消息完成记录一起写入。消息操作恢复使用原操作指纹和原结果时间；缺失这些字段的记录不能依靠调用参数或消息创建时间生成成功回执。其他领域的完成记录格式需按各自写入与恢复合同处理。

### 当前控制权限写者清点（2026-09-20）

此锚点承接历史写者清点链接。下面列出当前入口，不再声称旧 SQL 排空机制仍在使用。

| 控制事实 | 当前入口 |
| --- | --- |
| 拉黑、好友关系 | `PostgresV2SocialRelationshipStore` 的当前策略操作入口，需要 Policy Owner |
| 陌生人权限 | `PostgresV2AccountPreferenceOperationStore` 的陌生人偏好操作，需要 Policy Owner |
| 账号停用 | `V2AccountDisableService`，需要 Policy Owner |
| 新账号与展示资料 | 各自的账号／资料事务；展示字段变化不能直接等同于发送权限变化 |

增加控制事实写入入口时，必须接入当前策略变更与内存更新流程。管理员直接 SQL 不能作为已受此流程保护的应用接口。

## 验证与剩余范围

旧授权协议的[验证记录](verification-records.md)是历史证据，不能证明当前 Policy Owner 路径的正确性。历史测试中仍有直接调用旧发送夹具的构造，必须迁移到当前执行上下文；不得恢复生产兼容路径来满足旧夹具。

当前部署、跨库转发、策略变更与提交恢复的验证以对应版本的实际测试结果和[治理清单](status.md)为准。删除旧协议不表示这些验证已经全部完成。
