# 原生房间 Actor 的 Host 监督

房间执行资格来自三个独立 Placement 投票节点的已提交归属。消息路径不使用数据库房间租约、逐房间续租或 SQL 执行围栏。Host 网络不可达不会自动产生后继 Owner；崩溃接管必须先准确排除旧进程，再结束其数据库会话。

Docker 部署使用独立的 `IMV2RoomHostSupervisorApp` 管理本节点容器。监督服务是专门的 caller，只获得 Placement 读、写和排除权限，不承载房间。通过配置生成器的 `--caller` 和 `--exclusion-supervisor` 创建身份，三个投票节点由各自独立的进程和持久目录运行。

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

`scripts/test_v2_native_host_crash.py` 使用随机独立资源验证真实 Docker 排除、数据库收尾、监督进程重启及未知发送结果重放。它要求隔离的 `colima-imv2-native-*` context、固定源码快照及 Linux 构建摘要。源码或产物不匹配时不会启动验证，结束后只清理本轮容器、网络和私有配置。

当前验收结果以 [原生 Actor 实现契约](../../../docs/reviews/room-virtual-actor-contract.md) 为准。编译、启动意图检查和实际崩溃接管是不同证据，不能互相替代。

最新协议的真实故障接管、显式代次替换及旧代次记录实际回收已通过，记录见 `/private/tmp/imv2-native-supervisor-final-20261012/run-11.json`。六个 Linux Release 产品已编译，生产源码与冻结源码的逐文件摘要见同目录 `completion-audit.json`。这些结果不提供吞吐或压力测试结论。

控制迁移请求必须保存首次检查时的 `originRevision`，与迁移 ID 和预期 Owner 一起重试。控制归档按固定已提交日志索引滚动，近期结果和仍被引用的生命周期证明保留；无引用的过期请求明确返回 `requestExpired`。
