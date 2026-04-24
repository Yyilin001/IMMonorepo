# IMApp

`IMApp` 是一个基于 SwiftUI 构建的 iOS IM 客户端，用来对接 `IMServer`，完成登录认证、设备会话管理、会话列表、聊天详情、实时消息收发、历史拉取、增量补洞和文件传输等基础能力。

项目当前重点不是做视觉包装，而是把一条真实可运行的 IM 链路在 iOS 端落通：HTTP 负责登录与数据接口，TCP 负责实时消息和连接状态。

## 项目定位

- iOS 端登录与设备会话管理
- 会话列表和聊天详情页
- HTTP 历史消息拉取
- TCP 实时收发与重连
- 断线后的消息补洞同步
- 已读上报与未读校正
- 文件上传/下载演示链路

## 当前能力

### 认证与会话

- 注册 / 登录 / refresh
- 当前设备退出
- 退出全部设备
- 指定设备踢下线

### IM 能力

- TabView 首页结构
- “消息”页展示真实会话列表
- 进入会话详情后查看历史消息
- 基于 TCP 的实时消息接收与发送
- 断线重连后的 `messages/since` 增量补洞
- 已读节流上报
- 本地未读增量与服务端摘要未读合并

### 文件能力

- 上传文件到服务端
- 下载服务端最近一次上传文件

## 技术栈

- Swift
- SwiftUI
- URLSession / 自定义 HTTPClient
- 自定义 TCP client
- XCTest

## 目录结构

```text
IMApp/App                App 级配置与 AppDelegate
IMApp/Auth               登录态、token、AuthManager
IMApp/Networking         HTTP / TCP / 传输封装
IMApp/Services           API 请求模型
IMApp/Features/Auth      登录页面
IMApp/Features/Home      首页、设备管理、文件传输、探测
IMApp/Features/IM        会话列表、会话详情、会话状态存储
IMAppTests               单元测试与测试支撑
IMAppUITests             UI 测试入口
```

## 运行要求

- Xcode 16+
- iOS Simulator
- 本地已启动 [IMServer](https://github.com/Yyilin001/IMServer)

## 环境配置

客户端不再从 `IMClientKit` 读取默认地址，服务端地址统一由 `IMApp` 在组合根注入。当前本地开发配置定义在 [AppNetworkConfiguration.swift](/Users/yy/Desktop/vaporTest/IMApp/IMApp/App/AppNetworkConfiguration.swift:1)：

```swift
static let local = AppNetworkConfiguration(
    apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
    imTCPHost: "127.0.0.1",
    imTCPPort: 9000
)
```

应用入口会在 [IMAppApp.swift](/Users/yy/Desktop/vaporTest/IMApp/IMApp/IMAppApp.swift:12) 里显式构造 `NetworkEnvironment` 和 `IMTCPClientConfiguration` 后注入 `AuthManager`。如果你不是本机联调，只需要改这里的配置源。

## 快速开始

### 1. 启动服务端

先启动 `IMServer`，确保：

- HTTP 可访问：`http://127.0.0.1:8080`
- TCP IM 端口可连：`127.0.0.1:9000`

### 2. 打开工程

用 Xcode 打开 `IMApp.xcodeproj`。

### 3. 运行客户端

选择 iPhone 模拟器，直接运行 `IMApp` scheme。

## 交互模型

### 首页结构

当前应用采用 `TabView`：

- 首页
- 消息
- 文件
- 设备

### 消息页

消息页不是 demo 式的单页堆叠，而是更接近正式 IM 的结构：

- 首屏显示会话列表
- 点击会话后进入聊天详情
- 会话详情里负责历史消息、发送、已读推进

### 数据流拆分

- HTTP
  负责认证、分页会话摘要、增量摘要变更、历史消息、补洞、成员列表、mark read、文件接口
- TCP
  负责握手鉴权、实时消息、heartbeat、ack、kick

### 消息协议

消息内容已经从弱类型的 `kind + body` 收紧成强类型 `content`。当前文本消息统一编码为：

```json
{
  "type": "text",
  "text": "hello"
}
```

这套结构会同时用于：

- TCP 实时消息
- 会话历史接口
- `messages/since` 补洞接口
- 会话列表里的最后一条消息预览

## 当前实现重点

这个客户端目前已经把几条关键链路接通了：

- 登录后自动建连 TCP
- 登出时主动断开连接
- 被服务端 kick 时回到登录失效状态
- 会话页接入真实 `conversationID`
- 重连后自动做增量补洞
- 已读采用“最高序号合并后上报”的节流策略，避免实时消息连续到达时每条都请求 `/read`
- 会话摘要首屏分页拉取与后续增量同步

## 测试

当前仓库包含较完整的单元测试，覆盖了：

- `SessionClient`
- `AuthManager`
- `IMConversationStore`
- TCP / HTTP / 文件传输相关支撑逻辑

在 Xcode 中直接运行测试，或者使用：

```bash
xcodebuild test \
  -project IMApp.xcodeproj \
  -scheme IMApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

如果本机模拟器名称不同，请改成你自己的 destination。

## 当前状态

`IMApp` 已经不是纯 demo UI，而是一个正在成型的 IM 客户端工程。它已经具备真实的前后端链路，但还没有进入“可上线产品”阶段。

当前还未完整覆盖的方向包括：

- 更完整的 UI/视觉打磨
- 多媒体消息
- 群会话高级管理
- 更细粒度的未读模型
- 离线缓存和持久化
- 完整 push 通知链路

## 配套服务端

配套后端仓库：

- [IMServer](https://github.com/Yyilin001/IMServer)

## Roadmap

- 继续收紧未读与已读状态模型
- 增强历史分页和自动加载体验
- 扩展消息类型与附件能力
- 引入更清晰的本地持久化边界
- 为未来更正式的产品 UI 做分层准备
