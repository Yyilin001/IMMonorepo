# B06 当前角色权限基线

更新：2026-09-06。领域模型、PostgreSQL 当前态读取、owner 路由、protocol 25 网关请求和客户端传输已接通。客户端各角色效果与旧正权限行迁移已实现，见[角色效果合同](role-policy-effect-contract.md)；完整基线的[持久请求和合并存储](role-policy-recovery-store-contract.md)已实现，[自动 runner 与 App 生命周期](role-policy-recovery-runner-contract.md)已接通，[暂停反馈和显式重试入口](role-policy-recovery-ui-contract.md)已接通，真实链路及人工交互验收仍待完成，B06 仍为实施中。

## 为什么不能只回放个人快照

客户端旧库没有各角色的独立 revision，空集合又可能被当作未设置策略。个人快照不会替换独立 room_log/hybrid 的可见状态；房间历史还受成员加入范围限制。因此历史不足时必须获取当前有效策略，不能把缺失记录解释为默认权限，也不能任意制造某个角色的历史事件版本。

## 已实现的数据与读取合同

`V2GroupRolePolicyBaseline` 包含 room ID、读取点的 permission revision、membership revision、room sequence，以及 admin/member 的完整有效权限集合。两个角色都必须提供；空集合表示禁止全部权限。permission revision 为正数；membership revision 和房间序号可以为零，三者都受 Int64 范围限制。

基线的 permission revision 表示观察完整房间策略的读取点，不表示两个角色都在这一版本产生了修改事件。后续客户端必须用它建立基线下限，不能把它伪装成两个 sourceEventID 或历史 room event。

`PostgresV2GroupRolePolicyBaselineStore` 用一条 SQL 读取房间版本、当前成员资格、持久显式策略标记和权限行，因此这些值来自同一个 PostgreSQL MVCC snapshot。仅 group room 可以读取；非当前成员不能取得返回值。上层仍须认证设备，本接口不把裸 actor ID 当作设备认证证明。

有效权限按当前授权 resolver 的语义生成：有非空行时返回这些权限；有显式策略标记但没有权限行时返回空集合；两者都没有时才使用默认权限。读取不依赖可清理的幂等操作回执、用户投影 worker 或过滤后的历史事件。未知角色/权限、重复条目和非法版本作为持久化错误拒绝。

`V2RoutedGroupRolePolicyBaselineStore` 的公共构造器接收控制库，并直接创建不缓存的 PostgreSQL router；普通缓存路由提示不能满足恢复读取的版本检查。它使用当前 room owner，传递原 actor 和 room，并验证返回 room。读取结束后再次查询控制库、比较 owner/epoch；变化时返回 route conflict，不尝试旧 owner 或默认 owner。内部 router 注入仅用于确定性测试。此处只保证这次读的选址检查，未宣称完成整个 owner 迁移协议。

## 后续客户端接入要求

1. 已接入认证网关请求、响应解码与运行时选址；后续恢复 worker 使用该传输，并处理成员撤销和路由变化错误。
2. 持久记录需要修复的 room/role，保留 outbox 和现有消息数据；旧状态未知时不能展示成确定的默认策略。
3. 在客户端事务中校验 room、账号/设备生命周期及 membership fence，按基线读取点合并两类角色策略，再回放更新事件。晚到的旧基线不能覆盖更高版本事实。
4. 显式空集合现已保存为独立版本行；各角色版本用于 reducer 比较，房间全局 revision 继续用于命令的 expectedRevision。基线现已使用单独的观察点下限，不伪造历史事件 revision。
5. 覆盖个人流、前台预览、独立房间流、快照、旧库缺历史、退群重入和恢复过程中的网络失败；不能因基线恢复扩大历史消息可见范围。

基础读取批保持 protocol 24、PostgreSQL schema 18 与 SQLite 167/5；后续 wire 批升至 protocol 25，数据库结构未变。尚未部署，客户端与网关须配套升级，不宣称支持混合协议运行。基础读取验证和源码绑定记录在[权限基线证据](../../docs/reviews/verification-records.md#20260906-policy-baseline)。

最终 Core **82 项 / 25 套件**、服务端定向回归 **29 项 / 6 套件**通过。真实 PostgreSQL 覆盖普通/混合群模式、默认和显式空策略、回执清理、迁移、32 次读取与四次策略提交并发、退群重入，以及读取后控制库 epoch 变化。首轮发现合法零 membership revision 被模型拒绝；后续并发测试触发夹具准入额度不足，两者均已修正并保留失败日志。基线本身尚未做实际跨物理 owner 切换或网络协议验收，未重跑 App/ClientKit 全套。

## protocol 25 接线

帧命令 107/108 对应 GetGroupRolePolicyBaseline/GroupRolePolicyBaseline。请求仅携带 room ID，actor 来自已认证会话；网关在 interactiveRead 准入通道执行，命令成本为 2。运行时为配置的各群 owner 创建读取 store，并强制使用控制库上的无缓存路由复核。

响应包含房间、三个版本/序号及恰好 admin/member 两项策略；即使为空也保留角色项。客户端拒绝缺角色、重复角色、owner 角色、未知/重复权限、版本越界、房间不匹配、request ID 不匹配及协商版本不匹配。通用 requestEnvelope 现同时验证响应 request ID、envelope 协议版本和帧版本。

当前成员已撤销映射为 FORBIDDEN；房间不存在为 NOT_FOUND；owner epoch 变化为可重试 ROOM_OWNER_CHANGED；持久化或 owner 配置错误为可重试 UNAVAILABLE。非法 room UUID 在调用存储前返回 INVALID_ARGUMENT。仅 fetch 不写 SQLite，不会清除恢复意图、更新权限或触碰待发命令。

认证前及设备撤销后的请求拒绝、身份转发、空策略、错误映射和读准入均有回归。失败/成功日志与源码绑定见[协议接线证据](../../docs/reviews/verification-records.md#20260906-policy-wire)。测试包括编解码与会话、领域、真实 SQL 分层验证，未把它称为真实 TLS 网络的完整端到端验收。
