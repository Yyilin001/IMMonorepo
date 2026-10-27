# 阿里云 OSS 接入与验证

## 接入边界

业务服务继续使用 `V2ObjectStorage`、`V2UploadTransport`、`V2ResourceDelivery`，客户端继续执行通用传输计划。OSS 的签名、Bucket、Endpoint、请求和错误转换集中在 `IMV2ServerInfrastructure/Resources/Adapters/OSS`。Account 与 Gateway 通过 `V2ResourceStorageAssembly` 装配同一份后端配置，资源会话与旧对象仍按 binding ID 和 revision 解析。

上传使用 OSS V4 预签名 PUT，签名绑定内容类型、声明长度、防覆盖和私有对象 ACL。临时凭据只出现在短期能力中，不进入业务持久化。当前 OSS 适配器声明前台单次 PUT，最大 256 MiB；未声明分片或后台上传能力。客户端最终 SHA-256 由资源发布流程核验，不能将用户提交的 OSS 元数据当作已核验摘要。

下载沿用通用的 `V2SignedResourceDelivery` 和 Account 的 `/v2/resource-bytes/:placementID`，保留现有授权、到期、Range、完整性校验和缓存合同。该实现已从本地适配目录移到基础设施目录；原 `V2LocalResourceDelivery` 名称保留为兼容别名。当前没有启用公开 Bucket 或 CDN。

## 对象身份与删除

此适配器只支持**从未启用版本控制的私有 Bucket**，启动检查拒绝已启用或已暂停版本控制的 Bucket。每个 binding/revision 应使用独立且稳定的 prefix；改变 Bucket、prefix 等对象定位配置必须增加 revision，并保留仍被引用的旧配置。

最终对象使用预分配的 UUID key，写入前以有界内存暂存到私有临时目录并核验全文摘要。OSS `x-oss-forbid-overwrite` 防止同一身份被替换；冲突时核对原对象事实，仅同内容重试成功。

删除把同一 key 原子替换为零字节 tombstone。迟到的防覆盖 PUT 会与 tombstone 冲突，不能复活该对象；上传取消使用相同机制。**不能用生命周期过期、手工 DELETE 或外部清理删除这些 tombstone**。它们不是待清理的泄漏文件，而是永久删除栅栏。对象内容被清除，仍保留零字节对象与元数据。运行凭据不需要 `oss:DeleteObject`。

远端读取按 ETag 栅栏执行有界 Range 请求，输出块最多 64 KiB，最终核对全文 SHA-256。当前每块一次 OSS 请求，尚未进行大对象吞吐压测；不能将功能验证视为性能验收。

## 配置

参见 [oss.env.example](../../IMV2Server/oss.env.example)。Account 和 Gateway 必须使用一致的 bindings、分发域名和 32 字节分发密钥。`IM_V2_RESOURCE_MODE=enabled` 不需要本地媒体的 unsafe 测试开关；不要同时设置 `IM_V2_LOCAL_MEDIA_MODE`。

新资源默认改用 OSS 时，在 `IM_V2_RESOURCE_STORAGE_BINDINGS_JSON` 保留已有的本地条目与准确目录，只修改默认 binding。启动 readiness 会检查历史引用，不支持把找不到的旧对象静默映射到新 Bucket。

凭据通过运行环境注入。STS 使用 `IM_V2_OSS_SECURITY_TOKEN` 和 ISO-8601 `IM_V2_OSS_CREDENTIAL_EXPIRATION`；环境变量模式的进程需要在凭据过期前轮换并重启。ECS RAM Role 部署可设置 `IM_V2_OSS_CREDENTIAL_FILE=/run/im-oss-role/credentials.json`：服务按请求读取有界的凭据文件，拒绝缺失、损坏或过期内容，文件配置失败时不回退到环境变量凭据。宿主机通过 `scripts/refresh_v2_ecs_oss_credentials.py --role-name <role> --output <absolute-path>` 使用 IMDSv2 获取角色凭据，原子替换权限为 0600 的文件；由 systemd timer 每 5 分钟执行。容器应只读挂载整个凭据目录，以便原子替换后的新文件立即可见。角色轮换无需重启 Account/Gateway。`V2OSSCredentialProvider(load:)` 仍支持装配层注入其他凭据来源。不得将本机 CLI 的临时登录当作长期部署凭据。

运行权限应限制为目标 Bucket 的 `oss:GetBucketAcl`、`oss:GetBucketVersioning`，以及绑定 prefix 下的 `oss:GetObject`、`oss:PutObject`。Bucket 版本控制、ACL、生命周期变更不属于运行权限。

## 验证入口与当前证据

2026-10-23 已开通 OSS，创建并通过 API 核验测试 Bucket `imv2-oss-validation-20261023-7f2a9c`：深圳地域、private ACL、Standard、LRS。用户授权本次验证预算为 ¥5；仅使用合成测试字节，不上传个人文件。

第一轮真实云端合同测试已通过：180,000 字节写入、同内容幂等重试、拒绝不同内容覆盖、分块读取、删除重试、删除后拒绝写入、预签名直传、取消后旧 URL 返回 409、服务端导入重试。测试结束将涉及对象写为零字节 tombstone。普通/STS/附加头/预签名 URL 的签名使用阿里云官方 SDK 固定向量验证。

显式执行真实测试（使用已登录的本机 CLI，凭据只传给子进程）：

```sh
python3 scripts/run_v2_oss_live_tests.py \
  --bucket imv2-oss-validation-20261023-7f2a9c \
  --region cn-shenzhen --aliyun-profile default
```

省略 `--aliyun-profile` 时读取调用者的 `IM_V2_OSS_*` 凭据。每次测试使用独立 UUID prefix。普通测试不会自动访问云端；仅 `IM_V2_OSS_LIVE_TEST=1` 启用真实合同测试。该脚本也运行本地存储和分发合同，检查兼容性。

最新回归共 21 项测试、5 个测试套件全部通过（macOS Swift 6.4）。真实 OSS 测试还验证了通用签名下载分发，并暂停已经开始发送的 PUT，在删除同一 key 后恢复发送：旧 PUT 返回 409，后续 inspect 仍返回 notFound。日志为 `/tmp/imv2-oss-race-tests.log`；本次真实测试耗时约 3.9 秒。Account/Gateway 构建、服务端依赖边界、文档链接和运行环境示例检查均通过。

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
