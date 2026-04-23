# IMServer

`IMServer` 是基于 Vapor + Fluent + PostgreSQL 构建的 IM 后端服务，负责账号认证、设备会话管理、会话与消息存储、文件上传下载，以及基于 TCP 的实时消息链路。

当前项目的设计目标不是做一个“大而全”的通用聊天平台，而是先搭出一套清晰、可演进的 IM 基础能力：HTTP 负责登录和数据拉取，TCP 负责长连接、实时投递和连接态管理。

## 项目定位

- HTTP 认证与会话管理
- IM 会话列表、成员列表、历史消息、增量补洞
- 基于 `lastReadSequence` 的已读推进和未读统计
- TCP 握手鉴权、心跳、消息投递、ack、踢线
- 简单文件上传/下载能力

当前实现聚焦单体部署和本地开发体验，暂不处理分布式、分库分表、WebSocket、多节点连接路由等复杂场景。

## 当前能力

### 认证与设备会话

- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `GET /api/auth/sessions`
- `DELETE /api/auth/sessions/current`
- `DELETE /api/auth/sessions/all`
- `DELETE /api/auth/sessions/:sessionID`

### IM HTTP 接口

- `POST /api/im/conversations`
- `GET /api/im/conversations`
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

## 数据与消息模型说明

当前 IM 数据模型以“会话 + 消息 + 成员读位点”为核心：

- `Conversation`
  保存会话基础信息和最后一条消息序号
- `ConversationMember`
  保存成员关系和 `lastReadSequence`
- `ConversationMessage`
  保存消息正文、发送者、服务端顺序号、`clientMessageID`

这套模型支持以下链路对齐：

- 历史分页拉取
- `messages/since` 增量补洞
- TCP 实时消息投递
- 客户端 pending message 与服务端落库消息合并

## 当前状态

项目已经具备一个可运行的 IM 基础闭环：

- HTTP 登录后可建立 TCP 长连接
- 会话列表和历史消息可通过 HTTP 拉取
- 新消息可通过 TCP 实时收发
- 支持断线重连后的增量补洞
- 支持基于读位点的未读校正

但它仍然是一个持续迭代中的工程，目前还没有覆盖：

- 分布式连接路由
- 大规模消息分发
- 多媒体消息模型
- 群管理后台
- 完整的运营与审计能力

## 配套客户端

配套 iOS 客户端仓库：

- [IMApp](https://github.com/Yyilin001/IMApp)

## Roadmap

- 完善未读/已读模型与服务端一致性校正
- 补齐更明确的会话摘要刷新策略
- 扩展消息类型和附件消息
- 增强 TCP 集成测试和端到端验证
- 为未来多节点和消息队列方案预留演进路径
