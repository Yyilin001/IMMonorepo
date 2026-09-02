# ADR-003：原生 TLS TCP 与客户端发布平台

状态：原生 TLS 方向待发布批准；v20 有界帧压缩已批准实现与容量验证
日期：2026-07-23
所有者：客户端与平台负责人

## 背景与决定

V2 已实现原生 TLS TCP framing 和独立 `IMV2ClientKit`，不复用既有 HTTP/WS
协议。首个可发布客户端的平台、最低系统版本、后台能力、证书链轮换和网络
降级策略尚未批准；因此只接受“原生 TLS TCP 是 V2 实时协议”的方向，不批准
任何平台发布承诺。

## 备选方案

- HTTP/WebSocket：降低接入成本，但与已实现的帧、连接背压和协议模型冲突；
- 平台专属协议：增加多端不一致与测试矩阵；
- 原生 TLS TCP：统一二进制 framing，保留平台网络层适配空间。

## 不变量与后果

- TLS 1.3、帧上限、Protobuf 嵌套深度、单连接 in-flight 上限和 idle timeout
  必须在绑定端口前显式配置；认证成功前不得执行领域命令。
- v19 及以前不协商 payload compression，客户端与服务端必须在 protobuf 解码前
  拒绝所有非零 frame flags。v20 增加显式 `FrameCompression` 握手协商；未协商
  或选择 `UNSPECIFIED` 时仍拒绝压缩标志。
- v20 的 zlib 压缩是一帧一个独立 member，不使用跨帧/跨连接字典状态。编码前
  明文必须受部署帧上限约束；解压必须同时受明文字节上限和最大膨胀比约束。
  握手与认证帧不压缩，服务端只压缩超过阈值且确实变小的响应。双端 codec、
  golden vector、损坏输入、解压炸弹和未协商标志必须有离线自动化测试。
- 压缩只改变 protobuf payload 的 wire representation；授权、请求关联、命令头
  校验、游标连续性和 durable group-event recovery 均保持原有语义。
- v21 的 `GroupEventPage` 可设置 `headerBoundRequestID`：protobuf 内的
  `request_id` 必须为零，解码器只允许该命令使用此标志，并把 TLS 帧头中的
  request ID 注入已验证 envelope。帧头本来就是请求关联权威来源；去除重复字段
  让同一已授权群事件页可以共享序列化/压缩 payload。每个请求仍独立执行当前成员
  资格检查，缓存不得携带或替代授权事实。
- 平台发布前必须明确 iOS/macOS 的 deployment target、后台网络行为、证书
  pinning/轮换策略、网络代理与弱网测试范围。
- V2 首次发布不提供历史兼容层，详见 ADR-000；一旦外部分发，协议演进须另行评审。

## 落地、回滚与复审

批准后补齐平台自动化验证、真机 TLS/后台测试和证书轮换 runbook。首次外部测试版、
新增平台或证书策略变化时复审本 ADR。
