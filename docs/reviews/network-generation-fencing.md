# D01：旧连接回调与新连接隔离

验收对象是同一个 `V2TLSFrameConnection` actor 中，旧连接的接收、发送或取消回调晚于新连接建立时，是否会清理新连接或污染它的帧解码/请求关联。本文对应当前工作区，不代表生产 TLS 证书或部署配置验收。

## 实现边界

- reader 捕获自己的 byte connection 和 generation；`nextFrame` 捕获该代 decoder/state，并在每次异步接收后检查 generation，才追加数据或分发帧。
- reader 的错误通过 `closeTransport(expectedGeneration:)` 处理。旧代无法清除新代 connection、decoder、认证状态或 waiters。
- 请求发送失败、硬截止和取消同时检查 generation 与独立 waiter UUID；请求 ID 被新连接复用时，旧请求的回调不能操作新 waiter。
- `disconnect` 先摘除状态、取消旧 reader/socket，再等待捕获的 reader/send task 完成。等待期间 actor 可建立新连接；旧 reader 不会等待自己，已摘除的 continuation 不会二次完成。

上述生产修复已在前面的批次实现。本批仅补强真实 Network.framework 回调测试与关闭证据。

## 确定性网络交错

`realNetworkOldCallbackIsFenced` 使用实际 `NWListener`、两条 `NWConnection` 和生产 byte adapter。测试端通过 loopback TCP 提供 protobuf 握手及响应；未注入伪造的 receive 错误。

1. 旧连接完成握手后，等待后台 reader 进入接收操作。
2. 暂停旧连接专用 callback queue，启动 disconnect，等待 socket cancel 已调用。
3. 在旧 queue 仍暂停时建立新连接，确认 generation 已改变，且服务端已收到新请求 80；此时旧 receive 失败次数必须是 0。
4. 恢复旧 queue 并等待 disconnect drain 完成，要求旧 receive 恰好失败 1 次且无未结束接收。
5. 服务端此后才回复新请求 80，要求它正常完成。

这补上了原测试可能未启动旧 reader 就取消的覆盖缺口。接收观察器仅位于测试 wrapper 中，生产实现没有增加测试回调或可选的明文连接入口。底层回调队列行为通过真实 TCP 验证，TLS 加密和证书信任不在此用例内；公开 endpoint 初始化仍固定 TLS 1.3 和平台信任校验。

## 验证与复现

证据及精确运行结果见 [manifest](../../docs/reviews/verification-records.md#20260906-network-generation-fencing)。`client-run.sh --filter V2TLSFrameConnectionLifecycleTests` 可复现生命周期套件。

`negative-check.py` 会临时移除唯一的 generation close guard，运行上述实际网络测试，并在 `finally` 中恢复原文件。不要与构建或源文件编辑并行执行。此反向控制用来确认测试确实能发现旧 reader 误关新连接；不代表重新发现了当前生产实现中的缺陷。

其余生命周期用例覆盖旧半帧/迟到读取错误、旧 send failure 与请求 ID 复用、取消后的晚响应和容量、硬截止、未登记响应、旧 TaskLocal generation 与取消 hint consumer。完整客户端回归同时检查协调器、账号 session、同步和 durable command 行为。
