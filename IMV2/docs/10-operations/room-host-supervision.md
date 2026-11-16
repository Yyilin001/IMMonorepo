# 原生房间 Actor 的 Host 监督

日常水平扩容以[用户增长验证流程](../09-capacity/horizontal-user-growth.md)为入口，已完成固定规模 1/2/4/8 节点及在线 1→2→4→8 节点的用户增长验证。最新结果与适用范围以该入口为准；本页的故障接管与历史诊断供专项使用。

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

部署 ID 不代替节点身份、凭据或成员准入。扩容仍需保留现有可信身份，并通过成员管理和已提交分区迁移接纳新宿主；仅重新生成一套配置不能完成在线扩容。启动读取现有多数派历史，不使用新宿主名单覆盖已提交的分区归属。此配置版本不提供旧版按宿主名单派生控制组 ID 的历史兼容。

### 新逻辑宿主准入与当前在线扩容限制

已受信任但尚未出现在已提交宿主表中的 Host 启动时，先提交 `admitHost`，建立不持有分区的退役占位，再提交实际 incarnation 的 `registerHost`。准入端校验调用服务准确拥有该 Host，并具有目标分片的配置访问权；准入不授予分区，也不替换活动实例。宿主表最多容纳 64 个逻辑 Host。响应丢失时保留原请求身份，过期后仅在多数派读取仍确认 Host 不存在时更新准入请求。归档滚动期间，尚未被实际注册替代的准入收据继续保留。

该路径解决 Placement 已提交宿主表不能增加新 Host 的问题，目前尚不能单独完成运行中新增服务器。当前剩余边界：

- 签名授权文件已支持跨机器原子发布，但文件落盘回执尚不代表运行时已接纳身份。
- 实时成员状态已支持持久提交和运行中更新；房间发现、迁移目标校验及 Account/Operator 调用方已接入同一授权状态，仍需完整部署验证。
- 持续消息流下的新节点加入、分区迁移和旧节点退出尚未完成整体验证。

不能以预声明未来节点、降低多数派门槛或只重写配置文件作为在线扩容验收。联合阶段继续要求新旧集合各自达到多数派，并保留网络分区时的授权边界。

服务资格计算已具备成员版本及 `stable → joint → stable` 过渡：联合阶段分别计算新旧集合的多数派，本地票只计入包含本地节点的集合，资格期限取两个多数派期限的较小值。安装新版本立即撤销旧资格代次，旧版本探测不能授予或撤销新版本的资格；被移出的节点不能重新获得资格。分区控制器读取当前成员集合，并拒绝旧资格发出的迟到续租结果。

最终名单可以移除正在应用变更的本地节点。传输保留启动时绑定的本地地址，用于校验后续版本和准确重试；本地退出后不再参与发现轮询，不再把自己报告为可达成员，拒绝发布非空分区租约，但允许清空发布以完成收尾。启用成员控制分片的 Gateway 可以用已受信任的本地身份待命启动；本地不在已提交名单时没有服务资格，不能发布分区租约。待命端点取自本地启动配置，不把它补入已提交路由或投票名单。加入仍必须经过授权的成员变更。

Placement 控制快照新增独立的 `serviceMembership` 记录，包含成员版本、当前/下一集合、明确的节点服务身份和端点，以及 `roomPeers` 房间路由。每条房间路由绑定成员中的服务端点、唯一宿主、分片范围和容量上限；控制端校验该宿主的可信归属及授权范围。联合阶段保留原路由，最终阶段移除退出成员的路由；保留宿主不能夹带改变端点、分片范围或容量。`installServiceMembership` 通过原有三投票节点日志和 CAS 提交；成员版本与房间归属 revision 分开，房间生命周期命令保留成员记录，成员命令不修改分区归属。首次安装必须是稳定版本 1，后续严格遵守连续的 `stable → joint → stable`，保留节点的身份和端点不能夹带改写。联合阶段为最终提交预留归档容量，当前成员命令收据随快照归档保留。

