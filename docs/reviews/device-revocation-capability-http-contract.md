# 仅撤销凭据的 HTTP 与 ClientKit 合同

当前范围：本文的 `POST /v2/device-credentials/revoke` 只处理本机退出时的仅撤销凭据兑换。凭据已在注册事务原子交付；App 已接持久退出交接、独立 runner 和状态观察。下方 2026-09-07 验证数字是当时批次记录，不代表最新整批回归或真机生命周期验收。

远程撤销另走认证账户入口 `GET /v2/devices/revocation-baseline`、`POST /v2/devices/remote-revocations/submit` 与 `POST /v2/devices/remote-revocations/operations/recover`。完整 baseline 最多 256 个其他设备，用户确认窗口最长 120 秒；冻结目标、原 ID、deadline 与 fingerprint，32 KiB 请求/64 KiB 回执。服务端业务撤销及永久原回执同事务，query/close 共锁；后登录设备不扩入原目标。客户端专属 Keychain metadata 不保存 access/refresh/capability，账户 activity 拥有执行，重启不恢复首次 submit 授权；页面离开不取消已保存意图，账号关闭阻止旧页面及 service 新增操作。此最新链路仍待集中验证。

## 服务端入口

`POST /v2/device-credentials/revoke` 位于 Account 服务。与其他账号入口一样，先验证 HTTPS edge 注入的 secret 和有效客户端地址；随后使用 PostgreSQL 中持久化的地址限流。该路径明确列入生产 limitedPaths，且不经过当前账号认证 middleware。Caddy 的现有整体反向代理覆盖此路径。

请求必须是 JSON，且恰好有 `credential` 和 UUID `operationID` 两个字段。`deviceID`、`userID` 或任何其他字段（包括 null）均拒绝。流式与预先收集的请求体都有大小上限。访问令牌、账号设备头不会参与选择目标，唯一目标由凭据摘要查得。

| 响应 | 意义 | 是否确认本次撤销已提交 |
| --- | --- | --- |
| 204 | 已执行或同一操作幂等重放 | 是 |
| 400 | 请求结构、凭据编码或操作 ID 非法 | 否 |
| 401 | 凭据未知或会话绑定已不匹配 | 否 |
| 409 | 相同账号操作 ID 已属于其他目标 | 否 |
| 410 | 已识别凭据超过兑换期限 | 否，不冒充撤销确认 |
| 413 | 请求体超限 | 否 |
| 429 | 地址预算耗尽，附 Retry-After | 否 |
| 503 | 限流存储或撤销事务不可用 | 否 |
| 403 | 缺失或非法 trusted-edge 证明/地址 | 否 |

路由生成的响应为空且 no-store/no-cache；不回显凭据或目标。前置 middleware/流式 body collector 的错误由其既有错误处理器输出。兑换复用既有数据库事务，HTTP 503 不能留下部分设备、令牌、Push、事件或 journal 修改。

## 客户端传输

`V2HTTPDeviceRevocationClient` 只接受 capability、operationID 和传输依赖，不持有 `V2AuthSession`，也不读取当前账号凭据。调用方负责先持久化并复用 operationID。它不自动重试或自动刷新。

仅接受无 userinfo/query/fragment 的 HTTPS endpoint；默认使用禁用 cookie、HTTP credential storage、缓存和跳转的现有安全 URLSession。每次请求最长 15 秒，并在发送前和返回后检查任务取消。请求体只有 capability 与 operationID，不携带 Authorization、设备头或 cookie。

204 才返回 revoked；410、401、409 分别返回 expired、invalidCredential、operationConflict。其他状态保持结构化错误，429/503 保留合法 Retry-After 秒数或 HTTP 日期。网络失败不等于撤销成功；取消继续向上抛出 CancellationError。现有持久执行器必须区分这些状态，不能把 401/410 记为已撤销；410 可作为服务端确认旧会话期限结束的独立结果，按退出 checkpoint 合同收尾。

## 验证边界

- 20 项服务端单元 / 4 套件：状态映射、非法/附加字段、超大 body、trusted-edge、限流与存储失败。
- ClientKit 报告 421 项 / 66 套件，416 项实际执行，5 项在线用例跳过。新增覆盖响应丢失后稳定重试、无账号凭据、错误/期限区分、端点限制、限流提示和取消后迟到成功。
- 4 项真实 PostgreSQL 回归包含实际 Vapor middleware/route/service pipeline：403、400、401、503 全部回滚、204 重放及持久限流 429，随后新设备仍可认证；并保留此前会话隔离/并发/期限验证。
- 本批使用 Vapor 内存 HTTP pipeline，没有把它称为真实 HTTPS socket 或 App 到服务器验收；未重新运行 App/TLS live harness。

见 [证据](../../docs/reviews/verification-records.md#20260907-revocation-capability-http)。schema 27、protocol 27、SQLite 173/5 未改。完整签发与客户端持久生命周期仍待实现，47 项目标保持开放。
