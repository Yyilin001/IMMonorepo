# 验证运行记录索引

这些运行记录是整改期间在**本机**执行的测试、数据库回归和模拟器验收。**记录本身没有纳入版本控制**——
仓库里只有结论和复现范围。本页把它们集中列出，避免合同文档里散落指向不存在文件的链接。

## 这些记录能证明什么

- 每条记录对应一次实际执行，覆盖范围写在引用它的合同文档的验证小节里。
- 记录是**分层证据**，不等于生产就绪；证据等级的判定见
  [当前实现与发布证据](../../IMV2/docs/implementation-status.md)。
- 未覆盖的场景在合同文档里显式列出，不因为某条记录通过就关闭。

## 如何复现

```sh
# 分层测试（Core / ClientKit / Server package）
bash scripts/run_v2_swift_tests.sh

# 本机 PostgreSQL 集成
bash scripts/run_v2_postgres_integration.sh

# 唯一本地总门禁：分层测试、schema、双 PostgreSQL、iOS 构建与测试
bash scripts/verify_v2.sh
```

## 记录清单


共 89 条运行记录。

### 20260905-forward-delivery

- 日期：2026-09-05
- 主题：forward-delivery
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/status.md`）

### 20260905-forward-receipts

- 日期：2026-09-05
- 主题：forward-receipts
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/status.md`）

### 20260906-account-rate-limit-boundaries

- 日期：2026-09-06
- 主题：account-rate-limit-boundaries
- 引用文档：2 份（`docs/reviews/account-rate-limit-integer-boundaries.md`, `docs/reviews/archive/2026-09-05-remediation-timeline.md`）

### 20260906-announcement-effects

- 日期：2026-09-06
- 主题：announcement-effects
- 引用文档：3 份（`docs/reviews/announcement-effect-contract.md`, `docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`）

### 20260906-app-gateway-authentication

- 日期：2026-09-06
- 主题：app-gateway-authentication
- 引用文档：2 份（`docs/reviews/app-gateway-authentication-termination.md`, `docs/reviews/archive/2026-09-05-remediation-timeline.md`）

### 20260906-approval-recovery-evidence

- 日期：2026-09-06
- 主题：approval-recovery-evidence
- 引用文档：1 份（`docs/reviews/approval-recovery-evidence-contract.md`）

### 20260906-atomic-group-approval

- 日期：2026-09-06
- 主题：atomic-group-approval
- 引用文档：1 份（`docs/reviews/atomic-group-approval-contract.md`）

### 20260906-background-network-deadlines

- 日期：2026-09-06
- 主题：background-network-deadlines
- 引用文档：4 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-plan.md`, `docs/reviews/bounded-incremental-sync-contract.md` 等）

### 20260906-bounded-incremental-sync

- 日期：2026-09-06
- 主题：bounded-incremental-sync
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/bounded-incremental-sync-contract.md`）

### 20260906-client-timestamp-boundaries

- 日期：2026-09-06
- 主题：client-timestamp-boundaries
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/client-timestamp-integer-boundaries.md`）

### 20260906-current-device-logout

- 日期：2026-09-06
- 主题：current-device-logout
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/current-device-logout-contract.md`）

### 20260906-durable-retry-network

- 日期：2026-09-06
- 主题：durable-retry-network
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/durable-retry-network-contract.md`）

### 20260906-durable-sign-out-marker

- 日期：2026-09-06
- 主题：durable-sign-out-marker
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/durable-sign-out-marker-contract.md`）

### 20260906-edit-policy-commit-ordering

- 日期：2026-09-06
- 主题：edit-policy-commit-ordering
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/edit-policy-commit-ordering.md`）

### 20260906-forward-import-owner

- 日期：2026-09-06
- 主题：forward-import-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/forward-import-owner-fence-contract.md`）

### 20260906-forward-operator

- 日期：2026-09-06
- 主题：forward-operator
- 引用文档：4 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/forward-operator-replay.md`, `docs/reviews/forward-source-authorization.md` 等）

### 20260906-forward-runtime

- 日期：2026-09-06
- 主题：forward-runtime
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/forward-source-authorization.md`, `docs/reviews/status.md`）

### 20260906-group-approval-recovery

- 日期：2026-09-06
- 主题：group-approval-recovery
- 引用文档：1 份（`docs/reviews/group-approval-recovery-contract.md`）

### 20260906-group-capability-owner

- 日期：2026-09-06
- 主题：group-capability-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/group-capability-owner-fence-contract.md`）

### 20260906-group-policy-retention

- 日期：2026-09-06
- 主题：group-policy-retention
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/group-control-effect-contract.md`, `docs/reviews/group-policy-retention.md`）

### 20260906-group-policy-snapshots

- 日期：2026-09-06
- 主题：group-policy-snapshots
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/group-policy-snapshot-order.md`）

### 20260906-group-source-versions

- 日期：2026-09-06
- 主题：group-source-versions
- 引用文档：1 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`）

