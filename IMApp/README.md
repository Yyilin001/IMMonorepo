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

同一页面还提供按精确公开 ID 的“屏蔽/解除屏蔽”。屏蔽命令同样先持久化到
social outbox；目录查询仍不会向用户透露对方是否屏蔽自己。为了让用户能撤销
自己已经建立的屏蔽，服务端只允许重新解析该用户已知的准确公开 ID；若目标反向
屏蔽当前用户，仍与不存在保持相同的不可发现结果。群消息可附带最多 20 个提及
目标：输入 `@all` 或成员公开 ID，客户端在发送前解析成协议级不透明目标并写入
消息 outbox，服务端再根据提交瞬间的成员可见性和角色作最终授权。消息 UI 只展示
“提及人数/所有人”，不展示内部用户 ID。

个人菜单的“后台同步唤醒”默认关闭。用户明确打开后，App 才向系统申请远程通知
注册，并将仅存在内存中的 APNs token 直接提交给已认证的 V2 账户入口；通知本身不
含消息、房间或发送者内容，只会触发现有的同步路径。退出登录会尽力撤销服务端端点，
而该用户的本机偏好会保留，方便下次登录同一账号时重新申请系统 token。

这仍不是发布完成状态：真实设备双端到端回归、生产 WebAuthn、Push-enabled App ID /
provisioning profile 与真实 APNs 凭据、以及生产媒体供应商与扫描器接入仍未完成。本机已具备
文件系统媒体 provider 与 EICAR 无害扫描夹具，用于验证上传、扫描、下载和清理合同；它们不是
生产对象存储或恶意内容防护。公开身份显示本身
已经可用：私聊列表和详情会使用服务端投影的对端显示名，群成员页只通过已授权、按需的
成员目录显示公开 ID 与显示名，不会把群成员资料扩散为 roster 同步。仍缺的是这条体验在
两台真机离线/重连场景下的端到端及无障碍人工验收。本机双安装回归会通过真实认证命令创建
仅自己的随机群聊、打开并关闭成员页后返回会话列表；普通群聊的成员分页、角色受限
成员增删、@ 提及、1 小时禁言和带审计原因的管理员移除均已接入 V2 的持久化命令与同步
投影。禁言/审计移除与普通成员变更使用各自独立 outbox，网络中断会保留相同操作并在连接
恢复后重放；服务端仍是角色和目标资格的最终授权方。

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

若要在指定模拟器上实际走一次“密码注册 → 设备凭证 → 本地 SQLite 会话”，并验证两份
独立本地账号经 TLS gateway 的私聊投递最终写入接收端 SQLite 投影，显式指定一个 iOS 26.2
或更高版本的模拟器 UDID：

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
已解锁模拟器可重复运行。私聊投递检查创建两份随机账号和两条经认证的 TLS 连接；发送端创建
direct room 后双方断线：发送端以自己的 SQLite outbox 保存消息，重新认证后以原幂等 ID 重放；
接收端只以自己的独立 SQLite store 轮询同步并断言最终投影。它不代表两台 App 安装之间的 UI
交互，也不覆盖 APNs 唤醒或任何上线环境。Release
和默认离线 UI 测试均不能使用这些参数。

若需验证**两份独立 App 安装**之间的普通私聊、群聊 UI 投递和离线恢复，明确指定两台已经
启动并手动解锁的不同模拟器：

```sh
IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID='<RECEIVER_SIMULATOR_UDID>' \
IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID='<SENDER_SIMULATOR_UDID>' \
  IMApp/Scripts/verify_local_account_two_install_e2e.sh
```

若要在最大辅助字体、系统增加对比度和 Arabic RTL 方向下复用同一条本机回归，额外指定：

```sh
IMAPP_LOCAL_TWO_INSTALL_ACCESSIBILITY_PROFILE=accessibility-xl-rtl \
IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID='<RECEIVER_SIMULATOR_UDID>' \
IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID='<SENDER_SIMULATOR_UDID>' \
  IMApp/Scripts/verify_local_account_two_install_e2e.sh
```

该 profile 不改变随机账号、Keychain/SQLite scope 或投递断言；它会临时将两台指定模拟器设为最大辅助字号和系统增加对比度，并以 RTL 环境启动 App，结束时恢复原有模拟器设置，使已有的真实聊天和设置页裁切、触达区域、语义及对比度审计覆盖该显示配置。

两条本地账户 E2E 在开始前都会检查并仅在过期时续期本地 `rooms-primary/standard` 准入租约；因此长时间未重启的本地 Compose 栈不会因测试专用租约过期而把建群误报为网络失败。此处理只适用于本地开发栈，不替代生产控制面的租约管理。

该独立 scheme 会给两端分别创建随机账号、Keychain/SQLite scope 和安装身份：接收端先通过真实
注册 UI 建立会话并被终止；发送端再通过“新建私聊 → 开始 → 发送”的正常界面路径投递消息；接收端
仅恢复自己的 scope，确认私聊撤回投影后，以发送端公开 ID 创建真实群聊、在按需成员目录确认群主和发送端资料，再通过普通群聊输入区发送带 `@all` 的群消息；接收端会实际
进入后台并重新激活，确认会话详情与 SQLite 消息投影仍在；发送端仅恢复自己的 scope 后确认群与群消息
出现且呈现“提及所有人”，并通过普通输入区回复；最后接收端仅恢复自己的 scope，确认该成员回复也由自身 SQLite 同步投影出现。
在发送端的正常恢复前，脚本还会用仅限 DEBUG 的不可达实时端点启动同一份真实 App：用户经普通私聊输入区发送一条消息后，必须得到“已安全保存，连接恢复后会重试。”的明确反馈。随后以正常端点恢复同一 SQLite scope，接收端最终须在对应私聊详情看到该消息；这同时覆盖离线 outbox 的一次重放与跨投影 UUID 大小写规范化，避免 direct-profile 与 message 投影被错误存为两个房间键。
消息正文以最小 44×44 的可访问容器呈现，编辑和撤回 VoiceOver 操作挂在完整消息行上。它也确认账户菜单只位于会话列表
导航栏，不会遮挡会话详情页的输入和发送按钮。脚本会清理两端本次随机 scope，且不会抹掉、重启或关闭
调用方指定的模拟器。该验证仍仅覆盖本机 Docker 栈和 Simulator，不包含 APNs、真机签名、生产网络或容量。

若用户在设备受保护数据暂不可用时退出登录，App 会持久记录**不含凭据或账号信息**的删除意图，
阻止旧会话在下次启动时恢复；待设备解锁后切回前台或点击“重试”，才完成 Keychain 凭据删除。

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
端到端回归，以及推送、媒体等 V2 产品界面。完整证据见
[`IMV2/docs/implementation-status.md`](../IMV2/docs/implementation-status.md)；组件
边界与真实投递链路见 [`docs/current-system-map.md`](../docs/current-system-map.md)。
