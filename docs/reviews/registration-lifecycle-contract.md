# 注册身份与重新登录

2026-09-07，B08 的客户端注册身份阶段。App 已切换至 `V2DeviceRegistrationStore`，注册成功后的新登录不再复用安装级固定 device ID；本地数据库的安装绑定仍独立存在。完整退出 checkpoint、App 当前设备撤销接线和离线补偿尚未完成，B08 保持实施中。

## 当前合同

- App 每个凭据命名空间持有一个注册记录 owner。device ID 与 operation ID 在请求账号断言之前，作为同一条记录持久化到 device-only Keychain；临时不可访问或数据损坏时不发布新身份。
- 按规范化账号的摘要隔离待完成记录。同账号重试复用原两个 ID，换账号不覆盖先前中断的注册。摘要只是本地查找键，不是认证凭据或匿名性证明；账号明文与密码不写入该记录。
- 准备结果是绑定具体记录的不可变对象，供原 HTTP issuer 同时获取身份和注册操作。完成动作只有在账号槽仍匹配完整记录时才删除；迟到的旧完成和旧 save 不能清除或恢复后来创建的记录。Keychain 读写在同一个 actor 内没有挂起点；该合同要求同一命名空间只有一个 App 注册 owner。
- 凭据成功持久化后，既有 bootstrapper 调用 issuer finalizer，移除完成的注册。下一次登录生成新 device ID 和 operation ID。显式本地退出在认证任务已失效、凭据删除之后清除未完成注册，失败保留退出待完成状态；测试域清理也移除该 Keychain 项。
- App 在异步注册准备前捕获认证 epoch，并在恢复执行时检查 UI 登录代次。bootstrapper 开始签发前再次向 auth owner 验证原 epoch；已经完成的退出不能被一个尚未开始签发的旧登录任务撤销。

原固定身份 provider 不再用于 App 登录。当前绿地工程未为旧注册记录添加账号归属推断或跨版本迁移；新记录独立使用 `device-registration-ledger-v1`。没有修改 protocol 27、PostgreSQL 25 或 SQLite 173/5。

## 验证

客户端最终完整回归报告 **416 项 / 65 套件，411 项实际执行、5 项在线测试跳过，4.594 秒**。新记录测试覆盖 owner 重建、规范化账号、身份更新、账号隔离、旧完成/旧保存、读取、写入与删除失败、损坏和未知版本。原响应丢失测试已改为组合真实注册 owner 与 HTTP issuer，重建 owner 后发送新的断言但复用原 device/operation；另有退出先于签发的 epoch 验证。

App 单元回归报告 **193 项 / 19 套件，192 项实际执行、1 项在线测试跳过，5.707 秒**。真实独立 HTTPS/PostgreSQL/TLS Gateway/Keychain/SQLite 组合验证全部通过：

- 2 项 App UI：Gateway 与 HTTP 两种撤销入口均返回登录页、冷启动保持退出，再次输入同账号密码成功登录。服务端设备列表确认新设备不同于已撤销设备，其他设备仍保留。分别耗时 40.759、31.670 秒。
- 5 项真实 HTTPS：包括当前设备撤销的全部 token 失效、并发幂等、数据库 journal 失败回滚，2.743 秒。
- 1 项真实 App host 后台入口：独立 delegate/store 未附着页面，恢复与增量同步、另一设备撤销后退出通过，1.295 秒；这不代表真实 APNs 或系统无 scene 冷启动。

最终数据库 `15|5|0|0|5`：总设备、撤销设备、撤销设备残留有效 access、残留有效 refresh、撤销事件。UI 与后台测试清理后 Gateway 均为 0 连接。临时数据库、私有 CA/密钥和专用模拟器已清除。日志、xcresult 和源码散列见[证据](evidence/20260907-registration-lifecycle/manifest.json)。

## 仍需完成

本阶段证明正常完成注册及已验证中断路径的身份隔离，不代表整个 B08 已关闭。凭据持久化与注册完成记录之间仍有跨 Keychain 项的中断窗口，需要并入完整持久 checkpoint；注册 replay 到期、签发响应未到达时退出、每个 await 前后强杀、真机锁屏仍需覆盖。App 尚未调用当前设备撤销 API，离线仅可撤销能力和远端补偿也尚未实现，不能声称本地退出已经撤销远端会话。
