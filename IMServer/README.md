# IMServer

`IMServer` 是基于 Vapor + Fluent + PostgreSQL 构建的 IM 后端服务，负责账号认证、设备会话管理、会话与消息存储、文件上传下载，以及基于 TCP 的实时消息链路。

当前项目的设计目标不是做一个“大而全”的通用聊天平台，而是先搭出一套清晰、可演进的 IM 基础能力：HTTP 负责登录和数据拉取，TCP 负责长连接、实时投递和连接态管理。

## 项目定位

- HTTP 认证与会话管理
- IM 会话列表、成员列表、历史消息、增量补洞
- 基于 `lastReadSequence` 的已读推进和未读统计
- TCP 握手鉴权、心跳、消息投递、ack、踢线
- 简单文件上传/下载能力

当前实现已经从本地单体闭环演进到可按角色拆分的运行模式：本地开发仍默认使用 `combined`，生产环境按 `gateway`、`command-api`、`query-api`、`outbox-relay`、`stream-consumer`、`ops` 拆分部署。生产拓扑依赖 Kafka 事件流、Redis 连接路由、分片 summary read model、S3-compatible 媒体存储和私网 Prometheus 指标；具体约束以 [docs/im-runtime-operating-modes.md](docs/im-runtime-operating-modes.md) 为准。

## 当前能力

### 认证与设备会话

- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `GET /api/auth/sessions`
- `DELETE /api/auth/sessions/current`
- `DELETE /api/auth/sessions/all`
- `DELETE /api/auth/sessions/:sessionID`

### 联系人与好友申请

- `GET /api/contacts`
- `GET /api/contacts/changes`
- `PATCH /api/contacts/:contactUserID`
- `DELETE /api/contacts/:contactUserID`
- `GET /api/contact-requests`
- `POST /api/contact-requests`
- `POST /api/contact-requests/:requestID/accept`
- `POST /api/contact-requests/:requestID/decline`
- `POST /api/contact-requests/:requestID/cancel`

### IM HTTP 接口

- `POST /api/im/conversations`
- `GET /api/im/conversations`
- `GET /api/im/conversations/changes`
- `GET /api/im/conversations/:conversationID/members`
- `GET /api/im/conversations/:conversationID/messages`
- `GET /api/im/conversations/:conversationID/messages/since`
- `POST /api/im/conversations/:conversationID/read`

### 文件接口

- `POST /api/files/upload`
- `GET /api/files/download`

### TCP 实时链路

- 纯 TCP 长连接
- NDJSON framing
- access token 握手鉴权
- heartbeat / heartbeat_ack
- message / ack
- kick 事件用于 `logout current`、`logout all`、session revoke 等场景

协议草案见 [docs/im-tcp-protocol.md](docs/im-tcp-protocol.md)。

运行模式与生产上线检查清单见 [docs/im-runtime-operating-modes.md](docs/im-runtime-operating-modes.md)。生产发布门禁见 [docs/im-production-release-gate.md](docs/im-production-release-gate.md)。多端同时在线的上线验收门禁见 [docs/im-multidevice-release-gate.md](docs/im-multidevice-release-gate.md)。

## 技术栈

- Swift 6
- Vapor 4
- Fluent
- PostgreSQL
- SQLite
  说明：测试默认使用内存 SQLite
- SwiftNIO
- JWTKit

## 目录结构

```text
Sources/IMServer/Auth          认证、token、session 逻辑
Sources/IMServer/Controllers   HTTP 路由控制器
Sources/IMServer/Files         文件存储服务
Sources/IMServer/IM            会话、消息、已读等领域服务
Sources/IMServer/IMTCP         TCP 协议、连接注册、实时服务
Sources/IMServer/Migrations    数据库迁移
Sources/IMServer/Models        Fluent 模型
Tests/IMServerTests            服务端测试
docs/                          协议和说明文档
scripts/                       本地启动脚本
```

## 本地运行

### 1. 准备环境

建议环境：

- macOS 13+
- Xcode 16+ 或 Swift 6 toolchain
- PostgreSQL 14+

### 2. 配置环境变量

```bash
cp .env.example .env.local
```

`./scripts/run_local.sh` 会优先读取 `.env.local`，常用变量如下：

```bash
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_NAME=vapor_auth
DATABASE_USERNAME=$(whoami)
DATABASE_PASSWORD=
JWT_SECRET=dev-jwt-secret-change-me
SEED_USER_EMAIL=demo@example.com
SEED_USER_PASSWORD=password1234
```

如果你的 PostgreSQL 用户名不是当前 macOS 用户，请手动改 `DATABASE_USERNAME` 和 `DATABASE_PASSWORD`。

### 3. 启动服务

```bash
./scripts/run_local.sh
```

默认 HTTP 地址：

```text
http://127.0.0.1:8080
```

默认 TCP IM 端口由服务端启动逻辑负责绑定，当前客户端默认连接：

```text
127.0.0.1:9000
```

### 4. Docker 启动

```bash
docker compose up --build
```

## 开发命令

构建：

```bash
swift build
```

运行：

```bash
swift run
```

测试：

```bash
swift test
```

Postgres smoke 测试：

```bash
IM_POSTGRES_SMOKE_DATABASE_URL=postgres://user:password@127.0.0.1:5432/imserver_smoke swift test --no-parallel
```

生产拓扑 smoke：

```bash
./scripts/production_smoke.sh run
```

多端同步上线门禁：

```bash
./scripts/multidevice_release_gate.sh
```

小群/私聊压测入口：

```bash
./scripts/staging_baseline.sh --profile staging-baseline --env-file LoadTests/staging-baseline.env
cd LoadTests/k6 && k6 run -e PROFILE=local-smoke http-small-group.js
cd LoadTests/TCPDriver && swift run IMTCPLoadDriver --profile local-smoke
```

## 数据与消息模型说明

当前 IM 数据模型以“会话 + 消息 + 成员读位点 + 联系人变更日志”为核心：

- `Conversation`
  保存会话基础信息和最后一条消息序号
- `ConversationMember`
  保存成员关系和 `lastReadSequence`
- `ConversationMessage`
  保存消息正文、发送者、服务端顺序号、`clientMessageID`
- `ContactChangeLogEntry`
  保存联系人与好友申请变更游标，用于客户端离线后的增量补洞

这套模型支持以下链路对齐：

- 历史分页拉取
- `messages/since` 增量补洞
- TCP 实时消息投递
- 客户端 pending message 与服务端落库消息合并
- 联系人/好友请求 `changes` 增量同步

## 当前状态

项目已经具备一个可运行的 IM 基础闭环，并提供生产角色拆分的启动校验：

- HTTP 登录后可建立 TCP 长连接
- 会话列表和历史消息可通过 HTTP 拉取
- 新消息可通过 TCP 实时收发
- 支持断线重连后的增量补洞
- 支持基于读位点的未读校正
- 支持联系人和好友请求的实时事件与 HTTP 增量补洞

但它仍然是一个持续迭代中的工程，后续重点仍包括：

- 多媒体消息模型
- 群管理后台
- 更完整的运营与审计能力
- 更严格的生产故障演练和告警规则

## 配套客户端

配套 iOS 客户端仓库：

- [IMApp](https://github.com/Yyilin001/IMApp)

## Roadmap

- 完善未读/已读模型与服务端一致性校正
- 补齐更明确的会话摘要刷新策略
- 扩展消息类型和附件消息
- 增强 TCP 集成测试和端到端验证
- 为未来多节点和消息队列方案预留演进路径
