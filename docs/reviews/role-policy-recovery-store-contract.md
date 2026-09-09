# B06 权限基线的客户端持久恢复存储

更新：2026-09-06。本批完成持久请求、完整策略观察点及本地事务栅栏。后续自动重试 runner 和 App 生命周期接线见[执行器合同](role-policy-recovery-runner-contract.md)；下文保留本存储批的验证范围。

## 请求和事务栅栏

`requestRolePolicyBaseline` 由本地 store 创建请求，绑定 room、安装标识、账户 ID、成员 revision、成员事件来源和个人同步 generation。相同栅栏下重复请求复用持久 request ID，响应丢失或重启不会删除意图。请求对象标识本地意图，不是服务端授权或网络读取证明。

`enqueueMissingRolePolicyBaselines` 每次处理 1–100 个房间，默认 32 个；发现缺基线房间或更新旧栅栏下的请求，排除仍有效的已有请求以便后续扫描推进。它还按同一上限清理已失去本地授权房间的请求。未绑定账户、无房间授权或正在 reset 的 store 不启动恢复。runner 仍需调度这些接口。

`completeRolePolicyBaseline` 在同一 SQLite 写事务中重新检查持久请求、账号/安装绑定、房间授权、成员版本/事件身份和同步代次。栅栏变化返回 false，不改权限或新请求；reset 期间明确返回 resetPending。响应 room 必须匹配，远端 membership revision 不得落后于请求捕获的本地值。

本人退群和 `markRoomEventUnauthorized` 清除对应请求与观察点；重新加入后新请求有新的身份和成员栅栏。本人判断与清除前先规范化 UUID，避免服务端小写 UUID 无法匹配本地大写账户 ID。账号绑定检查在实际数据库中完成，不只比较调用方传入的值。认证设备的撤销与连接停止仍须由后续 runner/runtime 集成负责。

## 观察点与角色事件

`v2_group_role_policy_baselines` 独立保存 room、permission revision、membership revision、room sequence 和 admin/member 两套完整集合。它不生成 sourceEventID，不把全局读取 revision 写成两个角色的历史事件 revision。

读取权限时，角色事件高于观察点的版本优先；其余角色采用基线的完整值，空集合仍为明确禁止。房间全局命令 revision 不回退。基线观察点以下的迟到事件仍记录并验证 receipt，但不改变可见策略；恰好相同 revision 的事实必须与基线对应角色的集合一致。

较旧基线不能覆盖较新观察点，也不能清除恢复意图。相同基线 revision 的不同集合、与已知同版本角色事实冲突、较新观察点的成员版本或房间序号倒退均拒绝。相同策略版本下只选择可比较的真实读取点，不把不同读取的元数据拼成一个虚构观察点。

## 快照和迁移

请求表在 snapshot bank 外持久保存；代次切换后的旧请求不能写入，可通过发现接口更新栅栏。观察点属于投影 bank，只为新快照仍授权、且 live/incoming 成员版本与来源一致、基线成员版本不超出新视图的房间保留。相应覆盖范围内的已知 receipts 也保留，防止历史事件换内容后被重新接受。观察点不授予历史消息访问权。

追加 `recordRolePolicyRecovery` 迁移创建两张表，将主 schema 从 168 增至 **170** 个对象，搜索库仍为 **5**；主库指纹为 **0xfda1ba89465de725**。旧 staging 或 prepared snapshot 清除导入状态后从相同 artifact 重新导入，live 投影、待发命令和 pending reset 保留。迁移本身不发网络请求。

## 验证和剩余工作

真实 SQLite 回归覆盖持久请求重启、缺失角色填充、读取期间新事件、旧响应保留意图、同版本冲突、成员变化、本人退群/重入、房间授权撤销、数据库账号/安装标识变化、reset/代次切换、快照保留/移除房间及两种 staging 阶段的迁移。日志和源码绑定见[恢复存储证据](evidence/20260906-policy-recovery-store/manifest.json)。

自动发现与重试调度、网络取消/失败分类、服务端 FORBIDDEN 后的处理、认证设备/连接生命周期和 App 调用仍待实现。缺失角色的自动获取尚未完成；置顶、成员角色和完整 receipts 保留/清理合同仍开放。protocol 25、PostgreSQL 18 未变，没有部署。
