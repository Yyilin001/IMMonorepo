# Room Actor 应用配置

Gateway 的生产入口已经使用 RoomRef；Account 接线仍在集成。每个需要调用或承载房间的进程都必须提供 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE`。这个文件固定服务签名公钥、可信 hostID、节点 DNS 名与端口、允许访问的 shardID、容量上限及 PEM 文件路径。启动时缺少文件或信任映射不一致会失败，不会退回原房间 writer。

## 本地生成

以下命令只在指定的新目录生成本地/测试身份和一年有效的独立私有 CA，不启动服务，不覆盖既有密钥：

```sh
python3 IMV2/scripts/prepare_v2_room_actor_configuration.py \
  --output-dir /absolute/path/room-actors \
  --host gateway=gateway:7337 --caller account=account:7338 \
  --shards rooms-primary --mount-root /run/im-v2-room-actor
```

每个进程只挂载自己的 `gateway/` 或 `account/` 子目录到 `/run/im-v2-room-actor`，只包含自己的签名/TLS 私钥、叶证书、CA 公钥和配置。`ca/key.pem` 留在宿主机，不挂载进应用。对原生进程省略 `--mount-root`，地址使用 `localhost` 和不同端口。

`run_v2_local_account_stack.sh` 会在第一次运行时生成 `IMV2/local-room-actors/`，本地 Compose 已分别挂载两个节点目录；该目录被 Git 忽略。普通重启保留 hostID、签名密钥和 CA，只更新随机 process incarnation。证书更新或密钥轮换应显式进行，不通过普通启动隐式轮换。

当前 DistributedCluster 的 TLS 路径将地址作为 SNI；NIOSSL 拒绝 IP 字面量，因此配置要求 DNS 名。证书 SAN 必须匹配该名称，TLS 固定为 1.3、完整证书校验和双向认证。Cluster 内部端口无须发布到宿主机或公网。

## 拓扑与关闭

生成器默认每个 host 可访问全部传入 shard；实际多数据库部署应按需求缩小每个 peer 与 service 的 shard 集合。数据库访问能力来自 App 已有的配置，不从网络发现结果添加数据库连接。生成器给 Gateway 用户调用、协调、维护及可信审核权限，Account 只给用户调用与协调权限；部署时按实际职责裁剪。

同一个固定 hostID 不应同时运行两个进程。重启使用相同 hostID 和新的 incarnation；节点发现替换物理 ActorID，但不会提前删除 PostgreSQL 租约。现存有效租约暂时不可达时调用返回有界不可用，等租约到期后重新激活。

应用停止监听后先停止/排空工作器与连接，再等待 RoomDirectory 的实际 owner/lease 查询和 Cluster/Host 的实际请求结束，最后释放数据库池。排空超时会结束进程，不在活跃 SQL 下释放共享资源。本地 Compose 为这个关闭顺序保留 180 秒。

这些说明和生成器不是运行部署的验收记录。当前运行证据见 [组合阶段证据](i1-composition-progress-evidence.md)；完整多进程业务与故障矩阵仍按计划验证。
