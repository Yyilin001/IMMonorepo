# App 进程中断后的注册取消恢复

对应 B08。本批针对真正跨 App 进程、由 Keychain 保留状态的恢复路径；不把受控终止扩大为所有 OS 中断或真机锁屏验收。

## 故障注入

新增可选命令：

```sh
python3 scripts/verify_v2_live_account_authorization.py --output <new-evidence-directory> --current-logout --app-ui --gateway --headless-app --interrupted-issuance --load-credentials
```

所有操作发生在临时 PostgreSQL、原生账号服务、HTTPS 代理和新建专用模拟器中。代理只对本测试新注册的 `interrupt_<20位随机后缀>` 账号设备注入故障，普通签发和取消仍由实际服务处理。

1. App 保存注册证明后发起签发。代理读到真实账号服务的 200 响应，保留全部响应字节，不向 App 转发。
2. XCTest 在点击完成后发出测试代理就绪信号；代理通过 `simctl terminate <owned-simulator> com.stskcxfz.imapp` 终止 App，XCTest 确认其状态为 notRunning。
3. 使用相同测试 scope 重启 App。冷启动从真实 Keychain 读取原证明并自动取消。
4. 代理收到真实取消 204 后再次保留响应字节，等待 XCTest 完成 launch，然后再终止 App。
5. 再次重启。App 从 Keychain 恢复未完成任务，使用完全相同的四字段证明重放，得到 204 后完成本地任务；新登录成功且使用新设备 ID。

测试代理的 readiness 控制只协调测试动作，不加入生产接口，不提供账号或凭据，不替代服务端授权。证明和返回凭据只在代理内存中比较，不写入证据日志。没有在故障路径调用 App.signOut 或代替 App 写入 Keychain。

## 独立核对

UI 用例观察两次进程终止与重新登录。代理记录签发终止一次、取消终止一次、重放一次和完整证明相等。数据库按原设备单独核对：该账号共两个设备，原设备已撤销，原证明一条取消记录、一个撤销事件，原设备无有效 access/refresh。全库同时核对相邻授权测试的设备与事件总量。

## 本批修复的编码缺陷

命令行工具此前将 cancellation.deviceID 编成字符串，而 IMV2Core 的 Codable 合同实际为 `{"rawValue":"UUID"}`。原有脚本离线测试同样假设字符串，因此没有发现不兼容。已修正 Python 证明准备工具和本批离线夹具，保持历史证据不变。

新增 `--load-credentials` 会调用真实 `prepare_v2_gateway_load_credentials.sh`，验证输出确认了已保存证明，然后用输出的访问凭据读取设备列表、用保存的证明取消、再次访问被拒绝。原脚本输出和恢复证明放在临时目录，完成后与该测试数据库一起清理。没有运行或修改现有 Docker 栈。

## 边界

证据位于 [本批目录](evidence/20260907-registration-process-interruption/manifest.json)。本批修改验证工具、UI 测试和命令行证明编码；没有修改 Swift 认证/取消生产逻辑。

`simctl terminate` 证明实际 App 进程边界与 Keychain 恢复，不等同于设备断电、OS jetsam、SIGKILL、首次解锁前或真实锁屏行为。旧版本会话/legacy 档案清理、其他退出/换号检查点、真机系统中断和保留/GC 仍未完成，B08 不关闭。
