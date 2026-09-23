# G5 隔离真实发送 canary

`IMV2/scripts/test_v2_virtual_actor_capacity_canary.py` 用同一份容量 fixture 对冻结 main 或 candidate 各执行一次真实 TLS/protobuf Gateway 发送。它不编译、不修改源码，不依赖用户默认 Compose；每次随机创建 `imv2-va-cap-*` 项目、loopback 随机端口、control + N 个 owner PG、Gateway 和单次 loader，最后只销毁该项目的容器/卷。源码 checkout 必须干净且与 `--source-sha` 完全相等。Gateway 和 loader 都来自显式 Linux Release 产品目录；runner 用已完成的 `result.json` 核对源码、lockfile、固定 Swift 镜像和 ELF SHA-256，再复制到本次私有运行目录并重新哈希。

正式对照应给 main 与 candidate **同一个修正 TCP socket option 的 Release loader**；它可以来自独立于服务源码的构建。传 `--loader-products-dir` 与 `--loader-build-result` 两项，runner 会核对并在结果中记录 loader 自身的 source/lockfile/build-result/ELF SHA。未传时才使用所选版本的原始 loader。冻结 main 的原始 loader 把 TCP_NODELAY 误传为 SOL_SOCKET/SO_DEBUG，在普通 Linux 容器中会因 EPERM 失败。`--legacy-loader-net-admin` 仅供临时诊断已冻结原始 main 二进制，且只给一次性 loader 容器 NET_ADMIN；正式 canary 和容量采样均不使用该参数。

示例（路径由构建负责人提供，fixture 用同一个私有目录）：

```sh
python3 IMV2/scripts/test_v2_virtual_actor_capacity_canary.py \
  --source-checkout /path/to/clean/main-or-candidate \
  --source-sha FULL_40_CHARACTER_SOURCE_SHA \
  --release-dir /path/to/that-revisions/products \
  --build-result /path/to/that-revisions/result.json \
  --loader-products-dir /path/to/corrected-loader/products \
  --loader-build-result /path/to/corrected-loader/result.json \
  --fixture-dir /path/to/the-same-private-fixture \
  --layout hot --docker-context colima-imv2-vapor5 \
  --artifact-dir /path/to/new-private-artifact-dir
```

可先加 `--preflight-only`，此时只读源码、build metadata、二进制和 fixture，既不创建 artifact 目录也不调用 Docker。正式执行会从 **目标 checkout** 的 canonical `schema.sql` 安装每个独立的 `imv2_va_*` 数据库，再写入 seed 对应的 disposable 标记及 fixture SQL。控制库放 auth/profile/route，owner 库放 group/room/membership/admission；Gateway 的 HMAC key 只通过私有 env/Compose 传入。candidate 如在 Compose 中要求 Room Actor 配置，则由目标 checkout 的配置生成器创建仅有 Gateway host 的 TLS+签名配置；main 不需 Actor。客户端和 Gateway TLS 使用本次独立 CA。标准输出只有结果和证据目录，不打印 token、key 或容器化配置。

验收条件：native `IMV2GatewayLoadGenerator` 报告全部连接已认证、`messagesSent == messagesAcknowledged == 1`、`directRoomAttempted == 0` 且没有业务/连接失败；所有 owner 库合计恰有一条 `im_v2.messages`，其发送者在 fixture 用户集合、房间在 `targetRoomIDs` 集合、序号为 1，所在 owner 与控制库 `room_owner_routes` 完全一致。`result.json` 记录 source/lockfile/schema/镜像/ELF/fixture/roommap 摘要和唯一 SQL 效果；负载报告保存在 0700 artifact 目录。该 canary 仅证明 fixture 能在两版真实服务路径发送，不是性能值或吞吐阈值。

隔离测试：`python3 IMV2/scripts/test_v2_virtual_actor_capacity_canary_runner.py` 验证源 SHA、build-result、ELF 及 fixture hash 的拒绝路径，不启动 Docker。2026-09-23 冻结 main 原始 loader 的诊断运行在仅 loader NET_ADMIN 下通过一次真实发送：4/4 认证、1/1 ACK、0 开房、owner SQL 仅一行；证据 `capacity-canary-main-second-20260923/result.json`。此临时兼容运行不替代共用修正 loader 的最终 main/candidate 对照。
