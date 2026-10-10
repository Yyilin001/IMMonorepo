# IM V2

IM V2 是使用 Swift 构建的即时通信项目，包含 iOS 客户端、客户端 SDK、TLS 消息网关、账户服务和 PostgreSQL 持久化实现。当前运行链路使用下列 V2 模块，不依赖历史协议、数据存储、凭据或本地缓存。

## 项目组成

| 路径 | 职责 |
| --- | --- |
| `IMApp/` | iOS SwiftUI 应用与 V2 依赖组装。 |
| `IMV2Core/` | 领域类型、帧与命令规则，以及准入、扇出和同步约束。 |
| `IMV2ClientKit/` | 设备 Keychain 会话、SQLite 同步投影、持久化客户端发件箱，以及 TLS/HTTPS 传输。 |
| `IMV2Server/` | TLS 网关、PostgreSQL 存储、账户与设备服务，以及仅监听回环地址的运维服务。 |
| `IMV2/` | PostgreSQL 权威结构、隔离测试与本地服务的 Compose 配置、脚本、告警规则，以及设计和运维文档。 |

## 文档说明

项目自有文档以中文为主；命令、配置项、协议字段和代码标识符保留原名。第三方源码的许可证和上游文档保留原文。

- [文档入口](docs/README.md)：当前状态、权威合同与历史记录的查询方式。
- [当前系统架构](docs/current-system-map.md)：组件边界、持久化投递链路、群聊语义与签名 Actor 投递。
- [当前合同索引](docs/reviews/README.md)：各主题的权威合同。
- [当前问题状态](docs/reviews/status.md)：47 项已登记问题的状态与关闭依据。
- [V2 文档入口](IMV2/docs/README.md)：设计决定、实施证据、容量合同与运维手册。
- [iOS 应用](IMApp/README.md)：原生客户端开发流程与发布配置。
- [V2 网关](IMV2Server/README.md)：网关、账户服务与运维服务配置。

## 本地开发

使用 Xcode 运行原生 iOS 客户端，并单独启动其隔离的本地依赖：

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

本地服务仅在 Mac 回环地址发布 `https://localhost:8443` 和 `localhost:7443`。
脚本会在 `IMV2/` 下生成仅用于本机的密钥和 CA。验证 HTTPS 账户流程前，需将
`IMV2/local-ca/root.crt` 导入所选模拟器并启用信任。

## 验证

```sh
# 原生 ClientKit 编译与测试目标构建
xcrun --toolchain XcodeDefault swift build --build-tests \
  --package-path IMV2ClientKit --jobs 4

# Core、Server 与可丢弃 PostgreSQL 的隔离回归
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  run --rm --build swift-tests

# 可丢弃数据库的权威结构检查与逻辑恢复演练
bash scripts/test_v2_postgres_schema_bootstrap.sh
bash IMV2/scripts/test_v2_postgres_logical_restore.sh
```

隔离回归还会检查 Protobuf 生成代码、本地环境合同、数据库结构就绪检查、文档链接、
Prometheus 规则和运行时环境示例。当前本地验证证据与容量边界见
[实施状态](IMV2/docs/implementation-status.md)。
