# 本地文件系统媒体测试

本地账号栈现在可使用容器卷暂时代替对象存储，供 iOS App 验证附件上传、扫描、发消息和下载效果。它不是生产对象存储实现。

启动或重建本地栈：

```bash
IMV2/scripts/run_v2_local_account_stack.sh
```

脚本会在 `IMV2/.env.local` 中生成 `IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64`，并通过 `IM_V2_LOCAL_MEDIA_MODE=filesystem` 与 `IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY=1` 两个显式开关启用该能力。配置只接受回环 HTTPS 地址。对象字节保存在 Docker 命名卷 `v2-local-media-objects`；不要把该卷、`.env.local` 或其密钥用于生产环境。

首次在模拟器运行 App 前，按照启动脚本输出将 `IMV2/local-ca/root.crt` 信任为本地根证书。随后在会话中选择一个不超过 50 MiB 的文件：App 会请求短期上传目标、通过 HTTPS PUT 写入本地容器卷，等待本地 EICAR 测试扫描，再发送只带不透明 media ID 的消息。接收端点击下载后，会重新授权并通过一个新的短期 HTTPS GET 目标读取文件。

排查时使用：

```bash
docker compose --env-file IMV2/.env.local --file IMV2/docker-compose.local-account.yml logs -f account
```

若上传一直停在“等待安全扫描”，先确认 `account` 容器已由最新镜像重建；该容器拥有本地扫描轮询任务。生产接入时应移除 `IM_V2_LOCAL_MEDIA_*` 配置和此路由组合，改为对象存储与真实恶意文件扫描服务。
