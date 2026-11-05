# 账号通知待办与预留推送接口

更新：2026-11-05。APNs 可见提醒按用户要求尚未接入；不要把通知入队当作手机推送成功。

## 当前生产组合

```text
房间 Actor 接受事务：房间日志 + room_dispatch_outbox
  → 有界派发：按提交时成员区间分页
  → 账号事务：去重回执 + 个人 room_head + 同步唤醒 + account_notification_outbox
  → 账号通知 Worker：未配置 delivery，只清理 24 小时前的过期项
```

无在线连接或在线房间订阅，也会产生账号变化和非发送者的通知待办。源确认丢失时，
目标持久回执防止重复分配个人序号或重新生成已消费通知。通知的成员修订、房间序号
只是来源事实，不能直接作为未来推送或正文读取的授权。

待办在用户分片，源派发在房间分片。Gateway 为每个物理用户库启动独立清理；一次最多
128 行，跳过活跃租约，积压时持续分批清理。`account_notification_expired` 只记录计数。
源派发失败保留任务并退避；`room_dispatch_page_retry` 记录重试页数。

## 检查

在相应分片上检查以下计数和最老年龄，不输出消息内容或设备凭据：

```sql
SELECT count(*), min(created_at) FROM im_v2.room_dispatch_outbox;
SELECT count(*), min(created_at) FROM im_v2.account_notification_outbox;
SELECT count(*) FROM im_v2.account_notification_outbox WHERE claim_token IS NOT NULL;
```

当前预留模式下，通知待办增长至保留窗口是预期行为；应按实际消息扇出量评估容量。
不允许通过清空源派发队列来消除积压，这会丢失个人增量责任。通知过期清理不会删
个人或房间日志，不影响下一次登录后的补读。

## 后续接入

实现并注入 `V2AccountNotificationDelivering` 前，必须实现设备计划去重、当前权限及
偏好、已读、设备撤销、端点代次和限流策略。返回 `accepted` 表示下游持久接手任务，
不是终端展示；抛错或返回 retry 会保留任务并退避。取消保留租约供到期恢复，旧租约
不能确认新工作。

现有 `V2APNSPushWakeProvider` 仅发送静默 wake，不能直接用它替代 alert。APNs Key ID、
Team ID、密钥与 endpoint envelope key 沿用配置边界；本轮不要求提供或联网验证。
旧 `mention_wake` 活动不会自动启用可见通知，旧提及意图和 relay 已删除。