远程提交同时要求已有 `placementWrite` 分片访问权和专用 `placementMembership` 权限；普通房间宿主不能修改名单。拟加入名单中的实时服务必须已通过信任配置或签名授权接纳。

配置 `serviceMembershipShard` 指定唯一成员控制分片；生成器参数为 `--service-membership-shard`，扩展已有部署时保持原选择。Gateway 在房间宿主启动前重新读取该分片的已提交成员记录，用它创建共享服务资格并向实时传输传入已提交 peer 名单。记录缺失、读取失败或名单中存在未受信任身份时拒绝启动，不退回静态名单。本地尚未入选时允许待命启动，但保持不具备服务资格，直到当前已提交名单包含本地且获得对应多数派见证。新节点若处于联合版本，则从该版本启动，必须获得相应的新旧多数派见证。应先由控制端提交初始名单，再启动启用此配置的 Gateway；成员管理命令入口见下文；完整扩容仍需验收。

这一计算接口只接受控制平面已授权的成员状态，不能由可达节点集合自行生成成员变更。签名发现请求和响应已绑定成员版本；摘要同时覆盖当前集合、下一集合及节点与服务身份映射，避免同一节点集合的不同过渡阶段混用证据。发现传输使用创建时捕获的版本更新资格，不会把旧证据重新标记为最新版本。未配置成员控制分片的静态部署仍使用初始版本 1。传输层已支持接收授权后的成员变更：撤销旧资格与缓存、等待旧发现任务结束、切换发布端和 peer 名单，再通过新版本签名发现恢复资格。旧版本租约发布被拒绝，移除路由不直接将物理节点判为故障。该入口要求节点身份已通过配置或签名授权接纳。启用成员控制分片时，应用在实时组件和资格观察器装配完成后再次读取名单，然后每秒持续读取并安装已提交状态；暂停期间错过的中间版本可通过经多数派确认的最新快照追上，不能通过发现结果跳过版本。读取或安装失败会暂停资格、清空发现缓存和租约发布，普通发现回复不能解除暂停；恢复可信读取后才重新等待当前版本见证。停机先停止监听并等待实际读取/安装结束，再排空实时组件。房间发现由独立的同生命周期监听器读取相同控制记录；完整多服务器验证仍未完成。

房间发现层提供包内 `installAuthorizedPeers(_:revision:)` 入口，要求调用者提供控制平面授权的宿主、端点、分片范围和容量上限。入口校验唯一可信宿主身份、拒绝回退版本和保留节点的配置改写，支持相同版本准确重试。更新期间暂停新轮询，等待旧轮询及其路由发布结束；移除节点关闭新请求入口，已有授权操作继续结算，不对仍存活的物理节点执行 down。Gateway 和 Account/Operator 启动时从已提交记录构建房间发现配置，无静态回退；宿主自身的端点、分片及容量必须匹配记录。运行中每秒读取并更新路由，读取或安装失败时暂停发现和新请求，普通发现回复不能解除暂停；重新确认相同版本后允许恢复。分区迁移在执行目标授权时读取当前已确认名单，避免捕获旧静态配置。停机等待房间与实时两个监听器的实际工作结束。

应用提供 `roomMembershipStatus()` 作为运行时应用确认：返回已应用版本、当前是否获得控制确认、配置宿主集合及健康宿主集合。控制提交回执不能替代这一运行时确认；`confirmed` 为 false 时，应用 readiness 同样为 false。健康路由仍需等待签名发现，不应把 `configuredHosts` 当作已可服务节点。

集成验证已覆盖真实磁盘与 mTLS 的三控制节点，以及完整 Account 房间应用：拒绝缺失成员记录的启动、运行中应用联合/最终名单、丢失多数派后撤销 readiness、控制节点以新 incarnation 恢复、Account 重启读取最终名单。验证未运行消息负载，也未证明多 VM 在线扩容性能。停机回归另覆盖 RPC 在 EventLoop 关闭后才返回的情况；回复入队和传输关闭使用同一互斥检查，关闭后不再写通道。

