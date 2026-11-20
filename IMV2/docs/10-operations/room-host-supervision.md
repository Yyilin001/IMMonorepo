# 原生房间 Actor 的 Host 监督

部署目标为固定业务节点名单，增删节点采用停机维护窗口。以往的[在线扩容测量](../09-capacity/horizontal-user-growth.md)记录既有实现。持久 Placement 记录在重启时继续生效；仅从配置删除 Host 会留下指向旧 Host 的分区。停机增删流程需先完成归属调整并核对策略分区，再开放业务入口。

房间执行资格来自三个独立 Placement 投票节点的已提交归属。消息路径不使用数据库房间租约、逐房间续租或 SQL 执行围栏。Host 网络不可达不会自动产生后继 Owner；崩溃接管必须先准确排除旧进程，再结束其数据库会话。

Docker 部署使用独立的 `IMV2RoomHostSupervisorApp` 管理本节点容器。监督服务是专门的 caller，只获得 Placement 读、写和排除权限，不承载房间。通过配置生成器的 `--caller` 和 `--exclusion-supervisor` 创建身份，三个投票节点由各自独立的进程和持久目录运行。

## 停机顺序与异常退出

单 Host 测试环境必须先停止 Gateway，确认进程正常退出，再停止 Account/Operator，最后停止三个 Placement 节点。不得把这些服务放在同一次 `docker stop` 或无序的 Compose 停机调用中；Host 排空期间仍需要多数派提交退役记录。

使用 `bash IMV2/scripts/stop_v2_actor_stack.sh --compose <配置文件>`。默认项目名为 `imtest`，可通过 `IM_V2_COMPOSE_PROJECT` 指定。脚本针对固定单 Gateway 拓扑；多 Host 部署仍使用监督服务的逐 Host 排空流程。Docker 的 stop 命令成功不代表应用完成排空：脚本还检查容器退出码和 OOM 状态，异常时保留调用方和 Placement，不继续关闭多数派。

已登记的旧 Host 未退役时，新 incarnation 被拒绝是正确保护。此时不得删除 Placement 存储、降低 epoch、伪造托管启动记录，或把 TCP 端口可连接当成业务恢复。先完成旧进程不可重启的排除与数据库会话结清，再提交退役记录；恢复后验证认证、实时订阅就绪及消息收发。普通 Docker 自动重启部署缺少托管启动记录，不能依据当前容器名反推出旧 incarnation 的托管绑定。

## 部署文档

通过 `IMV2_HOST_SUPERVISOR_CONFIGURATION_FILE` 指定绝对路径。私有文档不要提交到仓库；数据库凭据、签名密钥和启动意图目录由部署环境保存。

```json
{
  "actorConfigurationFile": "/deployment/supervisor/configuration.json",
  "shardIDs": ["room-a"],
  "daemonID": "Docker info 返回的准确 daemon ID",
  "socketPath": "/var/run/docker.sock",
  "recoveryJournalPath": "/deployment/state/recovery.pb",
  "launches": [{
    "hostID": "配置生成器产生的 Host UUID",
    "serviceID": "host-a",
    "gateDirectory": "/deployment/state/host-a/generation-1/gate",
    "journalPath": "/deployment/state/host-a/generation-1/launch.pb",
    "inventoryPath": "/deployment/state/host-a/generation-1/inventory.pb",
    "createTemplatePath": "/deployment/templates/host-a.json"
  }],
  "retiredLaunches": [],
  "databases": {
    "control": "部署环境提供的 PostgreSQL URL",
    "owner": "部署环境提供的 PostgreSQL URL"
  },
  "shardDatabaseTargets": {"room-a": "owner"}
}
```

`launches` 只列本监督服务管理的 Host。每个 Host 的条目按旧到新排列，最多一个尚未完成的末代；每代使用不同的启动门、意图及清单路径。Actor 配置仍包含完整可信拓扑，用来查询多数派和选择可以访问相同数据分区的后继。

`databases` 必须覆盖这些 Host 能访问的所有物理 PostgreSQL，包括控制、权限及不直接持有房间的数据库。`shardDatabaseTargets` 将每个可访问房间分区映射到对应物理数据库的名字；多个分区共用数据库时复用同一个名字，收尾只执行一次。监督连接不能使用待排除 Host 的会话标识，数据库必须禁用 prepared transactions。

