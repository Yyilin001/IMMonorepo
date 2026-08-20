# 高活跃 10,000 在线压测

`IMV2GatewayLoadGenerator` 的 scenario 模式通过真实 TLS / protobuf / gateway
协议建立 10,000 个设备连接，并按角色权重选择实际发送者和读取者。它不把 10,000
个设备误建模为每人固定频率持续发送。

## 固定工作负载

[high-active-10000.json](../../load-scenarios/high-active-10000.json) 的两个
5,000 连接 worker 合起来运行以下逻辑总速率：

| 阶段 | 时间 | 消息/s | room-log 读取/s | Sync Pull/s |
| --- | ---: | ---: | ---: | ---: |
| `high_activity_baseline` | 10 分钟 | 250 | 500 | 40 |
| `evening_peak` | 10 分钟 | 400 | 800 | 70 |
| `burst_peak` | 5 分钟 | 650 | 1,300 | 100 |
| `recovery` | 15 分钟 | 250 | 500 | 40 |

连接角色为 reader（45%）、regular sender（35%）、high-frequency sender
（15%）和 heavy sender（5%）。发送、room-log 和 Sync 的抽样权重分别独立；
同一 `seed` 下选择可复现。私聊 peer 使用对称偏移，确保被动收件人也持有相同
room，room-log 读取不会退化为仅发送者自读。

首阶段包含 0.2%/分钟的随机设备重连。后续阶段不重连，以避免短期 access token
在长时间连接运行中把“凭证过期”误归因成数据库容量问题。运行前必须刷新凭证。

## 准备

1. 仅使用可清理的压测账号和数据库；不要把凭证提交到仓库。
2. 两份 JSONL 各含 5,000 个不同设备。现有造号脚本每份上限正好为 5,000；在
   压测专用账号服务已放宽创建限额时，以最多 16 个并发请求生成两份：

```bash
IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM=16 \
IM_V2_LOAD_CURL_RESOLVE=localhost:443:<gateway-ip> \
  ./IMV2/scripts/prepare_v2_gateway_load_credentials.sh \
  https://localhost <ca-path> 5000 <credentials-a.jsonl>
IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM=16 \
IM_V2_LOAD_CURL_RESOLVE=localhost:443:<gateway-ip> \
  ./IMV2/scripts/prepare_v2_gateway_load_credentials.sh \
  https://localhost <ca-path> 5000 <credentials-b.jsonl>
```

   两次生成必须顺序执行，避免在同一个压测机上把账号创建流量意外放大为 32 并发。
3. 在测试开始前刷新两份凭证，refresh token 会轮换，原文件保留为回滚输入：

```bash
IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM=16 \
  ./IMV2/scripts/refresh_v2_gateway_load_credentials.sh \
  <account-base-url> <ca-path> <credentials-a.jsonl> <fresh-a.jsonl>
```

4. 压测机执行 `ulimit -n`，必须至少为 65,536。单 Mac 运行两个 worker
前还须确认其 CPU、RSS、文件描述符与出站端口均未成为瓶颈。
5. 压测前后在数据库所在主机执行 `capture_v2_postgres_profile.sh baseline/report`，
并同时保存 gateway、PostgreSQL 和磁盘监控。

## 执行

```bash
mkdir -p /tmp/imv2-high-active-reports
./IMV2/scripts/run_v2_high_active_10000.sh \
  <gateway-host> <ca-path> <fresh-a.jsonl> <fresh-b.jsonl> \
  /tmp/imv2-high-active-reports <revision>
```

默认每个 worker 建立 5,000 条连接，并以 150 次 TLS 连接/秒爬坡（总计 300 次/秒），
用于同时测量上线风暴。若该阶段本身成为独立瓶颈，可设置
`IM_V2_HIGH_ACTIVE_RAMP_PER_SECOND=50`，以总计 100 次/秒建立 10,000 条连接；报告
必须保留该值，且不能把慢爬坡的成功解读为上线风暴也通过。

当压测机需要分流或仅验证较低在线量时，可设置
`IM_V2_HIGH_ACTIVE_CONNECTIONS_PER_WORKER=<N>`。脚本仍由两个 worker 各承担 50%
的业务速率，因此总消息、room-log 与 Sync 速率不变；例如 `N=1500` 会得到 3,000
在线、但仍维持上表的完整业务速率。生成的 `summary.json` 会以 `2 × N` 作为连接峰值
门槛，不能将这个结果表述为 10,000 在线通过。

脚本会并发启动两个 worker（默认各 5,000 连接），并将每个阶段速率缩放为 50%；因此
两者的和才是上表速率。所有 direct room 在计时前完成预热；预热失败或工作负载错误率超过
0.1% 会停止测试。成功结束后自动生成 `summary.json`：它只在两个 worker 的合计连接
峰值达到当前配置的目标、没有 terminal error、且工作负载失败率不超过 0.1% 时通过。
默认目标仍为 10,000 在线。

## 判定与证据

- 两个 JSON 报告中的 `peakActive` 合计应达到 10,000；
- `workloadFailed / (messagesSent + syncPullsSent + directRoomAttempted)` 不得超过 0.1%；
- 检查报告中的 p50/p95/p99、`messagesSkipped` 与 `plannedReconnects`；
- 高峰结束后的 recovery 必须不再持续增加错误或服务端 backlog；
- 用抽样的 `client_message_id`、`message_id`、`room_sequence` 校验 ACK 后可拉取、无重复、无乱序；
- PostgreSQL profile 必须记录锁等待、WAL、checkpoint、autovacuum、IO 与 top SQL。

该场景是高活跃私聊与读取基准。小群、中群和超大群 fanout 必须作为独立场景报告，
不得混入本报告后把结果解释成纯私聊吞吐。
