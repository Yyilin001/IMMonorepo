# 阿里云 OSS 接入与验证

## 接入边界

业务服务继续使用 `V2ObjectStorage`、`V2UploadTransport`、`V2ResourceDelivery`，客户端继续执行通用传输计划。OSS 的签名、Bucket、Endpoint、请求和错误转换集中在 `IMV2ServerInfrastructure/Resources/Adapters/OSS`。Account 与 Gateway 通过 `V2ResourceStorageAssembly` 装配同一份后端配置，资源会话与旧对象仍按 binding ID 和 revision 解析。

上传使用 OSS V4 预签名 PUT，签名绑定内容类型、声明长度、防覆盖和私有对象 ACL。临时凭据只出现在短期能力中，不进入业务持久化。当前 OSS 适配器提供单次 PUT、逐片 PUT 及各自的后台授权计划，最大 256 MiB；双方支持分片时优先选择逐片传输，每片最多 8 MiB、最多 32 片。客户端最终 SHA-256 由资源发布流程核验，不能将用户提交的 OSS 元数据当作已核验摘要。

下载沿用通用的 `V2SignedResourceDelivery` 和 Account 的 `/v2/resource-bytes/:placementID`，保留现有授权、到期、Range、完整性校验和缓存合同。该实现已从本地适配目录移到基础设施目录；原 `V2LocalResourceDelivery` 名称保留为兼容别名。当前没有启用公开 Bucket 或 CDN。

## 对象身份与删除

此适配器只支持**从未启用版本控制的私有 Bucket**，启动检查拒绝已启用或已暂停版本控制的 Bucket。每个 binding/revision 应使用独立且稳定的 prefix；改变 Bucket、prefix 等对象定位配置必须增加 revision，并保留仍被引用的旧配置。

最终对象使用预分配的 UUID key，写入前以有界内存暂存到私有临时目录并核验全文摘要。OSS `x-oss-forbid-overwrite` 防止同一身份被替换；冲突时核对原对象事实，仅同内容重试成功。

删除把同一 key 原子替换为零字节 tombstone。迟到的防覆盖 PUT 会与 tombstone 冲突，不能复活该对象；上传取消使用相同机制。**不能用生命周期过期、手工 DELETE 或外部清理删除这些 tombstone**。它们不是待清理的泄漏文件，而是永久删除栅栏。对象内容被清除，仍保留零字节对象与元数据。运行凭据不需要 `oss:DeleteObject`。

远端读取按 ETag 栅栏执行有界 Range 请求，每次最多获取 1 MiB，并从该缓冲区逐次输出最多 64 KiB；完整读取时核对全文 SHA-256，取消后停止交付。读取 256 MiB 对象需要 256 次 GET，不含 HEAD；每个读取器的范围缓冲上限为 1 MiB。定向测试验证请求数、分块、ETag/范围/长度/摘要拒绝和取消；尚未进行真实 OSS 大对象吞吐压测，不能将请求数下降视为吞吐或延迟验收。

## 分片续传与暂存回收