创建模板是 Docker Engine 的容器创建 JSON，不是 Actor 协议。它指定固定镜像 digest、可执行命令、业务环境、网络别名和挂载。必须禁用自动重启及自动删除，使用非特权、非宿主 PID 模式；把 `gateDirectory` 作为可写 bind mount 挂到 `/imv2-startup`。Host 配置必须来自该 Host 的私有目录。启动令牌、Host 标签和三个启动门环境变量由监督入口填入，不在模板中预填。

监督进程访问启动门的绝对路径必须与 Docker daemon 的 bind mount 源路径相同。容器化监督服务需要把这些私有状态目录挂到相同绝对路径，并访问准确的 daemon socket；配置中的 Host 和 Placement DNS 名称必须能从其网络解析。

## 稳定的 Placement 部署身份

所有节点的 Actor 配置必须使用同一个 `placementControl.clusterID` UUID。每个分片的持久控制组身份由这个部署 ID 和分片名派生，新增或移除房间宿主不会改变控制组 ID。首次生成配置时保存 `topology.json` 的 `placementClusterID`；后续生成同一部署的配置时，通过 `--placement-cluster-id` 明确复用它。测试专用 `--identity-seed` 在未指定部署 ID 时会派生可重复的值。

所有进程使用同一部署 ID 和相同固定名单。启动读取原有多数派历史，房间分区的调整需要提交到控制日志。

### 停机调整固定业务节点

关闭用户入口和生产流量，保持控制和数据库可用。变更名单须重启相关进程。配置生成器以 `--extend-from` 读取上次私有部署，在新目录输出完整配置；传入目标 Host 全集，沿用调用方、三个投票节点、部署身份、各分片数据库和原有控制日志。

增加 Host 时，先部署新名单并在维护窗口启动，待新增 Host 注册。要分配负载，可用固定名单中预设的 placement-controller 通过 `--transfer-room-partition` 提交分区转移。移除 Host 时，先在当前名单内把其房间分区转给保留的 Host；如需同时替换节点，先使用包含新旧 Host 的过渡配置。以 `--inspect` 核对每个分片没有指向待移除 Host 的 owner 或待接管引用，再排空停机、安装最终配置。保留投票文件和数据库。如果移除了策略分区负责人，在业务进程全部停止后，用 `IMV2PlacementControlApp --prepare-offline-policy-change old/topology.json new/topology.json` 生成 SQL，在原控制库通过 `psql -v ON_ERROR_STOP=1` 执行。该语句核对旧版摘要，只更新部署映射，重复执行会核对目标版本。确认房间读取、写入和实时路由后再开放入口。

托管部署先完成所有未结恢复与回收，再停止 Supervisor，更新部署文档中的启动代次及固定节点配置。保留原恢复日志，执行 `IMV2RoomHostSupervisorApp --reconfigure-hosts` 写入新的监督范围并准备启动记录。未完成的恢复意图会阻止变更。

故障接管使用名单内已注册且可访问原房间数据库的 Host。只有 Host 失效而数据分片仍可用时，新 Host 才能恢复已提交的房间状态。数据分片不可用时须先恢复数据库服务。

## 初始化与运行

```sh
export IMV2_HOST_SUPERVISOR_CONFIGURATION_FILE=/deployment/supervisor.json
IMV2RoomHostSupervisorApp --provision
IMV2RoomHostSupervisorApp
```

初始化只创建全新持久记录，重复初始化不会覆盖历史。正常启动只重开原记录；缺失、损坏、身份错配或文件仍被另一监督进程占用时拒绝运行。容器创建回复未知时核对同一确定性名称和准确 ID，不能另建一份；启动时间发生变化或已记录容器丢失时不能重新启动旧代次。

Host 先发布包含本次实际 incarnation 的启动握手，监督端持久保存准确容器 ID、启动时间和实例清单后才放行。Host 随后建立带 incarnation 标识的 SQL 连接并注册归属。监督服务持有长期控制会话，检查、退役和接管复用同一连接生命周期，正常退出等待实际工作和控制会话结束。监督服务通过具体 Docker 状态观察崩溃候选；观察结果不构成归属授权。

恢复依次执行：持久保存稳定操作 ID、不可逆删除准确旧容器并确认不存在、在每个物理数据库确认旧会话实际结束、多数派退役旧身份、接管已退役分区。多个故障实例先分别完成收尾并提交退役，再选择后继，避免先恢复的实例选择另一个已故障节点。退役后清除指向该身份的待迁移引用，允许显式新代次注册。失败或监督进程退出后沿用原操作；数据库收尾没有完成时不推进归属。没有可用后继时保持不可用，不能把等待时间当作旧实例排除证明。