### 20260906-headless-push-entry

- 日期：2026-09-06
- 主题：headless-push-entry
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/headless-push-entry-contract.md`）

### 20260906-invitation-applicant-quota

- 日期：2026-09-06
- 主题：invitation-applicant-quota
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/invitation-applicant-quota-contract.md`）

### 20260906-invite-creation-recovery

- 日期：2026-09-06
- 主题：invite-creation-recovery
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/group-invite-creation-recovery-contract.md`）

### 20260906-invite-directory

- 日期：2026-09-06
- 主题：invite-directory
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/group-invite-directory-contract.md`）

### 20260906-invite-directory-import

- 日期：2026-09-06
- 主题：invite-directory-import
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/group-invite-directory-import-contract.md`）

### 20260906-legacy-invite-retry

- 日期：2026-09-06
- 主题：legacy-invite-retry
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/group-invite-legacy-binding-contract.md`）

### 20260906-legacy-media-authorization

- 日期：2026-09-06
- 主题：legacy-media-authorization
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/legacy-media-authorization-contract.md`）

### 20260906-live-account-https

- 日期：2026-09-06
- 主题：live-account-https
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/live-account-https-authorization.md`）

### 20260906-local-forward-owner

- 日期：2026-09-06
- 主题：local-forward-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/foreground-forward-owner-fence-contract.md`）

### 20260906-member-role-snapshots

- 日期：2026-09-06
- 主题：member-role-snapshots
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/member-role-snapshot-contract.md`）

### 20260906-membership-owner-fence

- 日期：2026-09-06
- 主题：membership-owner-fence
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/room-membership-owner-fence-contract.md`）

### 20260906-message-audience

- 日期：2026-09-06
- 主题：message-audience
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-mutation-audience-contract.md`）

### 20260906-message-delivery-authority

- 日期：2026-09-06
- 主题：message-delivery-authority
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-mutation-delivery-authority-contract.md`）

### 20260906-message-edit-replacement

- 日期：2026-09-06
- 主题：message-edit-replacement
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-edit-replacement-contract.md`）

### 20260906-message-effects

- 日期：2026-09-06
- 主题：message-effects
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/status.md`）

### 20260906-message-mutation-owner

- 日期：2026-09-06
- 主题：message-mutation-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/message-mutation-owner-fence-contract.md`）

### 20260906-message-read-authority

- 日期：2026-09-06
- 主题：message-read-authority
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-mutation-read-contract.md`）

### 20260906-message-reference-visibility

- 日期：2026-09-06
- 主题：message-reference-visibility
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-reference-visibility-contract.md`）

### 20260906-message-terminal-projection

- 日期：2026-09-06
- 主题：message-terminal-projection
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/message-terminal-projection-contract.md`）

### 20260906-moderation-owner

- 日期：2026-09-06
- 主题：moderation-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/moderation-owner-fence-contract.md`）

### 20260906-network-generation-fencing

- 日期：2026-09-06
- 主题：network-generation-fencing
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/network-generation-fencing.md`）

### 20260906-password-hash

- 日期：2026-09-06
- 主题：password-hash
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/password-hash-contract.md`）

### 20260906-personal-snapshot-rebuild

- 日期：2026-09-06
- 主题：personal-snapshot-rebuild
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/personal-snapshot-rebuild.md`）

### 20260906-pin-effects

- 日期：2026-09-06
- 主题：pin-effects
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/pin-effect-contract.md`）

### 20260906-pin-snapshots

- 日期：2026-09-06
- 主题：pin-snapshots
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/pin-snapshot-contract.md`）

### 20260906-policy-baseline

- 日期：2026-09-06
- 主题：policy-baseline
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/group-policy-baseline-contract.md`）

### 20260906-policy-recovery-store

- 日期：2026-09-06
- 主题：policy-recovery-store
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/role-policy-recovery-store-contract.md`）

### 20260906-policy-recovery-ui

- 日期：2026-09-06
- 主题：policy-recovery-ui
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/role-policy-recovery-ui-contract.md`）

### 20260906-policy-runner

- 日期：2026-09-06
- 主题：policy-runner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/role-policy-recovery-runner-contract.md`）

### 20260906-policy-wire

- 日期：2026-09-06
- 主题：policy-wire
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/group-policy-baseline-contract.md`）

### 20260906-profile-projection-boundaries

- 日期：2026-09-06
- 主题：profile-projection-boundaries
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/profile-and-projection-integer-boundaries.md`）

### 20260906-push-intent-app

- 日期：2026-09-06
- 主题：push-intent-app
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-app-contract.md`）

### 20260906-push-intent-auth

- 日期：2026-09-06
- 主题：push-intent-auth
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-auth-contract.md`）

### 20260906-push-intent-http

- 日期：2026-09-06
- 主题：push-intent-http
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-http-contract.md`）

