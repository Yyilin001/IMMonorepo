# B16 Push 最终意图合同

本批只实现服务端条件存储及 schema 18→19 迁移；HTTP、ClientKit 持久 desired/reconciler 和 App 接线仍开放，B16 保持实施中。现有 App 的无版本 PUT/DELETE 竞态尚未消除。

## 三种不同的版本

- `session_epoch` 由服务端授予，限定一个客户端 Push 意图会话。读取当前 epoch（未初始化为 0）之后，用随机 claim ID 与 expectedEpoch 做比较并交换。只有匹配当前 epoch 才能前进；丢 ACK 重试必须使用原 claim ID/expectedEpoch。重复当前 claim 返回原 epoch，不清空已发布 revision。旧 claim 到达新会话后被拒绝。
- `intent_revision` 由客户端先持久递增，服务端只接受当前 epoch 中更高 revision；同版本同内容幂等，同版本异内容冲突。epoch/revision 限定正 Int64，初始化 revision 0 只供服务端内部使用。
- `endpoint_generation` 仍是 APNs 端点代次。新意图注册生成新值；旧 APNs 410 只能禁用原代次。同版本重试不生成新代次，也不重新启用已被 APNs 判无效的端点。

会话 claim 本身保留端点物理状态，直到当前会话发布 desired。客户端不能将 stale 错误处理为不受约束的“读取并再次抢占”：必须先确认当前账号、设备、安装及任务代次仍拥有意图，持久保存 claim，再发请求。epoch 是排序信息，不是认证凭据。

## 服务端事务与保留

所有 claim、版本写入及旧接口写入先锁 active `auth_devices` 行并核对 user/device。当前设备的版本行和端点在同一短事务内更新。disable 即使没有端点也保留版本行，防止迟到 enable 重建端点；不对该行做普通回执 TTL 清理。设备撤销后读取和修改均受 active device 检查约束。

`push_device_intents` 每设备仅保留当前 epoch、claim、revision、摘要和更新时间。摘要是经独立用途派生密钥计算的 HMAC-SHA256，输入包括设备、enabled、provider/environment/token；新表不保存明文 token 或无密钥 token hash。端点仍使用原有绑定 device/provider/environment/generation 的加密封装。密钥轮换和重注册仍需单独运行规程。

进入版本机制的设备拒绝旧无版本 register/delete，防止绕过排序。尚未 claim 的设备暂时保持旧接口行为，因此此存储改动本身不能证明 App 竞态已修复。HTTP 仍需稳定映射 invalid/stale/conflict/version-required/auth 错误并提供 no-store 响应。

## 受控迁移

新环境直接使用 schema 19；既有 schema 18 先停止旧 account-edge 写进程，备份并执行 `IMV2/sql/migrations/20260906_versioned_push_intents.sql`，再启动新版本。脚本要求精确来源版本，整次事务执行，保留既有加密端点，不发明历史用户意图。旧进程不知道版本行，不能混合运行。进入版本机制后不可简单降级或删除版本表，否则旧请求可重新生效。

Swift 和 SQL readiness 同时校验表列类型、空值条件、主键、epoch/revision 范围、摘要与 revision 的配对约束、指向 auth_devices.device_id 的 RESTRICT 外键。17→18 的已有权限迁移回归继续执行 18→19 后再检查当前合同；既有 7/8/10/14/15 起点的迁移测试链也补至 19。降级夹具必须移除后来新增的表，且测试拼接脚本先去除注释，再排除 BEGIN/COMMIT，以保持外层事务边界。

## 验证边界

本批测试覆盖真实 PostgreSQL 迁移保留端点、拒绝重复迁移、各关键约束缺失导致启动拒绝，以及禁用先到、旧 enable、同版本重放/冲突、claim 丢响应重试、新会话拒绝旧请求、39 个并发版本最高者生效、重建 store、token 轮换、旧 410 和端点/版本原子回滚。Core 验证数值边界。

测试结果与源码摘要见 [证据](../../docs/reviews/verification-records.md#20260906-push-intent-storage)。重建 store 只验证服务端持久状态，不等于 iOS 杀进程或账号切换验收。后续仍须完成 HTTP 真实请求、客户端持久 desired/claim/revision、单一 reconciler、取消与重试、App 生命周期以及 A→B→A、离线开关/退出和重启的组合验证。