Gateway 的现有指标接口提供 `im_v2_room_membership_` 前缀的 `revision`、`confirmed`、`configured_hosts`、`healthy_hosts`、`realtime_revision`、`realtime_qualified`。实时版本与资格在同一锁内采样；未配置动态成员或没有实时资格来源时，不伪造零值。指标无节点 ID 标签。

`python3 IMV2/scripts/wait_v2_gateway_membership.py --server-deployment deployment.json --gateway 0 --gateway 1 --metrics-port 20200 --revision 2 --hosts 2` 会通过既有测试 VM 管理通道读取指标，要求连续三轮匹配版本、宿主数量和资格。使用 `--retired-gateway N` 校验退出成员已应用最终版本并失去实时资格。超时返回非零状态和最后观测；缺失、重复、旧版本或格式错误不会通过。它是运行时确认步骤，不能独立证明消息完整性、完成迁移或授权直接提交最终名单。Account 的进程内状态接口已存在，但此脚本仅采集 Gateway。

### 成员控制命令

生成部署时通过 `--caller membership-controller=DNS:PORT --membership-controller membership-controller --service-membership-shard rooms-primary` 建立专用调用方。该身份仅有 `placementRead`、`placementWrite` 和 `placementMembership`，不运行房间宿主、策略服务或实时投票。扩展部署必须保留原控制身份。

