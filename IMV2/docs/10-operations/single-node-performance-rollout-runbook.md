# 单节点部署、配置变更与回滚

以下命令从仓库根目录执行。本地 Docker 栈用于验证配置和收发链路。实际环境使用自己的部署清单、数据库和镜像摘要。

## 发布前与启动

1. 记录正在运行的镜像摘要、配置版本、协议版本和数据库结构版本。保留上一版镜像及对应配置。新建环境按[服务端部署准备](../../../IMV2Server/README.md#部署准备)安装空库结构、证书和服务身份；已有数据库先核对兼容性。
2. 校验运行时配置示例。按 [Linux Release 指南](../../../docs/guides/native-linux-release.md)构建、打包并验证候选产物，保存构建清单和 `runtime-verification.json`。
3. 在本地参考栈验证候选配置。启动脚本使用本地专用身份；冒烟脚本检查账户 HTTPS、设备凭据与实时网关收发。

```sh
bash scripts/check_v2_runtime_env_examples.sh
bash IMV2/scripts/run_v2_local_account_stack.sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

4. 在目标环境按其部署清单发布对应镜像和配置。核对数据库 readiness、三个 Placement 投票节点的已提交归属及 Host 注册，再通过该环境的账户和 Gateway 验证私聊收发、断线查询原回执和接收方追平。记录镜像摘要与实际结果。

## 单项配置变更

从该环境上一份已验证配置开始，每次只调整一个数据库连接池、准入预算或工作器并发参数。对照变更前后相同负载下的 ACK 尾延迟、准入排队与拒绝、数据库连接占用和投影积压。指标和告警见[可观测性说明](observability.md)，场景和通过条件见[容量与压测入口](../README.md#容量与压测入口)。

已配置 `pg_stat_statements` 的环境可用下列命令采集同一统计周期的增量。先设置 `IM_V2_PROFILE_DATABASE_URL`，两次采集之间执行目标负载。

```sh
bash IMV2/scripts/capture_v2_postgres_profile.sh baseline /tmp/imv2-profile-before
bash IMV2/scripts/capture_v2_postgres_profile.sh report /tmp/imv2-profile-after /tmp/imv2-profile-before
```

## 回滚与故障分流

- **配置回退。** 恢复刚才变更前的配置值，按原部署方式重新加载或重启受影响服务。以相同负载复核错误率、前台追平和积压排空。
- **应用版本回退。** 先确认上一版可读取现有数据库结构、协议与 Placement 持久状态。按[有序停机流程](room-host-supervision.md#停机顺序与异常退出)排空受影响的 Host，再用原部署清单恢复之前保存的镜像摘要与配套配置。重启后重复归属检查与业务冒烟。固定单 Gateway 测试栈有专用停机脚本；多 Host 使用监督流程。
- **Host 异常退出。** 若排空失败，保留 Placement 多数派及监督记录，按[Host 恢复与代次替换](room-host-supervision.md#显式替换-host-代次)排除旧实例、结清 SQL 会话并确认接管。未收到 ACK 的发送按原操作身份查询。
- **数据库损坏或版本不兼容。** 停止版本回退，保留故障库与备份。项目提供[PostgreSQL 16 隔离 PITR 演练](../09-capacity/ADR-010-capacity-and-disaster-recovery.md#当前可重复的恢复证据)，可在独立实例核对恢复点及读写。恢复旧库会影响切换后的写入，应先对账并明确恢复点，再决定业务切换。

## 验证范围

[ECS 部署记录](../../../docs/verification/ecs-update-20261101.json)记录了一次启用新库、保留旧库的发布和冒烟。该记录没有验证带有后续业务写入的无损回切。生产规模 PITR、跨区域 WAL 与密钥恢复、流量切换和 RPO/RTO 仍需演练；生产多机分区及物理主机失效的边界见 [Actor 开放问题](../../../docs/reviews/virtual-actor/README.md#尚未闭环)。
