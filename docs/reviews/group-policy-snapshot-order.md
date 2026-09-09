# 公告与角色权限快照的版本顺序

此批处理 B06 的服务端权威快照前置路径，未宣称完成客户端群控制 reducer。

## 当前合同

- 公告按 room 的公告 revision 排序；权限按 room 和 role 的 policy revision 排序。不同角色共享命令侧 revision 分配器，但快照比较按各自对象进行，允许 revision 有间隔。
- 较旧事实被当前状态覆盖，消费者仍提交该次个人流消费位置。同版本必须来自同一 sourceEventID，并且已解析的领域事实相同；冲突不会替换快照或推进失败记录的 checkpoint。
- 权限集合顺序不参与事实身份；重复权限、未知权限、owner 策略、非正 revision、整数溢出或非法源 room sequence 会被拒绝。
- 空权限保留为当前版本。旧格式或权威 replacement 的空公告也保留 revision，防止迟到的非空公告恢复旧内容；没有新增允许提交空公告的用户命令。
- 旧 payload 没有 room sequence 时仍可使用已有的领域 revision。个人同步 cursor 从不用于对象版本排序；同一事实两份 payload 都有源序号时，两个序号必须一致。

## 验证与边界

测试通过真实群管理命令创建两版公告、非空到空的成员权限和独立 admin 权限，再倒序规划、分发和折叠快照。后续注入无 room sequence 的空公告及迟到旧事实，核对三份对象状态；同版本不同事实必须记录失败并保留 checkpoint 和当前快照。

既有快照与已经丢掉的旧负状态不会在此批凭空回填。新版处理需要统一切换 projection worker，不能让旧 worker 继续无条件覆盖版本。PostgreSQL schema 18、protocol 23、SQLite 结构不变，未部署。

最终 24 项服务端测试、4 个套件通过；失败/成功日志、完整 filter 和十份源码指纹见 [验证记录](evidence/20260906-group-policy-snapshots/manifest.json)。测试数据库已清理并停止。

仍待完成：客户端各持久流的统一效果事务、旧库与 staging 恢复、取消置顶的历史源版本、成员离开和角色更新的版本/授权组合，以及全局保留窗口与代次栅栏。