使用其配置设置 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE` 和 `IMV2_PLACEMENT_SHARD_IDS`，运行 `IMV2PlacementControlApp --inspect` 获取目标分片的控制 revision。保存 JSON 请求，字段为 `deploymentID`（配置中的 `placementControl.clusterID`）、`shardID`、固定 `requestID` UUID、首次读取的 `originRevision`，以及 `membership`。后者包含 `revision`、`current`、可选 `next`、`peers` 和必填 `roomPeers`；实时 peer 字段为 `nodeID`、`serviceID`、`address`、`port`。房间 peer 字段为 `hostID`、`serviceID`、`address`、`port`、`accessibleShardIDs` 和 `maximumRooms`。房间范围、容量取自已批准部署配置，不能由发现通告补全；空房间名单不能启动启用动态成员的业务应用。

运行 `IMV2PlacementControlApp --install-membership request.json` 提交并输出已提交控制 revision 与成员记录。初始化提交稳定版本 1；扩容依次提交保留原 current 的联合版本、以原 next 为 current 的最终版本。每一阶段使用独立保存的请求；该阶段响应丢失时重试同一文件，保留 requestID 与 originRevision。冲突不会改写名单，过期请求也不会自动换 ID 重新提交。该命令只提交控制记录；操作流程仍需确认节点接纳、资格恢复和分区迁移，不能连续盲发名单后就宣称扩容成功。

成员请求可用 `v2_benchmark_membership_commands.py --configuration configuration.json --origin-revision REV --target gateway-0 --output request.json` 生成；后续阶段传入上一阶段的 `--previous-receipt`，联合阶段重复 `--target` 指定完整目标集合，最终阶段省略 `--target`。输出文件只允许首次创建，未知结果时重用原文件。部署配置的 `shardIDs` 会转换为请求中的 `accessibleShardIDs`；房间 peer 的 `hostID`、`serviceID` 使用 `{ "rawValue": "..." }` 对象，不能直接复制配置中的字符串。实时 peer 的两个 ID 仍是字符串。

正常关闭会等待已接纳的 RPC 实际结算，再用调用方签名的准确会话凭据请求释放配额。接收方核对服务、宿主、进程代次及握手 ID；重复关闭已删除会话不会删除新会话。远端不可达时关闭调用有界结束，服务端会话仍按原 TTL 失效；会话数量上限不变。连续短命令的配额回收已通过真实远程生命周期验证；此结果只覆盖会话配额与关闭，不替代业务扩容验收。

### 计划分区迁移命令

生成部署时添加 `--caller partition-operator=DNS:PORT --placement-controller partition-operator --service-membership-shard rooms-primary`。该专用身份只有 `placementRead`、`placementWrite` 和 `roomCoordination`；不运行房间、策略或实时服务，也不能提交成员变更。迁移权限来自该身份的控制写入分片范围，不再误用仅宿主具备的本地 `allowedShards`。

使用操作者配置运行 `IMV2PlacementControlApp --inspect`，保存不可变 JSON 请求，字段为：`deploymentID`（配置的部署 ID）、`shardID`、`partition`、`expectedHost`、`expectedEpoch`、`successor`、`transferID` UUID 和首次读取的 `originRevision`。两个宿主对象都包含对象形式的 `hostID: { "rawValue": "宿主 UUID" }` 和字符串形式的精确 `incarnationID`；旧宿主与 epoch 取自该分区的已提交所有者，目标宿主必须已注册、已授权且能被签名发现。

执行 `IMV2PlacementControlApp --transfer-room-partition request.json`。命令通过原有协调器先提交撤回状态，向旧宿主取得真实排空证明，再校验目标资格并提交新所有者。超时不会充当排空证明，也不会自动选替代目标。暂时不可用或 CAS 冲突只重试原请求；响应丢失时重新执行同一文件，不修改 transfer ID、原始 revision、旧所有者或 epoch。成功输出 `status: completed` 及完整原请求；失败或未确认时返回非零状态。默认操作截止时间为 60 秒，之后还会等待资源关闭。

集成测试使用三个真实磁盘/mTLS 控制节点、两个房间宿主和独立操作者，验证活动房间在旧宿主关闭、所有者及 epoch 变化、准确重试不重复排空、新宿主可以激活同一房间，以及越权/错误绑定请求被拒绝。房间执行器是合成测试实现；该结果不能代替业务消息流和多 VM 扩容验收。

### 新身份的签名授权

Actor 配置可通过 `trustAdmissionAuthorityServiceID` 指定已列在 `services` 中的独立授权服务。它必须没有普通服务权限、Host 或 gateway 归属；授权绑定 `placementControl.clusterID`。不配置此字段时，运行中新增信任的入口关闭。

创建部署时可传入 `prepare_v2_room_actor_configuration.py --trust-admission-authority admission-authority`。生成器在部署根目录的 `.trust-admission/signing.pem` 保存专用 Ed25519 私钥，并在各节点配置中固定其公钥及空权限。该目录属于部署工具，不能挂载到业务节点。`--extend-from` 自动继承授权身份并复用已有授权私钥，拒绝替换授权身份或与业务节点共用身份；原部署没有授权身份时不能靠扩展配置给运行中的节点补设信任根。此参数只准备签名身份，不发布授权文件。

信任表由已创建的认证组件共享。`admitAuthorizedServices` 验证指定服务的签名、部署 ID 和整批身份约束后原子加入新身份；完全相同的授权可重放，已有公钥、权限、Host、gateway 归属和逻辑分片范围不能改写。普通业务服务不能签发授权，冲突批次不会留下部分新增身份。授权服务本身不能打开普通 Actor 会话。

配置 `trustAdmissionDirectory` 后，控制运行时在打开传输前重放目录中的 `.pb` 签名授权，并每秒读取新增文件；房间服务调用方、监督调用方和独立投票节点共用这一生命周期。目录必须为绝对路径，并同时配置授权服务。部署工具应保留已发布文件，以临时文件加原子重命名发布完整报文；文件内容是 `V2ActorProtobuf` 编码的 `V2ActorSignedPacket`，不包含私钥。读取在独立线程池执行，退出等待实际读取完成。启动时无效授权阻止启动，运行中无效扫描记录错误并保留已有信任。删除授权文件不是撤销，不能移除进程已经接纳的身份。

生成器启用专用授权身份时，会为每个进程创建权限为 `0700` 的 `trust-admissions` 目录并设置 `trustAdmissionDirectory`，路径遵循 `--mount-root`。扩展部署保留已有接收目录路径，并将节点目录内已发布的 `.pb` 文件复制到新暂存目录；已有自定义外部接收目录仍需保留原挂载。只给已运行进程改写配置不会动态打开扫描器，必须在它启动时完成此配置。

签名服务记录中的 `sourceIDs` 指定可访问的逻辑数据源（房间分片名、`user:` 前缀的用户桶及显式 `control` 别名）。Placement 读写与宿主准入、房间调用、实时发布与订阅回调已接入新增身份的签名范围，并保留各操作的角色校验和接收端范围校验。已有静态访问条目优先，签名授权不能扩大它们；没有静态条目的启动身份也不会自动获得动态访问权。

身份及分片授权不授予成员资格或分区所有权。跨机器文件发布、成员发布及应用组合仍需接入，不能据此宣称新服务器已经可以在线扩容。

部署端使用 `IMV2TrustAdmissionTool PREVIOUS_CONFIGURATION EXPANDED_CONFIGURATION AUTHORITY_PEM OUTPUT_PB` 生成授权文件。配置参数分别指向旧部署与扩展部署的某个节点 `configuration.json`，私钥参数指向旧部署的 `.trust-admission/signing.pem`。工具要求部署 ID、授权身份及全部旧服务记录保持一致，只签发新增服务，并通过生产信任验证器自检；没有新增服务或目标文件已经存在时失败。

输出是离线暂存文件。发布时只传输 `.pb` 报文，在每个接收节点的授权目录中先写临时文件，再原子重命名；不要让扫描器读取正在写入的目标文件。必须持久保留已发布报文以供重启重放。签名工具不分发私钥，也不修改成员版本或分区归属；跨机器发布和确认接纳仍需由部署流程完成。

测试部署可使用 `python3 IMV2/scripts/publish_v2_trust_admission.py --packet <授权文件> --target imv2-growth-node0:/absolute/admissions --target imv2-growth-control-a:/absolute/admissions`，本机使用 `--local-directory /absolute/admissions`。目标目录须已存在并与接收进程的 `trustAdmissionDirectory` 一致。发布器只读取报文，通过管理通道传输到各 VM 自己的文件系统；先同步临时文件，再以原子硬链接创建内容摘要命名的 `.pb`，不会替换已有文件，最后同步目录。相同报文重试会验证已有文件的完整内容；冲突、符号链接或不完整文件会拒绝。

回执中的 `published` / `already_published` 只证明文件持久发布，`runtimeAcceptance` 始终明确为 `unconfirmed`。连接中断时结果同样为未确认，可以用相同报文重试，不能删除旧文件或重新生成身份。进程接纳确认和成员版本切换仍是独立步骤。

### 扩展已有部署配置

`prepare_v2_room_actor_configuration.py --extend-from <已有私有部署目录> --output-dir <新目录>` 支持为新增节点准备配置。仍需传入完整的旧节点和新增节点参数，以及原分片、用户桶和策略分区数。工具复用原部署 ID、CA、已有节点身份与密钥、控制端口及投票节点持久数据路径；新增节点使用新密钥及原 CA 签发的证书。已有策略分区归属保持不变，新节点不会因配置生成而取得分区。

源目录保持不变，输出目录必须不存在。输出中的旧投票节点配置继续引用原持久路径，部署时必须保留对应存储挂载；不能把空目录作为旧集群的数据目录。CA 私钥仅用于部署端签发，不应挂载到业务进程。独立身份授权服务及其无业务权限的信任记录会被保留。

这一步只准备配置，不向运行中的进程发布身份或成员变更，也不启动服务器。输出中的扩展 peer 名单不能直接替换在线节点的配置作为扩容流程；必须由已提交的成员变更驱动发现版本和资格切换。

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

正常在线扩容的阶段、均衡检查和测量结果见[用户增长与在线扩容](../09-capacity/horizontal-user-growth.md)。另一次双节点暂停约 12 秒的故障负载中，399 个前台视图缺失，存活的 9,601 个视图追平；乱序缓冲溢出与重试耗尽的关系仍待核验。原始对照在 `~/Desktop/IMV2-Archive/IMV2-Retirement-Fix-20261019`，逐轮记录可从[清理前的手册](https://github.com/Yyilin001/IMMonorepo/blob/9e31ff0c82a7b239b43f5a6efe2eb2cafb607b93/IMV2/docs/10-operations/room-host-supervision.md)追溯。
