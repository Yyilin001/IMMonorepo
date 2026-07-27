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
持久化命令重试。普通私聊通过认证后的精确公开 ID（`@handle`）查询创建；服务端以
幂等操作返回两人唯一房间，客户端和界面不接收或显示内部 `user_id`。发送文本时，客户端先把命令写入本地 outbox，再尝试投递；
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

# 对本地 HTTPS、账户、私聊投递和运维边界运行黑盒回归
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

该脚本会：

- 创建被 Git 忽略的 `IMV2/.env.local`，其中是仅本机使用的随机密钥；
- 启动 PostgreSQL、仅监听容器回环地址的账户服务、V2 TLS 网关，以及 Caddy；
- 仅向 macOS 发布 `https://localhost:8443`（账户 HTTPS）和
  `localhost:7443`（V2 TLS 网关），不会发布数据库、指标或账户服务的
  内部 HTTP 端口；
- 输出 `IMV2/local-ca/root.crt`。首次使用时，将该证书导入所选模拟器并
  启用完全信任，否则 URLSession 会正确拒绝本地 HTTPS 证书。
- 回归脚本会让两个独立临时账号经 HTTPS 取得设备凭据，并在网关容器内完成真实
  TLS 1.3 / Protobuf 认证：发送端打开私聊并接受一条消息，接收端通过 `SyncPull`
  观察到同一消息。它不会打印或持久化凭据或身份。
- 该回归先验证网关实际提供的 TLS 证书。若长驻网关仍持有 Caddy 已轮换的过期本地
  叶证书，脚本只重建 Caddy 和网关以重新加载证书；不会重建 PostgreSQL、账户服务或
  删除本地卷。
- 本地脚本会忽略终端中意外遗留的 `IM_V2_*` 环境变量，始终以受限权限的
  `IMV2/.env.local` 为 Compose 的唯一 V2 配置来源；可用
  `bash IMV2/scripts/test_v2_local_compose_env_precedence.sh` 做无副作用验证。

Debug 默认配置已经是：

```text
IM_V2_ACCOUNT_BASE_URL=https://localhost:8443
IM_V2_GATEWAY_HOST=localhost
IM_V2_GATEWAY_PORT=7443
IM_V2_PASSKEY_RP_ID=localhost
```

若要在指定模拟器上实际走一次“密码注册 → 设备凭证 → 本地 SQLite 会话”的
iOS UI 回归，显式指定一个 iOS 26.2 或更高版本的模拟器 UDID：

```sh
IMAPP_LOCAL_ACCOUNT_E2E_SIMULATOR_ID='<SIMULATOR_UDID>' \
  bash IMApp/Scripts/verify_local_account_registration_e2e.sh
```

先启动并**手动解锁**该指定模拟器一次；每次模拟器重新启动后都需要重复这个动作，并保持
Mac 已解锁。设备 ID、注册操作和会话凭据使用
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，首次解锁前 iOS 会拒绝 Keychain 访问；
这不是 TLS、Docker 或账户服务故障。若 App 在首次解锁前已启动，解锁后切回前台或点击
“重试”即可重新读取会话，不需要重启 App。脚本会启动或复用本地 Docker 栈，并仅向指定模拟器
导入 `IMV2/local-ca/root.crt`。脚本本身不会抹掉、关闭或重启模拟器；Xcode 的测试运行器
可能在完成后关停其专用目标机，因此请指定可用于测试的模拟器。该回归使用 DEBUG-only 启动参数跳过旧 Keychain
会话恢复，但仍使用实际的 Debug HTTPS/TLS 配置；每次创建一个随机、仅本地使用的
账号。它使用独立的 `IMAppLocalAccountE2E` scheme，因此默认 UI 测试不依赖
Docker 或本地 CA，仍保持离线确定性。与不启动设备的通用编译基线不同，此 E2E
**不能**传入 `CODE_SIGNING_ALLOWED=NO`：模拟器上的设备 ID、注册操作与会话均需要
带应用标识 entitlement 的本地签名，脚本会使用工程的默认 Debug 签名设置。
在部分 iOS 26.2 Simulator/XCTest 组合中，`typeText` 会把 SwiftUI 表单输入截断为首字
符；因此专用 E2E target 仅在 DEBUG 的 `uiTestingLiveLocalAccount` 模式下，通过启动参数
预填随机账号、公开 ID、显示名、一次性的本地测试密码和一次性测试存储域。它仍由 UI 点击
提交，并完整经过真实账户 HTTPS、设备凭证、Keychain 与本地会话；测试结束时会以相同随机
scope 再启动一次 DEBUG-only 清理路径，删除该 scope 的设备凭证、注册操作、安装绑定及对应
SQLite/WAL/SHM 工件。它不会覆盖该模拟器的常规 V2 Keychain 身份、会话或数据库，因此同一台
已解锁模拟器可重复运行。Release
和默认离线 UI 测试均不能使用这些参数。

停止本地栈时使用脚本输出的 `docker compose ... down` 命令。数据库卷会被
保留，便于重复运行；如需清空本地账户数据，请明确执行 Compose 的
`down --volumes`，不要把该操作用于任何非本地环境。
本地启动脚本会在开始前、成功构建后以及构建失败退出时，清理带 V2 本地构建阶段
标签且未被引用的 Docker 镜像，以防 classic builder 的临时编译层耗尽 Docker
磁盘；它不会删除已标记镜像、容器或卷，也不会掩盖原始构建失败。

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

# 不启动模拟器，只构建 App、单元测试与 UI 测试 bundle
bash IMApp/Scripts/verify_generic_simulator_build.sh

# Core + Server + disposable PostgreSQL 的隔离回归
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  run --rm --build swift-tests
```

发布前还必须完成生产 WebAuthn verifier、账户服务 HTTPS/限流部署、真实设备
端到端回归，以及群聊、推送、媒体等 V2 产品界面。完整证据见
[`IMV2/docs/implementation-status.md`](../IMV2/docs/implementation-status.md)；组件
边界与真实投递链路见 [`docs/current-system-map.md`](../docs/current-system-map.md)。
