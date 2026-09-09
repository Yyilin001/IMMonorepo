# B16 Push 版本化 HTTP 与 ClientKit 传输

此批承接 [服务端条件存储](push-intent-contract.md)，将能力接入 Account 服务入口和 ClientKit。App 仍使用旧无版本开关链路；持久 desired、claim/revision、统一 reconciler 和生命周期接线尚未完成，B16 不关闭。

## HTTP 合同

全部路由以 bearer 和 X-IM-Device-ID 确定 actor/device，body 不接收可覆盖身份的 user/device。响应不返回 provider token。成功、路由校验及存储错误均设置 no-store/no-cache；生产的外层错误处理继续使用既有脱敏 middleware。

| 方法与路径 | 请求 | 成功 | 条件错误 |
| --- | --- | --- | --- |
| GET `/v2/push-endpoint/session` | 无 body | 200 `{epoch}`，初始为 0 | 403 设备不可用 |
| POST `/v2/push-endpoint/session` | `{requestID,expectedEpoch}` | 200 `{epoch}`，必须恰为 expectedEpoch+1 | 409 stale_intent 或 intent_conflict |
| PUT `/v2/push-endpoint/intent` | `{epoch,revision,enabled}`；enabled=true 必须同时给 provider/environment/token；false 时这些字段必须为空或缺省 | 204 | 409 stale_intent/intent_conflict；428 intent_version_required |

epoch/revision 为 JSON 整数，入口调用 Core 的受限类型构造器，不能用 Codable 绕过正 Int64 检查；claim 的 expectedEpoch 从 0 起且不得溢出 successor。非法输入为 400，设备失效为 403，依赖错误为 503，返回固定 code，不序列化错误描述。旧 PUT/DELETE 在版本机制下映射 428，避免被误认为普通网络错误。

Account 主程序给新旧路由注入同一 PostgreSQL store，并通过既有认证与跨副本限流中间件。所有 Push 子路由使用 push scope，读取成本 1、写入成本 3。没有运行线上服务或改动线上数据库。

## ClientKit

`V2ClientPushIntentPublishing` 是必需能力接口，无默认 legacy fallback。`V2HTTPPushEndpointClient` 在既有 endpoint 下追加 session/intent 路径，提供读取、原 claim 重试及发布方法。调用方必须显式给出持久意图的 deviceID；获取当前凭据后核对 UUID，并再次检查取消。设备不一致时不发送请求，防止旧任务用新账号的凭据提交旧意图。

传输只发送一次请求，不因 stale/conflict 自动重新申请 epoch。版本响应限制为 1024 字节、UInt64 解码且不超过 Int64.max；claim 返回值必须精确等于 expected+1。客户端分别暴露 staleIntent、intentConflict 和 intentVersionRequired。HTTP 401/403 保持终止认证分类，网络及其他状态保持原有分类。请求不缓存，超时保持 15 秒；token 仅在请求内存中存在，本批没有增加客户端持久化。

## 已验证与未完成

证据见 [日志和源码摘要](evidence/20260906-push-intent-http/manifest.json)：ClientKit 完整回归、App 单元测试、服务端路由/中间件和真实 PostgreSQL 定向回归。覆盖准确整数编码、设备不匹配拒绝、响应域校验、不自动重试、路由身份传递、输入拒绝、固定错误分类、Push 限流成本，以及真实 HTTP 的先关闭后旧注册、随后新注册和 legacy 写入拒绝。

VaporTesting 通过内存 HTTP pipeline 调用实际 PostgreSQL，尚未证明 HTTPS socket、真实 Account 进程、App 开关点击、杀进程恢复或账号 A→B→A。后续必须先持久保存用户 desired 和版本，再通过一个 reconciler 发送；处理 claim 丢 ACK、OS token 更新、退后台、重启及退出。App 仍使用旧协议，不应将本批兼容测试误认为开关竞态已经修复。
