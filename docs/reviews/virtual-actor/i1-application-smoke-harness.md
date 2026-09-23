# 独立应用进程冒烟入口

状态：脚本已准备，Python 编译与 shell 语法检查通过；完整应用运行结果尚未登记。

```sh
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --context colima-imv2-vapor5 \
  --scratch-dir /absolute/exclusive-linux-swiftpm-scratch
```

必须独占指定 Linux scratch；不得与其他构建同时使用。脚本在固定 Swift 6.4 镜像中从只读当前 checkout 构建 Account、Gateway、Operator 和协议 probe 的 Release 产品，再启动独立 Compose project。它不调用本地栈启动脚本、不重用固定 image tag，也不清理其他项目资源。

每次运行生成独立 PostgreSQL 及控制/Actor 密钥、私有 CA、网络、卷和随机 loopback 端口；应用配置来自现有 local-account Compose。数据库通过当前 canonical schema 合同后才植入一次临时 admission pool。现有 black-box 验证脚本现在允许传入 Compose/环境/CA/端口/注册恢复路径，默认开发栈用法保持不变。

验证范围是 HTTP 账号注册、限流、设备凭据签发、Gateway 真实 TCP/TLS 打开私聊和发送、接收方日志拉取、Operator 禁用账号及旧凭据拒绝、TLS 和指标。该脚本不能单独证明群邀请/昵称/媒体全部 HTTP 路径、多 Host 故障矩阵或容量预算。

产物位于 `~/.codex/virtual-actor-builds/application/run-*`：构建、启动、schema/seed、smoke、服务和清理日志，以及记录 revision、lockfile 摘要、各二进制 SHA-256、镜像和运行时间的 `result.json`。临时密钥/配置在容器和卷清理后删除；清理失败会使测试失败并保留权限受限的 private 目录供清理，不会报告成功。

## 首次完整 App 运行证据

`62046f6cba29d4fee8fab41ef1c0e59716a03dcd` 在固定 Linux Swift 6.4 镜像的四个 Release 产品构建与基础协议冒烟退出 0。证据目录：`/Users/yyl/.codex/virtual-actor-builds/application/run-a5c3d875a8944f90aff928da7e770708`。`result.json` 保存源码、锁文件与四个二进制摘要；`smoke.log` 确认注册/凭据、Gateway 私聊发送与接收方日志、禁用账号、TLS 1.3 和私有指标全部通过；本任务 Compose 资源与临时密钥已清理。

后续脚本还会调用独立 `verify_v2_virtual_actor_http_paths.py`，覆盖 HTTP 昵称、邀请审批、媒体上传、Gateway 群消息媒体关联和 HTTP 授权下载。群本身由可丢弃 SQL fixture 创建，不能将其声称为 TCP 群创建验收。新增路径随后已在 `3cfe62bb297a83f9cd7dd8ed4e59b2fa23747d70` 的完整 Linux Release 栈退出 0：`/Users/yyl/.codex/virtual-actor-builds/application/run-ad5c673efe8a4cb08c70467449810053`，`actor-http-smoke.log` 为 `ACTOR_HTTP_SMOKE_OK nickname invitation media_send_download`。此轮也重跑通过基础协议，临时资源全部清理；没有替代完整群创建与多 Host 故障验收。