每片是独立、私有、不可覆盖的 OSS PutObject，key 由媒体身份、冻结的全文摘要和片号确定。重建服务后，通过 HEAD 的大小和 ETag 恢复已确认片；默认只签发下一缺片，显式请求最多 16 个不重复片号。后台授权绑定原会话、generation、媒体身份、片号和截止时间。签名绑定长度，原生防覆盖规则见 [PutObject](https://www.alibabacloud.com/help/en/oss/developer-reference/putobject)。供应商的 UploadId/CompleteMultipartUpload 接口未启用。

finalize 比对完整片清单和 ETag，再顺序读取各片；打开时及每次 Range 请求均检查对应 ETag，并在流结束前核对全文 SHA-256。最终对象继续通过已有的服务端暂存、摘要核验和不可覆盖 PUT 发布。这会使用服务端磁盘及双向流量，不能把客户端断点续传等同于已通过吞吐或费用验收。单次缺片查询最多执行 32 个 HEAD，显式片号只检查所请求的片；状态确认、最终校验和读取还会产生 HEAD/GET，部署需按实际文件大小与重试率计入请求预算。条件读取语义见 [GetObject](https://www.alibabacloud.com/help/en/oss/developer-reference/getobject)。

新建库 `im-v2-current-78` 在发布事务内把上传会话标记为待清理；Account 为每个物理 owner 启动独立的 `resource_staging_cleanup` 循环。清理只读已完成会话的冻结 binding 和请求，不依赖用户设备仍在线，也不删除最终 placement。每次只领取一个会话，租约五分钟，单次提供方工作预算两分钟；取消会等待子任务结束，失败三十秒后重试，旧租约令牌不能确认或推迟新领取的工作。成功清理全部暂存 key 后才清除待办，发布响应不再等待云端清理成功。未完成会话的取消/到期仍由持久 purge outbox 恢复。

清理会把已上传与尚未上传的全部可能片 key 都写为永久 tombstone，确保已经签发或在途的旧 PUT 不能晚到复活。最多 32 片加整文件暂存 key，以及最终 placement，每次上传最多涉及 34 个永久对象身份；取消也可能为尚未上传的片创建标记。临时字节会被回收，标记本身继续保留。容量盘点的 `uploads/` 分类包含这些片 key；完成和取消后的标记都计入数量与费用。现场应监控 `resource_upload_sessions` 中 `staging_cleanup_pending=true` 的数量与最早重试时间；长期积压时排查凭据、提供方可用性和 worker 生命周期，不能清除待办或删除围栏来隐藏失败。

## 永久对象的容量盘点与保留

[`audit_v2_oss_capacity.py`](../../scripts/audit_v2_oss_capacity.py) 是独立的只读运维入口。按每个实际 OSS binding/revision 的 Bucket、地域、prefix 分别运行；配置指向相同物理 prefix 的条目只算一次，不把父子 prefix 的报告相加。它先拒绝启用或暂停版本控制的 Bucket，再分页列举整个 prefix；分别统计 `objects/`、`uploads/` 和非预期 key 的对象数、字节数、零字节对象数。每个零字节对象必须经过带 ETag 条件的 HEAD，确认 `x-oss-meta-im-deleted=true` 才计为 tombstone；未标记对象、可见的过期规则、异常 key、跨次统计数量下降均要求调查。

使用 Python 3.11+ 与 OpenSSL 1.1.1+，在独立虚拟环境安装[固定 SDK 版本](../../scripts/requirements-oss-capacity.txt)。沿用 `IM_V2_OSS_*` 环境凭据或 `IM_V2_OSS_CREDENTIAL_FILE`；每次签名重新读取轮换文件，文件错误或过期时不回退到环境凭据。凭据、签名 URL 和逐对象 key 不写入报告。盘点凭据只需目标 Bucket 的 `oss:GetBucketVersioning`、`oss:ListObjects`，以及被盘点 prefix 的 `oss:GetObject`（HEAD）；权限与元数据口径见 [ListObjectsV2](https://help.aliyun.com/en/oss/developer-reference/listobjectsv2) 和 [HeadObject](https://www.alibabacloud.com/help/en/oss/developer-reference/headobject)。不要为了盘点给运行服务增加列举、删除或 Bucket 策略写入权限。

```sh
python3 -m venv /tmp/imv2-oss-capacity
/tmp/imv2-oss-capacity/bin/python -m pip install -r scripts/requirements-oss-capacity.txt
# 以下数量是调用示例，不是生产容量承诺；按部署预算填写。
/tmp/imv2-oss-capacity/bin/python scripts/audit_v2_oss_capacity.py \
  --bucket YOUR_PRIVATE_BUCKET --region cn-shenzhen --prefix imv2/ \
  --object-budget 1000000 --warning-fraction 0.8 \
  --max-requests 10000 --max-seconds 600 --requests-per-second 5 \
  --output /tmp/oss-capacity-2026-11-01.json
```

报告同时记录执行时间区间、请求数和预算。每次完整盘点通常需要 `1 + ceil(对象数 / 1000) + 零字节对象数` 个只读请求；空 prefix 仍要一次 LIST。SDK 不自动重试，分页大小最多 1000，请求串行并限速。默认预算保护调用成本，不能保证大 prefix 在预算内扫完。超限、超时、分页异常、权限错误或对象在核验时变化都会保留部分观测并以退出码 **3** 标为 `incomplete`，禁止将该报告用于证明容量合格。单次网络调用有 5 秒连接和 10 秒读写超时；时间预算在请求前后核对，不是操作系统强制终止期限。

完整报告的退出码：**0** 表示本次观测在配置容量内；**1** 表示达到预警比例；**2** 表示达到对象预算或出现需调查的异常。这些退出码可供部署监控消费，本脚本不会自动修改上传准入或安排定时任务。接近预算时应扩大已批准容量、限制新增上传或停止向该 binding 分配新对象；已有 tombstone 保留。调整到新 prefix 不会消除旧 prefix 的保留成本，旧绑定也须持续盘点。大规模部署应安排独立盘点窗口、核算完整 LIST/HEAD 成本；如改用云端清单或索引汇总，必须另行验证 tombstone 元数据口径，不能把截断结果当作全量。

追加 `--previous <同一目标的前次完整报告>` 可计算每日对象/tombstone 增量和按本次速率估计的预算耗尽天数。OSS 分页不是原子快照；报告仅反映运行区间的观测，低频采样与并发写入会影响增量，单次估计不是 SLO 或未来增长保证。完整盘点也不等于 Bucket 生命周期策略审计：HEAD 的过期头只能发现部分危险策略；部署仍须禁止所有可能删除这些 key 的生命周期与外部 DELETE。

费用输入使用 `--prices <JSON>`，由部署方按实际地域、冗余类型、折扣及计费单位填写 `currency`、`storage_per_gib_month` 和 `read_per_10000`。两个单价表的 key 使用 `Standard`、`IA`、`Archive`、`ColdArchive`、`DeepColdArchive`；只读请求表另用 `bucket` 表示 versioning/LIST 的单价。示例结构为 `{"currency":"CNY","storage_per_gib_month":{"Standard":"实际单价"},"read_per_10000":{"bucket":"实际单价","Standard":"实际单价"}}`，运行前将文字替换为非负数。缺少单价时保留 `null` 和缺项，不按零费用处理。报告估算当前 tombstone 的月存储费和本次只读请求费，不包含写入、流量、历史内容提前删除、最低保留时长或其他账单项目。Standard 按实际大小计量，IA/Archive/ColdArchive/DeepColdArchive 的单对象最低计费大小为 64 KiB；因此零字节不等于所有费用为零。计费边界参照 [OSS 存储费用](https://www.alibabacloud.com/help/en/oss/storage-fees)，金额最终以实际账单为准。

当前保留策略仍是永久保留 tombstone。任何 GC 上线前必须给出同一对象身份的持久写入关闭证据：所有进程、导入重试及重启后的路径不能再签发或执行写入；既发预签名/后台上传能力已撤销或失效，所有在途写入已被证明不可能迟到提交；删除后旧身份的重放仍会被持久围栏拒绝。只等待 URL 到期、检查数据库引用为零或看到零字节都不足以建立这些条件。盘点命令不具备 GC 权限，也不生成可删除清单。

## 配置

参见 [oss.env.example](../../IMV2Server/oss.env.example)。Account 和 Gateway 必须使用一致的 bindings、分发域名和 32 字节分发密钥。`IM_V2_RESOURCE_MODE=enabled` 不需要本地媒体的 unsafe 测试开关；不要同时设置 `IM_V2_LOCAL_MEDIA_MODE`。

新资源默认改用 OSS 时，在 `IM_V2_RESOURCE_STORAGE_BINDINGS_JSON` 保留已有的本地条目与准确目录，只修改默认 binding。启动 readiness 会检查历史引用，不支持把找不到的旧对象静默映射到新 Bucket。

凭据通过运行环境注入。STS 使用 `IM_V2_OSS_SECURITY_TOKEN` 和 ISO-8601 `IM_V2_OSS_CREDENTIAL_EXPIRATION`；环境变量模式的进程需要在凭据过期前轮换并重启。ECS RAM Role 部署可设置 `IM_V2_OSS_CREDENTIAL_FILE=/run/im-oss-role/credentials.json`：服务按请求读取有界的凭据文件，拒绝缺失、损坏或过期内容，文件配置失败时不回退到环境变量凭据。宿主机通过 `scripts/refresh_v2_ecs_oss_credentials.py --role-name <role> --output <absolute-path>` 使用 IMDSv2 获取角色凭据，原子替换权限为 0600 的文件；由 systemd timer 每 5 分钟执行。容器应只读挂载整个凭据目录，以便原子替换后的新文件立即可见。角色轮换无需重启 Account/Gateway。`V2OSSCredentialProvider(load:)` 仍支持装配层注入其他凭据来源。不得将本机 CLI 的临时登录当作长期部署凭据。

运行权限应限制为目标 Bucket 的 `oss:GetBucketAcl`、`oss:GetBucketVersioning`，以及绑定 prefix 下的 `oss:GetObject`、`oss:PutObject`。Bucket 版本控制、ACL、生命周期变更不属于运行权限。

## 资源扫描配置

`IM_V2_RESOURCE_MODE=enabled` 必须同时配置 `IM_V2_RESOURCE_SCANNER=clamav`、绝对路径 `IM_V2_RESOURCE_CLAMSCAN_EXECUTABLE` 和 `IM_V2_RESOURCE_CLAMAV_DATABASE_DIRECTORY`。Account 的上传扫描与 Gateway 的转发扫描都通过同一装配入口创建 `V2ClamAVResourceScanner`；缺配置、二进制不可用、签名库缺失或启动样本检查不通过时启动失败。本地 EICAR 字符串夹具仅供显式 `IM_V2_LOCAL_MEDIA_MODE=filesystem` 加 `IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY=1` 的测试模式使用。

运行镜像安装 `clamscan`，签名库由部署环境只读挂载并持续更新，服务不自行下载签名。每次调用只加载官方签名并拒绝超过两天的签名库。启动检查同时要求干净样本通过、完整 EICAR 样本命中 EICAR 签名，使用实际扫描策略；固定探针的单文件限额至少为 68 字节，大小超限告警不能冒充签名检测成功。原生 OSS 验收脚本也要求传入上述三个扫描器变量；历史使用夹具的 OSS 验收不能作为真实 ClamAV 证据。

扫描前在私有临时目录流式核对声明长度和 SHA-256，只把已核验文件描述符交给子进程。每个进程最多运行 120 秒、返回 64 KiB 输出；Linux 地址空间上限 2 GiB，解包扫描上限 512 MiB、10,000 个文件、16 层嵌套。加密内容或超过扫描上限会拒绝；只接受明确完成的扫描结论，引擎错误、空输出、超时或取消都不会使对象变为可引用。取消和超时等待实际子进程退出后清理临时文件。这些参数遵循 [ClamAV 命令行合同](https://github.com/Cisco-Talos/clamav/blob/main/docs/man/clamscan.1.in)。

`clamscan` 每次加载签名库，当前并发由已有扫描/转发 Worker 限制。部署须按物理 owner 数及每个 Worker 的并发配置进程总内存、临时磁盘和队列告警，实际签名加载开销、误报、恶意样本覆盖与大对象性能仍需验收。

[真实引擎定向测试](../../IMV2Server/Tests/IMV2ServerTests/V2ClamAVLiveTests.swift) 显式启用后，使用指定引擎和已有签名库，检查启动探针、实际存储字节的干净/EICAR 判定，以及缺失签名库时的启动拒绝。测试不下载或修改传入的签名库，也不启动守护进程：

```bash
IM_V2_CLAMAV_LIVE_TEST=1 \
IM_V2_RESOURCE_CLAMSCAN_EXECUTABLE=/absolute/path/to/clamscan \
IM_V2_RESOURCE_CLAMAV_DATABASE_DIRECTORY=/absolute/path/to/signatures \
swift test --package-path IMV2Server --no-parallel --filter V2ClamAVLiveTests
```

2026-11-01 已使用 ClamAV 1.4.6 与 FreshClam 获取并校验的官方签名库，通过上述 2 个方法；另用过期的官方 `main.cvd` 与相同扫描参数确认退出码 2，未产生通过结论。引擎来自官方 macOS 包，校验发布摘要及 GPG 签名后，仅在临时副本中调整库路径并重新签名运行；未全局安装。该证据覆盖本机适配链路，尚不能代替 Linux 容器、生产签名更新/恢复、误报、并发资源和吞吐验收。详见[扫描验证记录](../verification/resource-scanner-clamav-20261101.json)。

## 验证入口与当前证据

2026-11-01 的逐片 PUT 与暂存回收修复通过 13 个定向测试方法：OSS 分片/Range、本地分片和取消所有权共 10 项（0.042 秒）；原生隔离 PostgreSQL 的发布/清理失败重试、重建、过期租约和 schema/index 准入 2 项（0.324 秒）；本地 HTTP/PostgreSQL 上传链路 1 项、整文件/逐片两个参数用例（最终重跑 0.126 秒，测试入口实际驱动回收 worker，确认上传/导入暂存待办清空且最终下载可用）。OSS 部分使用签名后受控 HTTP 响应，PostgreSQL 是真实临时实例；重建服务对象不等于操作系统杀进程验收。当前构建通过，已扩展显式启用的真实 OSS 分片和 HTTP 测试入口，但该批未运行云端写入、Linux、真实 ClamAV、手机后台或全量测试。以下 2026-10-23/25 的历史云端记录不能替代新增分片路径的现场证据。

2026-10-23 已开通 OSS，创建并通过 API 核验测试 Bucket `imv2-oss-validation-20261023-7f2a9c`：深圳地域、private ACL、Standard、LRS。用户授权本次验证预算为 ¥5；仅使用合成测试字节，不上传个人文件。

第一轮真实云端合同测试已通过：180,000 字节写入、同内容幂等重试、拒绝不同内容覆盖、分块读取、删除重试、删除后拒绝写入、预签名直传、取消后旧 URL 返回 409、服务端导入重试。测试结束将涉及对象写为零字节 tombstone。普通/STS/附加头/预签名 URL 的签名使用阿里云官方 SDK 固定向量验证。

显式执行真实测试（使用已登录的本机 CLI，凭据只传给子进程）：

```sh
python3 scripts/run_v2_oss_live_tests.py \
  --bucket imv2-oss-validation-20261023-7f2a9c \
  --region cn-shenzhen --aliyun-profile default
```

省略 `--aliyun-profile` 时读取调用者的 `IM_V2_OSS_*` 凭据。每次测试使用独立 UUID prefix。普通测试不会自动访问云端；仅 `IM_V2_OSS_LIVE_TEST=1` 启用真实合同测试。该脚本也运行本地存储和分发合同，检查兼容性。

2026-10-23 的历史回归共 21 项测试、5 个测试套件全部通过（macOS Swift 6.4）。真实 OSS 测试还验证了通用签名下载分发，并暂停已经开始发送的 PUT，在删除同一 key 后恢复发送：旧 PUT 返回 409，后续 inspect 仍返回 notFound。日志为 `/tmp/imv2-oss-race-tests.log`；该次真实测试耗时约 3.9 秒。Account/Gateway 构建、服务端依赖边界、文档链接和运行环境示例检查均通过。

客户端的通用上传恢复流程已补齐不可覆盖对象的重试：单次 PUT 收到 provider HTTP 409 后进入控制面的 finalize，由服务端验证大小和 SHA-256；不直接判为成功，也不影响分片上传。`V2ResourceStepTests` 的 9 项测试通过，包含单次/分片冲突分支，日志 `/tmp/imv2-oss-client-recovery.log`。

HTTP 与 PostgreSQL 集成验证可通过同一脚本追加 `--http-pipeline` 执行；必须显式设置已初始化的隔离数据库 `IMV2_RESOURCE_TEST_DATABASE_URL`，测试仅使用合成数据。该入口覆盖真实 OSS 直传、最终校验、扫描、带 Range 的 HTTP 下载和跨资源导入，认证与 room authorization 使用测试替身，不能替代 App 登录验收。

HTTP/PostgreSQL + OSS 联调已通过：2 项测试（本地上传含单次和分片两个参数用例），耗时约 2.7 秒，日志 `/tmp/imv2-oss-http-live.log`。共享数据库扫描器的用例已串行隔离，临时验证数据库已删除，云端合成内容已转为零字节 tombstone。

真实原生 ClientKit + 独立 Account/Gateway/PostgreSQL + OSS 网络验收已通过，证据目录 `/tmp/imv2-oss-native-20261023-r2`：`summary.json` 的 `clientExitCode=0`、`requiredTestPassed=true`、`readyAvatars=1`、`variants=2`。资源主场景约 10.2 秒，覆盖真实注册登录、头像上传/处理/绑定、TLS 作者信息分发、128px 图片内容校验、Range 下载、房间附件、消息撤回后停止发新下载能力、拉黑后拒绝访问。其余未启用的扩展场景不可计为已验证。

测试栈已正常关闭；本次 native 前缀中的合成对象已写为 private 零字节 tombstone，前后清单保存在证据目录。客户端日志与 HTTP 聚合统计均可复核。未部署到现有 ECS，未执行 Linux 或 iOS UI 实机验收；上述证据仅证明本次 macOS 原生服务栈与真实云存储的业务链路。

## 原生客户端验收入口

使用支持 TLS 1.3 的 Python，在已安装 PostgreSQL 命令行工具的 macOS 上运行：

```sh
python3 scripts/run_v2_oss_live_tests.py \
  --bucket imv2-oss-validation-20261023-7f2a9c \
  --region cn-shenzhen --aliyun-profile default \
  --native-output /tmp/imv2-oss-native-evidence
```

输出目录必须不存在。脚本启动独立 PostgreSQL、placement、Account、Gateway 和 HTTPS 入口，运行真正的 ClientKit 网络验收并关闭所建本地服务。服务端使用独立 `validation/native-<uuid>/` 前缀，凭据仅经环境注入服务端。`oss-fixture.json` 记录非敏感的 Bucket 与前缀；云端合成对象需在验收后转成零字节删除标记，不能删除标记后允许旧 capability 重新写入。客户端对 localhost 使用测试 CA，对 OSS 使用系统证书校验。

## 资源中心必选门槛（2026-10-25）

当前资源中心和群头像两条必选真实云端路径已在独立原生栈通过，详见 [资源中心实施证据第62节](client-resource-center-plan.md#62-当前代码的真实oss资源中心与群头像必选验收2026-10-25)。现有原生命令追加 `--resource-center`，driver会要求两个场景均真实执行并通过；不把跳过场景算作完成。每次输出目录必须不存在，Python须支持TLS1.3。

主场景现在实际经过ResourceCenter目录同步、持久下载请求、FileStore校验与借用、保留/清理/重新下载，以及TLS同步撤回后的本地读取拒绝。群头像场景检查上传、图片读取、移除及原操作恢复。`/tmp/im-resource-native-oss-20261025-gate-r2/summary.json`为本轮证据；未替代Linux、音视频实存、App持久发送及手机后台验收。

后续同一门槛已扩展并通过文本、真实WAV、真实MP4三类资源；上传改走LocalAsset和持久传输执行器，并在创建远端会话后关闭/重开本地运行时，沿原操作继续。最终证据为`/tmp/im-resource-native-oss-20261025-media-r3`，详见[第63节](client-resource-center-plan.md#63-真实oss三类资源与持久上传重开验收2026-10-25)。真实音视频时长/尺寸、保留/清理/重下与撤回均通过；仍未替代App完整发送链、Linux、真机系统后台或发布验收。

## 官方资料

- [OSS V4 签名](https://www.alibabacloud.com/help/en/oss/developer-reference/recommend-to-use-signature-version-4)
- [PutObject 防覆盖与版本控制限制](https://www.alibabacloud.com/help/en/oss/developer-reference/putobject)
- [官方 Swift SDK](https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2)：当前 Crypto 依赖上限 `<4.0.0` 与本项目 `>=4.0.0` 不兼容，因此适配器使用项目已有的 Crypto 和 AsyncHTTPClient，不下调项目依赖。
