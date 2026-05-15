# IMServer 10 万 DAU 落地运行手册

这份文档对应当前代码里的单区域中型 IM 架构，目标是把：

- Redis 在线路由
- 节点间 dispatch
- outbox 异步投影
- 会话内搜索索引
- 主写/读分流边界
- 对象存储媒体 provider

收成一套可以部署、压测和故障演练的运行手册。

## 1. 目标拓扑

固定部署形态：

- `im-api-1`
- `im-api-2`
- `postgres-primary`
- `postgres-replica`
- `redis`
- `object-storage`

单区域部署，不做跨区域双活。

## 2. 必填环境变量

### 路由与节点

- `IM_ROUTING_MODE`
  - `production` 固定为 `redis`
  - `development/testing` 可为 `local`
- `IM_NODE_ID`
  - 每个实例唯一
- `REDIS_URL`
  - 生产必填

### Outbox Worker

- `IM_OUTBOX_BATCH_SIZE`
- `IM_OUTBOX_POLL_INTERVAL_MS`
- `IM_OUTBOX_MAX_RETRIES`

推荐默认值：

- `IM_OUTBOX_BATCH_SIZE=100`
- `IM_OUTBOX_POLL_INTERVAL_MS=250`
- `IM_OUTBOX_MAX_RETRIES=5`

### 数据库

- `DATABASE_PRIMARY_HOST`
- `DATABASE_PRIMARY_PORT`
- `DATABASE_PRIMARY_NAME`
- `DATABASE_PRIMARY_USERNAME`
- `DATABASE_PRIMARY_PASSWORD`
- `DATABASE_REPLICA_HOST`
- `DATABASE_REPLICA_PORT`
- `DATABASE_REPLICA_NAME`
- `DATABASE_REPLICA_USERNAME`
- `DATABASE_REPLICA_PASSWORD`

### 媒体存储

- `MEDIA_STORAGE_PROVIDER`
  - `production` 固定为 `s3compatible`
  - `development/testing` 默认 `local`
- `MEDIA_STORAGE_S3_ENDPOINT`
- `MEDIA_STORAGE_S3_BUCKET`
- `MEDIA_STORAGE_S3_REGION`
- `MEDIA_STORAGE_S3_ACCESS_KEY_ID`
- `MEDIA_STORAGE_S3_SECRET_ACCESS_KEY`
- `MEDIA_STORAGE_S3_FORCE_PATH_STYLE`

## 3. 启动策略

### 开发环境

单节点本地运行：

```bash
./scripts/run_local.sh
```

双节点本地联调：

```bash
./scripts/run_cluster_local.sh im-api-1 8080 9000
./scripts/run_cluster_local.sh im-api-2 8081 9001
```

### 生产环境

- 禁止 `--reset-im-schema`
- 禁止 `IM_ROUTING_MODE=local`
- 禁止 `MEDIA_STORAGE_PROVIDER=local`
- `REDIS_URL` 缺失直接拒绝启动
- `IM_NODE_ID` 缺失直接拒绝启动

## 4. 读写路径

### 主写

主写固定走 primary：

- 发消息
- 编辑 / reaction / 撤回
- 已读推进
- membership 变更
- metadata 更新
- outbox enqueue

### 读路径

默认读 replica：

- `conversations`
- `conversations/changes`
- `messages`
- `search`

注意：

- 写事务永远不能落到 replica
- `messages/since` 仍是消息真相收敛链路

## 5. 实时与最终一致

### 实时路径

- TCP 先更新 timeline
- routing service 决定本机直投还是跨节点 dispatch
- Redis 故障时只保证本机实时

### 最终一致路径

- 主写只负责主事实 + outbox
- summary projection 与 search index 由 worker 异步消费
- `changes + reconnect + messages/since` 负责最终收敛

## 6. 容量压测前检查项

必须先确认：

- 双节点跨节点实时消息可达
- Redis 故障降级策略符合预期
- outbox backlog、retry、failed 可观测
- replica 读流量已接通
- 搜索已走索引表，不再回退线性扫消息
- 媒体上传/下载不再依赖生产节点本地磁盘

## 7. 压测场景

固定要跑：

- 登录 / 建连
- 私聊发消息
- 小群发消息
- 大群发消息
- 编辑 / reaction / recall
- `conversations/changes`
- `messages/since`
- 会话内搜索
- 媒体上传 / 下载

## 8. 故障演练

固定要演练：

- 单个 IM 节点重启
- Redis 短时不可用
- outbox worker 暂停 / 恢复
- PostgreSQL replica 延迟
- 对象存储短时失败

## 9. Go / No-Go 指标

必须全部达标才允许对外宣称“接近 10 万 DAU”：

- 同时在线连接 `>= 10,000`
- 峰值消息写入 `>= 300 msg/s`
- 目标消息峰值 `500~1000 msg/s`
- 消息主写 `P95 < 150ms`
- 消息主写 `P99 < 300ms`
- `changes` 收敛延迟 `P95 < 2s`
- search index lag `P95 < 3s`
- reconnect 后 `messages/since` 补洞成功率 `> 99.9%`
- 跨节点实时投递成功率 `> 99.9%`
- failed outbox residual rate `< 0.01%`

以下任一情况出现直接 No-Go：

- 任一核心指标不达标
- 故障演练后出现消息丢失
- `visibleFromSequence` 语义回退
- 多端 `edited / reaction / recall / read + changes + reconnect + gap sync` 回归失败

## 10. 当前代码对应边界

相关实现文件：

- 路由与 dispatch：
  - `Sources/IMServer/IM/ConnectionRoutingService.swift`
- Outbox：
  - `Sources/IMServer/IM/ConversationOutboxService.swift`
- 搜索：
  - `Sources/IMServer/IM/ConversationSearchService.swift`
- 数据库读写分流：
  - `Sources/IMServer/DatabaseRouting.swift`
- 媒体 provider：
  - `Sources/IMServer/Media/MediaStorageService.swift`
