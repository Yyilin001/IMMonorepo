# 本地 Swift 6.4 兼容及消息路径补丁

此目录基于 PostgresNIO 1.33.1，原始修订为
`39ce38a93408937bcd27f521f3cdf88266136b80`。
`UPSTREAM.json` 记录纳入仓库的文件及其 SHA-256 校验值；原始 `LICENSE`
和 `NOTICE.txt` 继续适用。校验值对应包含下述本地补丁的源码。

## Swift 6.4 兼容

`ConnectionStateMachine.swift` 中的 `AuthContext.==` 在检查数量后，显式逐项比较
有序键值对。Swift Collections 1.6 的实验性 `BorrowingSequence_` 增加了
`elementsEqual(_:by:)` 重载，导致已发布的 Swift 6.4 Linux 工具链出现歧义。
显式循环保留了顺序、重复键以及首个差异返回 false 的语义。

不能直接换用 Collections 1.7：其预览 API 删除了 AsyncStreaming 1.1.5 仍使用的
`Optional.borrow()`。

## 已有消息路径优化

提交 `47029ea2` 引入的以下补丁仍然保留：

- `AutomaticPreparedQueryCache.swift`、连接配置和查询分发增加按物理连接保存的
  有界预备查询缓存。缓存须显式启用；不匹配配置 SQL 前缀的查询沿用上游分发路径。
- `PostgresConnection.swift`、`PSQLTask.swift`、`PostgresChannelHandler.swift`
  和 `ConnectionStateMachine.swift` 增加 ReadyForQuery 确认。它在此前已注册工作
  完成后返回数据库事务状态，不额外发送 SQL，也不把 idle 状态视为查询成功证明。

本次补齐上述新增文件和已修改文件的校验记录，没有改变驱动行为。
其他上游源码、包配置和测试保持原样。根包的本地依赖会覆盖传递依赖中的远程
PostgresNIO 身份，正常构建不需要修改 `.build` 或使用远程 fork。

上游发布能兼容当前 Vapor 依赖图的版本后，才可移除此目录并恢复远程依赖。
修改版本固定值前，应重新验证 Linux 构建、PostgreSQL 会话／事务测试及应用兼容性。