## 显式替换 Host 代次

1. 向监督服务发送 SIGTERM，并等待进程实际退出、释放持久文件；已启动的 Host 容器继续由其自身生命周期运行。
2. 保留旧条目，追加同一逻辑 Host 的新代次及独立状态路径。
3. 执行 `IMV2RoomHostSupervisorApp --provision-launches`，创建追加记录，保留已有恢复和启动意图。
4. 正常启动监督服务。它先排除前任并完成 SQL 收尾、提交退役，再放行新代次。恢复意图保留到注册或接管消除旧身份引用后完成。

不要手工重启已绑定容器、覆盖清单、复用启动门或删除仍被恢复引用的旧记录。监督服务在成功监控轮次后回收已被新代次替换、且不再被任何注册、Owner、迁移或未完成恢复引用的旧记录。仅退役但尚未被新代次替换的当前记录继续保留。

部署文档由监督服务独占并可写；初始化必须显式提供空的 `retiredLaunches`。回收重新确认准确旧容器已不可逆删除、全部物理数据库会话已结束，再将旧条目从 `launches` 原子移动到 `retiredLaunches`。意图包含准确实例、完整容器 ID、启动时间及稳定操作 ID，并校验内容摘要，损坏记录不能用于删除。随后等待旧文件实际工作关闭，删除启动意图、清单及启动门，同步目录，最后移除回收意图。删除中途重启时，正常入口先重新核对排除、SQL 和多数派引用，再继续删除；不会尝试重新打开已移出 `launches` 的旧代次。意外文件、符号链接或仍被其他进程占用的文件会阻止删除。

追加代次前正常运行监督服务，让未完成的回收意图结束，再停止并编辑其当前部署文档；不要恢复一份包含已删除旧代次的文档备份。活动和待回收条目合计上限 256，正常回收后只保留每个 Host 的当前代次；创建模板和操作者私有配置不属于回收范围。

## 验证入口

控制运行时退出回归应设置 `SWIFTNIO_STRICT=1` 并运行 `V2PlacementControlRuntimeTests.nativeProductionLifecycle`。普通模式会把向已关闭 EventLoop 调度任务仅记录为错误，可能仍报告测试通过。RPC 定时器注册和取消现在与系统关闭同步，关闭后由 EventLoop 清理剩余定时器；该路径已通过严格模式连续三次复测。

`IMV2/scripts/test_v2_native_host_crash.py` 使用随机独立资源验证真实 Docker 排除、数据库收尾、监督进程重启及未知发送结果重放。它要求隔离的 `colima-imv2-native-*` context、固定源码快照及 Linux 构建摘要。源码或产物不匹配时不会启动验证，结束后只清理本轮容器、网络和私有配置。

当前验收结果以 [原生 Actor 实现契约](../../../docs/reviews/room-virtual-actor-contract.md) 为准。编译、启动意图检查和实际崩溃接管是不同证据，不能互相替代。

控制迁移请求必须保存首次检查时的 `originRevision`，与迁移 ID 和预期 Owner 一起重试。控制归档按固定已提交日志索引滚动，近期结果和仍被引用的生命周期证明保留；无引用的过期请求明确返回 `requestExpired`。

## 恢复验证范围

隔离 Linux 虚拟机内已演练 Host 强杀、数据库暂停、Supervisor 重启和旧代次回收。复跑条件与机器结果见[原生 Host 故障记录](../../../docs/verification/native-host-crash-20261101.json)。生产多机分区、物理主机失效、部分启动后排空失败，以及客户端 TLS 丢失发送 ACK 的端到端恢复仍待验证。[Actor 开放问题](../../../docs/reviews/virtual-actor/README.md#尚未闭环)

历史在线扩容的阶段、均衡检查和测量结果见[用户增长与在线扩容](../09-capacity/horizontal-user-growth.md)。另一次双节点暂停约 12 秒的故障负载中，399 个前台视图缺失，存活的 9,601 个视图追平；乱序缓冲溢出与重试耗尽的关系仍待核验。原始对照在 `~/Desktop/IMV2-Archive/IMV2-Retirement-Fix-20261019`，逐轮记录可从[清理前的手册](https://github.com/Yyilin001/IMMonorepo/blob/9e31ff0c82a7b239b43f5a6efe2eb2cafb607b93/IMV2/docs/10-operations/room-host-supervision.md)追溯。
