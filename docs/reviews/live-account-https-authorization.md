# 本地真实账号服务与 HTTPS 认证验收

后续状态更新：B09 已完成[真实 App 与 TLS Gateway 认证终止验收](app-gateway-authentication-termination.md)，修复握手拒绝退化为 EOF 的实际缺陷，现标为已验证。下文保留本批当时的范围与未覆盖记录；B08 完整退出/换号仍开放。

对应 B09。前一批验证了业务 HTTP 与认证 actor、App 状态观察者的组合，本批补真实网络和 PostgreSQL 证据。没有修改生产认证策略、接口或 schema。

## 使用的真实组件

`scripts/verify_v2_live_account_authorization.py` 构建当前 `IMV2AccountServerApp`，新建独立 PostgreSQL cluster 并导入当前 canonical schema，启动原生账号服务及仅监听 loopback 的临时 HTTPS 入口。测试入口替换并注入生产账号服务要求的两个可信 edge header，其余请求转发给真实服务；没有伪造注册、刷新或设备撤销响应。

ClientKit 使用实际 `V2URLSessionAuthHTTPTransport`、密码账号客户端、设备凭据发行器、刷新解码器、设备客户端和 `V2AuthSession`。测试用临时 CA 签发 localhost 证书，只在专用 URLSession 内设置信任锚并执行 hostname/证书链校验；未向系统或模拟器安装证书，未改变生产 URLSession 的信任规则。客户端凭据保存在测试 actor 中，服务端账号、设备和凭据状态保存在真实 PostgreSQL 中。

## 已验证场景

| 触发 | 客户端结果 | 真实服务与持久化证据 |
| --- | --- | --- |
| 被拒绝的 access token，仍有效的 refresh credential | 共享刷新成功，保留登录；原业务调用仍报原 401，显式重试成功 | 一个刷新 200；后继 refresh credential 与前驱不同；设备列表成功 |
| 同一账号的另一设备经 HTTP 撤销当前设备 | 当前设备的业务 401 触发刷新 401；凭据被删除，认证流发布 authenticationRequired | 另一个设备仍能列出自己；被撤销设备不再有未撤销的访问/刷新凭据，只有一个撤销事件 |
| 本地 access 过期，refresh credential 被真实服务拒绝 | 在获取业务凭据时结束认证，不发业务请求 | 刷新 401；本地记录删除、认证态 unauthenticated |
| 使用没有信任临时 CA 的生产 URLSession 请求 HTTPS | 证书校验失败是网络错误，保留凭据和登录 | TLS 握手未放行，未因此触发刷新或设备撤销 |

一次完整运行注册四个临时账号、发行五个设备凭据。HTTP 计数确认一次成功刷新、两次终止刷新和一次设备撤销；数据库读回为五个设备、一个已撤销设备、该设备零个有效访问凭据、零个有效刷新会话、一个撤销事件。客户端终止后再请求 refresh 直接返回 unauthenticated，未增加远端刷新次数。

## 可重复运行与清理

在安装了 Swift、PostgreSQL CLI 和 OpenSSL 的 macOS 上执行：

```sh
python3 scripts/verify_v2_live_account_authorization.py --output /private/tmp/im-v2-live-account-review
```

输出目录必须尚不存在。脚本忽略继承的应用配置、生成临时密钥、使用随机 loopback 端口，不读取 `.env.local`、不借用现有数据库或 Docker volume。测试子进程有独立进程组与期限，失败也停止本次账号服务和 PostgreSQL；临时 cluster、证书和私钥由临时目录生命周期删除。输出只保留运行日志、状态计数和验证结果。

`V2LiveAccountAuthorizationTests` 是 macOS 上显式启用的四项验收，普通 `swift test` 不会访问该服务。初版测试编译的 optional Task 返回类型和嵌套宏已修正；首次服务启动夹具使用空 owner registry，被生产配置校验拒绝，改为指向本次数据库的有效 room/user registry 后启动。这些失败没有被记为生产缺陷，也没有为了通过测试放松配置规则。

## 当前结果与未覆盖范围

最终四项真实 HTTPS 测试通过（2.704 秒）；普通 ClientKit 运行报告 388 项 / 60 套件，其中四项真实网络测试显式跳过，实际执行 384 项离线回归通过（4.284 秒）。服务端设备/凭据/撤销事件读回及 HTTP 次数通过，临时服务、数据库和密钥均已清理。见[原始证据](evidence/20260906-live-account-https/manifest.json)。

这条链路止于真实认证 actor 发布的状态，没有运行 App 界面、Keychain 或实时 protobuf TLS Gateway；前一批 App 状态观察者组合测试仍使用受控 HTTP。此处的 TLS 是 URLSession 到本地账号 HTTPS 入口，不代表 Caddy 部署、生产证书、实时 Gateway、完整退出/换号界面或外部 E 项验收。B09 保留“已实现待验证”；下一步应把真实认证终止接入 App 生命周期验收，并检查实时重连不会继续使用已删除凭据。
