# 本地文件系统媒体测试

本地账号栈现在可使用容器卷暂时代替对象存储，供 iOS App 验证附件上传、扫描、发消息和下载效果。它不是生产对象存储实现。

启动或重建本地栈：

```bash
IMV2/scripts/run_v2_local_account_stack.sh
```

脚本会在 `IMV2/.env.local` 中生成 `IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64`，并通过 `IM_V2_LOCAL_MEDIA_MODE=filesystem` 与 `IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY=1` 两个显式开关启用该能力。配置只接受回环 HTTPS 地址。对象字节保存在 Docker 命名卷 `v2-local-media-objects`；不要把该卷、`.env.local` 或其密钥用于生产环境。

首次在模拟器运行 App 前，按照启动脚本输出将 `IMV2/local-ca/root.crt` 信任为本地根证书。随后在会话中选择一个不超过 50 MiB 的文件：App 先持久保存发送意图与资源依赖，再按实际计划通过 HTTPS PUT 或分片 PUT 写入本地容器卷，等待资源 Ready 后冻结并提交消息操作。只带不透明 media ID 的消息不会在上传尚未 Ready 时发布。接收端点击下载后，会重新授权并通过一个新的短期 HTTPS GET 目标读取文件。

排查时使用：

```bash
docker compose --env-file IMV2/.env.local --file IMV2/docker-compose.local-account.yml logs -f account
```

若上传一直停在“等待安全扫描”，先确认 `account` 容器已由最新镜像重建；该容器拥有本地扫描轮询任务。生产接入时应移除 `IM_V2_LOCAL_MEDIA_*` 配置和此路由组合，改为对象存储与真实恶意文件扫描服务。

## 当前能力与部署边界

本地参考资源上传适配器开放整文件 PUT 和分片 PUT：对象最大 256 MiB，每片最大 8 MiB、最多 32 片；App 页面仍遵守自身用途/附件限额，不能以 provider 上限放宽产品准入。持久恢复复用原资源会话、已确认 part 和消息身份；finalize 未知先核对原会话，不另外发布资源。后台只接受带逐片、绑定原会话/generation/期限的狭义授权计划。App 已在账户激活时先对账并采用系统 URLSession 任务，再启动前台资源活动；这不等于已验证真机后台送达。

本地 `/v2/local-media/download/:mediaID` 字节路由现按全文 SHA-256 生成强 ETag，并在解释 Range 前检查 `If-Range`。验证器不匹配时返回完整 `200`，客户端丢弃旧部分再写入；匹配的 `206` 必须是连续正确区间。`416` 仅在本地长度已完整且服务端总长一致时允许继续完整性校验。客户端始终核对原大小及 SHA-256 才发布缓存。不要将此路由行为推断到独立资源分发入口或任意 CDN。

当前参考实现每个下载请求都以最多 64 KiB 块重新读取全文计算 ETag，即使只请求小区间也有全文磁盘/hash 成本；内存有界，CPU/磁盘开销和并发吞吐尚未测量。真实 provider 应基于写入时已核验的不可变对象摘要提供强验证器，避免每个 Range 请求重复全文扫描，并验证代理不会拼接不同 generation。

## 本地文件读取边界

授权后的本地对象持有已打开的文件描述符，摘要、完整下载及 Range 下载共用该描述符。资源存储读取、扫描输入和已完成分片也使用固定的文件句柄；后续读取通过 `pread` 指定偏移，每次最多 64 KiB，不重新解析对象路径。目录项或根目录在打开后被替换时，在途读取仍针对原文件；新请求拒绝根目录的符号链接。

打开目录和对象时分别使用 `O_NOFOLLOW`，对象通过目录描述符的 `openat` 打开，并以 `fstat` 确认普通文件、非负长度和单一硬链接。FIFO 以非阻塞方式打开后拒绝，避免等待另一端；目录、符号链接及打开时存在多个硬链接的文件同样拒绝。删除标记按目录项检查，悬空链接也视为已删除。资源存储在同一对象锁内校验已有对象，以同目录原子重命名发布新对象，避免正常读取或崩溃恢复遇到暂存双硬链接。

这项保护针对路径替换导致的越界读取。配置根目录的祖先、挂载和服务账号仍须可信；`O_NOFOLLOW` 只约束该次打开的末级路径，不能保护不可信祖先。发布后的普通文件必须保持不可变，不能以这项改动防御能够修改同一 inode、移动外部文件、删除围栏或控制服务账号/root 的本地进程。上传暂存、提交和删除仍包含按路径写入，不构成通用文件系统沙箱；本地卷不能授权给不可信写入者。描述符与路径替换的语义见 [open/openat](https://man7.org/linux/man-pages/man2/open.2.html) 和 [pread](https://man7.org/linux/man-pages/man2/pread.2.html)。

2026-11-01 在 macOS 临时目录和 Vapor HTTP 路由上完成 20 个定向测试方法，执行耗时 0.057 秒；[新增读取边界用例](../../../IMV2Server/Tests/IMV2ServerTests/V2LocalMediaReadBoundaryTests.swift) 的 3 个方法覆盖 9 个场景，包括符号链接、硬链接、目录、FIFO，以及计算摘要前后和首块读取前的目录替换。原子发布与并发建锁调整后，只复核并发同身份发布/重放和已打开资源流两个受影响方法，均通过，执行耗时 0.006 秒；这些 macOS 批次没有运行 Linux。

随后使用当前冻结源码，在隔离 Linux arm64 的 ext4 卷上运行上述 3 个读取方法、并发发布/重放和 2 个删除围栏方法：6 个方法全部通过，无跳过，执行耗时 0.044 秒，见[Linux 证据](../../../docs/verification/local-media-linux-20261101.json)。临时专项测试包使用同一生产库、原样测试文件与原有 39 项依赖版本；完整服务端测试模块曾在 6 GiB 双任务编译时触发内存不足，本次没有取得完整包门禁通过记录。本轮使用容器 root 身份，生产服务账号、挂载/目录权限、并发吞吐和实际媒体进程崩溃恢复仍需目标部署验收。

一次性本地 HTTPS/Actor/资源联调入口为 `scripts/verify_v2_live_resource_authors.py --output <全新证据目录>`；它自行建立临时数据库、密钥与 filesystem provider，不能证明外部对象存储、CDN 或跨故障域部署。本次读取边界整改没有执行该联调，也没有真机锁屏、挂起、强退、重启或后台晚完成证据。外部适配器接入、实际权限与撤权、分片/finalize 故障及容量验收按[当前适配器合同](../../../docs/proposals/resource-provider-adapter-contract.md)单列。
