# IMApp V2

`IMApp` 的运行入口为 V2。它只恢复、写入和依赖 V2 的登录态、账户 HTTPS
入口与 TLS 会话；当前组合根不包含任何兼容或迁移路径。

## 当前可运行链路

- SwiftUI V2 根状态机：启动时仅恢复 V2 Keychain 设备凭证。
- 设备专属 Keychain：设备 ID、刷新凭证和本地安装绑定均不进入
  `UserDefaults`。
- 本地 V2 SQLite：只有认证成功后才打开。
- 密码兜底：注册或登录会将一次性密码直接交给 HTTPS 账户服务；App
  不持久化密码。
- 设备凭证：账户断言必须绑定本机设备 ID，随后才换取访问/刷新凭证。
- Passkey：客户端 AuthenticationServices 与 WebAuthn 传输边界已经存在，
  但服务端的审计级 WebAuthn 验签和一次性 challenge 存储尚未部署，所以
  当前本地栈应使用密码兜底。

认证完成后，App 会打开 V2 本地会话列表，并启动 TLS 网关的同步、心跳和
持久化命令重试。普通私聊可输入对方的 V2 用户 ID 创建；服务端以幂等操作
返回两人唯一房间。发送文本时，客户端先把命令写入本地 outbox，再尝试投递；
网络中断会显示“已安全保存”，恢复连接后重试。会话和消息界面只读取 SQLite
同步投影，不直接读取网络响应。

个人菜单中的“消息接收设置”可关闭非好友消息。该操作与消息发送一样先写入
独立的本地 social outbox；即使离线退出，也会在下次认证、初始同步或后续同步
提示到达后补发。远端同步投影才是多设备之间的最终事实来源。

个人菜单的“后台同步唤醒”默认关闭。用户明确打开后，App 才向系统申请远程通知
注册，并将仅存在内存中的 APNs token 直接提交给已认证的 V2 账户入口；通知本身不
含消息、房间或发送者内容，只会触发现有的同步路径。退出登录会尽力撤销服务端端点，
而该用户的本机偏好会保留，方便下次登录同一账号时重新申请系统 token。

这仍不是发布完成状态：真实设备双端到端回归、生产 WebAuthn、Push-enabled App ID /
provisioning profile 与真实 APNs 凭据、以及媒体供应商接入仍未完成。公开身份显示本身
已经可用：私聊列表和详情会使用服务端投影的对端显示名，群成员页只通过已授权、按需的
成员目录显示公开 ID 与显示名，不会把群成员资料扩散为 roster 同步。仍缺的是这条体验在
两台真机离线/重连场景下的端到端及无障碍人工验收。普通群聊的创建、成员分页和角色受限
管理界面已接入 V2 的持久化命令与同步投影。

## 本地开发

客户端直接使用 Xcode 在 macOS 上运行。账户服务、数据库和本地 HTTPS
代理使用隔离 Docker 栈：

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
```

该脚本会：

- 创建被 Git 忽略的 `IMV2/.env.local`，其中是仅本机使用的随机密钥；
- 启动 PostgreSQL、仅监听容器回环地址的账户服务、V2 TLS 网关，以及 Caddy；
- 仅向 macOS 发布 `https://localhost:8443`（账户 HTTPS）和
  `localhost:7443`（V2 TLS 网关），不会发布数据库、指标或账户服务的
  内部 HTTP 端口；
- 输出 `IMV2/local-ca/root.crt`。首次使用时，将该证书导入所选模拟器并
  启用完全信任，否则 URLSession 会正确拒绝本地 HTTPS 证书。

Debug 默认配置已经是：

```text
IM_V2_ACCOUNT_BASE_URL=https://localhost:8443
IM_V2_GATEWAY_HOST=localhost
IM_V2_GATEWAY_PORT=7443
IM_V2_PASSKEY_RP_ID=localhost
```

停止本地栈时使用脚本输出的 `docker compose ... down` 命令。数据库卷会被
保留，便于重复运行；如需清空本地账户数据，请明确执行 Compose 的
`down --volumes`，不要把该操作用于任何非本地环境。

## 发布配置

`Config/IMAppInfo.plist` 从 Xcode build settings 读取：

- `IMV2AccountBaseURL` / `IM_V2_ACCOUNT_BASE_URL`
- `IMV2PasskeyRelyingPartyID` / `IM_V2_PASSKEY_RP_ID`
- `IMV2GatewayHost` / `IM_V2_GATEWAY_HOST`
- `IMV2GatewayPort` / `IM_V2_GATEWAY_PORT`
- `IMV2PushEnvironment` / `IM_V2_PUSH_ENVIRONMENT`

Release 校验要求账户入口为真实 HTTPS 域名（默认 443），RP ID 为该域名
或其父域，且 Push 环境必须为 `production`；占位域名、裸 IP、localhost、
明文 HTTP 和未解析的构建变量都会失败。`Config/IMApp.entitlements` 也会请求
`aps-environment`，因此真实设备签名必须使用启用 Push 的 App ID 和描述文件。自检：

```sh
IMAPP_NETWORK_CONFIG_SELF_TEST=true \
  bash IMApp/Scripts/validate_network_configuration.sh
```

## 验证

```sh
# V2 ClientKit 的编译与测试目标
xcrun --toolchain XcodeDefault swift build --build-tests \
  --package-path IMV2ClientKit --jobs 4

# Core + Server + disposable PostgreSQL 的隔离回归
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  run --rm --build swift-tests
```

发布前还必须完成生产 WebAuthn verifier、账户服务 HTTPS/限流部署、真实设备
端到端回归，以及群聊、推送、媒体等 V2 产品界面。完整证据见
[`IMV2/docs/implementation-status.md`](../IMV2/docs/implementation-status.md)；组件
边界与真实投递链路见 [`docs/current-system-map.md`](../docs/current-system-map.md)。
