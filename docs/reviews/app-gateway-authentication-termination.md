# App、真实账号服务与 Gateway 认证终止验收

对应 B09。真实 App 验收复现了此前替身测试遗漏的故障：另一设备撤销当前设备后，Gateway 查询已经返回 unauthenticated，但 NIO 只关闭连接。App 将 EOF 当作临时网络故障，继续重连，设备列表和已登录界面没有及时退出。

## 修复

Gateway 只对认证器明确返回的 `V2GatewayAuthenticationError.unauthenticated` 生成既有 protobuf Error：原 requestID、协商的协议版本、`UNAUTHENTICATED`、retryable=false。会话先关闭认证状态，byte stream 等待响应实际写出，再进入原有关闭和注销路径；同批后续请求不再执行。数据库异常和损坏持久化状态不发送终止认证响应，避免客户端误删仍有效的凭据。

ClientKit 的既有握手错误分类、账号 epoch/被拒 token 校验及 App 认证状态观察器因此得到明确结果，能够结束当前会话并停止实时任务。此次没有修改协议 schema 或添加新的客户端重试策略。同时补齐本地 Compose 中必填的 `IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND=20`，真实原生 Gateway 此前因缺少该配置无法启动。

## 真实验收边界

`scripts/verify_v2_live_account_authorization.py --app-ui --gateway --output NEW_DIRECTORY` 构建当前原生 Account/Gateway，创建独立 PostgreSQL cluster、当前 schema、临时 CA 和 localhost 证书；HTTPS 代理仅注入服务端要求的可信 edge header，其余响应全部来自真实账号服务。Gateway 使用真实 TLS、数据库认证和设备撤销监听。

脚本新建专用 iPhone 17 / iOS 26.2 模拟器，只向该模拟器添加临时 CA；使用正常模拟器签名，使 App 实际使用 Keychain、SQLite、URLSession 和实时运行时。App 通过已有 DEBUG scope 隔离凭据和本地库。结束时执行 scoped App 清理、删除本次模拟器，并停止和删除本次服务、数据库及密钥；没有使用既有数据库、已有模拟器或生产配置。

| 场景 | 实际操作 | 验收结果 |
| --- | --- | --- |
| HTTP 终止 | App 真实注册并打开设备列表；第二设备经真实 HTTP 撤销当前设备；Gateway 不可用时点击刷新 | 业务 401 → refresh 401 → Keychain 终止删除 → 自动回登录；旧页面和弹层消失 |
| 在线 Gateway 终止 | 同样真实注册；撤销前指标确认 App 有一个已认证 Gateway 连接；第二设备撤销后不点 HTTP 刷新 | 撤销断开后，重连得到明确认证拒绝，自动回登录；没有反复保留旧登录页面 |
| 前后台与冷启动 | 两个场景均切换主屏幕并重新激活，再 terminate/launch 相同 scope | 都保持登录页，不复活旧账号；保留截图并进行视觉核对 |
| 服务端持久结果 | 从真实 PostgreSQL 读回设备、访问凭据、刷新会话和撤销事件 | 九个设备、三个撤销设备；被撤销设备有效访问/刷新凭据均为零，三个撤销事件 |
| 连接清理 | Gateway 指标读回 | 撤销前已认证连接为 1，App 清理后为 0 |

## 验证记录

- 修复前真实 Gateway 用例失败，HTTP 用例通过；日志记录多次 unauthenticated 后重连，指标确认失败发生在实际连接建立之后。
- 修复后两项 App UI 测试通过；同次四项真实 HTTPS 测试通过（2.962 秒）。HTTP 计数为一次刷新成功、三次刷新 401、三次设备撤销 204。
- 服务端 64 项 / 3 套件回归通过（0.051 秒），含认证拒绝写出顺序、同批后续请求阻断，以及基础设施错误不发送认证终止响应。
- ClientKit 报告 388 项 / 60 套件（4.673 秒），其中四项实时服务测试显式跳过；实际执行 384 项离线测试全部通过。前批 183 项 App 单元回归作为已有证据，本批新执行的是两项真实 UI 验收。

初期夹具失败也保留：关闭模拟器代码签名导致 Keychain 注册保存失败；设备 UUID 大小写造成定位失败；指标刷新间隔不满足生产约束导致启动失败；新增服务端断言误用了不存在的 protobuf 字段导致编译失败。它们均修正夹具或断言，没有放宽生产 Keychain、认证或指标校验。缺少必填诊断配置及 EOF 丢失认证语义是本次确认并修复的实际问题。

原始失败/成功日志、状态计数、截图、运行脚本及源码摘要见[本批证据](../../docs/reviews/verification-records.md#20260906-app-gateway-authentication)。B09 的终止认证到重新登录链路标为已验证，问题总表更新为 15 项已验证、32 项仍开放。

此验收使用本地单库、原生进程和专用模拟器，不代表生产 Caddy、真实设备锁屏、生产证书或多副本部署验收。B08 的持久退出检查点、撤销专用能力、离线退出期限和完整 A→B→A 交错仍开放，不能随 B09 一并关闭。Protocol 27、PostgreSQL schema 25、SQLite 173/5 未变。原始日志目前保留在本工作区，既有日志忽略规则和干净 checkout 证据分发仍属于 E08。
