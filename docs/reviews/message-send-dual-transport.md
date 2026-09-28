# 消息发送双通道实施记录

日期：2026-09-28。当前状态：本地实现与聚焦集成验证完成；生产与真机验收尚未执行。

设计依据：[落地方案](../plans/message-send-dual-transport.md)。本记录只描述消息发送及其结果恢复，HTTP 发送入口继续保留；原有已退休 TCP 写请求编号不复用。

## 已落地行为

- App 默认 `automatic`：优先使用当前账户已认证、具备消息发送能力的 TLS/TCP 连接；最多等待就绪 300 ms，缺少能力、连接不可用、载荷超出协商上限或冷却期间选择 HTTPS。
- `IMV2MessageSendTransportMode`（Info.plist）支持 `automatic`、`httpOnly`、`realtimeOnly`。强制模式的提交与恢复都使用指定通道；automatic 的恢复固定使用 HTTP，进程重启后也保持一致。
- 一次持久 claim 只执行一个物理请求。未知提交转入原任务的 reconcile，保留消息 ID、指纹和首次期限；临时错误按原调度预算退避，取消不会触发旁路请求。
- Gateway 新增发送/恢复入口，复用 HTTP 的 `V2RoomRefMessagingClient` 与既有事务回执。发送任务有并发和字节限制，慢发送不阻挡心跳，关闭连接会取消并排空任务。
- 仅支持当前 v45；未认证时不开放发送大帧。新 opcode 为 127/128/129，旧 reserved 编号保持保留。
- 客户端保留最多 64 条枚举维度的选路诊断，不记录消息正文。

## 配置与回滚

Gateway 默认允许协商消息操作；只对 v45 且声明能力的客户端开启。运行参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED` | `true` | 关闭后新连接不协商 TCP 发送能力，automatic 客户端选择 HTTPS |
| `IM_V2_MESSAGE_SEND_MAX_IN_FLIGHT_PER_CONNECTION` | `4` | 每连接并发消息操作数 |
| `IM_V2_MESSAGE_SEND_MAX_IN_FLIGHT_BYTES_PER_CONNECTION` | `4194304` | 每连接在途消息操作字节预算 |
| `IM_V2_MESSAGE_SEND_MAX_IN_FLIGHT_BYTES_PROCESS` | `67108864` | 单 Gateway 实例的在途字节预算 |

普通 `IM_V2_MAX_FRAME_BYTES` 上限保持独立。发送帧上限为 1 MiB + 4 KiB；进程发送预算只计已经解码并进入操作任务的帧，压缩请求按最大展开大小保守计费，不代表 Gateway 总内存上限。入站队列、解码缓冲和其他业务内存分别受原有边界管理。关闭能力是配置重启后的新握手行为，不等于撤销已经提交的操作。回滚时必须继续恢复原 ID 的未知结果。

## 验证记录

实际验证：

| 范围 | 结果与边界 |
| --- | --- |
| Core `V2MessageSendFrameLimitsTests` | 3 项通过，覆盖普通/发送帧边界及认证前大帧限制 |
| ClientKit 聚焦组合 | 27 项通过，覆盖路由、线格式、持久任务、TCP policy、TLS 生命周期；后续持久确定性与路由变更分别重跑通过 |
| ClientKit `V2HTTPRouteRegistryTests` | 4 项通过，扫描包含新增 TCP 请求适配器，验证网络入口注册 |
| Server 聚焦组合 | 56 项通过，覆盖 ByteStream、DomainCommandHandler、ConnectionDrain 及持久消息回执 |
| Server 最终增补 | `dualTransportSharedRoomOperation`、`concurrentMessageSendDoesNotBlockHeartbeat`、`permanentMessageSendReceipts` 3 项通过；后者含群聊/私聊 2 组参数 |
| PostgreSQL | 本地隔离临时实例、独立 primary/secondary/control 数据库，显式配置 disposable 开关。验证 Protobuf/JSON 对应同一持久身份，重复提交返回原回执，send/close 竞争收敛；没有跳过数据库 fixture |
| HTTP/Gateway 共用入口 | Vapor HTTP 路由与 Gateway handler 连接到同一 RoomRef 测试实现，交叉恢复/重复提交回执一致、业务执行一次。该用例没有建立真实 TLS socket |
| App | `IMApp/Scripts/verify_generic_simulator_build.sh` 通过（build-for-testing，通用 iOS Simulator）；不是 UI 测试运行 |
| 生成与配置 | protobuf 重新生成一致性、协议文档版本、runtime env 示例、`git diff --check` 通过 |

服务端命令使用 `swift test --package-path IMV2Server --disable-automatic-resolution --no-parallel --filter …`；对应 PostgreSQL 测试的环境变量都指向临时实例。SwiftPM 仍报告已有 postgres-nio 依赖身份警告，不影响本次构建和测试。

## 外部验收

生产灰度、真实设备系统挂起、真实弱网和部署容量验收需要对应环境；本机聚焦测试不证明这些项目完成。