### 20260906-push-intent-local

- 日期：2026-09-06
- 主题：push-intent-local
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-local-contract.md`）

### 20260906-push-intent-reconciler

- 日期：2026-09-06
- 主题：push-intent-reconciler
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-reconciler-contract.md`）

### 20260906-push-intent-storage

- 日期：2026-09-06
- 主题：push-intent-storage
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/push-intent-contract.md`）

### 20260906-reaction-effects

- 日期：2026-09-06
- 主题：reaction-effects
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/status.md`）

### 20260906-read-receipt-owner

- 日期：2026-09-06
- 主题：read-receipt-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/read-receipt-owner-fence-contract.md`）

### 20260906-role-policy-effects

- 日期：2026-09-06
- 主题：role-policy-effects
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/role-policy-effect-contract.md`）

### 20260906-routed-invitation

- 日期：2026-09-06
- 主题：routed-invitation
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/group-invitation-owner-routing-contract.md`）

### 20260906-scoped-media

- 日期：2026-09-06
- 主题：scoped-media
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/forward-source-authorization.md`, `docs/reviews/status.md`）

### 20260906-send-owner

- 日期：2026-09-06
- 主题：send-owner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/send-message-owner-fence-contract.md`）

### 20260906-session-http-authorization

- 日期：2026-09-06
- 主题：session-http-authorization
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/session-http-authorization.md`）

### 20260906-shared-app-restoration

- 日期：2026-09-06
- 主题：shared-app-restoration
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/shared-app-restoration-contract.md`）

### 20260906-timeline-location

- 日期：2026-09-06
- 主题：timeline-location
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/timeline-location-contract.md`）

### 20260906-timestamp-integer-boundaries

- 日期：2026-09-06
- 主题：timestamp-integer-boundaries
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/timestamp-integer-boundaries.md`）

### 20260907-atomic-revocation-issue

- 日期：2026-09-07
- 主题：atomic-revocation-issue
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/atomic-revocation-credential-issue-contract.md`）

### 20260907-issuance-boundaries

- 日期：2026-09-07
- 主题：issuance-boundaries
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/credential-issuance-boundaries-contract.md`）

### 20260907-issued-result-recovery

- 日期：2026-09-07
- 主题：issued-result-recovery
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/received-credential-recovery-contract.md`）

### 20260907-legacy-app-process

- 日期：2026-09-07
- 主题：legacy-app-process
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/legacy-registration-app-process-contract.md`）

### 20260907-legacy-registration-arbitration

- 日期：2026-09-07
- 主题：legacy-registration-arbitration
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/legacy-registration-arbitration-contract.md`）

### 20260907-legacy-registration-client

- 日期：2026-09-07
- 主题：legacy-registration-client
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/legacy-registration-client-recovery-contract.md`）

### 20260907-legacy-registration-http

- 日期：2026-09-07
- 主题：legacy-registration-http
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/legacy-registration-http-contract.md`）

### 20260907-proof-bound-issuance

- 日期：2026-09-07
- 主题：proof-bound-issuance
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/proof-bound-issuance-contract.md`）

### 20260907-registration-cancellation

- 日期：2026-09-07
- 主题：registration-cancellation
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/registration-cancellation-contract.md`）

### 20260907-registration-cancellation-http

- 日期：2026-09-07
- 主题：registration-cancellation-http
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/registration-cancellation-http-contract.md`）

### 20260907-registration-cancellation-runner

- 日期：2026-09-07
- 主题：registration-cancellation-runner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/registration-cancellation-runner-contract.md`）

### 20260907-registration-lifecycle

- 日期：2026-09-07
- 主题：registration-lifecycle
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/registration-lifecycle-contract.md`）

### 20260907-registration-process-interruption

- 日期：2026-09-07
- 主题：registration-process-interruption
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/registration-process-interruption-contract.md`）

### 20260907-revocation-capability-http

- 日期：2026-09-07
- 主题：revocation-capability-http
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/device-revocation-capability-http-contract.md`）

### 20260907-revocation-capability-storage

- 日期：2026-09-07
- 主题：revocation-capability-storage
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/device-revocation-capability-storage-contract.md`）

### 20260907-revocation-handoff

- 日期：2026-09-07
- 主题：revocation-handoff
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/device-revocation-handoff-contract.md`）

### 20260907-revocation-runner

- 日期：2026-09-07
- 主题：revocation-runner
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/device-revocation-runner-contract.md`）

### 20260907-revocation-status

- 日期：2026-09-07
- 主题：revocation-status
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/device-revocation-status-contract.md`）

### 20260907-server-clock-boundaries

- 日期：2026-09-07
- 主题：server-clock-boundaries
- 引用文档：4 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-plan.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md` 等）

### 20260907-session-absolute-expiry

- 日期：2026-09-07
- 主题：session-absolute-expiry
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/device-session-absolute-expiry-contract.md`）
