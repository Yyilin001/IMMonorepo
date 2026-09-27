# 时间戳整数边界

对应 B01，延续[资料与投影整数边界](profile-and-projection-integer-boundaries.md)。当前 protocol 27、PostgreSQL 25、SQLite 173/5 不变。

## 缺陷与实现合同

`Double(Int64.max)` 无法精确表示原整数，会舍入到 2^63。因此“浮点值小于等于 Double(Int64.max)，再用 Int64(value) 转换”仍可能终止 Swift 进程。检查有限值不能解决这个边界。

以下入口在保留原取整规则后，用 `Int64(exactly:)` 完成可表示性检查，拒绝值沿用各自的领域错误，不截断、钳制、改单位或替换为当前时间：

| 入口 | 单位与原取整规则 | 拒绝结果 |
| --- | --- | --- |
| Core 资源上传/下载计划 | Unix 毫秒，向下取整 | invalidTimestamp |
| accepted 消息完整投影 | Unix 毫秒，向下取整 | invalidPayload |
| 跨 owner 批量消息状态 | Unix 微秒，向下取整 | corruptPersistenceState；进入目标事务前失败 |
| 设备凭据 HTTP 响应 | Unix 毫秒，向零取整 | malformedPersistence |
| 设备列表 HTTP 响应 | Unix 毫秒，向零取整 | malformedPersistence，路由返回 503 |
| APNs JWT iat | Unix 秒，向零取整；仍禁止负时间 | invalidConfiguration |

原媒体上传 envelope 已随资源系统收敛移除；当前上传/下载共用资源传输计划的时间校验。极端值代表错误时钟、损坏记录或服务返回，不表示普通用户已可通过公开接口注入这些值；具体可达性取决于入口上游。

## 本批排除的疑点

快照构建器的持久计数虽然使用普通加法，但当前 schema 的 CHECK 已把 next_page_index、item_count、total_bytes 分别限制为 4096、1000000、268435456，加上有界单页后远小于 Int64 上限。因此不能把这些行单独判定为当前有效 schema 下的溢出漏洞；本批没有删除约束以制造负例，也没有修改构建器。

分发 ACK 的两个 Int64 转换受 externalBatchAcknowledgementInputs 的正 Int64 校验支配；forward inbox receipt 和群唤醒租约也已有相应上界检查。已读回执在进入当前比较前调用 receiptSigned。本批不机械替换这些已被验证条件覆盖的转换。

## 验证范围

测试覆盖上界浮点舍入、下界外侧、非有限值及正常取整；设备凭据值类型本身已拒绝非有限日期，HTTP 响应测试针对它仍接受的有限超界值。跨 owner 测试调用真实 projector，检查拒绝时状态、inbox、序号和日志均无写入，合法微秒值和同输入重试保持精确与幂等。

修复前 Core 媒体与真实跨 owner projector 的独立负例均以 signal 5 退出。服务端第一轮编译因新夹具缺必填参数、宏嵌套和字段可空性错误失败，修正后才得到实际崩溃证据。修复后的初轮 21 项测试中，仅两个合法数据库场景误期望 message 写入通用 user_projection_effects 而失败；schema 的捕获触发器明确排除了 message，现已修正为该表始终为 0，并保留其他状态/inbox/序号/日志的精确行数检查。

最终扩展服务端 **338 项 / 33 套件**通过（352.801 秒）；Core **89 项 / 28 套件**、ClientKit **374 项 / 58 套件**、App **182 项 / 17 套件**全部通过。服务端包含本批时间边界、快照构建/失败恢复/迁移及既有媒体、消息受众和 owner 回归；未运行完整服务端全套。原始失败与最终日志、脚本、源码哈希见[本批证据](../../docs/reviews/verification-records.md#20260906-timestamp-integer-boundaries)。

其他未带精确检查的时间转换、恢复 DTO、计数器和完整恢复合同仍需逐入口检查；B01 未关闭。此处测试不替代真机、完整 TLS、生产 APNs 或 Linux 发布验收。

后续已补[客户端时间边界](client-timestamp-integer-boundaries.md)，修复合法最大毫秒值在 SQLite 禁言投影读回时的实际崩溃，并为禁言、会话命令和 heartbeat 添加精确编码检查。B01 其余审计范围仍开放。

后续已补[账号限流边界](account-rate-limit-integer-boundaries.md)，策略拒绝不可表示的时长，PostgreSQL 日期绑定前检查实际运算结果；密码失败计数的 SQL 上限并发和审计通过真实数据库验证。B01 的其他入口继续开放。
