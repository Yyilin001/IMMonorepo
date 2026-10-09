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


共 109 条运行记录。

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
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/archive/legacy-registration-app-process-contract.md`）

### 20260907-legacy-registration-arbitration

- 日期：2026-09-07
- 主题：legacy-registration-arbitration
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/archive/legacy-registration-arbitration-contract.md`）

### 20260907-legacy-registration-client

- 日期：2026-09-07
- 主题：legacy-registration-client
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/archive/legacy-registration-client-recovery-contract.md`）

### 20260907-legacy-registration-http

- 日期：2026-09-07
- 主题：legacy-registration-http
- 引用文档：3 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/archive/2026-09-05-system-remediation-progress.md`, `docs/reviews/archive/legacy-registration-http-contract.md`）

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

### 20260913-room-log-fixed-load

- 日期：2026-09-13
- 主题：当前 Release 私聊、标准群和 10 万人大群固定负载
- 证据：[实测报告与限制](archive/room-log-fixed-load-2026-09-13.md)
- 结果：每轮 800 条计划消息全部确认，最终排空，无逐用户正文；不代表容量上限或完整故障恢复验收。

### 20260907-session-absolute-expiry

- 日期：2026-09-07
- 主题：session-absolute-expiry
- 引用文档：2 份（`docs/reviews/archive/2026-09-05-remediation-timeline.md`, `docs/reviews/device-session-absolute-expiry-contract.md`）

### 20260919-governance-recovery

范围：D08 当前工具链下的恢复验收；未执行全仓完整测试。

- 首轮真实链路驱动 `/tmp/imv2-governance-reconnect-20260919-01-driver.log` 退出 1，失败发生在 ClientKit 测试编译，尚未执行 App 自动重连。Swift 6.4 拒绝 `V2RoomRecoveryCrashTests` 从异步数据库读取返回非 Sendable 的 GRDB Row；临时服务和数据库已清理。
- 修正为在数据库读取闭包内提取 Int/Bool/Double/String 值，保留原持久化断言。构建日志 `/tmp/imv2-governance-crash-build-20260919.log`；未启用环境的首次运行仅证明编译，两个 skipped 不计通过。
- 显式启用强杀后的 `/tmp/imv2-governance-crash-20260919.log` 退出 0，31 类事务、提交前后共 62 参数通过（7.447 秒）；父进程的 crashChild 跳过不计通过，子进程分别验证 SIGKILL 及重启状态。
- 自动重连驱动补计独立 scoped App 登录产生的一台设备；额外按恢复测试账号要求恰有两台未撤销设备，防止三次重连产生额外注册。保留总设备、撤销、凭据及撤销事件的严格数量检查。
- 本机只有 iOS 27 运行时，驱动增加 `--simulator-runtime` 并在构建前检查可用性，默认 iOS 26.2 保留。实际运行时写入证据目录，iOS 27 结果不代表 iOS 26 验证。

强杀复现（先完成 ClientKit 测试构建，再执行）：

```sh
cd IMV2ClientKit
IMV2_CLIENT_CRASH_BINARY="$PWD/.build/arm64-apple-macosx/debug/IMV2ClientKitPackageTests.xctest/Contents/MacOS/IMV2ClientKitPackageTests" swift test --skip-build --filter V2RoomRecoveryCrashTests
```

最终真实链路：`/tmp/imv2-governance-reconnect-20260919-02-driver.log` 退出 0，证据目录 `/tmp/imv2-governance-reconnect-20260919-02`。App 3 passed / 0 failed / 1 未启用后台待发专项 skipped；129 房间首轮 12.995 秒、重连 0.339 秒，跨 Gateway 在线及前台三次自动重连标记通过。HTTP 与数据库终验通过：总设备/撤销/已撤销设备有效 access/有效 refresh/撤销事件为 `13|3|0|0|3`，恢复账号设备/撤销为 `2|0`；代理恰好三次 disconnect。独立核实专用模拟器 E3563836-23FF-41FB-A64F-2D754901DF89 已删除，cleanup.log 记录临时数据库、证书和服务清理完成。源码绑定见 source-manifest.json。

本次使用与既有专项相同的 [NATS v2.11.0 官方发行包](https://github.com/nats-io/nats-server/releases/tag/v2.11.0)，下载后与官方 SHA256SUMS 比对。未修改生产业务行为，未跑全仓业务全量或外部发布验收。三次断线证明前台聊天页自动恢复正文，不证明自动跟随滚动、真机后台、所有房间游标或资源硬上限。

```sh
python3 scripts/verify_v2_live_account_authorization.py \
  --output /tmp/imv2-governance-reconnect-20260919-02 \
  --app-ui --gateway --room-recovery-scale 129 --room-recovery-app-reconnect \
  --multi-gateway-nats-binary /tmp/imv2-governance-nats-20260919/nats-server-v2.11.0-darwin-arm64/nats-server \
  --simulator-runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

复现时选择新的输出目录；已有目录会被拒绝。NATS 路径和模拟器运行时须指向本机已准备的资源。

### 20260919-member-role-profile

B06 当前房间恢复：个人流先应用本人修订10，房间页再应用另一成员角色修订2及移除修订3，原 reducer 按房间资料版本提前返回，留下已移除角色。修复前 `/tmp/imv2-member-role-before-20260919.log` 退出1，角色残留与重开后残留两处断言失败。

修复将目标角色删除移到房间资料旧版本判断之前，SQL 同时限制目标角色修订不超过移除修订；本人资格检查仍先执行，未改变数据库结构或事务边界。首次定向回归5项通过，扩展为4种目标/本人版本组合并增加真实快照激活与重开后，最终 `/tmp/imv2-member-role-snapshot-20260919.log` 退出0：26项/3套件（0.504秒）。包括 V2MemberRoleRecoveryTests、原本人资格/快照与持久恢复测试；参数不额外累计到测试函数数量。

```sh
swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4 \
  --filter 'V2MemberRoleRecoveryTests|V2SyncEngineTests.membership|V2SyncEngineTests.snapshotViewerMembershipRevision|V2RoomRecoveryPersistenceTests'
```

源码摘要：`/tmp/imv2-member-role-sources-20260919.json`。未重跑 App/TLS、服务端或全仓套件；B06 的逐成员负状态、基线、裁剪及全部代次组合仍开放。

### 20260919-member-role-identity

B06 角色身份边界：原代码验证 RoomID/UserID 后仍以原始字符串落库，等价大小写的角色无法匹配移除，且快照按规范 room ID 保留时会丢失角色；角色分支也未核对外层房间、显式来源序号和同修订冲突，并接受不能由合法角色变更生成的 owner。

修复前 `/tmp/imv2-member-role-identity-before-20260919.log` 退出1，2个测试函数（8参数场景）共18处断言失败。修复统一存储规范UUID、校验房间/序号与角色/整数域，并对同修订不同角色或不同已知来源序号拒绝整页；不新增schema或改变事务边界。最终 `/tmp/imv2-member-role-identity-after-20260919.log` 退出0：29项/3套件（0.633秒），包含新负例的角色/游标回滚断言以及移除、快照、重开、本人资格和持久恢复回归。

```sh
swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4 \
  --filter 'V2MemberRoleRecoveryTests|V2SyncEngineTests.groupSnapshot|V2SyncEngineTests.membership|V2SyncEngineTests.snapshotViewerMembershipRevision|V2RoomRecoveryPersistenceTests'
```

源码摘要：`/tmp/imv2-member-role-identity-sources-20260919.json`。未跑App/TLS、服务端或全仓测试。source_event_id/摘要持久化、逐成员撤销负事实与完整重入/裁剪仍待后续，B06不关闭。

### 20260919-member-ledger

B06 新增当前本地 `v2_member_effects`：持久保存逐成员 add/remove/role 的来源、修订、规范摘要与可选房间序号。移除和重加均不再丢掉阻止旧角色恢复的版本事实；同修订异来源、同来源变更语义或已知房间序号不一致会拒绝事务。快照保留仍授权房间的来源历史，核对冲突后重建角色；本人撤销清理来源表，独立本人撤销状态继续保留。仅更改当前全新 SQLite schema，PostgreSQL schema36和协议30不变。

复现阶段 `/tmp/imv2-member-tombstone-before-20260919.log` 退出1：移除、快照切换及重开后注入旧角色，两种本人版本均重新产生角色（2处断言失败）。修复后同修订异来源会被拒绝，更旧且未记录的修订可记入历史但不改变角色。补充重加、本人退出清理、快照旧角色合并、来源/摘要/序号冲突及数据库字段约束。

最终 `/tmp/imv2-member-ledger-final-20260919.log` 退出0：148项/4套件，2.651秒，含完整 V2SyncEngineTests 与成员恢复、持久恢复和schema专项。初轮新快照测试误把 resetPending 的代次断言为旧代次，按 beginReset 合同改为核对 prepare 失败前后完整游标不变，同时断言正式来源表、角色与房间游标保持原状态；未放宽生产校验。

```sh
swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4 \
  --filter 'V2MemberRoleRecoveryTests|V2SyncEngineTests|V2RoomRecoveryPersistenceTests|V2LocalSchemaContractTests'
```

进程中断测试新增成员移除提交前/后场景，检查来源记录、角色和房间游标整体提交，并在重开后重试同一页。首次运行发现旧固定路径指向9月14日的旧测试二进制，父子代码不一致，产生缺表错误（`/tmp/imv2-member-ledger-crash-20260919.log`，退出1）；该结果不作为当前代码证据。测试现在通过自身 Bundle 定位正在加载的可执行文件，并强制配置路径与之相同，避免旧测试程序被当成当前证据。历史文档中的固定路径不可不经校验直接复用。

切换到当前二进制后，新增重试夹具因两个进程的 JSON 键顺序不同被原有逐字节重放校验拒绝（`/tmp/imv2-member-ledger-crash-current-20260919.log`，退出1）；将夹具编码固定为 sortedKeys，保留原生产重放校验。

```sh
IMV2_CLIENT_CRASH_BINARY="$PWD/IMV2ClientKit/.build/out/Products/Debug/IMV2ClientKitTests.xctest/Contents/MacOS/IMV2ClientKitTests" \
  swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4 --filter V2RoomRecoveryCrashTests
```

最终 `/tmp/imv2-member-ledger-crash-final-20260919.log` 退出0：64个提交前/后参数场景全部通过，9.292秒；父进程跳过仅供子进程启动的 crashChild，不把该跳过计作额外通过项。

此路径对应本机当前 SwiftPM 构建布局；其他构建系统必须指向实际加载的测试 Bundle。源码和测试二进制摘要见 `/tmp/imv2-member-ledger-sources-20260919.json`。以上受控旧载荷/公共角色快照测试仅覆盖本地边界，不恢复旧个人公共投影生产路径。尚未验收首次安装/裁剪后的成员权威基线、本人重入全部代次、来源保留与容量，也未重跑 App/TLS、PostgreSQL、真机或全仓业务测试；B06继续开放。

### 20260919-member-directory

B06 核对当前成员展示链路：App 通过分页名录获取名单和 actorRole，而不是读取 SQLite 的 `v2_group_member_roles`。服务端名录查询当前成员关系，游标绑定房间/修订；日志裁剪不直接删除该关系，但跨 owner 名录路由和真实裁剪/重新加入组合尚未验收。

发现 App 已确认名录过时后仍保留旧管理角色：分页修订冲突后首屏重读失败、跨页版本变化后重读失败、FORBIDDEN、NOT_FOUND 和主动刷新失败均留下旧名单、actorRole、revision及分页游标。新增6参数测试还包含普通网络失败的对照场景；修复前实际运行 `/tmp/imv2-member-directory-repro-20260919.log` 退出65，1测试函数/6参数共25处断言失败。

修复统一失效清理；刷新期间的新刷新意图由原任务串行重读，不接受迟到旧页。拒绝重复成员、停滞游标和带后续游标的空页。普通分页网络失败可保留已加载状态；不修改服务端授权规则。

验证过程保留两次无效运行：初次 `/tmp/imv2-member-directory-before-20260919.log` 因新模拟器未完成启动，测试宿主启动失败；待模拟器 bootstatus 完成后，第二次旧筛选名称运行0项（`/tmp/imv2-member-directory-before-retry-20260919.log`），不计通过。通过测试枚举取得 Swift Testing 的完整标识（含参数签名）后，使用原已编译二进制执行上述失败复现，再重新构建修复版。

最终 `/tmp/imv2-member-directory-after-20260919.log` 退出0，10项测试函数全部通过（0.011秒），包含6种失效/网络情况和3种异常分页。其他场景覆盖正常分页、修订冲突后重读、单一请求所有者、刷新丢弃迟到旧角色、成员操作修订与取消。结果包 `/tmp/imv2-member-directory-after-20260919.xcresult`；准确筛选列表 `/tmp/imv2-member-directory-selected-tests.json`；源码摘要 `/tmp/imv2-member-directory-sources-20260919.json`。

```sh
xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug \
  -destination 'platform=iOS Simulator,id=<专用模拟器ID>' \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO -collect-test-diagnostics never \
  '-only-testing:IMAppTests/V2ConversationStoreTests/groupMemberInvalidationClearsOldManagementState(scenario:)' \
  '-only-testing:IMAppTests/V2ConversationStoreTests/groupMemberRefreshDiscardsLateRoleAndKeepsOneRequestOwner()' \
  '-only-testing:IMAppTests/V2ConversationStoreTests/groupMemberInvalidPageDoesNotLeavePartialRoster(scenario:)'
```

上面展示3个新增测试的复现入口；本次实际选择10项，完整清单见所列JSON。使用本机iOS27专用模拟器6977B62B-2D97-468B-A247-FA940FDF90A6；没有复用用户正在运行的模拟器。测试使用注入读取器，没有把模拟结果称为真实网络或PostgreSQL验收。未跑App全套、全仓、真机或发布检查，B06保持开放。

### 20260919-member-directory-routing

B06 当前名录跨库缺口：ServerApp 原来直接用默认数据库构造 `PostgresV2RoomMembershipDirectoryStore`，查询同时依赖该库的 rooms、room_memberships、public_user_profiles。房间恢复已有 owner 路由不代表名录读取也已路由。

新增 `V2RoutedRoomMembershipDirectoryStore` 并接入 ServerApp：不缓存的控制面路由选择 owner；owner 内共享锁核对 shard/epoch 与当前资格并分页取候选；控制库一次批量读取候选的有效公开身份并排除停用账号；返回前复核成员资格/修订/角色与控制面归属。游标版本2绑定房间、修订、owner shard/epoch和扫描边界；归属变化映射 REVISION_CONFLICT，不能回退旧 owner。单次扫描不超过100条候选，另取1条探测后续，不为填满可见页无界扫描。

边界校正：上一轮 App 将带后续游标的空页判为无效；跨控制库过滤隐藏资料后，这种页可以合法出现。现允许游标推进的空页并保留“加载更多”，继续拒绝重复成员和停滞游标，增加从隐藏空页加载到可见成员的验证。没有修改协议字段、协议版本或PostgreSQL schema。

最终 `/tmp/imv2-routed-members-postgres-final-20260919.log` 退出0：9项/4套件，1.162秒。包括路由/边界参数测试、Gateway身份与错误映射、服务输入合同，以及实际启用的 `PostgresV2MemberDirectoryRoutingTests.ownerSwitchHiddenProfilesAndRejoin`。真实专项创建三个独立临时数据库，分别作为控制面和两个 owner；核心断言：

- owner 中放入过期资料，只有控制库的当前公开资料可返回；隐藏与停用账号被过滤，空页游标能推进。
- owner 房间事件表为空、head/裁剪下界均为100，仍可读取当前角色和名录，不依赖旧角色事件。
- 切换 owner 后旧游标被拒绝，从第一页取得新代次游标；旧 owner 仍保留有效成员副本，当前 owner 撤销时不会回退读取旧副本。
- 重新加入后角色为普通成员、修订更新，旧成员修订游标被拒绝；物理 owner epoch 不符被拒绝。
- 在候选页读取后、公开身份返回前，通过真实 owner 事务撤销调用者资格，最终复核拒绝整页。

```sh
PGHOST=127.0.0.1 PGPORT=<专用PostgreSQL端口> PGUSER=<测试角色> \
  bash scripts/test_v2_server_native_postgres.sh --disable-automatic-resolution \
  --filter 'V2RoutedRoomMembershipDirectoryTests|PostgresV2MemberDirectoryRoutingTests|V2RoomMembershipDirectoryServiceTests|V2GatewayDomainCommandHandlerTests.membershipDirectory'
```

App `/tmp/imv2-routed-members-app-20260919.log` 退出0：11项/1套件，0.010秒；使用新建且确认启动完成的iOS27模拟器40F5B9EE-878C-4A47-A561-A70509F47382。结果包 `/tmp/imv2-routed-members-app-20260919.xcresult`，完整筛选列表 `/tmp/imv2-routed-members-selected-tests.json`，源码摘要 `/tmp/imv2-routed-members-sources-20260919.json`。测试以注入名录服务验证 App 状态，没有声称运行实际 App/TLS 名录请求。

上述三库切换是受控路由/状态夹具，不证明完整迁移搬运、首次安装App整链、全部恢复代次或容量。未跑全仓、真机或生产发布检查，B06保持实施中。

本轮专用PostgreSQL进程已停止、脚本创建的临时数据库剩余0个，专用模拟器已删除；清理证据 `/tmp/imv2-routed-members-cleanup-20260919.log`。

<a id="20260919-group-join-cancellation"></a>

## 2026-09-19：D06 申请人取消与审批竞态

本轮新增 cancelled 终态、owner 事务取消、HTTPS 入口、客户端响应校验和 App 操作。
规则见[申请取消合同](group-join-cancellation-contract.md)。采用当前新库 schema 37，不提供旧库升级。

| 范围 | 实际结果 | 证据 |
| --- | --- | --- |
| 真实 PostgreSQL、服务与 HTTP | 11 项测试 / 4 套件通过，7.318 秒；开启 disposable 标记并创建独立数据库，数据库项实际执行 | `/tmp/imv2-d06-postgres-final.log` |
| 取消数据库组合 | pending、expired、revoked、approve-first、reject-first、race、approving 共 7 场景；检查其他人/错房间拒绝、原终态重放、无重复成员/事件/次数、取消后重新申请；另含跨库 owner 路由及 epoch 拒绝 | 同上 |
| 相关审批与配额回归 | 3 个审批事务回滚点、2 个并发配额场景；HTTP 时钟边界 20 场景，包括取消和 cancelled 提交重放 | 同上 |
| ClientKit HTTP | 4 项测试通过，0.005 秒；取消正常终态及异常房间、申请、状态、时间共 8 个参数场景 | `/tmp/imv2-d06-client-final.log` |
| App store | 8 项测试通过，0.011 秒；新增取消结果/失败重试 4 场景、替换/关闭/退出后的迟到结果 3 场景，既有提交隔离回归同轮通过 | `/tmp/imv2-d06-app-final.log`、`/tmp/imv2-d06-app-final.xcresult` |
| Core 邀请模型 | 3 项测试通过，0.001 秒 | `/tmp/imv2-d06-core.log` |
| 历史账号升级脚本 | 35→36 的凭据保存和拒绝重复升级专项通过；不再把该旧版本宣称为当前就绪合同 | `/tmp/imv2-d06-historical-upgrade.log` |

开发中保留两次失败：客户端测试嵌套 `#require` 编译失败和响应 fixture 的 handle 字段写错，均已修复；
App 新增 completed 分支最初过宽，使旧提交完成后又可提交，原有隔离测试捕获 6 个失败参数，
已收紧为仅 cancelled 可再次提交并重跑全邀请 store 专项。失败日志为 `/tmp/imv2-d06-app.log`；
不把失败轮或修改前的通过记录当作最终证明。

完整房间迁移、跨 owner 全局配额、生产真机/APNs 仍按原条目开放；受控 owner epoch 切换不是搬迁执行器验收。
本轮没有执行全仓业务测试、提交或部署。最终 schema/文档门禁与源码摘要在本节继续记录。

最终 schema 检查：4 个约束偏离参数全部通过，1.649 秒，见 `/tmp/imv2-d06-schema-corrected.log`。
覆盖 state/decision CHECK 放宽、部分唯一索引误改为全量唯一、历史查询索引缺失。
初轮历史索引检查误接到了注册凭据检查，错误归因被专项捕获，已移到独立的 joinCancellationContract；
失败记录保留在 `/tmp/imv2-d06-schema-final.log`。独立 SQL 就绪门禁确认新库为 true、删除历史索引为 false，
见 `/tmp/imv2-d06-schema-gate-final.log`。该最后变更只重跑受影响的 schema 专项；未重复无关业务套件。

源码/测试/日志摘要保存于 `/tmp/imv2-d06-sources-20260919.json`；ClientKit 验证之后只整理了接口注释，
没有改变其运行逻辑。文档链接、结构、协议与差异门禁均已通过。D06 关闭，B23/B27 和全部 E 类保持开放。

<a id="20260919-group-join-quota-ledger"></a>

## 2026-09-19：B23 控制库预留账本（尚未接入生产）

下述为最初账本阶段；当前接线与关闭结论见[后续验收](#20260919-group-join-global-quota)。

新增 `PostgresV2GroupJoinQuotaStore` 和 schema 38 的 `group_join_quota_intents`。
这是全局配额的持久化组件，**生产 submit 仍直接调用 owner，B23 不关闭**；完整接线与验收条件见
[全局配额合同](group-join-global-quota-contract.md)。

- `/tmp/imv2-b23-ledger-final.log`：真实 PostgreSQL，7 项测试 / 2 套件通过，6.500 秒。
  配额账本 6 项函数含 14 个展开场景；另重跑取消功能的 4 个约束偏离场景。
- 同一申请人、不同 room/invite 的 40 次并发预留恰好得到 20 个 reserved 和 20 个 limited；
  另一个申请人有独立容量。重新创建 store 并推进一年时钟不会释放不确定的 held。
- 验证同操作的 room/invite/note/token 摘要冲突、同活跃邀请共享预留、服务重试不覆盖首次 request ID；
  approved/rejected/cancelled/already_member 释放名额，迟到 pending 不能重新打开终态。
- unavailable/rate_limited/permission_denied 的确定拒绝记录允许同操作新 generation 重试；
  旧 generation 不能释放新预留，tracking 不能被伪装为失败而释放，Int64.max 代次拒绝递增且不崩溃。
- 启动门禁验证账本列、11 项约束及 4 个索引；弱化 outcome/generation CHECK、删除活跃唯一索引或恢复索引均被拒绝。

仅账本调用方的前置条件规定 resolve 必须有 owner 持久回执；本阶段未实现该回执和恢复协调器，
所以不能把本轮结果描述成完整跨 owner 提交/释放或故障恢复已经通过。未运行全仓业务测试。

独立 SQL 就绪门禁确认 schema 38 为 true、删除活跃邀请唯一索引后为 false，见
`/tmp/imv2-b23-sql-gate.log`（该临时日志后续被覆盖，原摘要见本段及本阶段源码/日志摘要）。旧 35→36 账号升级专项仍通过，见 `/tmp/imv2-b23-historical-upgrade.log`；
该记录不宣称旧版本符合当前 schema 38。文档链接、结构、协议与差异门禁通过。
源码与日志摘要：`/tmp/imv2-b23-ledger-sources-20260919.json`。本轮临时数据库已清理，专用 PostgreSQL 已停止；未提交或部署。


<a id="20260919-group-join-global-quota"></a>

## 2026-09-19：B23 全局配额、重复绑定与崩溃恢复

B23 已关闭。生产代码接入 control 预留→owner 原子申请/回执→control 确认；Account runtime
每轮有界处理恢复任务。schema 39 增加 owner 不可变回执、重复操作别名与持久认领字段。
本文验证本机原生 PostgreSQL 的真实跨库提交与独立进程中断，不代表生产部署、容量或完整房间迁移验收。

| 专项 | 实际结果与边界 | 日志 |
| --- | --- | --- |
| 配额及邀请 | 16 项测试 / 2 套件通过，21.849 秒；10 项账本函数与 6 项 owner/路由函数，参数展开共 39 场景 | `/tmp/imv2-b23-alias-integrated.log` |
| 全局 20 上限 | 同一申请人向两个 owner 提交 40 次，20 个接受、20 个限流；两库都有申请且总数为 20。control 与其中一个 owner 共用数据库，另一个 owner 使用独立数据库 | 同上 |
| 重复操作 | 满额时不同 operation 返回同一申请；记录各自输入绑定；取消后旧别名返回 cancelled，新操作才可重新申请。确定拒绝可重试新代次，绑定到另一已确认申请后旧证明不能释放其名额 | 同上 |
| owner 原子回执 | 回执插入失败时申请一并回滚；并发提交只有一个申请/回执；到期、邀请限流、账号停用的拒绝结果不会因条件变化被旧代次重新执行 | 同上 |
| 进程中断 | 6 个真实 SIGKILL 检查点：预留后、owner 提交后、control 确认后，以及取消/批准/拒绝后未通知 control。使用本次已加载测试二进制，新 worker 只依赖持久状态恢复 | 同上 |
| operator 与失败退避 | 1 项测试、committed/released/quarantined 三场景通过。归属不匹配时退避并保留名额；运维确认批准后释放，退回 pending 或证据不足仍占名额 | `/tmp/imv2-b23-operator.log` |
| 新库合同 | 当前建库、导出/恢复和结构偏离检查通过；149 张表、349 个索引。新增三表的七个索引加取消历史索引，取代旧 146/341 断言 | `/tmp/imv2-b23-current-bootstrap.log` |
| 独立 SQL 就绪 | schema 39 为 true；删除操作绑定外键、owner 结果约束或恢复索引均为 false。Swift 门禁也覆盖缺失回执约束和账本约束 | `/tmp/imv2-b23-current-39-sql-gate.log` |

最初跨库用例在审批处失败：测试容量配置的命令额度为 100，种子数据为 10，实际得到限流。
分阶段诊断见 `/tmp/imv2-b23-diagnose.log`；修正为 10 后保留严格的审批成功、名额和两库 pending 数断言。
同时修复了真实遗漏：不同 operation 共用申请却未持久绑定，取消后的迟到重试可能重新申请。
不能把此前未通过的跨库记录描述成成功，也不能把该问题仅归为测试配置。

16 项主专项之后仅增加 operator 专项和清理源文件行末空白；operator 使用后续编译版本。
测试构建已编译 Account 可执行程序。文档链接、结构、协议及差异检查另行通过。
未运行全仓业务套件、真机/APNs 或负载长稳；完整房间迁移由 B27 跟踪。
源码及日志摘要见 `/tmp/imv2-b23-global-quota-sources-20260919.json`。本轮测试数据库已清理，未提交或部署。


<a id="20260919-message-projection-bounds"></a>

## 2026-09-19：B01 消息投影整数入口

消息投影构造、JSON 解码及恢复修订统一拒绝超出 PostgreSQL bigint 的值；编辑/撤回在最后合法修订停止递增。
存储投影读取先检查修订为正，负修订返回错误，避免 UInt64 转换崩溃。

修复前 `/tmp/imv2-b01-projection-before.log` 中两项测试共八个失败，均为超界值没有被拒绝。
修复后 `/tmp/imv2-b01-projection-after.log` 中消息投影、快照响应及群响应边界共 16 项 / 3 套件通过。
新增存储负修订与合法最大值推进用例；没有把合法上界也一并拒绝，没有修改 wire/schema 版本。

具体入口和剩余范围见[消息投影边界](message-projection-integer-boundaries.md)。本批未运行真实 PostgreSQL、App、ClientKit 或全仓套件；
快照构建累计计数的加法边界仍待修复，B01 继续开放。源码/日志摘要：`/tmp/imv2-b01-projection-sources-20260919.json`。


<a id="20260919-snapshot-sequence-bounds"></a>

## 2026-09-19：B01 快照计数约束与 Core 发送序号

更正上一批对快照 worker 的初步判断：schema 39 的累计页数/条数/字节数 CHECK 已将值限制在协议范围，
有界单页追加不会溢出 Int64。未修改构建算法、未删除约束制造故障；新增真实 PostgreSQL 专项证明边界行为。

- `/tmp/imv2-b01-snapshot-counts.log`：3 项 / 2 套件通过，3.099 秒。
  新增 6 个计数边界场景，另跑原分页续传/发布/GC，以及空账号/失败恢复。
  恰好达到上限仍提交页面；再追加会标记失败且不写新页，释放租约并清理 pending token、重置记录，恢复设备游标。
- `/tmp/imv2-b01-send-sequence.log`：Core 接受与指纹 14 项 / 2 套件通过。
  新增首序号零、Int64 上界加一、UInt64.max 的拒绝，以及最后合法序号成功、耗尽后重放/冲突/新提交组合。
  `V2SendMessageReducer` 在首次接受前验证持久化范围，返回 `invalidRoomSequence`；不使用截断或饱和递增。

快照测试使用合成累计计数，不代表容量测试；Core 修复不等于所有生产写库此前都存在同样问题。
详见[入口核对](message-projection-integer-boundaries.md)。本轮不修改协议/schema，未运行全仓测试，B01 继续开放。
源码/日志摘要：`/tmp/imv2-b01-snapshot-sequence-sources-20260919.json`。未提交或部署。


<a id="20260919-cache-worker-integer-bounds"></a>

## 2026-09-19：B01 私聊缓存与后台重试边界

扩展两个私聊缓存套件，覆盖 Int64.max - 1 到最后合法修订、迟到和重复回调不再次递增；
扩展持久任务退避套件，覆盖 Int32.max、Int.max - 1、Int.max。
调用链核对确认单条/批量数据库回复标记更新已有 Int64 上界条件，缓存派生依赖该成功更新。
没有为绕过生产前置条件的合成调用增加新的业务分支。

原生 PostgreSQL 脚本过滤两个缓存套件、持久任务错误分类套件及三个数据库测试：
`pushWakeRetryCounterBoundary`、`migrationRetentionRetryCounterBoundary`、`mediaSessionRetryCounterBoundary`。
`/tmp/imv2-b01-cache-worker-boundaries.log` 记录 16 项 / 4 套件通过，17.941 秒；
数据库参数场景分别为 6、6、12，覆盖饱和重试/旧完成隔离，以及媒体最后合法认领与耗尽后不写入。
这不是生产长稳或所有 worker 的验证。

另核对事务重试辅助函数的生产调用点，均使用默认最多两次重试；当前乘法输入有界。
没有将该只读结论写成任意 maximumRetryCount 的测试证明。
详见[入口清单](message-projection-integer-boundaries.md)。本批无生产代码变更，未跑全仓测试，B01 保持开放。
源码与日志摘要：`/tmp/imv2-b01-cache-worker-sources-20260919.json`。未提交或部署。


<a id="20260919-client-recovery-integer-bounds"></a>

## 2026-09-19：B01 客户端恢复整数与事务边界

新增 `V2RoomRecoveryIntegerBoundsTests` 两项真实 SQLite 测试：最后合法调度序号成功，耗尽后
retryRoomRecoveryWork 抛 invalidWork 且重试时间、待办与调度序号保持原值；完整房间状态的
最大合法值读写一致，六个负状态字段被 schema 拒绝，超界通知不改写现有任务。

定向运行 `V2RoomRecoveryIntegerBoundsTests`、`V2RoomRecoveryPersistenceTests`、
`V2ProjectionRecoveryBoundsTests`、`V2SyncCursorRecoveryBoundsTests`、
`V2PendingCommandRecoveryBoundsTests`：26 项 / 5 套件通过，0.430 秒。
日志 `/tmp/imv2-b01-client-recovery-integers.log`。既有命令恢复 14 字段 × 5 数值是 Row 解码测试，
不描述成数据库重开；游标恢复套件实际执行 SQLite 写入、关闭和重开。

本批仅新增测试并完善[入口映射](message-projection-integer-boundaries.md)。没有新增生产算法，
没有关闭约束来制造失败，未跑全仓或设备验收。B01 仍开放，其他 worker/outbox/分页入口映射待完成。
源码和日志摘要：`/tmp/imv2-b01-client-recovery-sources-20260919.json`。


<a id="20260919-recovery-storage-types"></a>

## 2026-09-19：B01 SQLite 恢复表精确整数读取

修复 `GRDBV2RoomRecoveryWork`：目标序号、调度序号及六个房间状态字段先校验
`DatabaseValue.storage` 为非负 int64，再转换或递增。SQLite INTEGER affinity 与非负 CHECK
仍允许 REAL 存储；上一批负值约束测试未覆盖此情况。此次没有调整约束或 schema。

`V2RoomRecoveryIntegerBoundsTests.nonintegerStorageFailsWithoutMutation` 含 5 字段 × 2 数值：
1.5 和 Double(Int64.max)。真实数据库在完整约束下接受测试写入；业务读取返回 invalidWork，
存储值、real 类型和重试时间保持不变；显式修复测试数据后重新读取成功。
没有声称正常生产写入会生成这些 REAL 值；此修复针对持久化恢复入口的异常数据处理。

运行恢复整数、恢复持久化、恢复引擎三个套件及 outbox 的 retryCounterBounds、
nonintegerRetryCounter 两项：48 项 / 4 套件通过，1.779 秒。
日志 `/tmp/imv2-b01-recovery-storage-types.log`。其中 outbox 的既有负计数测试会关闭 CHECK
模拟损坏，恢复表新增 10 场景没有关闭约束，二者证据范围不同。
未运行全仓/App/真机验收。B01 继续开放；其他 SQLite 读取不能直接继承此结论。
源码摘要 `/tmp/imv2-b01-recovery-storage-types-sources-20260919.json`。


<a id="20260919-recovery-authority-integers"></a>

## 2026-09-19：B01 恢复成员资格与摘要的整数读取

将恢复表的精确存储类型检查扩展至成员资格栅栏/授权比较，以及最新消息摘要的版本、计数、
内容游标和本地消息修订。MAX(room_sequence) 仍用原聚合查询，空值按原契约为零。
异常存储返回 invalidWork，不进行近似转换，不据此授予资格、提交摘要或删除恢复待办。

新增 2 个真实 SQLite 成员修订场景和 12 个摘要 Row 解码场景；真实成员写入保持数据库约束开启。
运行 `V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests`，
48 项 / 3 套件通过，1.783 秒，日志 `/tmp/imv2-b01-recovery-authority-integers-after.log`。
初次编译因可空聚合闭包把零推断成 Int 而失败，已显式指定返回 Int64 后重跑；
失败日志保留 `/tmp/imv2-b01-recovery-authority-integers.log`，不计为测试通过。

未改变 schema/协议，未跑全仓/App/真机。其他本地表与 B01 剩余映射仍开放。
源码/日志摘要：`/tmp/imv2-b01-recovery-authority-sources-20260919.json`。


<a id="20260919-remaining-worker-integers"></a>

## 2026-09-19：B01 其余后台任务计数核验

读取当前饱和递增实现后，执行原生 PostgreSQL 定向过滤：
`propagationRetryCounterBoundary|contentReviewRetryCounterBoundary|groupWakeRetryCounterBoundary|mediaWorkerRetryCounterBoundary`。
四项测试 / 一套件通过，50.695 秒；参数场景分别 24、12、12、24，共 72。
日志 `/tmp/imv2-b01-remaining-worker-integers.log`。覆盖传播效果去重、审核决策/暂停、群唤醒新修订保留，
媒体瞬时失败继续重试且不阻挡健康任务。均包含计数上限或最后合法推进及部分过期租约组合。
不是迁移、容量或全体后台任务完整验收；群唤醒测试旧展示名含 Hybrid，不代表运行旧投递架构。

另完成客户端 16 个命令重试存储入口到共享精确计数 helper 的映射，以及五个分页/窗口 API 的
limit 加一上界核对，详见[整数入口清单](message-projection-integer-boundaries.md)。这些调用点本轮为源码核对，
不声称 16 条业务端到端全部重跑。本轮未新增测试或生产代码变更，B01 继续开放。
源码/日志摘要：`/tmp/imv2-b01-remaining-worker-sources-20260919.json`。未提交、部署或运行全仓套件。


<a id="20260919-send-completion-retention"></a>

## 2026-09-19：B11 接受记录保留与真实维护回归

当前源码核对确认：SendMessage 没有服务端可验证的旧操作期限/代次，35 天常量只是最短保留期；
`v2ForwardSourceVisibility` 同时依赖接受记录中的 accepted_membership_revision 作为历史授权事实。
因此安全 GC 需要同时解决旧操作拒绝和仍存活内容的授权依赖，不能直接加一条按年龄 DELETE。
现行合同已从历史 v1/v2 实施记录分离，见[接受记录保留与清理](send-completion-retention.md)。

扩展 `sendCompletionIsIndependentOfMutableContent`：完成编辑、撤回、正文删除后，将维护时刻设为
最短服务端保留期加一天，调用真实控制面维护工作器；检查接受事实不变、重发仍返回原回执、六类
改参仍冲突、正文行数为零、接受记录一条。三个参数场景通过，1 项 / 1 套件，1.105 秒。
日志 `/tmp/imv2-b11-completion-retention.log`。参数历史名字仍为 standard/hybrid/hybrid-mention，
当前实际为标准群、大群和带提及的大群房间日志，不代表旧投递模式仍运行。

本批业务算法未改变，仅补回归、维护列表的禁止误删说明和现行合同。维护器注释是在测试编译期间
补充，不改变测试二进制语义；不把这次保留验证描述成 GC、迁移或容量完成。未跑全仓，B11 仍开放。
源码/日志摘要：`/tmp/imv2-b11-retention-sources-20260919.json`。测试库已清理，未提交或部署。


<a id="20260919-role-policy-storage"></a>

## 2026-09-19：B01 角色权限恢复的整数类型

修复角色恢复任务建立、成员版本匹配、基线完成及权限读取中的直接整数转换。
新增 `rolePolicyInteger` 统一检查真实 integer 类型及字段下界；读取完整先前基线后再决定版本合并。
没有用截断、默认零或覆盖异常数据的方式消除错误。既有 Int32 饱和重试计数逻辑保持不变。

新增 8 个真实 SQLite 场景，包含房间成员修订与三项权限基线字段，各写入 1.5 或 Double(Int64.max)，
约束保持开启。验证异常返回 invalidMessagePayload，重置任务的删除回滚、原请求及原值保留；
修复测试数据后同一待办可成功完成。

- `/tmp/imv2-b01-role-policy-storage.log`：9 项 / 1 套件通过，0.366 秒。
- `/tmp/imv2-b01-role-policy-regression.log`：10 项 / 1 套件通过，0.278 秒。

两组过滤不同，共 19 项；补充组覆盖正常重开、权限来源/快照及后台运行器，未跑整个同步套件或全仓。
B01 仍开放。源码与日志摘要 `/tmp/imv2-b01-role-policy-sources-20260919.json`。未提交或部署。


<a id="20260919-command-storage-types"></a>

## 2026-09-19：B01 待执行命令修订/序号的精确类型

`GRDBV2LocalSyncStore` 的 17 个可选、4 个必填 commandStorageUnsigned 调用点改为先读取
DatabaseValue 并检查 integer，之后执行非负 UInt64 转换；可选 NULL 仍为 nil。
覆盖消息接受、编辑/撤回、成员/审核、禁言、表情和已读结果恢复，异常抛 commandConflict。

边界测试保留编辑/撤回/成员/回执 14 个字段的 70 个整数 Row 解码场景，增加 28 个 REAL 场景。
这些是解码测试，不声称写入/关闭/重开。受影响 outbox 现有业务测试另覆盖正常写入、重试及终态行为。
41 项 / 10 套件通过，0.462 秒，日志 `/tmp/imv2-b01-command-storage-types.log`。

未改 schema/协议，未跑全仓或设备测试。B01 仍开放；源码/日志摘要
`/tmp/imv2-b01-command-storage-sources-20260919.json`。未提交或部署。


<a id="20260919-projection-storage-types"></a>

## 2026-09-19：B01 投影与同步的精确 Row 整数转换

`GRDBV2LocalSyncStore` 的 projectionStorageUnsigned 五处和 storageUnsigned 十一处 Row 调用
先检查实际 integer 类型，之后复用原非负转换。保留原投影/同步错误分类、合法零与最大值行为。
涉及消息投影、同步记录、资料版本、快照累计值和其他引用这些 helper 的恢复读取。
新增 8 个 REAL 投影解码场景；原负值与最大值断言保留。

`V2ProjectionRecoveryBoundsTests|V2SyncEngineTests|V2ProfileRepositoryTests|V2GroupCapability`
过滤运行共 130 项 / 4 套件通过，2.301 秒；日志 `/tmp/imv2-b01-projection-storage-types.log`。
共享转换影响完整同步流程，因此运行该模块的同步套件；未跑全仓、App 或真机。
新增 Row 场景不描述成真实数据库重开。B01 仍开放。
源码/日志摘要：`/tmp/imv2-b01-projection-storage-sources-20260919.json`。未提交或部署。


<a id="20260919-forward-terminal-query"></a>

## 2026-09-19：B04 跨 owner 转发终态元数据查询

新增 `PostgresV2ForwardReceiptStore.terminalStatus`，由 `V2CrossOwnerForwardService` 在 prepare 前调用。
按 actor/operation/source message/target room 唯一身份联结 export 与 receipt，验证 source room/revision
以及两侧摘要，再返回原成功/拒绝结果。查询不选择 payload，未命中继续原准备/投递路径，prepare 后仍重查回执。
无终态路径多一次有界查询，尚未做容量测量；不将此改动描述为已经启用载荷 GC。

新真实 PostgreSQL 测试在不存在源房间/正文/目标库/投递任务的条件下，验证成功、拒绝、摘要不匹配三类记录，
包含改源房间/修订冲突和不同 actor/operation/target 不命中。fixture 直接插入合法编码导出和回执，
摘要不匹配记录为显式异常注入；没有删除约束或关闭触发器。
初轮 `/tmp/imv2-b04-terminal-replay.log` 1 项通过（0.368 秒），补充摘要异常后
`/tmp/imv2-b04-terminal-replay-after.log` 1 项通过（0.370 秒），两次不是不同测试项。

实际双 owner 业务回归过滤 `forwardRoutedRuntimeLifecycle|forwardTerminalReceiptRecovery`：
2 项 / 1 套件、6 参数场景通过，4.840 秒，日志 `/tmp/imv2-b04-terminal-runtime-regression.log`。
覆盖终态回执、源 epoch、事务回滚、标准/大群运行器重启及原转发重放。

[载荷清理边界](forward-terminal-payload-retention.md)明确尚缺 schema 压缩状态、其他读者适配、
预查未命中后并发压缩栅栏、清理 worker 和完整 room owner 迁移。B04 继续开放。
文档链接/结构/差异检查通过；未跑全仓、容量或真机，未部署。
源码/日志摘要 `/tmp/imv2-b04-terminal-query-sources-20260919.json`。


<a id="20260919-forward-bodyless-receipt"></a>

## 2026-09-19：B04 终态回执不再携带正文

`V2ForwardTerminalReceipt` 改为 exportID、32 字节 payloadDigest、终态结果，移除完整 export 属性；
导出构造入口仍为模块内部，另有内部元数据构造入口供目标持久读取使用。服务器调用点同步调整，
这不是网络协议变更，也不授权客户端凭摘要构造回执。

目标 terminalReceipt 仅查询 completed/rejected 行并用 NULL 代替 payload，不读取正文；pending/accepted
仍返回 nil。源 record 按导出主键与摘要核对，在首次落盘时从数据库元数据校验源房间 shard/epoch，
精确旧回执重放沿用原先无需再次授权的规则。工作器/目标 endpoint 均核对 ID 与摘要匹配原导出。

- `/tmp/imv2-b04-bodyless-receipt-regression.log`：4 项 / 1 套件通过，21.050 秒。
  inbox 接受恢复 2、源回执 4、投递恢复 18、路由运行器 2，共 26 个真实双库参数场景。
  包含原结果冲突、改正文后的摘要冲突、源 epoch、ACK 丢失、租约、取消和重启断言。
- `/tmp/imv2-b04-bodyless-receipt-boundaries.log`：2 项 / 1 套件通过，0.362 秒。
  新增 4 个非法摘要长度拒绝场景；原终态查询成功/拒绝/摘要不匹配数据库专项同轮通过。

schema 仍为 39，没有修改 payload 非空约束或启用清理任务。目标 receive、投递租约等其他读者与
压缩并发栅栏仍按[清理合同](forward-terminal-payload-retention.md)实施，B04 保持开放。
未跑全仓、容量或设备测试，未提交或部署；测试库已清理。
源码/日志摘要 `/tmp/imv2-b04-bodyless-receipt-sources-20260919.json`。

<a id="20260919-forward-inbox-terminal"></a>

## 2026-09-19：B04 目标收件箱终态读取与导入重放

receive 的重复请求查询只读取 payload_digest；输入 V2ForwardExport 已校验完整载荷 SHA-256，
相同 exportID 而摘要不同仍拒绝。status 与 v2LockForwardInbox 对 completed/rejected 返回空正文，
pending/accepted 保留完整正文；importForwardExport 先检查摘要，终态返回原结果，未完成任务仍检查正文相等。

真实 PostgreSQL 终态 fixture 在没有房间和业务消息的条件下插入合法终态记录，验证成功/拒绝的 receive、
status、terminalReceipt、加锁读取及 importForwardExport，断言加锁读取不返回正文、改正文请求冲突。
未删除 schema 约束或触发器，存储中正文仍在；此测试不宣称物理清理已经可用。

- `/tmp/imv2-b04-inbox-terminal-bodyless.log`：2 项 / 1 套件通过，0.384 秒。
  包含非法摘要长度 4 场景及源回执/目标终态 fixture。
- `/tmp/imv2-b04-inbox-terminal-regression.log`：5 项 / 1 套件通过，26.345 秒。
  接受恢复 2、目标准入/权限/媒体边界 8、私聊收尾及归属变化 4、投递恢复 18、路由运行器 2，
  合计 34 参数场景。覆盖 pending/accepted 正文路径、终态重放及重启恢复。

schema 39 / 协议 30 未变。源 prepare 并发压缩栅栏、operator 媒体回放、实际载荷压缩及完整房间迁移
仍按[清理边界](forward-terminal-payload-retention.md)跟踪，B04 保持开放。
未跑全仓、容量或真机，未提交或部署。
源码与日志摘要：`/tmp/imv2-b04-inbox-terminal-sources-20260919.json`。

<a id="20260919-forward-prepare-terminal-snapshot"></a>

## 2026-09-19：B04 准备导出在同一快照选择终态或载荷

源端服务改用 prepareForDelivery；原 pair advisory lock 内，一条 SQL 联结 export/receipt，
可见终态时不选择 payload，校验 source room/revision、导出与回执摘要后返回结果。
尚无回执则读取并复核完整导出，原首次授权、配额和导出/任务原子提交不变。
取得完整导出后服务仍重查回执，处理之后发生的提交。公共 prepare 保留返回完整导出的合同；
实际压缩启用前仍须定义它的无正文行为，不能把此次改动描述为所有 API 已支持压缩。

真实 PostgreSQL fixture 先断言终态预查为空、准备返回原导出，再提交回执并调用生产准备入口，
验证在源房间/正文不存在时返回原成功或拒绝；更改源绑定及异常回执摘要拒绝。
这是受控排列“预查未命中 → 回执提交 → 准备查询”，并未执行实际清理或并发压缩工作器。
SQL 同一快照的读取仍需与后续压缩事务联测。

过滤 PostgresV2ForwardTerminalReplayTests、forwardExportCommitAndReplay、forwardTerminalReceiptRecovery、
forwardRoutedRuntimeLifecycle，共 5 项 / 2 套件通过，5.795 秒。
包括终态专项、4 个摘要长度参数，以及导出 2 / 回执 4 / 双 owner 运行器 2 个参数场景。
日志 `/tmp/imv2-b04-prepare-terminal-snapshot.log`；源码摘要 `/tmp/imv2-b04-prepare-terminal-snapshot-sources-20260919.json`。
未跑全仓、容量、设备或实际 GC；schema 39 / 协议 30 未变，B04 保持开放。

<a id="20260919-forward-inbox-owner-metadata"></a>

## 2026-09-19：B04 收件箱保存独立归属，operator 重放不读正文

schema 40 为 message_forward_inbox 新增非空 target_shard_id / target_epoch，并约束非空分片、
非负代次；原身份不可变触发器覆盖新字段。接收导出时与 inbox/media 同事务保存。
operator 媒体重放改读归属和 state，通过不可删除的 inbox_media 行校验 ordinal；保留
inbox → room → import 锁顺序、当前归属检查、仅 pending inbox 重排 paused 工作及原审计幂等规则。
不再为终态或非终态 operator 请求选择/解码 payload，错误序号及旧归属仍拒绝。

新建库标识、Swift/SQL 启动门禁、实现状态文档及生命周期测试的旧版注入脚本同步到 schema 40；
协议仍为 30，无旧库迁移脚本。本次没有放宽正文非空、不可变或删除约束，没有启用清理任务。

- `/tmp/imv2-b04-inbox-owner-metadata.log`：5 项 / 2 套件通过，28.961 秒。
  含摘要长度 4、收件箱接受恢复 2、operator 投递/媒体 2、schema 漂移 42 个参数场景，及终态 fixture。
  schema 新增缺归属分片非空、缺代次、缺归属约束 3 场景，Swift 和 SQL 门禁均拒绝。
  operator 补验证归属元数据不可改、拒绝终态的新请求返回 notPaused、旧审计重放不变、
  不存在媒体序号/错误分片/当前 epoch 已变化时新请求拒绝。没有物理清理后的重放验证。
- `/tmp/imv2-b04-schema40-bootstrap.log`：原生 PostgreSQL 新建库、恢复及结构漂移脚本通过。
  使用独立创建的临时数据库；测试后已清理。

文档链接、结构、schema 表覆盖、协议文档及差异检查通过；未跑全仓、容量或真机，未提交或部署。
B04 仍须完成实际压缩状态、清理工作器、剩余读者/媒体保留边界与完整房间迁移。
源码/日志摘要：`/tmp/imv2-b04-inbox-owner-metadata-sources-20260919.json`。

<a id="20260919-forward-inbox-compaction"></a>

## 2026-09-19：B04 目标终态正文实际清理与维护接线

schema 41 为目标 inbox 引入 payload_compacted_at 和单向清理约束。仅已完成/拒绝的正文可以置空，
身份、摘要、结果、时间及其他元数据必须不变；清理后的正文不能恢复，记录不可删除。
新增按 completed_at/export_id 的部分索引，canonical 基线为 149 表、350 索引。
源 export 载荷仍非空且不可修改；不将目标清理描述为双端全部完成。

PostgresV2ForwardInboxCompactor 按 7 天终态排查保留期、1...1024 有界批量执行，
单条 SQL + FOR UPDATE SKIP LOCKED 原子转换；Gateway 现有维护任务调用各 owner 后台库，
沿用取消/关闭生命周期。7 天不是幂等身份期限；身份、摘要、结果及媒体映射没有删除。
没有部署、修改生产库或清理媒体对象/备份。

真实 PostgreSQL fixture 对成功、拒绝验证：pending/accepted 不清理、未满期限不清理、
非法提前置空拒绝、事务取消回滚后仍可清理、4 个并发清理器合计只清理一次、再次运行零行。
直接查询断言数据库 payload 已为空，随后运行 receive、status、terminalReceipt、加锁读取和
importForwardExport，原结果仍可重放，改参冲突仍拒绝，恢复正文/删除身份仍失败。
operator 媒体测试先实际清理拒绝终态正文，再验证迟到请求、序号、归属和原审计重放。
这些测试不等同 SIGKILL 或真实媒体存储并发清理验收。

- `/tmp/imv2-b04-inbox-compaction-final.log`：6 项 / 2 套件通过，43.604 秒。
  含终态 fixture、摘要长度 4、收件箱接受恢复 2、operator 2、投递恢复 18、schema 漂移 45 参数场景。
  漂移覆盖缺清理列、约束和扫描索引；Swift 与 SQL 启动门禁均拒绝。
- `/tmp/imv2-b04-schema41-bootstrap-final.log`：新建库、schema 恢复与结构漂移通过。
- 初次 bootstrap 的约束自动命名冲突、索引数量基线失败日志保留在
  `/tmp/imv2-b04-schema41-bootstrap.log`、`/tmp/imv2-b04-schema41-bootstrap-after.log`。
  修正期间的旧编译产物在 `/tmp/imv2-b04-inbox-compaction.log` 有 1 项结构断言失败；
  最终源码重新编译并运行上述 final 日志，历史失败不作为通过证据。

文档、schema 表覆盖、协议文档及差异检查通过；未跑全仓、容量或真机，未提交或部署。
尚须完成源端清理、进程强杀/媒体组合及完整 owner 迁移，B04 保持开放。
源码/日志摘要：`/tmp/imv2-b04-inbox-compaction-sources-20260919.json`。

<a id="20260919-forward-source-compaction"></a>

## 2026-09-19：B04 源 export 终态正文清理

schema 42 为源 export 增加 delivery_completed_at / payload_compacted_at。投递 job 完成触发器
与 job 同事务写入完成标记，导出不可变触发器必须看到 completed job、相同完成时间和匹配摘要的回执。
源清理器按部分索引扫描，要求投递与回执均满 7 天、两侧摘要一致；单批 1...1024，SKIP LOCKED，
只把正文置空。身份、路由、媒体 ID、摘要与回执不清理，禁止恢复正文或制造新的接受。
Gateway 原有维护任务已接入源清理，与目标清理分别处理失败和取消。

业务 prepareForDelivery 在清理后返回原终态；直接 prepare 在验证原绑定及回执后抛出
payloadCompacted，不误报源不存在或重新导出。旧租约不能 complete/reschedule 已完成任务。
保留期不是幂等身份期限；源媒体引用释放沿用终态回执规则，未声称清理媒体对象或备份。

真实 PostgreSQL 新增：仅有回执不可清理、paused/pending/claimed 不清理、伪造完成资格拒绝、
完成标记与投递完成共同回滚、未满期限跳过、清理回滚、4 个并发清理器只更新一次、重复运行零行。
确认实际 payload=NULL；原接受/拒绝结果、迟到源回执、目标导入、改参冲突和直接 prepare 错误仍正确。
摘要错误的回执不能使 job 完成并建立清理资格。未删除约束或关闭业务触发器。

- `/tmp/imv2-b04-source-compaction.log`：业务回归 5 项通过，包含导出 2、回执 4、投递恢复 18、
  双 owner 运行器 2、schema 漂移 50，共 76 参数场景；该轮整体 7 项中新增 fixture 有 1 项失败，
  原因是测试直接尝试 paused → claimed，被原状态机拒绝，不能把本轮称为全绿。
- 修正测试为 paused → pending → claimed，未修改生产代码或已通过的业务测试，定向重跑
  `/tmp/imv2-b04-source-compaction-after.log`：2 项 / 1 套件通过，0.408 秒。
- `/tmp/imv2-b04-schema42-bootstrap-final.log`：新建库、恢复、结构漂移通过。
  基线 149 表、351 索引、26 应用触发器、24 函数；早期计数基线失败日志
  `/tmp/imv2-b04-schema42-bootstrap.log`、`/tmp/imv2-b04-schema42-bootstrap-after.log` 保留。

文档、schema 表覆盖、协议文档和差异检查通过。未跑全仓、容量、真机或 SIGKILL，未部署或提交。
B04 仍缺强杀/媒体端到端组合、成本和完整房间迁移证据。
源码/日志摘要：`/tmp/imv2-b04-source-compaction-sources-20260919.json`。

<a id="20260919-forward-media-terminal-compaction"></a>

## 2026-09-19：B04 真实媒体复制后双端清理与迟到回调

扩展 forwardMediaImportBytesAndRecovery 两个参数：compact-success / compact-rejected。
使用真实 source/target PostgreSQL 与两个独立本地文件 provider，复制真实字节并记录摘要。
成功路径扫描并接受消息；拒绝路径在原媒体租约有效时冻结目标房间，使收件箱拒绝。

两条路径均验证 pending 不清理；目标先实际清理正文时，源仍没有回执/完成状态，源不能清理。
目标 endpoint 未配置媒体工作器也可重放终态；源记录回执仍不立即清理，投递完成后才清理。
SQL 直接断言两端 payload=NULL。迟到 recordCopied/complete/reject/retry 和 claim 使用仍在原租约
有效期内的逻辑回调时间，全部不能写入；拒绝不能仅归因于租约过期。operator 返回 notPaused。
真实删除源文件后，目标 endpoint 与源服务仍返回原接受/拒绝结果，目标文件字节不变，
媒体对象、导入任务、映射和消息的整体快照不变；对象数保持 1，成功 1 条消息、拒绝 0 条消息。

`/tmp/imv2-b04-media-terminal-compaction.log`：1 项 / 1 套件、16 参数场景全部通过，12.531 秒。
包含原大文件、扫描重试、ACK 丢失、租约、并发复制、取消、双附件、EICAR 等 14 场景和新增 2 场景。
本轮仅修改测试与文档，schema 42 / 协议 30 不变，未修改生产代码或重跑全仓。

边界：测试单独推进正文清理的时钟，没有执行七天后的媒体对象过期流程；复制在清理前已完成，
不代表在途复制跨清理、生产对象存储、孤立对象擦除、SIGKILL、容量或完整房间迁移均已通过。
B04 继续开放。文档链接/结构及差异检查通过；未提交或部署，临时数据库和文件已清理。
源码/日志摘要：`/tmp/imv2-b04-media-terminal-compaction-sources-20260919.json`。

<a id="20260919-forward-local-purge-fence"></a>

## 2026-09-19：B04 本地媒体删除后禁止迟到提交重建对象

发现 V2LocalFilesystemMediaProvider.purge 仅 unlink 最终文件，正在暂存的普通上传或转发复制
随后仍可 move/link 回同一对象。修复为持久 `.object-state` 删除标记与每对象 flock：
两类提交与删除共用锁；删除同步标记和目录后 unlink，重复删除也同步既有标记，再同步对象目录。
各读取入口检查标记，处理标记已写入但旧文件尚未移除的状态。锁文件不删除，避免 inode 更换破坏互斥。
标记跨 provider 重建/prepare 保留；标记和锁文件无自动 GC，媒体 ID 不得复用。
文件锁与 I/O 在既有 detached utility 工作中执行，不阻塞 NIO event loop。

新增测试覆盖普通和转发两条提交：已暂存后被另一个 provider 删除，再提交拒绝；
每条路径 8 次提交/删除并发，最终不能下载；重新构造 provider 并 prepare 后同一 ID 上传仍拒绝。
另重建“标记已持久但旧文件仍在”的磁盘状态，旧下载目标、扫描及转发对象复核均拒绝，重复 purge 移除文件。
这不是实际 SIGKILL 或多进程/Linux 文件系统验收。

旧 concurrent 复制测试原用 purge 模拟未确认文件丢失，却要求同 ID 重建。现改为直接移除测试文件，
明确模拟偶发丢失；永久删除由新增用例验证。没有放宽已删除对象的防护来满足旧测试。

- `/tmp/imv2-b04-local-purge-fence.log`：12 项 / 3 套件通过，0.043 秒。
  新删除防护、原本地 provider 和 Vapor 字节路由专项。
- `/tmp/imv2-b04-local-purge-media-regression.log`：1 项 / 1 套件，16 参数场景通过，12.603 秒。
  真实双 PostgreSQL、本地文件复制/扫描/回收及双端正文清理后的媒体终态重放回归。

schema 42 / 协议 30 未变。该 provider 只用于本地开发，生产存储防迟到写入仍由 E03 验收。
未跑全仓、真机、容量或强杀；未提交或部署。文档链接/结构和差异检查通过，临时测试库已清理。
源码/日志摘要：`/tmp/imv2-b04-local-purge-fence-sources-20260919.json`。

<a id="20260919-forward-local-purge-sigkill"></a>

## 2026-09-19：B04 本地媒体真实 SIGKILL 与独立进程恢复

新增 macOS 专项 V2LocalMediaPurgeCrashTests，复用仓库已有 Swift Testing 子进程宿主机制。
对 staged / installed / purged 三个检查点，各启动一个真实进程执行当前 provider，写入检查点后
直接 SIGKILL 自身；父进程要求退出原因为 uncaughtSignal、信号为 SIGKILL，且检查点内容匹配。
每次再启动另一个真实进程，仅从文件系统恢复并要求正常退出，共六个子进程。

验证范围：暂存后中断不产生最终对象，prepare 清理暂存并允许重试；安装后中断保留原字节，
清理遗留暂存后同 ID/摘要安装仍幂等；删除完成后中断，新的 provider 仍拒绝同 ID 的转发安装。
每个子进程有 30 秒超时，并通过检查点防止超时杀进程被当成检查点通过；取消只终止本测试子进程。

`/tmp/imv2-b04-local-purge-sigkill-after.log`：1 项 / 1 套件、3 参数场景通过，0.430 秒。
初轮日志 `/tmp/imv2-b04-local-purge-sigkill.log` 为测试诊断字符串类型的编译失败，修正后重跑；
未修改生产代码，也未重跑数据库/全仓套件。schema 42 / 协议 30 不变。

本证据是应用进程在 API 边界被 SIGKILL；不是文件系统掉电、fsync 内强杀、多进程同时竞争、
数据库清理事务强杀、生产对象存储或 Linux 验收。B04 仍有对应组合、容量与完整房间迁移缺口。
文档链接/结构及差异检查通过，未提交或部署，子进程和临时文件已收尾。
源码/日志摘要：`/tmp/imv2-b04-local-purge-sigkill-sources-20260919.json`。

<a id="20260919-forward-compaction-sigkill"></a>

## 2026-09-19：B04 清理事务提交前后真实 SIGKILL

新增 PostgresV2ForwardCompactionCrashTests，源/目标 × 提交前/提交后 × 接受/拒绝共 8 个参数场景。
每个场景由真实子进程调用当前 PostgresV2ForwardExportCompactor 或 PostgresV2ForwardInboxCompactor，
提交前场景在外层 Fluent 事务内执行清理 SQL，确认更新 1 行后 SIGKILL；提交后场景在清理器返回后 SIGKILL。
父进程检查实际退出信号和检查点，再启动独立恢复进程，共 16 个子进程。
未提交场景记录真实 PostgreSQL backend PID，恢复进程先确认该连接已消失再检查与重跑。

恢复验证：提交前正文和摘要保留、清理时间为空，重跑更新 1 行；提交后正文已空、摘要保留、
清理时间非空，重跑更新 0 行；再次运行均为 0。未选中的另一侧表正文保持不变。
源终态查询/回执重放/prepareForDelivery 和目标 receive/terminalReceipt/importForwardExport
仍返回相同成功或拒绝结果。没有源房间与业务正文可用于重新授权或重新接受。

`/tmp/imv2-b04-compaction-sigkill-after.log`：1 项 / 1 套件，8 参数全部通过，4.431 秒。
初轮 `/tmp/imv2-b04-compaction-sigkill.log` 为测试局部函数缺 @Sendable 的编译失败，修正后定向重跑。
本轮仅新增测试及文档，schema 42 / 协议 30 不变，无生产代码修改。

范围：在脚本拥有的临时 PostgreSQL 数据库中，用合法导出/回执/收件箱 fixture 分别执行两侧真实清理器；
两侧表位于同一临时物理库，用于验证各自本地事务，不代表跨 owner 网络故障或完整运行器联动。
SIGKILL 杀的是清理客户端，不是 PostgreSQL 服务，也不是 WAL/PITR、主机掉电或 Linux 验收。
B04 仍缺运行器/外部媒体副作用组合、容量成本与完整 owner 迁移。
文档链接/结构及差异检查通过；未跑全仓、未提交或部署，子进程和测试数据库已收尾。
源码/日志摘要：`/tmp/imv2-b04-compaction-sigkill-sources-20260919.json`。

<a id="20260919-forward-compaction-cost"></a>

## 2026-09-19：B04 清理 SQL 成本与源端历史回执扫描修复

新增 `scripts/measure_v2_forward_compaction.py`，只在其创建的唯一临时数据库加载当前 schema，
直接提取 Swift 清理器中的 SQL 并替换已知绑定；未知绑定拒绝执行。保存完整
EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON)、PostgreSQL 版本及源码/schema/脚本摘要。
每组装载后 VACUUM ANALYZE；每次测量实际 UPDATE、触发器与 WAL，随后 ROLLBACK。
不修改服务端设置，不通过关闭顺序扫描强迫计划。

数据集：1,000/10,000 条记录配 1 KiB 文本，另有 1,000 条配 64 KiB 文本；文本用逐行不同的散列片段构造。
75% 为已清理历史终态，5% 为可清理旧终态，5% 为近期终态，其余为未完成任务；
最终 fixture 的可清理集合包含成功和拒绝。两侧分别测量 limit 1/128/1024，共 18 组。
每组更新条数必须等于 min(limit, rows/20)，万行源端小批不得全扫历史 receipt/job。

发现与修复：原源端 JOIN 在 10,000 条记录、limit=1 时先扫描 8,000 条旧回执
（另过滤 500 条近期回执），核验 500 个完成任务，再选 1 条。现在使用主键标量子查询，
保持 job 状态/时间、receipt 摘要/记录时间全部条件不变，缺行不满足条件；部分索引按时间选候选。
最终万行 limit=1/128 分别只查询 1/128 条任务及回执；目标小批同样走候选索引。
目标 limit=1024、更新 500 行时仍有 UPDATE 连接输入的全表扫描，不宣称扫描量在所有分布下都受 limit 限制。

| 最终数据集与批量 | 源端实际更新 / 执行时间 / WAL 字节 | 目标实际更新 / 执行时间 / WAL 字节 |
| --- | --- | --- |
| 10,000 条 / 1 KiB / limit 1 | 1 / 0.973 ms / 877 | 1 / 0.796 ms / 513 |
| 10,000 条 / 1 KiB / limit 128 | 128 / 5.089 ms / 106,368 | 128 / 2.970 ms / 63,864 |
| 1,000 条 / 64 KiB / limit 128 | 50 / 5.829 ms / 136,050 | 50 / 4.593 ms / 119,550 |

原测量 `/tmp/imv2-b04-compaction-cost.{json,log}` 保留旧 SQL 与计划。
中间 `/tmp/imv2-b04-compaction-cost-after.log` 因修改 fixture 成功/拒绝分布时误改 bucket 表达式，
更新数断言失败；修正脚本后重新运行。最终 `/tmp/imv2-b04-compaction-cost-final.{json,log}` 全部通过。
前后 fixture 的成功/拒绝比例不同，因此不将时延差作为严格性能提升比率；扫描计划本身证明原问题及修复。

修改后 `/tmp/imv2-b04-compaction-cost-regression.log`：两套件通过，清理/并发重放与摘要边界通过，
8 个成功/拒绝、源/目标、提交前后 SIGKILL 场景通过，总计 4.251 秒。
测试框架汇总 4 项，其中子进程专用入口在父进程中按设计跳过，由 8 个场景实际启动执行。
未改 schema 42 / 协议 30，未跑全仓业务套件。

这些是单机缓存命中的 SQL 探针，每轮回滚后可能留有已回滚版本；不提供冷缓存、百分位延迟、
混合业务、运行器开销、复制中断、长期身份增长或生产容量结论。B04 继续开放，完整归属迁移仍依赖 B27。
源码及日志摘要：`/tmp/imv2-b04-compaction-cost-sources-20260919.json`。未提交或部署。

<a id="20260919-forward-copy-purge-interleaving"></a>

## 2026-09-19：B04 导入工作器复制回调与媒体清除交错

在真实双库、本地文件的 forwardMediaImportBytesAndRecovery 专项中新增
purge-before-copy / purge-after-copy 两个参数。测试包装器仅在真实 copier 调用前或返回后插入检查点，
实际字节 I/O、claim、回调、重试判定均由现有导入工作器和提供方执行。
这是确定性排列交错，不是操作系统随机竞争，也不是在文件字节流中段暂停。

检查点中，在临时媒体到期后先运行真实 retention worker，确认 pending inbox 仍阻止过期；
随后冻结目标房间，通过真实 claim 授权检查把 inbox 置为 ROOM_FROZEN，
再次运行 retention worker，实际标记过期并创建 purge outbox，再由真实 purge worker 清除对象。
同一检查点内重复 purge 无新工作，下载目标签发拒绝。

释放复制调用后，before-copy 场景实际尝试复制/安装但被删除标记阻止，after-copy 场景返回清除前的成功回执；
导入工作器都应返回 superseded，再次运行 idle。原租约仍未到期，结果不能归因于时间超时。
检查媒体保持 expired、copied_digest 仍为空、purge outbox 已完成、没有接受消息且对象仍不可访问。
随后推进到 7 天保留期后实际清理 inbox 正文，并经 endpoint 重放原 ROOM_FROZEN 回执。

本轮只新增测试，生产路径沿用此前的本地删除标记与持久状态栅栏。
`/tmp/imv2-b04-copy-purge-interleaving.log`：1 项 / 1 套件、18 个参数场景全部通过，14.104 秒。
新增两种交错与原有 16 场景同轮通过；未跑全仓业务套件，schema 42 / 协议 30 不变。
源码/日志摘要：`/tmp/imv2-b04-copy-purge-interleaving-sources-20260919.json`。未提交或部署。
范围不包括进程强杀、生产对象存储、文件流中段停顿、完整源投递运行器或房间归属迁移。

<a id="20260919-forward-media-prepare-flight"></a>

## 2026-09-19：B04 本地媒体初始化重入修复

检查取消/重启路径时发现 V2LocalFilesystemMediaProvider.prepare 在 didPrepare=false 后等待文件 I/O，
同一 actor 的其他调用可在等待期间再次进入删除/重建 .upload-staging 的操作。
32 个并发调用的真实文件系统专项复现目录重复创建错误；这也使较早调用返回后开始的暂存上传暴露于后续删除。

现由提供方持有一个初始化 Task，在首次 await 之前保存；其他调用等待该任务。
成功后置 didPrepare，成功或失败均由任务自身清除运行中引用，失败后可重试。
调用方取消不取消共享初始化，各调用等待已拥有的文件操作收尾；实际阻塞文件操作仍在 utility detached task 中执行。
这只协调同一提供方实例，不是多个实例/进程共用媒体根目录的启动锁。

新增 V2LocalMediaPrepareConcurrencyTests：32 次初始化后立即各写一个独立暂存文件，
全部返回后核验 32 份字节均保留并提交、下载一致；另验证根路径被普通文件占用导致失败后，移除阻碍可重试成功。
初轮 `/tmp/imv2-b04-media-prepare-before.log` 为测试误读 fileprivate 字段的编译失败，
修正测试为自行保存媒体 ID 后，`/tmp/imv2-b04-media-prepare-repro.log` 在未改生产代码时复现目录创建竞态。
修改后 `/tmp/imv2-b04-media-prepare-after.log`：4 套件、框架汇总 12 项，0.170 秒；
32 并发初始化、失败重试、原提供方行为、删除栅栏和 3 个 SIGKILL 恢复参数通过。
子进程入口在父进程中按设计跳过，由 SIGKILL 参数实际启动执行。
真实双库媒体复制回归 `/tmp/imv2-b04-media-prepare-copy-regression.log`：18 参数全部通过，14.156 秒。
没有扩大到全仓业务测试；schema 42 / 协议 30 不变，未提交或部署。
源码/日志摘要：`/tmp/imv2-b04-media-prepare-sources-20260919.json`。

<a id="20260919-forward-runtime-compacted-retry"></a>

## 2026-09-19：B04 媒体运行器回执丢失、正文清理与不可达重试

在真实双库、本地文件专项新增 runtime-ack-loss-compacted 参数，驱动完整
V2ForwardDeliveryRuntime → DeliveryWorker → ImportEndpoint → MediaImportWorker → 真实本地 copier/scanner。
第一次目标正常提交媒体和消息，测试投递边界丢弃终态回执并抛 targetUnavailable；
等待源任务持久化 pending/retry_count=1 后取消并等待运行器退出。

推进逻辑时钟超过 7 天，实际清理目标 inbox 正文，源端没有收到回执所以不能清理。
第二个运行器使用缺少目标分片的配置注册表，模拟目标不可达，必须持久化 pending/retry_count=2，
不能形成拒绝回执或放行源正文清理。再次取消并等待退出。

移除源提供方文件以模拟源字节不可用；第三个运行器连接不配置媒体 worker 的真实 endpoint，
必须从已清理正文的目标终态取回原结果，完成源任务（retry_count=3）。
验证源回执与原接受结果一致、目标仅一条消息和一个媒体对象、目标字节不变；
再推进源回执与完成时间的保留期，实际清理源正文，目标重放仍保持原结果。
每次运行器均有有界状态等待并在成功/异常路径取消及等待，不能留下后台任务。

本场景故障由受信投递接口和配置路由注入，不是真实网络断连；三次运行器均为同一测试进程内重建，
不是跨进程 SIGKILL。源字节删除为故障注入，不宣称业务媒体保留策略会提前删除来源。
没有新增生产代码；完整进程强杀、生产外部存储和归属迁移仍开放。
`/tmp/imv2-b04-runtime-compacted-retry.log`：1 项 / 1 套件、19 参数场景全部通过，15.307 秒。
新增运行器组合与原 18 个媒体场景同轮通过；未跑全仓业务套件，schema 42 / 协议 30 不变。
源码/日志摘要：`/tmp/imv2-b04-runtime-compacted-retry-sources-20260919.json`。未提交或部署。

<a id="20260919-snapshot-storage-types"></a>

## 2026-09-19：B01 快照导入存储类型保护

快照清单匹配、恢复页索引、应用页、准备切换与确认切换原有部分直接 Int64/Int 解码，
现对八个持久化整数字段先检查 SQLite 的实际 integer 类型，再执行原领域范围/一致性校验。
新增 16 参数 × 3 阶段共 48 组合，确认 REAL 输入返回 storageRangeExceeded，
原字段值/类型和游标保持；显式修复测试数据后同一快照继续成功。
页索引注入临时绕过 next_page_index<=page_count，其他字段保留正常约束。

`/tmp/imv2-b01-snapshot-storage-types-after.log`：V2SyncEngineTests 124 项全部通过，3.600 秒。
初轮 `/tmp/imv2-b01-snapshot-storage-types.log` 为新增测试宏内缺 try 的编译失败，修正后重跑。
未跑全仓、App、真机或跨进程恢复；本地 schema 未变，B01 仍有其他读取入口与用例映射待审计。
源码与日志摘要：`/tmp/imv2-b01-snapshot-storage-types-sources-20260919.json`。未提交或部署。

<a id="20260919-push-storage-types"></a>

## 2026-09-19：B01 Push 意图整数恢复检查

本地 Push 的五个整数读取入口现先检查实际 integer 类型，再沿用既有范围及状态关系检查。
新增 10 个真实数据库关闭/重开场景，覆盖分数与 Int64 上界外的 REAL 值；
异常读取、重试和 owner 替换均明确拒绝且不覆盖原状态，修复测试字段后原意图可继续重试。
仅 attempt_count=1.5 不绕过约束，其他注入通过临时关闭 CHECK 模拟损坏记录。

`/tmp/imv2-b01-push-storage-types.log`：V2LocalPushIntentTests、V2PushIntentReconcilerTests
共 14 项 / 2 套件通过，1.275 秒；包含原计数饱和、取消、迟到响应与所有者替换回归。
未修改 schema，未跑全仓或真实 APNs；B01 仍有其他恢复/比较入口待审计，相关生命周期项不因此关闭。
源码/日志摘要：`/tmp/imv2-b01-push-storage-types-sources-20260919.json`。未提交或部署。

<a id="20260919-command-duplicate-storage"></a>

## 2026-09-19：B01 命令重复比较与已读水位

四个命令重复比较入口补实际 SQLite integer 类型检查；已读合并水位在 MAX 前检查每个参与序号，
拒绝被更大合法值掩盖的小数等非法数据。正常空集合、pending/acknowledged 选择和幂等行为不变。
新增 12 个真实 SQLite 场景，不关闭 CHECK；异常返回 commandConflict、原记录保留且无新增命令，
显式修复测试数据后重复提交/水位推进可继续。

`/tmp/imv2-b01-command-duplicate-storage.log`：新增专项、恢复边界、成员/撤回/编辑/已读 outbox
共 17 项 / 6 套件通过，0.171 秒。未跑全仓、App 或真机；schema 未变，B01 仍开放。
源码/日志摘要：`/tmp/imv2-b01-command-duplicate-storage-sources-20260919.json`。未提交或部署。

<a id="20260919-social-storage-types"></a>

## 2026-09-19：B01 私聊能力和已读版本恢复

私聊发送能力版本及已读可见性/偏好版本改用 SQLite integer 存储检查；旧已读序号在新旧版本分支前校验，
不允许较新的事件覆盖损坏历史。新增五字段 × 两种 REAL 值，验证明确拒绝、原值与同步游标保留，
修复测试数据后同一批次可以继续应用。全部使用正常 SQLite CHECK，无约束绕过。

`/tmp/imv2-b01-social-storage-types.log`：新专项、V2DirectReceiptVisibilityTests 与 V2SyncEngineTests
共 127 项 / 3 套件通过，3.679 秒。包含已有隐藏可见性、旧事件、快照与恢复回归；
新增场景本身不是数据库重开测试。未改 schema、未跑全仓、未提交或部署，B01 仍开放。
源码/日志摘要：`/tmp/imv2-b01-social-storage-types-sources-20260919.json`。

<a id="20260919-search-storage-types"></a>

## 2026-09-19：B01 搜索索引整数读取

搜索状态/观察、索引代次与版本、任务期望修订、主库与派生文档版本/序号的读取增加实际正 integer 检查，
主库不存在的 LEFT JOIN NULL 继续按缺失处理，其他类型明确返回 invalidMessagePayload。
新增七类位置 × 两种 REAL，共 14 个真实 SQLite 场景，不关闭 CHECK。
确认异常观察/查询拒绝、任务保留、派生索引重建恢复，以及显式修复主库字段后同一任务继续完成。

`/tmp/imv2-b01-search-storage-types.log`：V2MessageSearchTests 与 V2SyncEngineTests
共 135 项 / 2 套件通过，3.868 秒。新增场景没有关闭/重开数据库，不能当作新的跨进程恢复证据。
未改 schema、未跑全仓、未提交或部署。B01 仍需完成其余投影/回滚入口核对。
源码/日志摘要：`/tmp/imv2-b01-search-storage-types-sources-20260919.json`。

<a id="20260919-reset-fence-storage"></a>

## 2026-09-19：B01 重置回滚与快照搜索状态整数检查

回滚游标三字段及快照复制的搜索 generation/index_version 改为先检查实际 integer 类型。
新增 10 个真实 SQLite 异常场景，确认取消/准备切换被拒绝时游标、快照页进度与回滚记录保留，
修复注入字段后原流程仍可完成。仅回滚 ACK 序号注入绕过字段间关系 CHECK，其余未关闭约束。

`/tmp/imv2-b01-reset-fence-storage.log`：V2SyncEngineTests 与 V2MessageSearchTests
共 136 项 / 2 套件通过，3.957 秒。未改 schema、未跑全仓/App/真机、未提交或部署。
B01 仍有成员/角色收据和其他投影的内部版本比较待核对。
源码/日志摘要：`/tmp/imv2-b01-reset-fence-storage-sources-20260919.json`。

<a id="20260919-effect-storage-types"></a>

## 2026-09-19：B01 公告与角色权限收据整数检查

公告/角色权限的效果收据和当前投影版本、可选来源序号，以及权限基线版本，增加精确正 integer 读取。
新增 18 个真实 SQLite 异常场景，保留正常 CHECK，验证 invalidMessagePayload、原值/游标保留，
以及失败事务不会残留新效果收据；恢复测试字段后原事件可继续应用。
收据重复场景移除旧 personal 事件 fixture 后保留独立效果账本，不作为真实裁剪/跨进程恢复验收。

`/tmp/imv2-b01-effect-storage-types.log`：V2SyncEngineTests 与 V2MemberRoleRecoveryTests
共 130 项 / 2 套件通过，3.977 秒。没有修改成员历史聚合实现；该入口仍待下一步审计。
未改 schema、未跑全仓、未提交或部署，B01 继续开放。
源码/日志摘要：`/tmp/imv2-b01-effect-storage-types-sources-20260919.json`。

<a id="20260919-member-storage-types"></a>

## 2026-09-19 成员效果历史整数读取

- 修复：成员收据三个整数字段、历史最大修订与角色来源序号使用实际存储类型检查；聚合拒绝被较大合法版本掩盖的异常历史。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2MemberRoleRecoveryTests'`，131 项、2 套件通过，3.942 秒；新增参数场景 8 个。
- 日志：`/tmp/imv2-b01-member-storage-types.log`；源码证据：`/tmp/imv2-b01-member-storage-types-sources-20260919.json`。
- 边界：真实 SQLite 正常 CHECK 下验证回滚和修复后重试；未跑全仓或真机，B01 继续开放。

<a id="20260919-room-projection-storage"></a>

## 2026-09-19 房间投影整数比较

- 修复：时间线、禁言、房间冻结与群资料四处比较使用实际 integer 类型读取，拒绝 REAL 后再参与幂等或新旧版本判断。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomProjectionStorageTests|V2SyncEngineTests|V2MemberRoleRecoveryTests'`，132 项、3 套件通过，3.997 秒；新增 12 个参数场景。
- 日志：`/tmp/imv2-b01-room-projection-storage.log`；源码证据：`/tmp/imv2-b01-room-projection-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下验证重复/较新投递的事务回滚与修复后重试；未跑全仓、App 或真机，B01 继续开放。

<a id="20260919-message-effect-storage"></a>

## 2026-09-19 消息效果与墓碑整数读取

- 修复：消息收据、墓碑、当前撤回目标及旧式编辑七处修订比较先检查实际 integer 类型。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2MessageSearchTests'`，138 项、2 套件通过，4.025 秒；新增 14 个参数场景。
- 日志：`/tmp/imv2-b01-message-effect-storage.log`；源码证据：`/tmp/imv2-b01-message-effect-storage-sources-20260919.json`。
- 边界：真实 SQLite 正常 CHECK 下验证事务回滚、修复后重试及撤回正文不恢复；未跑全仓、App 或真机。B01 继续开放。

<a id="20260919-reaction-storage"></a>

## 2026-09-19 消息反应整数读取

- 修复：重复反应收据校验实际正 integer 来源序号与输入一致；当前反应版本排序拒绝非整数存储。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，128 项、1 套件通过，3.833 秒；新增 6 个参数场景覆盖重复/较新/迟到事件的回滚与修复后重试。
- 日志：`/tmp/imv2-b01-reaction-storage.log`；源码证据：`/tmp/imv2-b01-reaction-storage-sources-20260919.json`。
- 边界：保留正常 SQLite CHECK，未跑全仓、App 或真机；B01 继续开放。

<a id="20260919-profile-storage"></a>

## 2026-09-19 资料及失效记录整数读取

- 修复：六处资料版本读取及失效记录合并/清理前的最低版本检查，拒绝 REAL 存储参与比较。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2ProfileStorageTypesTests|V2ProfileRepositoryTests|V2SyncEngineTests'`，132 项、3 套件通过，3.959 秒；新增 16 个参数场景。
- 日志：`/tmp/imv2-b01-profile-storage.log`；源码证据：`/tmp/imv2-b01-profile-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下验证资料/私聊身份/待刷新记录事务回滚与修复后重试；未跑全仓、App 或真机。B01 继续开放。

<a id="20260919-membership-entry-storage"></a>

## 2026-09-19 成员入口整数检查与剩余范围核对

- 修复：成员入口的本人资格版本及他人成员事件比较已有群资料版本先检查实际正 integer。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2MemberRoleRecoveryTests|V2SyncEngineTests'`，134 项、2 套件通过，4.079 秒；新增 4 个异常场景。
- 日志：`/tmp/imv2-b01-membership-entry-storage.log`；源码证据：`/tmp/imv2-b01-membership-entry-storage-sources-20260919.json`。
- 范围核对：整数专题文首新增当前调用链表，明确置顶/权限快照、水位聚合与审核解码等剩余项；转发推进和群创建计数确认已有上游实际类型检查，未重复修改。
- 边界：本次未跑全仓、App、真机或转发专项；B01 继续开放。

<a id="20260919-effective-watermark-storage"></a>

## 2026-09-19 有效已读水位整数检查

- 修复：有效水位聚合检查全部正 integer 候选，不让较大合法值掩盖 REAL；本人水位同步更新前也检查原持久值。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2CommandDuplicateStorageTests|V2SyncEngineTests|V2ReadReceiptOutboxTests'`，135 项、3 套件通过，3.881 秒；新增 8 个参数场景。
- 日志：`/tmp/imv2-b01-effective-watermark-storage.log`；源码证据：`/tmp/imv2-b01-effective-watermark-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下覆盖持久水位、pending/acknowledged 回执、更新回滚和修复后重试；未跑全仓、App 或真机，B01 继续开放。

<a id="20260919-pin-storage"></a>

## 2026-09-19 置顶事件与快照整数检查

- 修复：可选置顶来源序号精确读取，快照合并前检查 shadow 状态/收据与相关 live 收据，保留 NULL 未知来源语义。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，129 项、1 套件通过，4.125 秒；新增 12 个参数场景。
- 日志：`/tmp/imv2-b01-pin-storage.log`；源码证据：`/tmp/imv2-b01-pin-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下覆盖增量与快照两侧数据，验证失败回滚和修复后同操作重试；未跑全仓、App 或真机，B01 继续开放。

<a id="20260919-policy-snapshot-storage"></a>

## 2026-09-19 角色权限快照整数检查

- 修复：快照两侧角色修订/来源序号及全局权限版本在排序和 SQL 合并前验证实际类型；保留 NULL 来源语义。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，130 项、1 套件通过，5.132 秒；新增 36 个参数场景覆盖快照更旧/相等/更新。
- 日志：`/tmp/imv2-b01-policy-snapshot-storage.log`；源码证据：`/tmp/imv2-b01-policy-snapshot-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下验证快照准备事务回滚及修复后同快照切换；未跑全仓、App 或真机。B01 继续开放。

<a id="20260919-policy-global-moderation-storage"></a>

## 2026-09-19 增量权限全局版本与审核解码

- 修复：增量权限入口验证全局版本，审核公开读取先验证真实正 integer 再转换 UInt64。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2RoomProjectionStorageTests'`，131 项、2 套件通过，5.175 秒；新增 6 个权限参数场景，扩展两个既有审核异常场景的公开读取断言。
- 日志：`/tmp/imv2-b01-policy-global-moderation-storage.log`；源码证据：`/tmp/imv2-b01-policy-global-moderation-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下验证回滚及修复后重试；未跑全仓、App 或真机。房间聚合及基线全局版本仍待处理，B01 继续开放。

<a id="20260919-room-applied-storage"></a>

## 2026-09-19 房间已应用序号聚合检查

- 修复：八来源原始候选在聚合前验证实际类型与正值/零/NULL 域，结果经精确整数读取。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2RoomRecoveryRunnerTests'` 实际匹配 131 项、1 个同步套件，通过，5.288 秒；新增 16 个参数场景。第二过滤名未匹配套件，不计作 runner 验收。
- 日志：`/tmp/imv2-b01-room-applied-storage.log`；源码证据：`/tmp/imv2-b01-room-applied-storage-sources-20260919.json`。
- 边界：正常 CHECK 下覆盖同表/跨来源较大合法值掩盖小数，以及最大值、零和未知来源语义。新候选扫描的大历史读取成本待测；未跑全仓、App 或真机，B01 继续开放。

<a id="20260919-room-applied-index-cost"></a>

## 2026-09-19 房间已应用序号成本修复

- 测量脚本：`scripts/measure_v2_room_applied.py`，真实相关表/索引子集、两个房间、1 千/1 万/10 万三档合成数据，保留 CHECK。本机热缓存扫描发现 10 万档约 24 ms；新 8 个稀疏异常索引与 3 个序号索引使同档约 0.0054 ms。
- 成本证据：`/tmp/imv2-b01-room-applied-cost.json`、`/tmp/imv2-b01-room-applied-cost-final.json`、`/tmp/imv2-b01-room-applied-cost-no-index.json`；写入/空间样本和测量边界见整数专题，不外推生产容量。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2LocalSchemaContractTests'` 中同步 131 项通过，schema 2 项旧对象数/指纹失败；核对差异恰为 11 索引后更新合同，`--filter V2LocalSchemaContractTests` 两项通过。未重跑已通过的同步套件。
- 日志：`/tmp/imv2-b01-room-applied-indexed-final.log`、`/tmp/imv2-b01-room-applied-schema-after.log`；证据清单 `/tmp/imv2-b01-room-applied-index-cost-sources-20260919.json`。
- 边界：新库及快照索引复制；旧库未追加索引时不继承成本结果。无全仓、App 或真机验收，B01 继续开放。

<a id="20260919-policy-completion-storage"></a>

## 2026-09-19 权限基线完成路径整数检查

- 修复：全局权限修订及角色观察修订/可选序号在基线完成写入和版本比较前校验实际类型。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，132 项、1 套件通过，5.519 秒；新增 12 个相同/较新基线异常组合。
- 日志：`/tmp/imv2-b01-policy-completion-storage.log`；源码证据：`/tmp/imv2-b01-policy-completion-storage-sources-20260919.json`。
- 边界：正常 SQLite CHECK 下验证旧基线/待办保留及修复后相同请求完成；未跑全仓、App 或真机。未读快照独立聚合新列为待核对，B01 继续开放。

<a id="20260919-unread-snapshot-storage"></a>

## 2026-09-19 未读快照整数检查

- 修复：六个状态字段精确读取、成员修订先验证后过滤、独立水位 MAX 拒绝异常且保留无记录 NULL。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryPersistenceTests|V2ConversationUnreadModelTests|V2CommandDuplicateStorageTests'`，26 项、3 套件通过，0.531 秒；新增 20 个参数场景。
- 日志：`/tmp/imv2-b01-unread-snapshot-storage.log`；源码证据：`/tmp/imv2-b01-unread-snapshot-storage-sources-20260919.json`。
- 边界：head/子序号关系约束不允许的四种 fixture 临时绕过 CHECK，其余保留正常约束；验证原值保留及修复后读取，撤权/绑定隔离原回归通过。未跑全仓、App、真机或容量，B01 继续开放。

<a id="20260919-member-snapshot-storage"></a>

## 2026-09-19 成员快照历史整数检查

- 修复：授权群/同源 live 历史与 shadow 成员效果在冲突 join、复制和最新角色归并前检查三个整数字段。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2MemberRoleRecoveryTests|V2SyncEngineTests'`，139 项、2 套件通过，5.989 秒；新增 12 个参数场景。
- 日志：`/tmp/imv2-b01-member-snapshot-storage.log`；源码证据：`/tmp/imv2-b01-member-snapshot-storage-sources-20260919.json`。
- 边界：正常 CHECK 下验证准备失败保持 live 移除状态及修复后旧角色不复活；未跑全仓、App 或真机。其他 SQL 复制继续审计，B01 开放。

<a id="20260919-snapshot-receipt-storage"></a>

## 2026-09-19 公告与权限快照收据整数检查

- 修复：相关 live 与 shadow 历史收据在保留版本筛选前校验修订/可选来源序号，避免异常被过滤或复制。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，133 项、1 套件通过，5.961 秒；新增 16 个参数场景。
- 日志：`/tmp/imv2-b01-snapshot-receipt-storage.log`；源码证据：`/tmp/imv2-b01-snapshot-receipt-storage-sources-20260919.json`。
- 边界：正常 CHECK 下验证准备失败保持 live 版本及修复后同快照切换、历史收据保留；未跑全仓、App 或真机。其他 SQL 复制仍待核对，B01 开放。

<a id="20260919-reaction-snapshot-storage"></a>

## 2026-09-19 反应快照整数检查

- 修复：shadow 反应状态/收据及相关 live 收据在序号保留过滤前检查实际正 integer。
- 验证：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，134 项、1 套件通过，6.135 秒；新增 8 个参数场景。
- 日志：`/tmp/imv2-b01-reaction-snapshot-storage.log`；源码证据：`/tmp/imv2-b01-reaction-snapshot-storage-sources-20260919.json`。
- 边界：正常 CHECK 下验证准备事务回滚及修复后同快照切换；新旧添加/移除时可见表与版本表一致性尚需专项核对。本轮未跑全仓、App 或真机，B01/B06 继续开放。


<a id="20260919-reaction-snapshot-order"></a>

## 2026-09-19 反应快照合并与来源冲突

- 复现：live/shadow 分别复制可见反应和版本记录，导致旧添加复活或较新版本丢失。修复前 4 个参数场景产生 8 个断言问题，日志 `/tmp/imv2-b06-reaction-snapshot-order-before.log`。
- 修复：保留原授权房间范围；合并前校验实际正整数序号、同键房间/同版本/同源冲突，按较新房间序号选择 add/remove；收据保留前拒绝历史同源摘要冲突；依据最终版本重建可见反应，排除撤回/tombstone。
- 验证：先有 4 项反应专项通过，日志 `/tmp/imv2-b06-reaction-snapshot-order-targeted.log`。扩展测试的首次编译因 Swift Testing 不接受三组参数集合失败，记录于 `/tmp/imv2-b06-reaction-snapshot-order-final.log`；改为 8 个明确位组合后，`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2MemberRoleRecoveryTests'` 实际 143 项、2 套件通过，6.900 秒，日志 `/tmp/imv2-b06-reaction-snapshot-order-final-v2.log`。
- 新增覆盖：8 个新旧方向/add-remove/撤回组合，快照激活后关闭重开并重放旧来源；3 个同版本/同来源/历史来源冲突，检查准备失败、游标/live 状态保留及未准备标记。既有 8 个整数异常与独立反应快照专项同轮通过。
- 源码证据：`/tmp/imv2-b06-reaction-snapshot-order-sources-20260919.json`。
- 边界：未改 schema，未跑全仓/App/真机、容量或完整 owner 迁移；B01/B06 保持开放。此前整数专项的历史验证范围不扩大为本轮验证。


<a id="20260919-policy-eligibility-storage"></a>

## 2026-09-19 权限基线快照资格整数检查

- 复现：资格比较前未验证存储类型；异常修订可使基线静默被过滤，或将非法权限/序号复制后才在读取时失败。10 场景修复前产生 30 个断言问题，日志 `/tmp/imv2-b01-policy-eligibility-before.log`。
- 修复：对两侧授权且房间匹配的候选，在修订/来源比较前校验基线三个整数及 live/incoming 成员修订；不改变合法资格筛选条件和撤权范围。
- 验证：新增五位置 × 两种 REAL 共 10 场景，正常 CHECK 下确认准备失败保留原值/类型、游标和未准备标记，修复后同快照可激活并恢复两个权限角色。`swift test --package-path IMV2ClientKit --jobs 4 --filter V2SyncEngineTests`，137 项、1 套件通过，6.559 秒；既有房间保留/移除与权限快照回归同轮通过。
- 日志：`/tmp/imv2-b01-policy-eligibility-after.log`；源码证据：`/tmp/imv2-b01-policy-eligibility-sources-20260919.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量；普通房间行 SQL 复制和完整跨模块映射仍待完成，B01 保持开放。


<a id="20260919-snapshot-room-log-storage"></a>

## 2026-09-19 房间日志与游标快照整数检查

- 复现：复制前未验证事件序号、应用游标和裁剪下界。准备意外成功，REAL 游标进入激活库；读取 2^63 时 GRDB Row 强制转换触发 fatal error，修复前进程失败，未完整跑完参数矩阵。日志 `/tmp/imv2-b01-snapshot-room-log-before.log`。
- 修复：按原授权房间范围先验证三字段，再复制日志/游标；公开 groupEventCursor/roomLogTrimmedThroughSequence 使用实际整数读取并抛 storageRangeExceeded，缺失行保持零。
- 验证：12 个参数场景覆盖三字段 × 两种 REAL × 保留/移除。保留范围检查回滚、原值/类型和游标保留、修复后激活及关闭重开；移除范围允许丢弃异常旧记录，且无事件/公告残留。两个公开 getter 安全拒绝异常值，重开读取正常游标/零裁剪下界。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2RoomRecoveryPersistenceTests'`，159 项、2 套件通过，7.633 秒。日志 `/tmp/imv2-b01-snapshot-room-log-after.log`；源码证据 `/tmp/imv2-b01-snapshot-room-log-sources-20260919.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量。普通消息和管理等投影的复制仍须核对，B01 保持开放。


<a id="20260919-snapshot-message-storage"></a>

## 2026-09-19 消息快照与历史修订整数检查

- 修复：两侧相关消息的三个整数在冲突复制前检查；相关撤回记录修订在复制前检查；效果收据修订在保留版本筛选前检查，防止 REAL 被静默过滤或复制。
- 初始复现：18 参数场景、36 个断言问题，日志 `/tmp/imv2-b01-snapshot-message-before.log`。其中两个 live 收据场景存在夹具 ID 不一致，不能作为正确匹配候选的修复前证据。
- 中间轮：`/tmp/imv2-b01-snapshot-message-after.log` 实际只运行 139 项同步测试，搜索过滤名未命中。四个断言来自收据夹具 ID 不一致，另两个时限断言超出 5 秒；未改时限断言。修正夹具并使用真实搜索套件名，串行重跑相关套件。
- 最终验证：`swift test --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2SyncEngineTests|V2MessageSearchTests'`，150 项、2 套件通过，55.973 秒；日志 `/tmp/imv2-b01-snapshot-message-final.log`。18 场景验证异常时准备失败、原值/类型/游标和未准备标记保持，以及修复后同快照激活恢复撤回消息 revision 3。此前两个时限用例在原断言下通过；这不证明并发时限根因已经完成独立诊断。
- 源码证据：`/tmp/imv2-b01-snapshot-message-sources-20260919.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量；管理/控制/时间线等普通表复制及完整映射仍开放，B01 未关闭。


<a id="20260919-snapshot-room-projection-storage"></a>

## 2026-09-19 管理/控制/时间线快照序号检查

- 复现：三类普通房间行复制前无实际整数检查；新增 18 参数场景修复前产生 30 个断言问题，日志 `/tmp/imv2-b01-snapshot-room-projection-before.log`。
- 修复：copyRoomRows 仅对三个明确调用点检查全部 shadow 与授权 live 序号为实际正 integer，再复制。撤权/移除范围仍丢弃旧数据。
- 验证：18 场景覆盖三类 × 两种 REAL × live/shadow/移除；保留范围确认原值/类型/游标/未准备标记不变，修复后激活并关闭重开；移除范围确认无记录残留。shadow 损坏由导入房间后复制合法行构造，未声称完成服务端快照产物验证。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'snapshotRoomProjectionStorage|V2RoomProjectionStorageTests|privateTimelineActivityAndCapabilityAreApplied|conversationTimelineUsesUnifiedKeysetPages|moderationProjectionIsApplied|snapshotPreservesHybridRoomLogOwnership|snapshotV3AtomicallyReplacesProjection|snapshotStagingResumesAfterInterruption|snapshotAckCrashWindowResumesSafely|repeatedSnapshotActivation|preparedSnapshotFencesProjectionWrites'`，实际 11 项、2 套件通过，0.944 秒。
- 日志：`/tmp/imv2-b01-snapshot-room-projection-after.log`；源码证据：`/tmp/imv2-b01-snapshot-room-projection-sources-20260919.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量。其他普通表和快照初始化复制仍待审计；B01 状态保持开放，总表缩短累积描述，原批次证据保留在专项清单。


<a id="20260919-snapshot-member-fence-storage"></a>

## 2026-09-19 快照本人成员状态整数检查

- 复现：初始化无条件复制本人成员状态，准备阶段也未检查修订；8 场景修复前产生 28 个断言问题，日志 `/tmp/imv2-b01-snapshot-member-fence-before.log`。
- 修复：创建影子表前检查 live 全量成员修订；准备时检查 shadow 全量成员修订，再执行投影复制/撤权过滤。撤权历史也必须保持有效版本。
- 验证：8 场景覆盖 begin/prepare × 成员/已移除 × 两种 REAL，失败时游标/原值/类型保持，begin 不残留影子表及导入记录，prepare 保持未准备标记；修复后同快照激活、重开保留原成员状态，后续 revision 3 授予成功。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'snapshotMembershipFenceStorage|V2MemberRoleRecoveryTests|snapshotRoomLogStorage|snapshotRoomProjectionStorage|snapshotMessageStorage|snapshotV3AtomicallyReplacesProjection|snapshotStagingResumesAfterInterruption|snapshotAckCrashWindowResumesSafely|repeatedSnapshotActivation|preparedSnapshotFencesProjectionWrites'`，16 项、2 套件通过，2.690 秒。日志 `/tmp/imv2-b01-snapshot-member-fence-after.log`。
- 源码证据：`/tmp/imv2-b01-snapshot-member-fence-sources-20260919.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量；无完整 owner 迁移或重入整链声明。其他普通表/派生查询与跨模块映射仍开放，B01/B06 未关闭。


<a id="20260919-room-page-cursor-storage"></a>

## 2026-09-19 房间恢复页游标整数检查

- 复现：恢复页提交直接 Row 转 Int64，2^63 REAL 游标触发 GRDB fatal error；修复前进程失败，参数矩阵未完整执行。日志 `/tmp/imv2-b01-room-page-cursor-before.log`。
- 修复：事件应用前检查应用游标和裁剪下界为实际非负 integer，缺口判断复用本事务验证后的旧游标，避免二次未经检查的转换；旧裁剪值在 SQL MAX 前检查。
- 验证：8 参数场景覆盖两字段 × 两种 REAL × 空/有事件页；失败原值/类型和缺口标记保持、无事件/冻结投影写入；修复后同页可提交、正常置位历史缺口，重复不增加事件。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|snapshotRoomLogStorage'`，51 项、4 套件通过，1.971 秒；日志 `/tmp/imv2-b01-room-page-cursor-after.log`。
- 源码证据：`/tmp/imv2-b01-room-page-cursor-sources-20260919.json`。最终只再修正了缺口判定注释，无行为变化。
- 边界：未改 schema、未跑全仓/App/真机/容量；其他普通表/派生查询与跨模块审计仍开放，B01 未关闭。


<a id="20260919-latest-visible-max-storage"></a>

## 2026-09-19 最新可见摘要 MAX 候选整数检查

- 复现：合法较大序号掩盖 1.5，摘要读取/提交被接受并清除待办。4 场景修复前产生 3 个断言问题，日志 `/tmp/imv2-b01-latest-visible-max-before.log`。
- 修复：同一查询先检测目标房间非法序号，再取 MAX；异常返回 -1 并由 recoveryInteger 拒绝。无关房间不影响目标摘要，空消息范围仍为零。
- 验证：4 场景覆盖两种 REAL × 目标/无关房间，验证错误时待办仍需摘要、原值保持，修复后原请求可提交/读取。`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2ConversationUnreadModelTests'`，首版 53 项通过，1.976 秒，日志 `/tmp/imv2-b01-latest-visible-max-after.log`；优化查询表达式后同范围 53 项、4 套件通过，1.909 秒，日志 `/tmp/imv2-b01-latest-visible-max-final.log`。
- 查询计划：首个最小模型计划断言失败，显示 SELECT 1 偏好普通覆盖索引；改为存在性子查询 SELECT message_id 后，Python SQLite 的最小主键/唯一/稀疏索引模型使用既有异常索引和 MAX 覆盖索引，记录 `/tmp/imv2-b01-latest-visible-max-plan.txt`。不是实际 GRDB 设备容量测试，无 INDEXED BY 或 schema 改动。
- 源码证据：`/tmp/imv2-b01-latest-visible-max-sources-20260919.json`。测试后只补充解释查询计划的注释。
- 边界：未跑全仓/App/真机/容量；其他查询/转换/计数完整映射继续进行，B01 未关闭。


<a id="20260919-recovery-work-merge-storage"></a>

## 2026-09-19 恢复待办整数合并与完成检查

- 复现：初始五条路径 45 场景产生 90 个断言问题，日志 `/tmp/imv2-b01-recovery-work-merge-before.log`；修复后 59 项回归通过，2.734 秒，日志 `/tmp/imv2-b01-recovery-work-merge-after.log`。扩展重试及完成比较后，两个测试产生 19 个断言问题，日志 `/tmp/imv2-b01-recovery-work-completion-before.log`。
- 修复：统一验证五个待办整数，接入已返回工作行、入队/ensure、状态/摘要提交与服务记账；完成删除前验证待办和本地应用游标。允许合法 NULL 目录版本，不调整 schema。
- 新增验证：六操作（读取、入队、ensure、状态提交、摘要提交、重试）× 九字段/异常值组合，共 54 场景；另两字段 × 两种 REAL 的 4 个完成比较场景。使用正常 CHECK；priority 只测合法范围内的 1.5，其余字段测 1.5/2^63。错误时原值、请求修订和待办标记保持，不写状态/摘要；修复后继续原动作，完成路径原待办可正常删除。
- 最终命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2MemberRoleRecoveryTests'`，60 项、4 套件通过，2.792 秒；日志 `/tmp/imv2-b01-recovery-work-merge-final.log`。
- 源码证据：`/tmp/imv2-b01-recovery-work-merge-sources-20260919.json`。
- 边界：不包括所有延迟待办筛选前的完整验证，不扩大到所有目录/触发器/清理调用链。未跑全仓/App/真机/容量，B01 未关闭。


<a id="20260920-directory-summary-storage"></a>

## 2026-09-20 目录恢复缓存摘要整数比较

- 复现：缓存三个版本字段未经实际整数校验即参与目录资格比较；6 场景产生 24 个断言问题，日志 `/tmp/imv2-b01-directory-summary-before.log`。
- 修复：目标房间缓存 personal_generation、owner_epoch、membership_revision 在 SQL EXISTS 比较前校验，沿用原非负/正值范围。
- 验证：三字段 × 两种 REAL，共 6 场景。两房间页中第二个缓存异常，确认游标/拓扑/完成状态不变、无待办残留、异常值保持；修复后同页可推进并正确区分缓存复用与新摘要请求。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests'`，54 项、3 套件通过，2.218 秒；日志 `/tmp/imv2-b01-directory-summary-after.log`。
- 源码证据：`/tmp/imv2-b01-directory-summary-sources-20260920.json`。
- 边界：未改 schema、未跑全仓/App/真机/容量；其他目录输入、触发器与清理调用链继续映射，B01 未关闭。


<a id="20260920-recovery-scan-binding"></a>

## 2026-09-20 恢复调度计数账号隔离

- 复现：账号/安装绑定变化后，旧待办已清空，但旧 service_sequence 仍被新扫描继承；最大计数导致新身份无法进行服务记账。6 场景产生 8 个断言问题，日志 `/tmp/imv2-b01-recovery-scan-binding-before.log`。
- 修复：身份变化的原清理事务内同时删除旧 scan，新建行以默认零开始；同身份重连保持历史，不重置耗尽保护。
- 验证：用户/安装绑定/同身份 × 7/Int64.max，共 6 场景；检查旧 scope 失效、待办隔离、新身份记账到 1，以及同身份正常递增/耗尽安全拒绝。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2AccountLocalStoreOwnerTests'`，61 项、4 套件通过，2.390 秒；日志 `/tmp/imv2-b01-recovery-scan-binding-after.log`。
- 源码证据：`/tmp/imv2-b01-recovery-scan-binding-sources-20260920.json`。
- 边界：身份变化测试沿用仓库已有安装表更新夹具；不等同 App 换号/Keychain/真机闭环。未改 schema、未跑全仓或容量，B01/B08 的剩余范围继续开放。


<a id="20260920-core-boundary-audit"></a>

## 2026-09-20 核心帧长度配置与整数调用链

- 缺口：帧配置允许超出 UInt32 线格式的长度，编码器随后直接转换包体计数。修复为构造器限定 UInt32 可表达长度并保证加帧头不溢出 Int，失败抛 invalidLimits。
- 复现：首次测试编译因使用了错误的 decodeSingle 名称失败，日志 `/tmp/imv2-b01-frame-length-before.log`；修正为实际 decodeExactlyOne 后，7 项帧测试中两个超上界配置断言失败，日志 `/tmp/imv2-b01-frame-length-before-v2.log`。未分配超大包体或声称复现了 4 GiB 编码崩溃。
- 验证：新增 6 个参数场景，覆盖负值/超上界配置、零/普通/UInt32.max 合法配置、空帧 round trip 和仅最大声明长度的帧头。预算、发送序号、指纹、富文本、媒体时间戳及版本包装既有专项同轮通过。
- 命令：`swift test --package-path IMV2Core --jobs 4 --filter 'V2FrameCodecTests|CommandAdmissionTests|PushAdmissionTests|SendMessageAcceptanceTests|SendMessageFingerprintTests|RichMessageContentTests|MediaTimestampBoundsTests|ProfileRevisionBoundsTests|MessageMutationResultBoundsTests|GroupCapabilityResultBoundsTests'`，40 项、10 套件通过，0.004 秒；日志 `/tmp/imv2-b01-core-boundary-audit.log`。
- 源码证据：`/tmp/imv2-b01-core-boundary-audit-sources-20260920.json`。
- 边界：仅当前 64 位平台验证；未跑 Server/App/全仓/网络或超大包体。源码核对与实际测试范围在整数专项表分别记录，B01 未关闭。


<a id="20260920-server-boundary-audit"></a>

## 2026-09-20 Gateway 配置接入与服务端时间边界

- 变更：新增 Gateway 环境配置入口的帧上限测试，拒绝三个非法值并接受零/常规/最大线格式值，验证此前 Core 修复实际作用于运行配置。未改服务端业务源码或重试策略。
- 核对：限流重试整秒转换与二分、PostgreSQL 截止点检查、用户投影 failure_count 的 schema 下界与递增上界保护；详细范围见整数专项表。源码核对不作为数据库工作器运行证据。
- 命令：`swift test --package-path IMV2Server --jobs 4 --filter 'V2GatewayRuntimeConfigurationTests|V2PostgresTimestampBoundsTests|V2AccountRateLimitBoundsTests'`，40 项、3 套件通过，0.004 秒，无数据库前置条件；日志 `/tmp/imv2-b01-server-boundary-audit.log`。
- 源码证据：`/tmp/imv2-b01-server-boundary-audit-sources-20260920.json`。
- 边界：当前 64 位本机验证；未跑 PostgreSQL/TLS/工作器整链、App、全仓或超大包体。B01 的跨模块完整映射仍开放。


<a id="20260920-review-budget"></a>

## 2026-09-20 内容审核跨归属汇总预算

- 缺口与修复：单归属预算只检查正数，跨归属累加缺总上界；现在在启动任何工作前以 Int.max / 归属数验证，避免执行后计数溢出。推进协议明确每项报告计数须在 0...limit。
- 复现：`/tmp/imv2-b01-review-budget-before.log`，5 项测试中越界预算参数场景出现 6 个断言失败；实际验证了非法配置仍启动工作，未以巨量实际任务复现溢出崩溃。
- 验证：2/3 归属拒绝超限且零调用，1/2/3 归属允许最大合法预算并精确汇总；既有归属失败隔离、全部失败及审核重试专项同轮通过。
- 命令：`swift test --package-path IMV2Server --jobs 4 --filter 'V2RoutedContentReviewWorkerTests|V2ContentReviewWorkerTests'`，19 项、2 套件通过，0.002 秒；日志 `/tmp/imv2-b01-review-budget-after.log`。
- 源码证据：`/tmp/imv2-b01-review-budget-sources-20260920.json`。
- 边界：替身驱动的预算与工作器测试；生产 PostgreSQL LIMIT 及每租约计数仅作源码核对，未跑真实数据库、App、全仓或容量。B01 继续开放。


<a id="20260920-sharded-threshold"></a>

## 2026-09-20 分片发送准入自适应阈值溢出

- 缺口：合法 Int.max 阈值在向上取整的中间加法溢出；现使用商和余数计算，不收紧合法配置，保留每通道最小样本数。
- 复现：实际构造器边界测试在旧源码下异常退出，signal code 5；日志 `/tmp/imv2-b01-sharded-threshold-before.log`。无需分配巨量任务，未声称已有生产流量触发记录。
- 验证：2/3/128 通道 × Int.max-1/Int.max 共 6 场景构造和空快照通过；既有稳定分片、并发、共享容量、取消及自适应延迟测试同轮通过。
- 命令：`swift test --package-path IMV2Server --jobs 4 --filter V2SendMessageServiceTests`，27 项、1 套件通过，0.142 秒；日志 `/tmp/imv2-b01-sharded-threshold-after.log`。
- 源码证据：`/tmp/imv2-b01-sharded-threshold-sources-20260920.json`。
- 边界：当前 64 位平台与替身存储；未跑 PostgreSQL、App、全仓或容量。已核对的分页上界另列整数专项，不据此推断所有分页及计数安全，B01 继续开放。


<a id="20260920-compression-boundaries"></a>

## 2026-09-20 发送准入计数与压缩预算边界核对

- 变更：新增 3 项压缩测试，其中非法预算为 3 个参数场景。生产逻辑已有保护，本轮未修改，也没有宣称复现新缺陷。
- 验证：Int.min/-1/0 压缩预算、解压预算与膨胀比均返回 invalidConfiguration；Int.max / 压缩字节数的膨胀比可用，再加一及 Int.max 按既有合同返回 expansionRatioExceeded；精确字节预算可用，少一字节分别返回输入/输出超限。
- 命令：`swift test --package-path IMV2Compression --jobs 4`，8 项、1 套件通过，0.001 秒；这是独立小模块的完整测试，非全仓运行。日志 `/tmp/imv2-b01-compression-boundaries.log`。
- 源码核对：共享待处理容量加一、发送与数据库准入毫秒饱和计算、分片 UInt64 指标求和及 Server/ClientKit 编码膨胀比上界；详细限制见整数专项。本轮没有执行服务端/客户端套件。
- 源码证据：`/tmp/imv2-b01-compression-boundaries-sources-20260920.json`。
- 边界：未跑 App、数据库、真实超大缓冲、跨平台或容量测试；剩余转换与计数入口继续核对，B01 开放。


<a id="20260920-recovery-dates"></a>

## 2026-09-20 恢复待办持久化时间校验

- 缺口：待办行时间可为 SQLite 文本或无穷；原整数校验不覆盖这些值，合并/重试可以继续并改变请求或覆盖异常。
- 修复：整行校验增加整数/有限实数时间要求，匹配请求的重试在覆盖 next_attempt_at 前校验；保持事务回滚及过期请求不改写新请求的条件。
- 复现：修改前无穷时间的合并/重试测试 4 组参数各测正负无穷，19 个断言失败，日志 `/tmp/imv2-b01-recovery-dates-before.log`。文本读取测试只在修复后执行，未声称有修改前崩溃运行证据。
- 验证：无穷值拒绝及行/请求/调度计数不变、修复后重试恢复；文本入队时间两种排序均拒绝，负小数时间读取保持合法。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests'`，57 项、3 套件通过，2.421 秒；日志 `/tmp/imv2-b01-recovery-dates-after.log`。
- 源码证据：`/tmp/imv2-b01-recovery-dates-sources-20260920.json`。
- 边界：未增加 schema 或全队列扫描，被到期筛选排除的异常待办仍需独立处理；未跑 App/Server/全仓或容量，B01 未关闭。


<a id="20260920-recovery-progress-dates"></a>

## 2026-09-20 恢复进度识别被筛选掩盖的异常重试时间

- 缺口：原进度只读 MIN(next_attempt_at)，既可能将无穷作为日期返回，也会漏掉正常最小值之后的非法文本/二进制/正无穷。
- 修复：保留空队列语义；非空队列在同一快照用两个标量子查询读取 MIN/MAX，共享时间解码器拒绝非数值与非有限值，返回 invalidWork。无 schema 变更。
- 复现：修改前正负无穷 × 是否另有正常行，4 个场景均未抛错；日志 `/tmp/imv2-b01-recovery-progress-dates-before.log`，4 个断言失败。文本/二进制场景仅在修改后运行。
- 验证：8 个参数场景拒绝异常、保留原值、修复后正确返回计数和最早日期；空队列保持 nil。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryIntegerBoundsTests|V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests'`，59 项、3 套件通过，2.432 秒；日志 `/tmp/imv2-b01-recovery-progress-dates-after.log`。
- 查询计划：从当前源码提取表/索引/查询，在 Python SQLite 内存库 EXPLAIN；MIN/MAX 均 SEARCH USING COVERING INDEX v2_room_recovery_work_due_idx，日志 `/tmp/imv2-b01-recovery-progress-dates-plan.txt`。不作为 GRDB 真机性能或容量结果。
- 源码证据：`/tmp/imv2-b01-recovery-progress-dates-sources-20260920.json`。
- 边界：补齐恢复进度读取对异常重试时间的发现，不是自动修复坏库；未选中行的其他字段/排序仍需审计。未跑 App/Server/全仓或容量，B01 开放。


<a id="20260920-recovery-invalid-date-runner"></a>

## 2026-09-20 非法重试时间的前台/后台停止与恢复

- 变更：新增前台/后台 × 文本/正无穷 4 个运行器场景，使用真实 SQLite、替身恢复传输及通知流；生产逻辑不变。
- 失败保持：invalidWork 上抛，engine idle，目录与正文均未请求，两个待办保留、异常房间请求修订不变，正文游标仍零；不宣称完成个人流证明。
- 修复后：显式修复一行并以新通知流复用引擎，在有限预算内推进两个游标到 5、清空待办、再次停止。
- 首轮：`/tmp/imv2-recovery-invalid-date-runner.log`，24 项中 4 个新场景的最终空队列断言失败。预存队列可能先于后续目录页被处理，目录页随后重新安排摘要核对，原 4 单位预算不足；保留清空断言，将测试预算改为 6，未改变生产预算或运行器。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryEngineTests`，24 项、1 套件通过，1.412 秒；日志 `/tmp/imv2-recovery-invalid-date-runner-v2.log`。
- 源码证据：`/tmp/imv2-recovery-invalid-date-runner-sources-20260920.json`。
- 边界：不是自动坏库修复、真实 TLS 重连、APNs 或真机系统后台；未跑全仓。此证据补齐局部运行器生命周期，不关闭 B01/D08。


<a id="20260920-membership-inflight-runner"></a>

## 2026-09-20 本人撤销与恢复响应在途交错

- 变更：只新增测试与一次性响应拦截替身。前台/后台 × 状态/正文响应两个边界，共 4 个参数场景。
- 过程：目录发现房间后，在恢复响应返回前通过真实个人流 apply 提交本人 remove（修订 2），再让旧状态或正文页继续进入现有恢复运行器。
- 结果：staleMembership 上抛，engine idle；正文游标仍为零；目标房间同步状态、最新摘要与待办没有复活；成员资格保留修订 2、is_member=false；无个人流完成证明。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryEngineTests`，25 项、1 套件通过，1.405 秒；日志 `/tmp/imv2-recovery-membership-flight.log`。
- 源码证据：`/tmp/imv2-recovery-membership-flight-sources-20260920.json`。
- 边界：真实 SQLite + 可控传输替身；未跑真实 TLS、App、迁移、成员重入或全仓。生产逻辑已有栅栏，本轮未改，B03/B06/D08 继续开放。


<a id="20260920-rejoin-inflight-runner"></a>

## 2026-09-20 在途旧资格响应与本人撤销后重入

- 变更：测试替身可按房间更新成员修订；状态响应在拦截之前构造，确保返回的确为旧修订。新增状态/正文两个边界，未改生产实现。
- 交错：实际个人流 reducer 在 generation 1 中提交 remove 修订 2、add 修订 3；新待办 request_revision 与旧请求不同；旧恢复响应随后进入运行器。
- 结果：旧响应 staleMembership，engine idle、正文游标零；修订 3 的成员记录与新 request_revision 保留。使用新通知流和返回修订 3 的传输替身重启，同一引擎在 6 单位预算内推进两个房间游标到 5、保存状态修订 3、清空队列。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryEngineTests`，26 项、1 套件通过，1.402 秒；日志 `/tmp/imv2-recovery-rejoin-flight.log`。
- 源码证据：`/tmp/imv2-recovery-rejoin-flight-sources-20260920.json`。
- 边界：真实 SQLite、真实个人流 reducer，传输为替身且正文页为空；不证明缺席消息可见性、个人流重置代次、真实网络/App 或 owner 迁移。未跑全仓，B03/B06/D08 仍开放。


<a id="20260920-rejoin-content-flight"></a>

## 2026-09-20 重入在途响应的非空正文验证

- 变更：重入测试增加空/非空正文参数，状态/正文两个响应阶段合计 4 场景。替身正文响应先构造再执行交错，保证晚到的仍是旧消息；生产逻辑未改。
- 验证：旧资格序号 1 消息响应被拒绝后，事件表及消息投影为空、游标零；新资格序号 5 消息经新通知流恢复后，仅新消息及一条事件落库，旧消息不存在，状态修订 3、游标 5、待办清空。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryEngineTests`，26 项、1 套件通过，1.388 秒；日志 `/tmp/imv2-recovery-rejoin-content-flight.log`。
- 源码证据：`/tmp/imv2-recovery-rejoin-content-flight-sources-20260920.json`。
- 边界：真实 SQLite/reducer，服务端过滤由传输替身预设；不证明服务端历史成员区间、重置代次、TLS/App 或迁移，未跑全仓。B03/B06/D08 未关闭。


<a id="20260920-recovery-body-authorization-fence"></a>

## 2026-09-20 旧正文借用重入后新状态授权的修复

- 缺口：正文落库只检查当前持久状态允许访问；请求等待期间发生撤销/重入并写入新状态后，旧正文可重新落库。
- 复现：真实 SQLite/个人流 remove 修订 2、add 修订 3，再提交新状态；旧任务的非空页不应写入。修改前 4 个断言失败，旧消息与游标实际写入，日志 `/tmp/imv2-recovery-body-fence-before.log`。
- 修复：正文提交必须带已捕获状态；当前 ownerEpoch、viewerMembershipRevision 及个人成员栅栏必须匹配请求捕获值，之后仍做当前资格检查。head/read 变化和新通知的 request_revision 不作全等限制。
- 调用约定：提交状态后重新读取任务再发正文请求；生产引擎已这样执行。四处持久化测试沿用旧的预状态任务，首次回归因此失败，日志 `/tmp/imv2-recovery-body-fence-after.log`；修正测试后一次编译因 async let 捕获可变量失败，日志 `/tmp/imv2-recovery-body-fence-final.log`，改为不可变捕获。
- 验证：重入后先提交新状态仍拒绝旧消息、新待办保留且可继续；未捕获状态、owner/成员修订变化拒绝，仅 head 推进允许；原并发实时/恢复、新通知公平性与条件 unavailable 场景保持通过。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2RoomRecoveryIntegerBoundsTests'`，64 项、3 套件通过，2.577 秒；日志 `/tmp/imv2-recovery-body-fence-final-v2.log`。
- 源码证据：`/tmp/imv2-recovery-body-fence-sources-20260920.json`。
- 边界：未跑真实 TLS/App、SIGKILL、完整迁移或全仓；旧强杀 fixture 已在状态提交后重新获取正文任务，仅源码核对，不声称重跑其历史验收。B03/B06/D08 开放。


<a id="20260920-rejoin-summary-fence"></a>

## 2026-09-20 重入后的旧摘要拒绝

- 变更：扩展实际撤销/重入并提交新状态的持久化测试，分别覆盖摘要携带旧恢复任务与不带恢复任务；生产逻辑未改。
- 验证：修订 1 的非空旧摘要在当前修订 3 下返回 false，未写缓存且未清除新待办的 requires_summary；新资格空摘要提交后，旧摘要再次返回 false，缓存仍是新资格结果。旧正文拒绝、新资格正文可继续的断言保留。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryPersistenceTests`，23 项、1 套件通过，0.503 秒；日志 `/tmp/imv2-recovery-rejoin-summary-fence.log`。
- 源码证据：`/tmp/imv2-recovery-rejoin-summary-fence-sources-20260920.json`。
- 边界：真实 SQLite 的提交顺序测试；不等同真实网络/App、代次重置或迁移。未跑全仓，B03/B06/D08 保持开放。


<a id="20260920-recovery-body-generation"></a>

## 2026-09-20 重置前正文响应跨代次写入修复

- 复现：同一成员资格、同一恢复 scope，在 generation 1 捕获正文任务，真实完成 generation 2 的快照导入/准备/激活后交付旧非空公告页。旧实现仍写公告、推进游标并完成待办，4 个断言失败；日志 `/tmp/imv2-recovery-body-generation-before.log`。
- 修复：V2RoomRecoveryWork 读取时在同一快照捕获可选 personalGeneration；正文提交事务复核当前 generation，变化则抛 staleScope。原成员资格/owner 栅栏继续生效；未修改 schema。
- 验证：旧正文拒绝且公告/游标未写、待办 request_revision 保留；新代次重新读取的任务可提交公告到游标 20。既有恢复持久化/运行器/整数与快照房间日志类型专项同轮通过。
- 命令：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2RoomRecoveryIntegerBoundsTests|V2SyncEngineTests/recoveryBodySnapshotGenerationFence|V2SyncEngineTests/snapshotRoomLogStorage'`，66 项、4 套件通过，2.775 秒；日志 `/tmp/imv2-recovery-body-generation-after.log`。
- 源码证据：`/tmp/imv2-recovery-body-generation-sources-20260920.json`。
- 边界：真实 SQLite 快照激活与正文提交，不是实际服务器 ACK/TLS/App；其他异步结果入口仍须独立核对，未跑全仓或 SIGKILL，B03/B06/D08 开放。


<a id="20260920-recovery-results-generation"></a>

## 2026-09-20 恢复结果共用个人流代次检查

- 复现：将真实快照激活场景扩展到状态、不可用、重试及完成入口。原正文检查通过，其余入口未拒绝旧任务，出现更新状态/删除待办/延后待办；5 个参数场景共 6 个断言失败，日志 `/tmp/imv2-recovery-results-generation-before.log`。
- 修复：抽取 requireRoomRecoveryWorkScope，在事务内校验 scan/账户及捕获 generation；状态、不可用、重试、完成、服务计数、正文、带 work 的摘要共用。没有 work 的摘要仍按原请求 generation 校验。
- 回归：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2RoomRecoveryIntegerBoundsTests|V2SyncEngineTests/recoveryBodySnapshotGenerationFence'`，65 项、4 套件通过，2.520 秒；日志 `/tmp/imv2-recovery-results-generation-after.log`。
- 补测：加入新摘要请求搭配旧 work 的场景后，仅重跑 `V2SyncEngineTests/recoveryBodySnapshotGenerationFence`；1 项测试、6 个参数场景通过，0.356 秒，日志 `/tmp/imv2-recovery-results-generation-summary.log`。每个场景都验证旧结果拒绝、正文游标/公告未写、待办保留，以及新代次任务可继续提交。
- 源码证据：`/tmp/imv2-recovery-results-generation-sources-20260920.json`。
- 边界：真实 SQLite 快照流程，不是服务端 ACK/TLS/App；未跑全仓或 SIGKILL，不扩大到未核对的其他协议入口，B03/B06/D08 开放。


<a id="20260920-recovery-work-fence-crash"></a>

## 2026-09-20 恢复资格与代次栅栏后的六入口强杀复验

- 变更：测试增加显式事务选择 IMV2_CLIENT_CRASH_TRANSACTIONS；默认完整矩阵不变，拒绝不支持、重复或空的选择。生产源码未再修改。
- 实际范围：recovery、state、unavailable、retryWork、finishWork、summary，各 before/after，共 12 个真实 SIGKILL 参数。父进程确认子进程使用当前加载的测试 bundle；随后重开 SQLite 验证正文/游标、状态、待办、延期/调度计数或摘要对应的原子性与恢复。
- 命令：设置 IMV2_CLIENT_CRASH_BINARY 为当前 `IMV2ClientKit/.build/out/Products/Debug/IMV2ClientKitTests.xctest/Contents/MacOS/IMV2ClientKitTests` 的绝对路径，IMV2_CLIENT_CRASH_TRANSACTIONS=`recovery,state,unavailable,retryWork,finishWork,summary`，运行 `swift test --package-path IMV2ClientKit --jobs 4 --filter V2RoomRecoveryCrashTests/killedCommitRecoversAtomically`。
- 结果：1 项测试、12 个参数通过，1.103 秒；日志 `/tmp/imv2-recovery-work-fence-crash.log`。
- 源码证据：`/tmp/imv2-recovery-work-fence-crash-sources-20260920.json`。
- 边界：这是资格/代次保护修改后六入口的真实进程验证；未重跑其余强杀参数、App/TLS、系统后台或全仓，不据此关闭 B03/B06/D08。


<a id="20260920-directory-flight-fence"></a>

## 2026-09-20 目录旧扫描轮次与旧代次响应修复

- 复现：同一 scope 重扫回到首页、或个人游标代次由 1 改为 2，旧目录响应仍被接受并标记完成。2 个场景共 8 个断言失败，日志 `/tmp/imv2-directory-flight-before.log`；代次变更首轮使用定向数据库夹具。
- 修复：V2RoomRecoveryScan 捕获 directory_round 与个人流 generation；目录提交以 request 替代单独 scope 参数，事务核对轮次、代次、请求/当前游标；引擎在请求前捕获。全部调用点已更新，未改 schema。
- 回归：`swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2RoomRecoveryPersistenceTests|V2RoomRecoveryEngineTests|V2RoomRecoveryIntegerBoundsTests'`，65 项、3 套件通过，2.599 秒；日志 `/tmp/imv2-directory-flight-after.log`。
- 强杀：设置当前 IMV2_CLIENT_CRASH_BINARY，IMV2_CLIENT_CRASH_TRANSACTIONS=`directory,emptyDirectory,finalDirectory,restartDirectory`，`swift test --package-path IMV2ClientKit --skip-build --filter V2RoomRecoveryCrashTests/killedCommitRecoversAtomically`；1 项测试、8 参数通过，0.679 秒，日志 `/tmp/imv2-directory-flight-crash.log`。
- 真实快照补测：随后仅新增目录参数到已有快照六入口测试，实际 beginReset/import/prepare/activate 后，旧目录页 stalePage、新目录页可提交。`V2SyncEngineTests/recoveryBodySnapshotGenerationFence` 1 项、7 参数通过，0.382 秒，日志 `/tmp/imv2-directory-flight-snapshot.log`。强杀运行早于此测试扩展，生产源码未再改变。
- 源码证据：`/tmp/imv2-directory-flight-sources-20260920.json`。
- 边界：真实 SQLite/进程强杀；无实际网络/App/跨 owner 迁移，未跑全仓，B03/B06/D08 开放。


<a id="20260920-housekeeping-small-budget"></a>

## 2026-09-20 服务端小额度清理类别饥饿修复

- 复现：控制面按固定类别顺序分配额度，limit=1 时只有第一类获得额度。真实 PostgreSQL 连续模拟 300 个分钟槽位，过期连接租约和普通命令幂等记录均未被删除，4 个断言失败；日志 `/tmp/imv2-housekeeping-small-before.log`。
- 修复：类别额度改用商/余数分配，余数按分钟槽位轮转；小于 10 的总额度下，内层幂等表按外层完整周期推进，避免两层取模仅命中部分表。分钟转换在事务前验证，单轮总预算不变；无 schema、保留条件、历史兼容或客户端变更。
- 专项：`swift test --package-path IMV2Server --jobs 4 --filter 'V2ControlHousekeepingBudgetTests|PostgresV2RoomWriteStoreIntegrationTests/housekeepingSmallBudgetDoesNotStarve|PostgresV2RoomWriteStoreIntegrationTests/housekeepingTimestampBoundaries|PostgresV2RoomWriteStoreIntegrationTests/housekeepingRetentionPrecision|PostgresV2RoomWriteStoreIntegrationTests/boundedHousekeepingRecoversExpiredSyncReset|PostgresV2RoomWriteStoreIntegrationTests/invitationApprovalReceiptsSurviveHousekeeping'`。设置独立端口 55479 的临时数据库及 disposable 标记，报告 7 项、2 套件通过，3.298 秒；其中保留期精度用例因当时未设置第二数据库而提前返回，不计该轮有效证据。日志 `/tmp/imv2-housekeeping-small-after.log`。
- 补验：随后配置同一临时实例的第二个独立数据库，`--skip-build --filter PostgresV2RoomWriteStoreIntegrationTests/housekeepingRetentionPrecision`，真实执行 6 个参数场景，1 项通过，4.049 秒；日志 `/tmp/imv2-housekeeping-small-retention.log`。
- 覆盖：小额度真实清理、单轮删除不超额、负时间/非法时间拒绝、保留期边界、新记录保留、审批回执保护；纯预算用例覆盖 1–9 的代表额度、10/11/1024、Int.max 附近及 UInt.max 轮转值。
- 证据：`/tmp/imv2-housekeeping-small-sources-20260920.json`。没有运行全仓测试。轮转证据按连续分钟槽位；任意配置周期若长期只采样固定槽位仍可能遗漏类别，调度周期与轮转覆盖组合需继续核对，不将本轮视为所有调度配置的公平性证明。B01/D08 继续开放。


<a id="20260920-housekeeping-durable-rotation"></a>

## 2026-09-20 服务端清理按持久事务轮次推进

- 继续核对发现：上一轮分钟取模仍与固定调度周期耦合，例如每 10 分钟运行、limit=1 时仅一个类别持续获得额度。当前实现替换该方式，不再依赖墙钟轮转。
- 当前 schema 43 新增 control_housekeeping_cursor 单行表及种子。清理事务锁定轮次行，用它分配类别/幂等表预算并推进有界循环计数；删除失败连同轮次回滚。不同存储实例、并发维护器共享数据库进度。缺表、缺种子、列或约束漂移由启动/建库合同拒绝；只更新新库基线，不增加旧库升级路径。
- 测试：小额度真实 PostgreSQL 用例扩展为时钟不变、每分钟、每 10 分钟、每小时四参数，并每轮重建 store。时钟不变场景同时验证缺种子启动拒绝、删除触发器注入失败后的轮次/数据回滚、两个独立 store 并发提交后轮次推进两次。
- 回归命令：设置端口 55479 的主/次临时独立数据库与 disposable 标记，`swift test --package-path IMV2Server --jobs 4 --filter 'V2CurrentSchemaSourceTests|V2ControlHousekeepingBudgetTests|PostgresV2RoomWriteStoreIntegrationTests/housekeepingSmallBudgetDoesNotStarve|PostgresV2RoomWriteStoreIntegrationTests/housekeepingTimestampBoundaries|PostgresV2RoomWriteStoreIntegrationTests/housekeepingRetentionPrecision|PostgresV2RoomWriteStoreIntegrationTests/boundedHousekeepingRecoversExpiredSyncReset|PostgresV2RoomWriteStoreIntegrationTests/invitationApprovalReceiptsSurviveHousekeeping'`，8 项、3 套件通过，9.431 秒；本轮主/次库齐全，保留期 6 参数实际执行。日志 `/tmp/imv2-housekeeping-durable.log`。
- Schema 专项：`IMV2_SCHEMA_BOOTSTRAP_NATIVE=1` 配合独立实例运行 `scripts/test_v2_postgres_schema_bootstrap.sh`。首轮提示表数 149 应为 150；同步表数 150、索引数 352，并将轮次种子纳入导出恢复，新增移除轮次约束时拒绝的断言后通过。日志 `/tmp/imv2-housekeeping-durable-schema.log`、`/tmp/imv2-housekeeping-durable-schema-v2.log`。
- 源码证据：`/tmp/imv2-housekeeping-durable-sources-20260920.json`。本轮仅服务端及对应 schema/文档；未跑全仓、实际进程强杀、生产容量或完整 owner 迁移。store 重建与事务失败证据不冒充真实进程重启；B01/D08 其余范围仍开放。


<a id="20260920-housekeeping-readiness-bound"></a>

## 2026-09-20 清理轮次启动范围与执行范围统一

- 复现：轮次设为 Int64.max，原启动检查只验证非负而放行；工作器却要求小于完整轮转周期。真实 PostgreSQL 新增用例出现 1 个预期抛错未发生的失败，日志 `/tmp/imv2-housekeeping-readiness-before.log`。
- 修复：PostgresV2ControlPlaneHousekeepingStore.housekeepingRotationPeriod 由当前幂等表数量计算，事务读取、循环回绕和启动检查共用；不改 schema 43 或历史兼容策略。
- 验证：拒绝恰好等于周期及 Int64.max；随后分别恢复到 0 和最大合法轮次，启动检查成功。并重跑预算边界及四种调度间隔下的真实清理（含此前的并发、回滚分支）。
- 命令：主/次临时 PostgreSQL 与 disposable 标记齐备，`swift test --package-path IMV2Server --jobs 4 --filter 'PostgresV2RoomRecoverySchemaTests/housekeepingReadinessRejectsOutOfRangeRotation|V2ControlHousekeepingBudgetTests|PostgresV2RoomWriteStoreIntegrationTests/housekeepingSmallBudgetDoesNotStarve'`；4 项、3 套件通过，2.770 秒，日志 `/tmp/imv2-housekeeping-readiness-after.log`。
- 源码证据：`/tmp/imv2-housekeeping-readiness-sources-20260920.json`。仅此服务端边界与相关回归，不代表 B01 所有入口审计完成；未跑全仓。


<a id="20260920-publication-replay-policy"></a>

## 2026-09-20 普通发送/编辑在权限变化后的重放与额度一致性

- 审计范围：普通发送 PostgresV2RoomWriteStore 的完成记录分支、编辑 PostgresV2MessageEditStore 的操作回执分支，以及共用 v2AuthorizeContentWrite。二者都在新写入授权前处理既有操作的原参重放或改参冲突；本轮未发现需要修改的生产逻辑。
- 补强既有 editsRespectCurrentContentWriteAuthorization：房间冻结、禁言、成员移出、发送权限撤销、账号停用五个场景，在发送并编辑成功后改变权限；新发送/编辑被拒绝，原发送与原编辑返回各自原回执，同 ID 改参均返回幂等冲突。前后房间/分片 command_window_used 及房间序号不变，消息/房间事件/投影数量不变，发送完成记录和编辑操作记录各保留一条。
- 实际验证：独立临时 PostgreSQL（55479），设置主数据库及 disposable 标记，`swift test --package-path IMV2Server --jobs 4 --filter PostgresV2RoomWriteStoreIntegrationTests/editsRespectCurrentContentWriteAuthorization`，1 项、5 参数通过，1.882 秒；日志 `/tmp/imv2-publication-replay-policy.log`。
- 源码证据：`/tmp/imv2-publication-replay-policy-sources-20260920.json`。
- 边界：此处通过服务/存储调用验证数据库策略，账号停用场景不表示已停用账号仍可通过 Gateway 认证。批量发送只做了源码定位，未新增/运行其与权限变化的组合；转发、管理、完整 owner 迁移及跨组件并发仍由 D07/D08 跟踪。未改生产代码、客户端或 schema，未跑全仓测试。


<a id="20260920-publication-batched-policy"></a>

## 2026-09-20 两类群的准入队列重放与拒绝隔离

- 将上一轮普通发送/编辑的权限变化用例扩展到 standard/large 两类群，共 10 个参数组合；保留原有标量发送、编辑、新请求拒绝、原回执和改参冲突断言。
- 每个组合再通过实际 V2SendMessageAdmissionBatcher 并发提交原发送、同 clientMessageID 改参及新的无权发送。分别得到原回执、幂等冲突及当前权限错误；房间/分片额度、房间序号、消息/事件/投影数量均与运行前一致，发送完成记录和编辑记录仍各一条。
- 验证：独立临时 PostgreSQL（55479），主数据库与 disposable 标记齐备；`swift test --package-path IMV2Server --jobs 4 --filter PostgresV2RoomWriteStoreIntegrationTests/editsRespectCurrentContentWriteAuthorization`；1 项、10 参数通过，4.090 秒。日志 `/tmp/imv2-publication-batched-policy.log`，源码证据 `/tmp/imv2-publication-batched-policy-sources-20260920.json`。
- 边界：实际准入队列和逐条回退路径的结果隔离验证，没有断言三条请求必须形成同一个原子批次，也不据此宣称已覆盖所有批量优化分支、有效相邻请求、私聊、转发或管理路径。未发现需改动的生产行为；仅补测试与证据，无客户端/schema 变更，未跑全仓，D07/D08 继续开放。


<a id="20260920-forward-target-policy-replay"></a>

## 2026-09-20 跨库转发目标权限变化与终态重放

- 扩展 forwardInboxTargetBoundaries 到 standard/large 两类群。移出成员、禁言、冻结、发送权限撤销、账号停用五种情形中，先额外完成一次转发，再修改目标权限；已完成转发重试及 inbox 状态读取均返回原成功结果，尚未接受的另一操作按当前权限拒绝。
- 同轮保留 owner epoch 不匹配、准入额度耗尽及媒体未就绪路径，合计 8×2=16 个参数。失败/等待与终态重放前后，目标 rooms、room_admission、shard_admission_pools 的完整行快照不变；消息/发送完成记录只包含预先完成的那一条，待办可保存终态拒绝。额度恢复后的等待任务仍可成功接受。
- 验证：主/次独立临时 PostgreSQL 数据库（55479），disposable 标记已设置；`swift test --package-path IMV2Server --jobs 4 --filter PostgresV2RoomWriteStoreIntegrationTests/forwardInboxTargetBoundaries`，1 项、16 参数通过，11.266 秒。日志 `/tmp/imv2-forward-policy-replay.log`，源码证据 `/tmp/imv2-forward-policy-replay-sources-20260920.json`。
- 边界：跨数据库真实目标导入/状态读取，权限变化由受控 SQL 夹具建立；不是 Gateway 认证、实际网络/进程强杀、完整 owner 搬迁或全部管理命令验收。本轮未发现需改动的生产逻辑，仅补测试与清单证据，未改客户端或 schema，未跑全仓。B04/D07/D08 仍有其他开放范围。


<a id="20260920-room-migration-preparation"></a>

## 2026-09-20 房间 owner 迁移准备记录

- 实现：V2RoomOwnerMigrationPreparation 规范化目标分片并保护 epoch 加一；准备存储验证分片注册，锁定明确源目录，按迁移 ID 幂等、按房间排他，新建 prepared 记录。精确重试返回原记录；改参、未知分片、源路由过期和房间已有任务分别拒绝。准备不切换路由、不复制数据。
- schema 44：新增 9 列 room_owner_migrations、主键和进行中房间唯一索引，以及保护任务身份的函数/触发器；启动检查核对列、唯一索引和启用的保护触发器。新库基线同步，未提供旧库升级。
- 首次 Swift 构建因新启动查询的多行字符串缩进失败，修正后 2 项通过；再补数据库身份防篡改与不同 ID 并发争用房间验证后，`swift test --package-path IMV2Server --jobs 4 --filter V2RoomOwnerMigrationPreparationTests` 最终 2 项、1 套件通过，0.445 秒。主数据库和 disposable 标记齐备；日志 `/tmp/imv2-room-migration-preparation.log`、`/tmp/imv2-room-migration-preparation-v2.log`、`/tmp/imv2-room-migration-preparation-final.log`。
- 真实数据库用例覆盖同 ID 并发只产生一条任务、store 重建后原记录重放、同 ID 改参、未知分片、源 epoch 不符、不同 ID 并发只允许一个成功、数据库禁止修改目标身份、源路由保持不变、移除排他索引后启动拒绝；纯请求用例覆盖同分片拒绝及 epoch 最大边界。
- Native PostgreSQL 建库/导出恢复/漂移专项最终通过：151 张表、354 个索引、27 个应用触发器、25 个函数；保护触发器禁用时 SQL gate 拒绝，恢复启用后通过。日志 `/tmp/imv2-room-migration-preparation-schema-final.log`。
- 源码证据：`/tmp/imv2-room-migration-preparation-sources-20260920.json`。仅准备组件，不是完整迁移执行器；冻结、复制/校验、发布、任务接管、operator/runtime 组装及进程强杀仍未完成。B27 保持开放。无客户端修改，未跑全仓。


<a id="20260920-room-migration-abort"></a>

## 2026-09-20 迁移准备记录读取与安全取消

- 实现：record(migrationID:) 读取原记录；abortPreparation 使用与准备相同的 ID 建议锁及记录行锁，核对请求，prepared → aborted，精确重复返回原结果。拒绝不存在、改参、非法/倒退时间和已离开准备阶段的取消。取消不依赖当前分片注册集合，也不更新源目录。
- 验证：重建 store 且清空注册表后读取与取消、两个并发取消返回同一记录、取消后原 ID 不复活、新 ID 成功准备、旧取消不能影响新任务、路由不变。7 个后续阶段由受控 SQL 夹具建立，仅验证取消拒绝；不冒充实际冻结/复制/发布。
- 命令：临时 PostgreSQL 主库（55479）及 disposable 标记齐备，`swift test --package-path IMV2Server --jobs 4 --filter V2RoomOwnerMigrationPreparationTests`，3 项、1 套件通过，0.742 秒；日志 `/tmp/imv2-room-migration-abort.log`，源码证据 `/tmp/imv2-room-migration-abort-sources-20260920.json`。
- 边界：schema 44 未变；无真实进程强杀、operator/runtime 组装或 owner 数据搬迁。B27 继续开放；本轮未改客户端，未跑全仓。


<a id="20260920-room-migration-freezing-intent"></a>

## 2026-09-20 迁移冻结意图与准备取消互斥

- 实现：schema 45 / V2RoomOwnerMigrationPhase 增加 freezing。beginFreezing 验证注册分片、任务完整身份和阶段，在同一事务锁定当前源路由并比较 shard/epoch；prepared → freezing，重复 freezing 返回原记录。任务进入此阶段后准备取消拒绝，不能与源端后续效果交错释放任务。
- 真实 PostgreSQL 专项：源 epoch 变化时保持 prepared；非法/倒退时钟不推进；两个并发 beginFreezing 返回同一记录；重建 store 后重试不刷新时间；取消与启动的实际并发只有一个成功，最终阶段对应赢家，两条源路由均未切换。原有准备、取消、身份冲突、排他和整数边界同时回归。
- 命令：临时主库（55479）与 disposable 标记齐备，`swift test --package-path IMV2Server --jobs 4 --filter V2RoomOwnerMigrationPreparationTests`，4 项、1 套件通过，1.072 秒；日志 `/tmp/imv2-room-migration-freezing-intent.log`。
- schema 新库建库、导出恢复和漂移检查通过，日志 `/tmp/imv2-room-migration-freezing-schema.log`。没有历史升级链、客户端或协议改动，未跑全仓。
- 边界：freezing 仅为持久控制意图；没有源 owner 写屏障/排空证明、数据复制或发布。冻结和取消互斥不等于完整迁移已完成，B27 继续开放。源码证据 `/tmp/imv2-room-migration-freezing-intent-sources-20260920.json`。


<a id="20260920-room-migration-owner-marker"></a>

## 2026-09-20 源房间迁移标记与共用归属检查

- schema 46：rooms 新增可空 UUID migration_fence_id，新库 SQL 合同与启动检查同步。源端安装器要求 freezing 记录，在房间行锁下复核源 shard/epoch；同迁移 ID 并发安装和重建 store 后重试幂等，不同 ID 拒绝。共用 v2RequireRoomOwner 以同一加锁查询读取标记，标记存在时拒绝操作。
- 新增真实 PostgreSQL 用例覆盖 prepared 拒绝、源 epoch 不符、并发安装、重建重试、标记前后共用检查、冲突 ID、源 epoch/房间序号与控制阶段不变，以及移除字段后启动拒绝。迁移准备套件首次 5 项通过，日志 `/tmp/imv2-room-migration-owner-marker.log`。
- 首轮既有归属回归失败：测试按旧 SQL 文本定位等待房间锁的请求，新增查询列后匹配不到；保留失败日志 `/tmp/imv2-room-migration-owner-marker-regression.log`。同步 3 个测试定位条件，仍要求观察到锁等待后才改变归属，没有移除并发断言。
- 新库建库、导出恢复和漂移专项通过，日志 `/tmp/imv2-room-migration-owner-marker-schema.log`；151 张表、354 个索引、27 个应用触发器、25 个函数。
- 边界：仅共用归属检查的调用路径受到此标记约束；独立检查、非路由写入、后台工作与清理尚未全覆盖。本次没有新增“实际在途写入与安装器竞争”的排空专项，也没有执行完整搬迁、进程强杀或运行入口组装。任务仍为 freezing，B27 保持开放。无客户端、协议或历史升级改动，未跑全仓。
- 修正测试定位后，临时 PostgreSQL 主/次库（55479）及 disposable 标记齐备：迁移准备套件 5 项，加发送 3、moderation 12、群能力 8、消息变更 6 个参数场景，合计 9 项测试、2 个套件通过，21.124 秒。日志 `/tmp/imv2-room-migration-owner-marker-final.log`；仅运行上述过滤范围。测试定位修正后的锁等待和重放效果断言全部保留。
- 文档链接、结构与 diff 空白检查通过。源码/日志 SHA-256 清单为 `/tmp/imv2-room-migration-owner-marker-sources-20260920.json`，属于本机证据，不代替 CI 或生产验收。


<a id="20260920-room-migration-send-fence"></a>

## 2026-09-20 路由发送独立归属检查的迁移屏障

- 发现并修复：PostgresV2RoomWriteStore.requireSelectedOwners 原先只校验 shard/epoch，即使源房间设置 migration_fence_id 仍可能通过。现有按房间排序的 FOR NO KEY UPDATE 查询同时读取标记；任一房间已有标记则拒绝整个事务。该检查由路由发送的标量、标准与加速批量等提交分支调用。没有引入旧版本兼容，schema 46 和协议 30 不变。
- 扩展既有归属专项，覆盖普通群、大群单条/同房间批量，以及私聊纯文本、富文本、跨房间批量。真实 control 准备和 beginFreezing 后调用源端安装器，不用直接 SQL 伪造冻结结果；迁移房间的新发送、原请求重放均拒绝。逐表比较 rooms、messages、room_events、message_send_completions、message_content_versions、message_projection_states、message_projection_state_values，防止异常返回掩盖部分提交。保留旧 epoch、未知分片、错误数据库、锁等待期间代次变化和新 owner 重放断言。
- 首轮 5 个发送参数通过，私聊批量夹具因同房间重复而触发 duplicateRoom，未进入归属检查；保留 `/tmp/imv2-room-migration-send-fence.log`。修正为两个不同私聊房间，另一个未迁移房间的独立重放仍应成功，混合原子批次应整体拒绝。
- 边界：并非所有非路由发送、转发/已读独立检查或后台任务均已受屏障约束。准入信用额度可在消息事务前预取，本轮未证明额度池冻结/失效；也未证明每个加速分支都被参数用例实际命中。完整排空、复制、发布及运行入口未完成，B27 继续开放。无客户端改动，未跑全仓。
- 修正后使用临时 PostgreSQL 主/次库（55479）及 disposable 标记，`swift test --package-path IMV2Server --jobs 4 --filter 'PostgresV2RoomWriteStoreIntegrationTests/routedSendOwnerEpochFence|V2RoomOwnerMigrationPreparationTests'`：迁移套件 5 项与发送 6 个参数全部通过，合计 6 项测试、2 个套件，5.126 秒。日志 `/tmp/imv2-room-migration-send-fence-final.log`。文档链接、结构与 diff 空白检查通过。
- 源码和日志 SHA-256 清单 `/tmp/imv2-room-migration-send-fence-sources-20260920.json` 是本机证据，不代替生产容量、全入口冻结或完整迁移验收。


<a id="20260920-room-migration-receipt-forward-fence"></a>

## 2026-09-20 已读回执与同库转发迁移屏障

- 修复：PostgresV2ReadReceiptStore 的标量 FOR UPDATE、读者查询 FOR SHARE 和群回执批量 prepared statement 均读取 migration_fence_id，在归属判断中要求为空；批量行解码同步为包含可空 UUID 的四列。v2RequireForwardOwners 的读写加锁查询同时检查源/目标房间迁移标记，任一端正在迁移则拒绝。
- 普通群/大群的单条回执、批量回执和读者页用例，以及同库转发源端/目标端用例，使用真实控制记录与源端安装器设置屏障。拒绝新操作及既有操作重放后逐表比较持久房间、回执/个人日志或消息/转发接受事实，防止部分提交。保留原有 owner 代次变化、加锁等待及幂等回归，并选择混合回执批次、转发接受/结果发布间归属变化专项一起回归。
- 边界：新增标记场景覆盖群回执和同库转发，不代表私聊标量回执的两个事务间交错、跨库 export/inbox、后台 worker、非路由路径及准入额度均完成冻结。没有复制、路由发布或完整迁移进程恢复证据，B27 仍开放。schema 46、协议 30 不变，没有客户端或历史兼容改动，未跑全仓。
- 临时 PostgreSQL 主/次库（55479）与 disposable 标记齐备。过滤运行 routedReadReceiptOwnerEpochFence、readReceiptOwnerMixedBatch、foregroundForwardOwnerFence、foregroundForwardOwnerStageChange：4 项测试、14 个参数、1 套件通过，11.301 秒，日志 `/tmp/imv2-room-migration-receipt-forward-fence.log`。
- 复用同一构建产物（--skip-build），directReceiptOwnerOutbox 和 directReceiptResponseTimestampPrecision：2 项测试、6 个参数通过，5.658 秒，日志 `/tmp/imv2-room-migration-receipt-direct-regression.log`。这是私聊正常路径投递、隐私和时间精度回归，不冒充私聊迁移交错验证。
- 文档链接、结构与 diff 空白检查通过。源码/日志 SHA-256 清单 `/tmp/imv2-room-migration-receipt-forward-fence-sources-20260920.json` 是本机验证证据，不替代生产或完整迁移验收。


<a id="20260920-room-migration-cross-forward-fence"></a>

## 2026-09-20 跨库转发创建、接受与完成的迁移屏障

- 修复：源端新导出、目标新 inbox 与 v2AssertForwardInboxOwner 均在原加锁查询中读取 migration_fence_id，并要求为空。已存在导出的读取、重复 receive 的摘要核对与不可变 completed/rejected 回执保持只读重放。
- 额外缺口：正文长度校验可能在进入接受事务内部的 owner 检查之前抛出，再由 catch 把 pending 写为 rejected。现于构造/校验命令前，按 inbox → message operation → room 的现有顺序取得操作锁并检查 owner，防止迁移期间仍写业务拒绝。原接受与完成阶段检查继续保留。
- 新增普通群/大群双库场景：创建 completed、pending、accepted 未完成、尚未接收四类导出；通过完成事务触发器注入失败建立真实 accepted 检查点，确认状态后撤掉故障。使用 control 准备/冻结意图与实际源端安装器分别标记源房间和目标房间。
- 校验新导出与新接收拒绝；pending 和 accepted 在正常正文限制、过小限制下均因 ownerChanged 停止；原导出、已存在接收与 completed 回执读取仍保留。比较源/目标各 11 张表的完整行快照，覆盖房间、消息、接受回执、房间事件、准入额度、导出/投递待办、源回执及目标 inbox/媒体关联，防止错误返回后仍产生持久效果。
- 边界：媒体复制/映射、投递任务 claim/推进、源回执写入、清理与非路由入口尚未全部纳入迁移屏障。本次故障由数据库触发器控制，不是进程强杀；尚无完整复制、发布或运行入口，B27 保持开放。schema 46、协议 30 不变，无历史兼容和客户端改动，未跑全仓。
- 临时 PostgreSQL 主/次库（55479）及 disposable 标记齐备，过滤运行 forwardMigrationWriteBoundaries、forwardInboxTargetBoundaries、forwardInboxAcceptanceAndRecovery、forwardInboxReceiveOwnerFenceWait、forwardExportCommitAndReplay。5 项测试通过：22 个参数场景加 1 个接收锁等待用例，17.104 秒。日志 `/tmp/imv2-room-migration-cross-forward-fence.log`。文档链接、结构与 diff 空白检查通过。
- 本机源码/日志 SHA-256 清单 `/tmp/imv2-room-migration-cross-forward-fence-sources-20260920.json`，不代替生产或完整迁移验收。


<a id="20260920-room-migration-delivery-fence"></a>

## 2026-09-20 源转发投递任务与终态回执迁移屏障

- 修复：认领候选除过滤 shard/epoch 外，还要求 migration_fence_id 为空；同时 FOR UPDATE OF job SKIP LOCKED 与 FOR SHARE OF room SKIP LOCKED，房间锁持有到认领提交。仅过滤不加房间锁不足以防止检查与迁移安装交错。按表分别加锁及跳过行为核对 [PostgreSQL 16 官方 SELECT 文档](https://www.postgresql.org/docs/16/sql-select.html#SQL-FOR-UPDATE-SHARE)。
- isCurrent 增加当前房间归属/标记检查；complete/reschedule 改为事务内读取不可变导出绑定、取得源房间共享锁并复核后更新任务。源归属变化或迁移标记存在时返回 false，不推进状态或清空旧租约。首次保存源端终态回执在原房间锁内额外要求无迁移标记；完全相同的既有回执仍只读返回。
- 新增 migration/epoch 两个参数：4 个导出中认领 3 个，实际目标接受两个并产生终态回执，其中一个先写回源。持有源房间排他锁期间第四个 pending 任务不能被认领；然后通过实际安装器设置标记，或受控 SQL 改 owner epoch。旧租约失效、完成/重试/暂停均不写，新回执拒绝、旧回执可重放，未过期和已过期任务均不再认领。比较房间、导出、投递任务与回执四表完整快照。
- 边界：没有证明所有房间写入、媒体映射、operator 恢复或清理已冻结，也没有取消已发出的远程请求。网络请求前后 isCurrent 是快照检查；在途目标接受与源回执缺失的承接仍须由完整迁移执行器处理。B27 保持开放；schema 46、协议 30 不变，无客户端/历史兼容改动，未跑全仓。
- 首轮测试夹具的 SQL 参数插值符号在生成时丢失，持锁任务语法错误回滚后，观察方一直等待。确认 PostgreSQL 无活动锁等待、错误日志命中该 SQL 后终止本次测试 helper；未把观察超时当成进程停止。修正插值，并在持锁任务失败时释放观察方、继续传播原错误。失败构建/运行日志 `/tmp/imv2-room-migration-delivery-fence.log`，数据库错误摘录 `/tmp/imv2-room-migration-delivery-fence-fixture-failure.txt`；终止后仅清理 55479 的两个一次性测试库中的 im_v2 夹具，再重跑同一过滤范围。
- 修正后在临时 PostgreSQL 主/次库（55479）与 disposable 标记下，过滤运行 forwardDeliveryMigrationFence、forwardDeliveryWorkerRecovery、forwardTerminalReceiptRecovery：3 项测试、24 个参数、1 套件全部通过，21.978 秒。日志 `/tmp/imv2-room-migration-delivery-fence-final.log`；覆盖新屏障 2 参数、既有源回执 4 参数、投递工作器 18 参数。没有扩大到全仓。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 `/tmp/imv2-room-migration-delivery-fence-sources-20260920.json`，不代替完整迁移或生产验收。


<a id="20260920-room-migration-media-operator-fence"></a>

## 2026-09-20 媒体数据库回写与运维重放迁移屏障

- 核对：PostgresV2ForwardMediaImportStore.claim 和统一 mutate 已调用 v2AssertForwardInboxOwner，前批迁移标记检查因此已覆盖复制摘要、对象扫描/可用/失败状态、inbox 媒体映射、任务完成/拒绝/重试/暂停。本轮为这些路径补充证据，没有重复改写媒体存储。
- 实际修复：PostgresV2ForwardWorkReplayStore.assertOwner 原先只核对 shard/epoch；现在同一加锁查询同时读取 migration_fence_id，新 operator 重放必须无标记。新审计预占在同一事务回滚，原有审计结果的精确重放仍只读返回。
- 媒体新增两个检查点：本地提供方实际复制文件后，分别在记录复制摘要之前、之后通过真实 control 准备/冻结及源端安装器设置目标屏障。claim、recordCopied、complete、reject、retry/pause 以及重新启动的 worker 均应拒绝；比较 rooms、media_objects、inbox、inbox_media、media_imports 五表快照，且实际目标文件仍保留原字节。不是网络 I/O 强杀或扫描中途并发验收。
- operator 新增 delivery/media 两参数：先正常重放并再次暂停，安装对应房间迁移标记后，新操作拒绝且审计/任务/媒体快照不变；旧审计操作仍返回原 requeued 结果，当前任务保持 paused。原有非迁移幂等、并发、审计回滚、时钟及改参验证保留。
- 边界：对象提供方 I/O 不在数据库事务中，正在进行的复制不能仅凭数据库屏障宣称已取消。清理、其他写入口与完整搬迁/恢复继续开放，B27 未关闭。schema 46、协议 30 不变，无历史兼容或客户端改动，未跑全仓。

- 临时 PostgreSQL 主/次库（55479）及 disposable 标记齐备，过滤运行 forwardMediaImportBytesAndRecovery、forwardOperatorReplay：2 项测试、25 个参数、1 套件全部通过，19.452 秒。媒体 21 参数含两个新增迁移检查点；operator 4 参数含 delivery/media 的正常与迁移状态。日志 /tmp/imv2-room-migration-media-operator-fence.log。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-media-operator-fence-sources-20260920.json，不代替完整迁移或生产验收。


<a id="20260920-room-migration-compaction-fence"></a>

## 2026-09-20 转发正文压缩迁移屏障

- 修复：PostgresV2ForwardExportCompactor 与 PostgresV2ForwardInboxCompactor 在候选筛选中按 source_room_id/target_room_id 查询房间主键，要求迁移标记为空，使用 FOR SHARE SKIP LOCKED 持有房间锁；候选正文继续 FOR UPDATE SKIP LOCKED，单语句原子清理且更新数量受 limit 限制。缺少本地房间时不清理；旧 owner 回收仍待完整迁移协议。
- 专项补齐源/目标房间夹具：房间被另一连接排他锁定时清理返回零；实际准备、冻结意图与安装器在外层可回滚测试事务中设置标记，同事务清理返回零，随后回滚整个夹具再验证正常清理、并发最多一次和事务回滚。这里回滚的是隔离测试夹具，不是已提交迁移的恢复方案。清理结束后删除夹具房间，继续证明终态回执读取不依赖活房间。
- 首次测试编译因本地 compact 函数缺少 @Sendable 失败，修正后功能专项 2 项通过，0.465 秒。日志 /tmp/imv2-room-migration-compaction-fence.log 与 /tmp/imv2-room-migration-compaction-fence-final.log。
- 第一版直接 JOIN 房间表。实际 SQL 成本探针 18 组通过原有回执/任务扫描门槛，但大批次出现房间全表扫描，证据 /tmp/imv2-room-migration-compaction-cost.json、/tmp/imv2-room-migration-compaction-cost.log。改为带锁的主键标量子查询，并为探针增加禁止房间 Seq Scan 的断言；保留旧结果，不把其作为最终查询证据。
- 最终功能专项 2 项通过，0.449 秒，日志 /tmp/imv2-room-migration-compaction-fence-bounded.log。最终 18 组 SQL 成本探针通过，/tmp/imv2-room-migration-compaction-cost-bounded.json 与 /tmp/imv2-room-migration-compaction-cost-bounded.log；1 万条导出/收件箱、2 万房间下，limit 1/128/1024 都按房间主键查询，实际更新 1/128/500 行。探针使用独立临时数据库、当前 Swift SQL 和回滚 EXPLAIN，只有本机暖缓存成本含义，不是生产容量或所有数据分布的扫描上界证明。
- schema 46、协议 30 不变；无客户端或历史兼容改动，未跑全仓。其他清理、完整写入覆盖、迁移复制/发布及在途 I/O 承接仍开放，B27 未关闭。

- 复用最终构建运行 PostgresV2ForwardCompactionCrashTests：source/target × 提交前/后 × 接受/拒绝共 8 个真实 SIGKILL 与新进程恢复场景全部通过，3.770 秒；父进程中的子进程入口按设计跳过，实际由每个场景启动执行。日志 /tmp/imv2-room-migration-compaction-crash.log。
- 文档链接、结构与 diff 空白检查通过。B27 清单改为当前实现与剩余范围摘要，逐批细节仍保留在迁移合同和验证记录。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-compaction-fence-sources-20260920.json。


<a id="20260920-room-migration-log-retention-fence"></a>

## 2026-09-20 房间日志裁剪迁移屏障

- 修复：PostgresV2RoomLogRetentionStore 的首次和回绕候选查询均要求 migration_fence_id 为空，并以 FOR UPDATE SKIP LOCKED 锁定有界房间集。锁保持到同事务下界更新及事件删除结束，与迁移标记安装互斥；遇到其他事务占锁不再阻塞整轮。
- 新专项分别使用 permanent/window，建立三个具备可裁剪日志的房间；通过真实 prepare、beginFreezing、install 提交首尾两个房间的迁移标记。独立连接锁住中间房间，清理返回零；释放锁后只清理中间房间两条事件。继续验证游标回绕与存储实例重建，迁移房间的 rooms、room_events、room_read_receipts、room_memberships 完整行快照保持不变。测试竞争连接设置两秒锁等待上限，防止缺少跳锁造成挂起。
- schema 46、协议 30 不变；未修改客户端或增加历史兼容。只覆盖房间日志保留入口，不证明其他维护已冻结、完整迁移已排空或生产扫描成本达标，B27 继续开放。

- 临时 PostgreSQL（127.0.0.1:55479、disposable 标记）过滤执行 roomRetentionMigrationFence、roomRetentionMissingReceiptsAndRotation、roomLogRetentionFollowsActiveReaders：3 项测试、5 个场景、1 套件通过，测试 1.901 秒；构建 205.47 秒，没有运行全套测试。日志 /tmp/imv2-room-migration-log-retention-fence.log。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-log-retention-fence-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-housekeeping-fence"></a>

## 2026-09-20 房间操作回执与审核终态清理迁移屏障

- 修复：控制维护器显式标注 14 类 room_id 直接归属的操作回执和 content_review_jobs；候选通过房间主键标量子查询要求 migration_fence_id 为空，并以 FOR SHARE SKIP LOCKED 持锁到事务结束，待删行仍使用 FOR UPDATE OF target SKIP LOCKED。保留原审批/审计依赖判断、轮转和总删除预算。缺少本地房间不会被当作安全清理依据。
- 新 PostgreSQL 专项为迁移房间与普通房间各构造 15 条终态记录，实际调用准备/冻结意图/安装器提交迁移标记。另一连接锁定普通房间时，清理只删除账号侧偏好回执；两房间的 15 表完整行快照均保持不变。释放锁后普通房间删除 14 条回执和 1 条审核任务，迁移房间不变；重建维护器重跑仍不删除。竞争事务设两秒锁等待上限。
- 临时 PostgreSQL（55479、disposable 标记）新专项 1 项通过，0.422 秒，日志 /tmp/imv2-room-migration-housekeeping-fence.log。
- 用户分片偏好回执不纳入房间 owner 冻结；message_forward_operations 的跨房间归属、共享媒体及其他审计/后台清理仍开放。schema 46、协议 30 不变，未改客户端或历史兼容，B27 未关闭。本机专项不证明全量冻结或生产扫描成本达标。

- 复用构建过滤执行 housekeepingSmallBudgetDoesNotStarve、housekeepingTimestampBoundaries、boundedHousekeepingRecoversExpiredSyncReset、invitationApprovalReceiptsSurviveHousekeeping：4 项测试、10 个场景通过，5.252 秒，日志 /tmp/imv2-room-migration-housekeeping-regression.log。小预算轮转、事务回滚/并发维护、时间非法拒绝及批准中/已批准/身份错配的审批证据保留仍通过。未跑全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-housekeeping-fence-sources-20260920.json；未提交或部署。


<a id="20260920-forward-operation-retention"></a>

## 2026-09-20 转发操作绑定过期后重复发送修复

- 问题：同库转发的 message_forward_operations 保存固定 target_client_message_id，但通用维护器按 35 天期限删除它；旧转发命令没有服务端过期拒绝边界，再试会生成新的发送身份，绕过仍保留的 message_send_completions。
- 首轮扩展 forwardSourceRevisionFencesABAAndRetry：真实清理删除回执，重试不再返回原结果；因夹具额度租约只有效 100 秒，返回 UNAVAILABLE。失败日志 /tmp/imv2-forward-operation-retention-before.log。随后把夹具租约延至迟到重试之后，保持其余生产代码不变，第二轮直接复现重复接受：原消息序号 4，迟到同一操作返回不同消息标识和序号 5。失败日志 /tmp/imv2-forward-operation-retention-before-renewed.log。
- 修复：将 message_forward_operations 移出通用清理，保留未完成绑定与已完成结果。可清理回执表从 27 减为 26，维护游标周期由动态表数计算为 260；当前新库仍从零开始，不增加旧配置或旧 schema 兼容。
- 扩展专项要求真实维护后两条转发绑定仍在、迟到精确重放返回原结果且消息数不变，并继续运行来源 ABA、修订冲突、接受指纹与完成后来源变更的既有检查。长期增长、旧操作拒绝边界和完整迁移承接仍未实现，B11/B27 不关闭。

- 修复后在临时 PostgreSQL（55479、disposable 标记）过滤执行 forwardSourceRevisionFencesABAAndRetry、housekeepingSmallBudgetDoesNotStarve、boundedHousekeepingRecoversExpiredSyncReset、V2ControlHousekeepingBudgetTests：5 项测试、2 套件通过，3.812 秒；包含 4 个维护周期参数和 13 个预算边界参数，未运行全套测试。日志 /tmp/imv2-forward-operation-retention-fixed.log。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-forward-operation-retention-sources-20260920.json；schema 46、协议 30 不变，未改客户端，未提交或部署。

<a id="20260920-room-migration-moderation-audit-fence"></a>

## 2026-09-20 审核审计清理迁移屏障

- 修复：PostgresV2ModerationAuditRetentionStore 的候选选择按房间主键取得 FOR SHARE SKIP LOCKED，要求 migration_fence_id 为空，审计行使用 FOR UPDATE OF audit SKIP LOCKED；房间锁保留到清理事务完成，与标记安装互斥。保留原 retain_until、排序及数量上限，缺少本地房间不删除。
- 扩展 PostgresV2HousekeepingMigrationTests：真实迁移标记提交后对两房间分别保存 16 表完整行快照；普通房间被独立连接占锁时，审计删除返回零，两房间数据不变。释放后普通房间先清理其他 14 行，审计和对应 moderation 回执仍在；删除 1 条到期审计后才能清理对应 1 条回执。迁移房间全程不变，重建两类清理器重复执行返回零。竞争事务设两秒锁等待上限。
- 临时 PostgreSQL（55479、disposable 标记）运行新专项及 V2ModerationAuditRetentionWorkerTests：4 项测试、2 套件通过，0.432 秒，日志 /tmp/imv2-room-migration-moderation-audit-fence.log。
- schema 46、协议 30 不变；未改客户端或历史兼容。其他审核写入、外部 I/O、共享媒体及完整迁移仍开放，B27 未关闭。

- 复用构建过滤执行 moderationRetentionClockBounds、moderatorRedactionIsDurableAndExplicit：2 项测试通过，1.235 秒，日志 /tmp/imv2-room-migration-moderation-audit-regression.log。原非法时刻拒绝、到期边界及真实审核撤回/审计/事件/重放行为保持通过，未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-moderation-audit-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-content-review-fence"></a>

## 2026-09-20 内容审核任务数据库迁移屏障

- 修复：PostgresV2ContentReviewStore 认领候选时使用房间主键标量查询、FOR SHARE SKIP LOCKED 和 migration_fence_id 为空条件，候选任务仍 FOR UPDATE OF job SKIP LOCKED。validateAndRenew、resolve、stageViolation、scheduleRetry 均在同一数据库事务内持有房间共享锁并检查标记，任务修改同时匹配房间身份。源端标记安装与这些数据库写入互斥。
- 新 PostgreSQL 专项通过真实 prepare/beginFreezing/install 提交迁移标记；验证旧租约的续租、违规暂存、三类结果保存、重试及暂停均拒绝，六表完整行快照不变。另一连接锁住唯一正常房间时认领为空；释放后正常房间可认领并保存人工复核结果。重建存储并推进到旧租约到期后，迁移房间的 pending/claimed 均不重新认领。竞争连接设置两秒锁等待上限。
- 只覆盖审核存储的认领和数据库回写；外部审核 I/O、运维重放及所有 trusted-safety 内容处置入口仍待完整核对。schema 46、协议 30 不变，未改客户端或历史兼容，B27 保持开放。

- 临时 PostgreSQL（55479、disposable 标记）新专项 1 项通过，0.384 秒，日志 /tmp/imv2-room-migration-content-review-fence.log。复用构建过滤运行 contentReviewRetryCounterBoundary、contentReviewClockBounds、editReplacesTheClaimedContentReviewJob、contentReviewJobsAreTransactionalLeaseFencedAndDurablyResolved、contentReviewEscalationDoesNotRedactTheMessage、contentReviewViolationUsesAuthoritativeRedaction：6 项测试通过，13.882 秒，日志 /tmp/imv2-room-migration-content-review-regression.log。未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-content-review-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-moderation-write-fence"></a>

## 2026-09-20 审核内容处置迁移屏障

- 修复：PostgresV2ModerationStore 的 redact、mute、removeMember、controlRoom 四条事务路径从既有房间 FOR UPDATE 查询读取 migration_fence_id，新操作发现标记即抛 ownerChanged；房间锁保持至事务结束，源端标记安装与内容/成员/审核回执/事件/额度修改互斥。覆盖非路由后台调用及普通审核调用。已完成非路由精确重放仍为只读回执，路由入口继续先验证 owner 与标记。
- 扩展 routedModerationOwnerEpochFence：普通群/大群各覆盖 redact、mute、remove、safety_redact、freeze、unfreeze，通过真实 prepare/beginFreezing/install 提交标记。非路由新操作拒绝，路由新操作与旧操作拒绝，非路由旧操作返回原回执；rooms、messages、room_events、room_memberships、room_member_mutes、moderation_operations、moderation_audit_entries、room_admission、shard_admission_pools、content_review_jobs 十表完整行快照不变。保留原 epoch、并发提交、错库和等待后重新检查回归。
- schema 46、协议 30 不变；未改客户端或历史兼容。此批验证内容处置事务，不等同于外部审核 I/O 排空或完整迁移，B27 仍开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 routedModerationOwnerEpochFence、trustedSafetyRoomControlIsDurableAndEnforced、contentReviewViolationUsesAuthoritativeRedaction：3 项测试、14 个场景、1 套件通过，10.115 秒，日志 /tmp/imv2-room-migration-moderation-write-fence.log。未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-moderation-write-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-review-replay-fence"></a>

## 2026-09-20 审核运维恢复迁移屏障

- 修复：PostgresV2DurableWorkReplayStore 的 contentReview 分支在任务变更前，关联实际任务的房间并 FOR SHARE 取得锁，拒绝 migration_fence_id 非空。外层事务一并回滚 processing 审计预占；没有任务时仍保留原 notPaused 语义。单目标和按事件恢复共用此分支，原精确操作审计命中先返回，不能重新激活任务。
- 扩展 PostgreSQL 审核迁移专项：先正常暂停、运维恢复并重新认领，再提交迁移标记；额外保留一个暂停任务。新的单目标和事件恢复均拒绝，原运维操作返回 wasIdempotent/requeued；七表完整行快照含 durable_work_replay_audit 保持不变。原认领、续租、结果和重试/暂停屏障验证继续执行。
- 首轮编译因测试 seed 夹具缺少 message 参数失败，日志 /tmp/imv2-room-migration-review-replay-fence.log；修正夹具后重跑同一专项。生产修复没有因夹具失败放宽。
- schema 46、协议 30 不变；未改客户端或历史兼容。其他运维类型、外部 I/O 与完整迁移仍开放，B27 不关闭。

- 修正后临时 PostgreSQL（55479、disposable 标记）新专项 1 项通过，0.394 秒，日志 /tmp/imv2-room-migration-review-replay-fence-final.log。复用构建过滤运行 contentReviewClockBounds、durableReplayAuditClockBounds、V2VaporDurableWorkOperatorReplayRoutesTests：6 项测试、2 套件通过，5.885 秒，日志 /tmp/imv2-room-migration-review-replay-regression.log。未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-review-replay-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-membership-write-fence"></a>

## 2026-09-20 成员变更迁移屏障

- 修复：PostgresV2RoomMembershipStore 的两处房间 FOR UPDATE 查询均读取 migration_fence_id；提供 ownerRoute 时与分片/epoch 一起校验，无路由时在成员效果产生前检查。覆盖直接 change 和邀请审批调用的同事务原语。保留操作建议锁先于房间锁的顺序；本地已提交回执仍只读，路由回执先验证归属/标记。
- 扩展 routedMembershipOwnerEpochFence 的普通群/大群参数：真实 prepare/beginFreezing/install 提交标记后，直接与路由入口的新增/移除均拒绝；路由旧命令拒绝，本地旧命令返回原回执。rooms、room_memberships、room_membership_operations、room_events、room_admission、shard_admission_pools、user_state_event_outbox 七表完整行快照保持不变。原并发幂等、身份、epoch 与锁等待回归继续运行。
- 邀请存储自己的创建/申请/管理归属检查仍待补齐；本批不证明邀请全链路已冻结。schema 46、协议 30 不变，未改客户端或历史兼容，B27 仍开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 routedMembershipOwnerEpochFence、invitationApprovalIsOneTransaction、invitationApprovalSharesMembershipLockOrder：3 项测试、6 个场景、1 套件通过，3.728 秒，日志 /tmp/imv2-room-migration-membership-write-fence.log。包含审批后段三种失败的完整回滚、十次并发重放，以及最后邀请名额的并发竞争；未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-membership-write-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-invitation-fence"></a>

## 2026-09-20 邀请存储迁移屏障

- 修复：PostgresV2GroupInvitationStore 共用 fence 对 scoped/直接调用都锁定房间并要求 migration_fence_id 为空；scoped 继续验证分片/epoch。无 scope 的新提交在锁邀请前通过摘要查询房间绑定并锁房间，保持 room → invite 顺序。直接精确提交重放仍只读。已使用 fence 的只读管理查询也在迁移后拒绝。
- 新 invitationMigrationFence 普通群/大群参数通过真实 prepare/beginFreezing/install 提交标记，对 scoped 与直接存储验证创建预查、创建精确重试、列表、撤销、新提交、申请列表、批准、拒绝、取消均抛 ownerChanged，scoped 预览拒绝；直接旧提交只读返回。rooms、group_invite_links、group_join_requests、group_join_submission_receipts、room_memberships、room_membership_operations、room_events、room_admission、shard_admission_pools、user_state_event_outbox 十表快照不变。
- 只覆盖 owner 邀请存储的事务边界，不代表 control 目录与配额恢复的跨库交错、审批运维恢复或完整迁移已完成。schema 46、协议 30 不变，未改客户端或历史兼容，B27 保持开放。

- 首轮迁移专项及审批/配额回归通过，但取消申请的 7 个参数均发现不存在房间从 requestNotFound 被误报为 ownerChanged，日志 /tmp/imv2-room-migration-invitation-fence.log。修正共用 fence：直接调用找不到房间时交回原领域检查，scoped 找不到选定房间仍拒绝归属；存在房间的迁移标记检查不变。
- 修正后临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 invitationMigrationFence、invitationApplicantCancellation、invitationApprovalSharesMembershipLockOrder、invitationApplicantQuotaIsAtomic：4 项测试、12 个场景、1 套件通过，5.609 秒，日志 /tmp/imv2-room-migration-invitation-fence-final.log。未运行全套测试。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-invitation-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-approval-recovery-fence"></a>

## 2026-09-20 审批异常恢复迁移屏障

- 修复：PostgresV2GroupApprovalRecoveryStore 的 assertOwner 在既有房间 FOR UPDATE 查询中读取 migration_fence_id，并与 shard/epoch 一起校验。标记存在时，新恢复和候选分页抛 ownerChanged；精确已提交操作仍只读返回原审计结果。
- 扩展 groupApprovalRecoveryPagesConfiguredOwner：在既有双库分页、并发恢复与 epoch 验证后，通过真实 prepare/beginFreezing/install 提交冻结标记；对仍 approving 与已释放申请发起新恢复均拒绝，首页/续页查询拒绝，重建服务后的原操作重放保持 released/wasIdempotent。八张房间、申请、邀请、审计、阻断记录、成员操作、成员及事件表的完整行快照不变。
- 同轮选择四种审批证据场景回归；完整迁移、在途外部 I/O 与 control 配额恢复仍未关闭。schema 46、协议 30 不变，未改客户端或历史兼容。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤运行 groupApprovalRecoveryPagesConfiguredOwner、groupApprovalRecoveryIsAuditedAndFenced：2 项测试、5 个场景、1 套件通过，4.439 秒；日志 /tmp/imv2-room-migration-approval-recovery-fence.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过。本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-approval-recovery-sources-20260920.json；未提交或部署。

<a id="20260920-room-migration-invitation-recovery-fence"></a>

## 2026-09-20 邀请创建与全局配额恢复冻结交错

- 本批补充跨库验证，不新增兼容路径或生产写入分支。现有邀请共用 fence 已覆盖 resumeCreation 的 owner 预检以及 resumeSubmission 的 owner 提交/回执观察。
- invitationRecoveryMigrationFence 分别构造仅预留配额、owner 已提交但 control 尚未确认、owner 已取消但 control 仍 tracking 三个检查点，并保留另一条尚未发布目录的邀请创建意图（owner 未创建/已创建）。真实 prepare/beginFreezing/install 后，在两个到期时刻重建工作器并执行。
- 验证目标：创建与配额恢复均延期，不在同轮重复认领、不误报完成或暂停；保留 held/tracking 配额，未发布邀请仍不可解析；源库八张表及 control 路由、邀请目录、配额别名三表完整行快照不变。控制恢复租约/重试时间允许按既有协议推进，它们不属于 owner 复制集。
- 同轮定向选择 groupJoinQuotaOperatorRecovery 和 inviteCreationRecoveryClaimsAndFences，验证正常恢复、终态释放和认领竞争。未覆盖冻结安装与 control 最终确认同时提交、目标发布后的重新路由、三库完整迁移或进程强杀；这些仍按 B27 跟踪。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行上述三项测试：7 个场景、1 套件通过，5.541 秒；日志 /tmp/imv2-room-migration-invitation-recovery-fence.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-invitation-recovery-sources-20260920.json。未提交或部署，B27 保持开放。

<a id="20260920-room-migration-message-mutation-fence"></a>

## 2026-09-20 消息编辑、撤回与反应迁移屏障

- 修复：PostgresV2MessageEditStore、PostgresV2MessageWithdrawalStore、PostgresV2MessageReactionStore 在既有房间 FOR UPDATE 查询读取 migration_fence_id；新操作在消息、反应、事件、额度或审核任务变更前拒绝迁移标记。不依赖调用方是否传入 ownerRoute，保留原锁顺序。已提交直接操作仍可只读返回精确回执；路由操作继续在回执读取前检查选定 owner。
- 扩展 routedMessageMutationOwnerEpochFence 的普通群/大群 × 编辑/撤回/反应六种组合：真实 prepare/beginFreezing/install 后，直接新命令与路由新/旧命令均拒绝，本地原命令返回原回执；比较房间、消息、正文版本、投影表/视图、反应、三类操作回执、事件、房间/分片额度、审核任务及唤醒队列十四个关系的完整行快照。原十次并发幂等、错误分片/物理库、epoch 与房间锁等待验证保留。
- schema 46、协议 30 不变，未改客户端或历史兼容。其他直接写入入口和完整排空/复制/发布仍待完成，B27 不关闭。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤运行 routedMessageMutationOwnerEpochFence：1 项测试、6 个场景通过，4.777 秒；日志 /tmp/imv2-room-migration-message-mutation-fence.log。
- 复用构建运行 withdrawalWritesTombstoneTransaction、reactionWritesSetChangeAndDeliversIt、editWritesRevisionFencedTransaction、concurrentEditAndWithdrawalDoNotCreateConflictingHistory：4 项直接写入/并发回归通过，1.591 秒；日志 /tmp/imv2-room-migration-message-mutation-regression.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-message-mutation-sources-20260920.json。未提交或部署。

<a id="20260920-room-migration-group-capability-fence"></a>

## 2026-09-20 群管理写入迁移屏障

- 修复：PostgresV2GroupCapabilitiesStore 的共用 prepare 在既有房间 FOR UPDATE 查询读取 migration_fence_id，并在成员权限、准入及领域修改前拒绝标记。置顶、公告、角色权限和成员角色的新写入不再依赖调用方提供 ownerRoute 才受保护；本地精确回执仍只读。直接修改本人角色的既有无效果提前返回未改动，不能据此产生房间变更。
- 扩展 routedGroupCapabilityOwnerEpochFence：普通群/大群 × 四类操作，在真实 prepare/beginFreezing/install 后验证直接新操作及路由新/旧操作拒绝、本地原操作只读重放；房间、成员、置顶、公告、权限、四类回执、事件、两级额度及个人/群唤醒队列共十四张表完整行快照不变。原十次并发、错误物理库、归属切换和锁等待回归保留。
- 同轮选择 groupCapabilitySourceVersions 验证普通群/大群正常版本与房间日志行为。schema 46、协议 30 不变；其他直接写入入口、完整排空与迁移执行器仍待完成，B27 保持开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 routedGroupCapabilityOwnerEpochFence 和 groupCapabilitySourceVersions：2 项测试、10 个场景、1 套件通过，7.082 秒；日志 /tmp/imv2-room-migration-group-capability-fence.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-group-capability-sources-20260920.json。未提交或部署。

<a id="20260920-room-migration-nickname-fence"></a>

## 2026-09-20 群昵称写入迁移屏障

- 修复：PostgresV2ProfilePresentationStore 的新群昵称操作在读取成员资格和昵称前，按 room_id 取得房间 FOR SHARE 锁并检查 migration_fence_id；锁持有到昵称与回执事务结束，和迁移安装的 FOR UPDATE 互斥。不存在房间仍返回 forbidden，已提交精确操作仍只读返回原回执；联系人备注不受房间标记影响。
- 新 nicknameMigrationFence 覆盖普通群/大群。先正常提交昵称，再通过真实准备与冻结安装器在外层事务保存未提交标记；并发新昵称请求须出现在真实房间锁等待中，标记提交后须抛 ownerChanged。重建存储后更名/清除同样拒绝，旧操作保持原结果；昵称、昵称回执、成员和事件四表完整行快照不变。
- 定向回归选择资料写入时间边界及展示 HTTP 路由。现有 HTTP 通用错误映射会将 ownerChanged 返回 503；本批未新增 API。Account 展示存储仍直接使用配置数据库，房间昵称的完整 owner 路由与迁移后承接尚未实现，不以源端拒绝替代。
- schema 46、协议 30 不变；未改客户端或历史兼容，B27 保持开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 nicknameMigrationFence、profileWriteTimestampBoundaries 和 V2VaporProfilePresentationRoutesTests：6 项测试、17 个场景、2 套件通过，8.929 秒；含 2 个真实冻结锁等待参数、6 个数据库时间边界参数及 9 个 HTTP 场景。日志 /tmp/imv2-room-migration-nickname-fence.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-nickname-sources-20260920.json。未提交或部署。

<a id="20260920-room-migration-nickname-routing"></a>

## 2026-09-20 群昵称归属路由与 Account 接线

- 新 V2RoutedProfilePresentationStore 将群昵称分页/更新解析到 room owner；联系人备注委派原配置存储，不因群昵称路由搬动。拒绝未知分片、非标准 schema；不回退控制库。Account 的展示 HTTP 接口现使用此路由存储与现有房间存储注册表。
- PostgresV2ProfilePresentationStore 增加内部房间作用域。作用域写入在操作锁后、旧回执前通过共用 owner 检查验证 room/shard/epoch/迁移标记；作用域分页在同一事务内锁房间、复核归属并读取成员资格和昵称。此处读取使用共用 FOR UPDATE 检查，正确性优先，后续如需共享读锁应独立测量。非路由旧接口保留其原只读行为与上一批新写入保护。
- 新 routedNicknameOwnerFence 覆盖普通群/大群真实双库：昵称落 owner、control 无昵称及操作记录；联系人备注仍落 control。昵称首页/续页正确；缓存旧 epoch 的读取、新更新、旧操作重放均拒绝，新路由精确重放保持原结果。错误物理库及未知分片拒绝；真实迁移标记安装后重建路由存储，读取/新操作/旧重放均拒绝，owner 保留原昵称和唯一回执。
- 同轮回归真实昵称锁等待与展示 HTTP 路由。schema 46、协议 30 不变；本批未实现数据复制和路由发布，不以配置 epoch 的定向检查替代完整迁移承接，B27 保持开放。

- 首轮真实昵称分页暴露既有 SQL 别名 authorization 与 PostgreSQL 保留字冲突（syntax error at or near authorization）。失败日志 /tmp/imv2-room-migration-nickname-routing.log；数据库错误摘要 /tmp/imv2-room-migration-nickname-routing-postgres-errors.log。将该 CTE 改名为 nickname_authorization，未放宽断言或绕过真实数据库查询。
- 修正后临时 PostgreSQL 主/次库（55479、disposable 标记）重跑同一过滤：6 项测试、13 个场景、2 套件通过，2.969 秒；包含 2 个双库路由、2 个真实冻结锁等待及 9 个 HTTP 场景。日志 /tmp/imv2-room-migration-nickname-routing-final.log。Account 可执行目标同次构建通过；未启动完整 Account 服务、未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-nickname-routing-sources-20260920.json。未提交或部署。

<a id="20260920-room-migration-direct-send-fence"></a>

## 2026-09-20 直接发送与大群快速批量迁移屏障

- 修复：PostgresV2RoomWriteStore 的 requireSelectedOwners 不再因 ownerRoutes 为空直接退出。所有传入房间按稳定顺序取得 FOR NO KEY UPDATE 锁，现存房间有迁移标记即拒绝；有路由时额外检查完整房间集合与 shard/epoch。未选路由且房间缺失仍交回原接受流程产生领域错误。直接发送的旧请求也先检查迁移标记，不能通过重放绕过。
- 大群 plain conditional append 保留正常路径的单条原子 SQL：在已锁定房间中读取标记，将标记为空加入 eligible，batch_gate 要求全部输入符合条件后才修改消息/序号/额度。标记造成零写入时，诊断路径先调用共用检查并抛 ownerChanged。标记检查未改变原递归操作锁和稳定房间锁顺序。
- 扩展 routedSendOwnerEpochFence 的 standard、hybrid、hybridBatch、direct、directBatch、directRich 六种参数，冻结后额外直接调用 writer 的新单条/原子批量及旧请求重放；比较房间、消息、事件、接受回执、正文版本与投影表/视图七个关系的完整行快照。原路由、epoch、错误物理库和锁等待回归保留。
- 修改脚本第一次因测试中同一断言出现两次而停止，生产文件已写入、测试扩展尚未落盘；当次既有四项测试通过（5.576 秒），日志 /tmp/imv2-room-migration-direct-send-fence.log。确认进程退出后将扩展定位到冻结段，再运行最终专项；初次通过不作为新增直接路径的证明。
- 预取信用额度的冻结/退还/接管仍是独立未完成项。本批不声称所有额度状态不变，也不证明全部发送优化/在途路径已排空。schema 46、协议 30 不变，B27 保持开放。

- 最终临时 PostgreSQL 主/次库（55479、disposable 标记）过滤运行 routedSendOwnerEpochFence、atomicallyPersistsPlainHybridGroupMessagesAcrossRooms、atomicallyPersistsRepeatedPlainHybridGroupRoomMessages、overlappingMultiShardBatchesUseDeterministicLockOrder：4 项测试、9 个场景、1 套件通过，5.894 秒；日志 /tmp/imv2-room-migration-direct-send-fence-final.log。正常跨房间/同一热点房间原子批量和交叠分片锁顺序继续通过；未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-direct-send-sources-20260920.json。未提交或部署。

<a id="20260920-room-migration-direct-receipt-fence"></a>

## 2026-09-20 直接已读回执迁移屏障

- 修复：PostgresV2ReadReceiptStore 的 recordGroups 在没有 ownerRoutes 时也按稳定顺序取得房间共享锁并读取迁移标记，将标记非空的输入设为 ownerIsValid=false。既有批量 SQL 在任何回执效果前按单项返回 owner_changed；没有房间的直接请求仍使用原领域结果。路由数量检查仍在输入阶段执行，路由调用继续验证 shard/epoch。
- 私聊从群批处理探测返回 notGroup 到真正写入之间还有事务间隔，故其既有房间 FOR UPDATE 查询也读取并检查标记；新回执不会因探测后开始冻结而落入未保护的私聊路径。精确私聊回执若已在该事务命中只读结果，不产生后处理。
- 扩展群 owner 专项：普通群/大群的冻结后直接 record/recordBatch 对新操作和旧操作均拒绝；原路由/读者分页/锁等待及四表快照检查保留。扩展 directReceiptOwnerOutbox：完成原控制隐私与 owner outbox 投递验证后安装真实迁移标记，私聊直接标量/批量新旧请求拒绝，房间、已读位置、操作回执、个人事件队列及同步日志五表完整行快照不变。
- 同轮运行 readReceiptOwnerMixedBatch，确保某项归属失败不破坏其他合法项。未修改客户端、schema 46 或协议 30；未证明个人事件队列整体排空或完整迁移，B27 仍开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 routedReadReceiptOwnerEpochFence、directReceiptOwnerOutbox、readReceiptOwnerMixedBatch：3 项测试、10 个场景、1 套件通过，8.832 秒；日志 /tmp/imv2-room-migration-direct-receipt-fence.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-migration-direct-receipt-sources-20260920.json。未提交或部署。

<a id="20260920-user-event-source-room"></a>

## 2026-09-20 个人事件队列的显式来源房间

- 归属核对发现：room/membership、私聊资料、已读水位、已读候选、发送能力及时间线提示由 owner 事务产生；control 的已读偏好传播也产生带 room_id 的 direct_read_receipt。不能按 projection_kind 或载荷房间 ID 推断源队列属于房间。
- 新库 schema 47 为 user_state_event_outbox 增加可空 source_room_id、源房间有界扫描索引及载荷房间绑定约束。非空表示随房间迁移的源事件；空表示其他来源，不自动因载荷含 room_id 归类。共用 enqueue 接受显式来源并将其纳入幂等比较，避免同一事件身份在 control/room 间重绑定。
- 群创建、成员变更、审核移除、私聊创建/资料、发送能力、时间线拒绝提示及标量/批量已读水位/候选写入均标明源房间；control 偏好传播继续使用空来源。Account/Gateway 新库契约和启动检查同步为 47，协议仍为 30；没有旧库升级或兼容分支。
- sourceRoomOwnership 专项区分同类型/同房间载荷的 owner/control 事件，验证精确重试、来源改参冲突、数据库绑定约束及删除来源列后启动拒绝。运行相关业务回归检查实际生产 SQL 与新约束配合。
- 本批提供队列归属和后续复制选择依据，尚未将 claim/acknowledge/retry/operator/清理接入房间屏障，也未排空已认领事件或完成迁移。B27 保持开放。

- 首轮 canonical 建库检查发现新增索引导致总数从 354 变为 355，日志 /tmp/imv2-user-event-source-room-schema.log；核对新增单个来源索引后更新精确计数，重跑建库/恢复、漂移及 readiness 关系覆盖检查通过，日志 /tmp/imv2-user-event-source-room-schema-final.log。当前仍为 151 张表、27 个应用触发器、25 个函数。

- 临时 PostgreSQL（55479、disposable 标记）sourceRoomOwnership 1 项通过，0.525 秒，日志 /tmp/imv2-user-event-source-room.log。复用构建顺序执行生产入口过滤回归：routedSendOwnerEpochFence、routedMembershipOwnerEpochFence、routedModerationOwnerEpochFence、directReceiptOwnerOutbox、readReceiptOwnerMixedBatch、groupCreationTimestampBoundaries、readReceiptPolicyDirectoryPropagation，共 7 项测试、29 个场景通过，22.666 秒，日志 /tmp/imv2-user-event-source-room-regression.log。未运行全套测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-user-event-source-room-sources-20260920.json。未提交或部署。


<a id="20260920-user-event-migration-fence"></a>

## 2026-09-20 个人事件队列迁移屏障

- PostgresV2UserStateEventOutbox 的 claim、acknowledge、retry 按 source_room_id 主键查询来源房间，在队列修改所在 SQL 内取得共享锁并要求 migration_fence_id 为空。认领使用 SKIP LOCKED，确认及重试等待并复核；空来源事件不受载荷中房间 ID 影响，缺失来源房间时保持队列不变。
- 新增 sourceRoomMigrationFence：真实安装冻结标记前认领一个事件，保留另一待认领事件；冻结后确认返回 false，重试及暂停不修改原行。重建存储并越过租约期限，冻结与缺失房间事件不被认领，正常房间及载荷包含被冻结房间的 control 事件仍认领/确认成功。冻结两行完整快照保持不变。
- 临时 PostgreSQL 主/次库（55479、disposable 标记）执行 PostgresV2UserStateEventTests，24 项测试、1 套件通过，15.254 秒；新增场景 0.323 秒。日志 /tmp/imv2-user-event-migration-fence.log。未运行全仓测试。
- 本批仅保护队列三类修改；运维重放和已确认队列清理仍需接入屏障，已经认领的事件仍可能向用户库提交投影，其排空/去重承接需单独闭环。未变更客户端、schema 47 或协议 30；B27 保持开放。

- 文档链接、结构与差异空白检查通过，临时数据库已停止。本机源码/日志 SHA-256 清单 /tmp/imv2-user-event-migration-fence-sources-20260920.json；未提交或部署。


<a id="20260920-user-event-maintenance-fence"></a>

## 2026-09-20 个人事件运维重放与过期清理迁移屏障

- PostgresV2DurableWorkReplayStore 的 userStateEvent 分支读取不可变 source_room_id；有来源时先共享锁定房间并检查迁移标记，再修改暂停事件。更新条件复核相同来源；房间缺失或冻结抛出 ownerChanged，外层事务回滚审计预占。没有目标仍按既有 notPaused 结果处理，原操作精确重放只读已有审计。
- PostgresV2UserStateEventGCWorker 的到期候选按来源房间主键取得共享锁并跳过占锁，冻结/缺失房间事件保留；control 空来源不受载荷房间影响，原 delivered_at 保留期限和数量限制不变。
- 新增运维专项覆盖正常重放后冻结、精确结果重放、单目标及按事件批量拒绝、缺失房间拒绝、事件与审计完整快照不变，以及同房间载荷 control 事件继续处理。新增清理专项覆盖安装标记的在途事务和普通房间占锁、正常/control 清理、缺失房间保留、锁释放后清理恢复或继续因标记保留。
- 验证结果在本节后续记录；本批不证明在途投影/外部 I/O 已排空，不关闭 B27。未变更客户端、schema 47 或协议 30。

- 首轮 5 项测试中，运维新专项、原运维重放及审计时间边界均通过（3 项、5 个场景，4.174 秒），原清理回归也通过；新增清理两个并发场景遇到 connectionRequestTimeout。核对测试依赖默认每事件循环只有 1 条连接，持锁事务耗尽连接后无法启动独立清理，尚未进入待验证 SQL。将该测试辅助数据库配置为每事件循环 4 条连接，仅重跑受影响清理专项。首轮日志保留为 /tmp/imv2-user-event-maintenance-fence.log。

- 修正测试连接池后，sourceRoomGCFence 两场景及 completedEventGC 通过（2 项、3 个场景，1.112 秒）；日志 /tmp/imv2-user-event-maintenance-fence-final.log。两轮合计覆盖 5 项、8 个不同场景，未重跑已通过的运维专项或全仓测试。临时 PostgreSQL 已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-user-event-maintenance-fence-sources-20260920.json。未提交或部署。


<a id="20260920-room-wake-migration-fence"></a>

## 2026-09-20 房间唤醒队列迁移屏障

- PostgresV2GroupEventWakeStore 在候选认领、发布确认删除和安排重试三处按实际 room_id 取得房间共享锁，并检查 migration_fence_id 为空；认领使用 SKIP LOCKED 避免一个忙碌房间阻塞其他候选，回调等待并复核。原租约令牌与修订条件保留。
- 认领保留两条 READ COMMITTED 语句：先持久化租约，再取得当前房间水位；房间锁持有到事务提交。此项不取消已经发出的外部通知，也不证明完整排空。
- 新增 groupWakeMigrationFence 的直接/路由两种入口：先认领旧租约，再创建待认领及正常房间；实际持房间锁时只有正常房间被认领。安装真实迁移标记后，旧租约确认/重试均保持队列原行，重建存储并越过租约期限仍跳过冻结房间，正常房间可认领并确认删除。另保留高水位 7 覆盖队列目标 3 的断言。
- 同轮选择重试整数边界、时间边界和同房间批量发送/唤醒水位回归。验证结果见后续记录；未修改客户端、schema 47 或协议 30，B27 继续开放。

- 首轮日志 /tmp/imv2-room-wake-migration-fence.log：原重试边界 12 场景、时间边界 2 场景和同房间批量发送 1 场景通过；新增直接调用场景通过，路由场景失败。原因是测试先经路由确认再以同一租约经路由重试，前者已按既有契约移除进程内映射，后者因此报 corruptPersistenceState，未进入数据库重试检查。
- 修正新增测试为直接/路由 × 确认优先/重试优先四场景：第一个回调走所选入口，迟到的另一个回调直接进入持久存储，覆盖两种冻结后回调顺序及原路由映射消费规则；仅重跑新增专项，保留首轮失败日志。

- 修正测试调用方式后，groupWakeMigrationFence 四场景通过，3.064 秒，日志 /tmp/imv2-room-wake-migration-fence-final.log。连同首轮通过的三项回归，本批覆盖 4 项测试、19 个不同场景。只运行所选专项，临时 PostgreSQL 主/次库（55479、disposable 标记）已停止。
- 文档链接、结构和 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-wake-migration-fence-sources-20260920.json。未提交或部署。


<a id="20260920-direct-open-migration-fence"></a>

## 2026-09-20 复用私聊房间迁移屏障

- 核对发现 open 的 existingPair 分支已持房间共享锁，但未检查 migration_fence_id，冻结后仍可插入新的 direct_room_operations。现从同一锁定查询读取标记并在新增回执前抛出 ownerChanged；创建新房间流程和已有精确操作只读重放保持原行为。
- directRoomOpenMigrationFence 覆盖直接及路由两种入口：先经真实 control 路由创建 owner 私聊，再持有真实标记安装事务，发起新操作，并从 pg_stat_activity 确认请求等待房间锁；释放冻结提交后新操作拒绝，操作回执仅原有一条。重建存储后的新请求仍拒绝，旧请求仍返回原房间；owner 七表与 control 三表完整行快照保持不变。
- 同轮选择 directRoomOpenConcurrentReplay 六种操作/用户对并发组合、directRouteClockBounds 两种目录恢复状态回归。验证结果见后续记录。没有历史兼容或客户端变更；schema 47、协议 30 不变，完整私聊迁移仍按 B27 跟踪。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行上述三项，3 项测试、10 个场景、1 套件通过，7.809 秒；新增冻结交错两场景 1.553 秒。日志 /tmp/imv2-direct-open-migration-fence.log。没有运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-direct-open-migration-fence-sources-20260920.json。未提交或部署。


<a id="20260920-special-account-migration-fence"></a>

## 2026-09-20 特殊账号消息后处理迁移屏障

- PostgresV2SpecialAccountMessagingStore.record 原先仅按操作加锁，新操作仍可在房间冻结后插入操作记录和审计。现新操作在房间共享锁下检查 migration_fence_id，冻结或缺失房间拒绝；已存在的精确操作保持只读。
- 校验接受回执的 roomID、senderUserID、clientMessageID 分别与输入房间、账号及操作一致，防止锁定其他房间而绕过实际消息的冻结边界；既有操作幂等比较增加 room_id。
- 扩展 specialAccountMessageClockBounds 的系统/客服两个场景：保持原时间边界、并发重放和审计插入失败回滚验收后，实际接受另一条消息但不记录特殊账号审计；安装迁移标记，重建存储的新后处理拒绝，旧后处理重放不变。错房间和错操作回执拒绝，整个服务重试也拒绝；操作、审计、消息、事件、私聊操作、支持会话与准入完整快照保持不变。
- 同轮选择特殊账号服务单元回归。结果见后续记录；没有客户端或历史兼容变更，schema 47、协议 30 不变。尚未实现消息接受后缺失审计的迁移承接/自动恢复，B27 保持开放。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）执行 specialAccountMessageClockBounds 与 V2SpecialAccountMessagingServiceTests：2 项测试、3 个场景、2 套件通过，1.784 秒。日志 /tmp/imv2-special-account-migration-fence.log。未运行全仓测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-special-account-migration-fence-sources-20260920.json。未提交或部署。


<a id="20260920-room-credit-migration-fence"></a>

## 2026-09-20 房间命令额度持久预扣迁移屏障

- 核对消息投影补建：loadCurrentOrMaterialize 的当前生产调用只有编辑、撤回和审核处置，均在已有房间写入检查内；本次未给只读路径增加无依据的额外锁。
- V2RoomAdmissionCommandCreditPool.reserveBatch 原先独立修改 room_admission，发送事务虽然拒绝冻结，预扣仍可能先改动源数据。现使用 materialized 房间候选取得 FOR KEY SHARE 锁并要求 migration_fence_id 为空，然后按原分片租约/代次/窗口上限锁定准入行和预扣。rejection 读取迁移标记并抛 ownerChanged，不把冻结误报为额度耗尽。
- 新增 roomCreditMigrationFence 的标量/批量场景：持真实冻结安装事务，启动额度预扣，从 pg_stat_activity 确认等待房间锁，提交冻结后拒绝；重建额度池后仍拒绝，源准入完整行不变。批量中的正常房间先预扣，后项冻结失败时归还进程令牌，没有悬挂 inFlight；正常房间仍可取得额度且仅预扣原批量的 2 个额度。
- 同轮选择房间额度容量与时间边界回归。结果见后续记录；本批不验证已预取额度的迁移失效、分片额度清退或目标重建，不关闭 B27。未修改客户端、schema 47 或协议 30。

- 首轮冻结/容量/时间专项 3 项、11 个场景通过，7.868 秒，日志 /tmp/imv2-room-credit-migration-fence.log；该轮尚未覆盖真实发送事务持锁后请求独立预扣的路径。继续查调用链发现 acceptSingleDirectRoomLogWithCredits 的预检持有房间锁后才调用额度池，不能使用与之冲突的共享锁。
- 对照 [PostgreSQL 16 行锁文档](https://www.postgresql.org/docs/16/explicit-locking.html#LOCKING-ROWS)，额度预扣采用 KEY SHARE，发送预检改为 NO KEY UPDATE（仍串行正常写入），冻结安装保持显式 FOR UPDATE（与两者冲突）。中间构建在发现预检仍有 FOR UPDATE 时主动终止，进程已确认为退出 143，尚未执行测试；日志 /tmp/imv2-room-credit-migration-fence-final.log 保留，不记作通过。
- 新专项追加正常发送持有 NO KEY UPDATE 时通过独立连接预扣成功的检查；扩大到真实私聊发送/额度快速路径及 routedSendOwnerEpochFence，复验最终锁组合，结果见后续记录。

- 最终版本在临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 roomCreditMigrationFence、directRoomLogRoomCommandCreditsPreserveRoomCapacity、admissionCreditClockBounds、persistsDirectRoomLogWithoutPerUserFanoutArtifacts、routedSendOwnerEpochFence：5 项测试、19 个场景、1 套件通过，13.448 秒。日志 /tmp/imv2-room-credit-migration-fence-verified.log；先前结果不替代最终锁组合的复验。未跑全仓测试，临时数据库已停止。
- 文档链接、结构与 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-room-credit-migration-fence-sources-20260920.json。未提交或部署。


<a id="20260920-direct-control-policy-fence"></a>

## 2026-09-20 私聊控制权限事务基础

- 调用链核对确认：Gateway 的 PostgresV2SocialRelationshipStore 写控制库，V2RoutedRoomWriteStore 选择 owner 后直接调用其接受实现；当前 owner 的关系/拉黑/偏好和缓存版本不能替代控制权威。未把加入迁移标记过滤当作跨库授权修复。
- 新增内部 V2DirectSendControlPolicyFence.withPolicy，复用实际关系/拉黑、陌生人偏好和停用账号写者的咨询锁键，以共享模式持有到异步回调完成；现有资料及特殊账号行另取共享行锁。读取双方活跃状态、特殊账号设置、拉黑、好友及接收者陌生人偏好，缺失资料返回 inactive，非法/同一用户对拒绝。
- directControlPolicyFence 使用独立控制库和 owner 库；控制回调等待期间发起四种真实写者（拉黑、删除好友、陌生人权限拒绝、账号停用），从 pg_stat_activity 确认它们等待咨询锁。释放回调、在 owner 测试表提交后，写者才能完成；下一次范围读取观察最新控制事实，owner 本地副本保持未修改。另测回调抛错后锁释放、缺失账号和非法用户对。
- 测试中的 owner 提交是专用测试表，**不是实际发送验收**。新增入口尚未接入 PostgresV2RoomWriteStore 或应用组装，也未改写社交版本递增；缓存、批量统一锁顺序、控制连接失效与真实消息提交的端到端边界仍待完成，B27/D07 不关闭。

- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 directControlPolicyFence：1 项测试、4 个场景通过，2.994 秒；日志 /tmp/imv2-direct-control-policy-fence.log。此证据限于连接正常时的回调生命周期，控制连接中断与 owner 迟到提交尚须故障注入验证；不能将本方法当作已完成的分布式提交保证。未运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-direct-control-policy-fence-sources-20260920.json。未提交或部署。


<a id="20260920-direct-send-control-authority"></a>

## 2026-09-20 单条私聊发送控制权限接入

- PostgresV2RoomWriteStore 增加内部 acceptDirectUsingControlPolicy：先只读定位接收者，在控制事务取得权限范围后才进入 owner 接受事务；固定 room/sender/recipient 并在领域预检时复核，不把快照暴露给调用者复用。
- 普通接受、单条额度预检及快速追加以控制事实覆盖账号状态、拉黑、好友、陌生人偏好和特殊账号设置；成员、禁言、回复、可见性投影、房间/分片额度继续取自 owner。已有操作回执仍先按原结果重放。
- 新增 directSendControlAuthority，在独立控制/owner 数据库上使用真实私聊房间与真实发送，覆盖冷路径/预热路径 × 拉黑、并发拉黑、删除好友、陌生人权限拒绝、发送者停用、接收者停用；owner 权限副本保持过时，另检查权限恢复后的新发送以及旧拒绝回执不变。结果见后续记录。
- 本批只提供内部单条接受入口。应用组装、原子批量全局锁顺序、转发目标接入、社交版本归属，以及控制连接失效/owner 迟到提交仍待完成；B27/D07 保持开放。未修改客户端、schema 47 或协议 30。


- 首轮 /tmp/imv2-direct-send-control-authority.log：新增 10 场景均在“首次接受结果与重放结果直接比较”的测试断言失败；既有控制范围 4 场景和房间日志 2 场景通过。实际契约区分 accepted 与 idempotent，已修正为检查重放类型及原接受回执相等；该轮整体不记为通过。
- 快速追加仅在事务内使用控制事实派生快照，提交后继续缓存原 owner 快照，避免控制范围结束后经共享缓存泄漏到其他入口。新增缓存断言：控制库拒绝陌生人、owner 仍允许时，好友快速追加成功，但缓存仍保存 owner 的允许值。
- 增加两种并发场景：先持 owner 房间锁，启动实际发送并观察其等待房间锁，再发起控制拉黑并观察其等待咨询锁；释放房间锁后发送完成、拉黑随后提交，后续新发送被拒绝。控制连接中断不在此证据范围内。


- 最终版本在临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 directSendControlAuthority、directControlPolicyFence、persistsDirectRoomLogWithoutPerUserFanoutArtifacts：3 项测试、18 个场景、1 套件通过，12.295 秒；新增实际发送 12 场景 8.403 秒。日志 /tmp/imv2-direct-send-control-authority-final.log，首轮失败日志保留。未运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-direct-send-control-authority-sources-20260920.json。未提交或部署；问题关闭数量不变。


<a id="20260920-direct-batch-control-authority"></a>

## 2026-09-20 私聊原子批量控制权限接入

- V2DirectSendControlPolicyFence 增加 withPolicies：最多 128 个发送方向，完整用户集合、规范用户对集合分别去重排序；先统一取得账号、用户对、偏好锁，再集合读取账号和方向策略。单条入口委托同一实现，不按请求顺序嵌套单对事务。
- PostgresV2RoomWriteStore 增加内部 acceptDirectAtomicallyUsingControlPolicy；单条与批量共用一次 owner 集合发现、固定 room/sender/recipient 映射及控制事务。范围覆盖实际 acceptAtomicallyOwnerValidated 的普通批量和缓存快速追加，owner 当前回复、成员与额度规则仍保留。
- 新增 directBatchControlAuthority：冷/预热 × 拉黑第一/第二条四场景，使用独立控制/owner 库、两个真实私聊。检查正常接受、预热后的实际快速批量、相反房间顺序的并发接受、owner 权限未更新时整批拒绝且无前缀落库、解除后以同批操作重试成功，以及空集合和超出 128 条的拒绝。另选既有单条权限、控制锁及房间日志专项回归。
- 首轮 /tmp/imv2-direct-batch-control-authority.log 在新增测试构造 ownerRoute 时缺少 try，编译失败，未执行测试。已修正测试构造；最终结果见后续记录。
- 应用组装尚未使用这两个内部入口，转发目标接入、社交版本归属及控制连接失效边界仍未贯通，B27/D07 继续开放。未修改客户端、schema 47 或协议 30。


- 最终版本在临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 directBatchControlAuthority、directSendControlAuthority、directControlPolicyFence、persistsDirectRoomLogWithoutPerUserFanoutArtifacts：4 项测试、22 个场景、1 套件通过，16.637 秒；新增批量四场景 3.216 秒。日志 /tmp/imv2-direct-batch-control-authority-final.log，首轮编译失败日志保留。未运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-direct-batch-control-authority-sources-20260920.json。未提交或部署；问题关闭数量不变。应用接线另须隔离控制权限连接池并计入预算，避免同物理库下控制与 owner 嵌套取连接的依赖。


<a id="20260920-control-policy-runtime"></a>

## 2026-09-20 控制权限运行入口及独立连接池

- 将先前仅用于内部专项的单条/批量方法并入正式 accept、acceptAtomically、importForwardExport；usingControlDatabase 绑定控制池，usingWorkloadDatabase 保留绑定。房间集合发现记录 kind，owner 锁下复核；群聊保留 owner 授权且不占私聊控制事务。单条和批量旧专项改为调用正式 owner-validated 方法。
- Gateway 同库和多库两处写存储构造均绑定独立 direct-send-control 池；前台转发及后台目标写存储复用绑定。每 EventLoop 配额跟随当前 foreground 配额，独立于 owner 和个人事件路由池；计入总连接上限、溢出检查、会话就绪验证、Application 关闭及固定指标 direct_send_control。
- 新增 routedDirectControlPools 的同物理库/不同库两个场景：控制与 owner 各只有一个连接，经实际 V2RoutedRoomWriteStore 执行群聊、并发私聊及拉黑后拒绝。新增 directForwardControlAuthority：真实源消息导出至另一库私聊，拉黑后新导入拒绝、旧终态不变、解除后新导入恢复；工作连接池副本保留控制配置。
- 配置测试覆盖隔离/共享模式：预算少一条即拒绝，足额时接受，并检查权限池配额。选择单条、批量和控制围栏回归；结果见后续记录。未修改客户端、schema 47 或协议 30。
- 这不是完整分布式提交保证：控制连接失效、社交版本与冻结房间解耦、所有转发组合及生产容量仍需证据，B27/D07 保持开放。


- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行上述数据库专项与 V2GatewayRuntimeConfigurationTests：37 项测试、2 套件通过，18.048 秒，其中数据库专项 23 个场景。实际路由小池 2 场景 1.655 秒，私聊转发 1 场景 0.808 秒。日志 /tmp/imv2-control-policy-runtime.log。
- 因共用 requireSelectedOwners 查询增加 room_kind，另以同一构建补跑原有 persistsDirectRoomLogWithoutPerUserFanoutArtifacts 的直接/路由两场景：1 项测试、2 场景通过，1.072 秒，日志 /tmp/imv2-control-policy-runtime-room-log.log。合计 38 项不同测试、数据库部分 25 个场景；未运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-control-policy-runtime-sources-20260920.json。源码中的旧“未组装”说明已同步修正，仅注释不改变已验证行为。未提交或部署，问题关闭数量不变。


<a id="20260920-social-frozen-source-policy"></a>

## 2026-09-20 社交变更与冻结源副本解耦

- PostgresV2SocialRelationshipStore.bumpDirectPairPolicyRevision 改为 rooms 共享锁 → direct_room_pairs 更新锁，仅锁定并递增未冻结房间。真实冻结安装的 FOR UPDATE 与此共享锁互斥，等待后复核 migration_fence_id。控制库关系/拉黑不依赖已冻结副本的版本空间，正常本地房间保留原修订与 Int64 上限检查。
- 陌生人设置修改的是控制库用户偏好与用户策略版本，没有直接写 direct_room_pairs，本批未改该实现。目标房间继续通过已接入的控制权限范围判定拉黑、好友及偏好，房间副本的旧好友状态不参与控制权威。
- 新增 socialFrozenSourcePolicy 的拉黑/删除好友两场景：在两个独立数据库预置相同 roomID 的私聊、预热目标缓存，将源策略版本设至 Int64.max；持真实冻结安装事务，启动社交写入并观察它等待房间锁，释放冻结后控制变更成功且源用户对完整行不变。目标副本仍保存旧好友且没有拉黑，实际发送仍拒绝；解除/重新建交后新发送恢复，源完整用户对行仍不变。
- 同 roomID 的双库房间是测试预置，不是执行了迁移复制或路由发布。选择社交并发重放/最终整数边界、正式路由小池发送和单条控制权限专项回归。结果见后续记录；B27/D07 继续开放，未修改客户端、schema 47 或协议 30。


- 临时 PostgreSQL 主/次库（55479、disposable 标记）过滤执行 socialFrozenSourcePolicy、socialOperationConcurrentReplay、routedDirectControlPools、directSendControlAuthority：4 项测试、28 个场景、1 套件通过，21.941 秒；新增冻结副本 2 场景 1.669 秒。日志 /tmp/imv2-social-frozen-source-policy.log。未运行全仓测试，临时数据库已停止。
- 文档链接、结构及 diff 空白检查通过；本机源码/日志 SHA-256 清单 /tmp/imv2-social-frozen-source-policy-sources-20260920.json。未提交或部署，问题关闭数量不变。


<a id="20260920-direct-control-connection-loss"></a>

## 2026-09-20 控制连接中断故障复现

- 新增 directControlConnectionLoss 的冷/预热两场景：实际私聊发送取得控制权限后等待 owner 房间锁；仅在 disposable 主/次库中，精确定位该控制事务的后端并终止它；随后通过真实社交服务提交拉黑，再释放 owner 锁，检查旧发送是否仍创建消息以及调用者是否收到错误。
- 安全断言要求旧操作消息数为零。测试以 withKnownIssue 显式标记尚未解决的 D07 故障边界；这是可执行的未关闭回归，不是放宽通过标准。正常请求随后必须观察到拉黑并拒绝。实际运行结果见后续记录。
- 本地 Fluent 驱动事务实现等待异步业务闭包返回后才执行 COMMIT，独立 owner 回调不因控制连接关闭自动获得持久拒绝。已在迁移合同补充待实现的持久授权意图、owner 回执/拒绝标记及撤权恢复要求；尚未新增生产协议、schema 或回收规则。


- 首轮 /tmp/imv2-direct-control-connection-loss.log 两场景在故障注入 SQL 处失败，尚未断开控制连接。临时 PostgreSQL 日志明确为 pg_terminate_backend(bigint) 不存在；已将绑定的测试后端 PID 显式转为 int4，仅重跑该专项。该轮不作为业务安全证据。


- 第二轮 /tmp/imv2-direct-control-connection-loss-final.log 已成功终止控制后端；冷场景观察到控制库 user_blocks 为 1、owner messages 为 1，但测试等待旧请求收尾未结束。约 149 秒后核对仍运行的测试子进程 PID/父进程关系，终止该确切子进程，原运行以退出 1 结束。随后独立读取上述两库计数仍各为 1，确认记录已提交；清理本轮测试创建的 im_v2 schema。此轮不是通过结果，也没有因观察超时重启同一进程。
- 故障探针改在独立子进程运行：父进程创建并拥有临时 schema，子进程完成注入和观测后写出报告并退出，父进程核对报告及安全断言后清理。设 30 秒子进程 watchdog，不等待被断连接口的收尾。此隔离只修正测试生命周期，不是生产问题修复。


- 隔离版日志 /tmp/imv2-direct-control-connection-loss-isolated.log：父测试冷/预热 2 场景均完成观测，1.754 秒；两份报告均为 controlBlocks=1、ownerCommitted=1，观测时 callbackSettled=0。新请求已按拉黑拒绝，但先前持有快照的操作仍在拉黑提交后写入消息。安全断言实际失败两次，由 withKnownIssue 明确记录；测试工具退出 0 不代表缺陷修复。子探针在父运行中跳过，仅由父测试显式启动。
- 父进程已清理两个场景的临时 schema，PostgreSQL 主/次库（55479）已停止。没有跑无关回归或全仓测试，没有修改生产授权行为、schema 47 或协议 30；生产源码仅补充了连接失效边界的注释。
- D07 优先级升为 P1，仍为实施中；关闭数量不变。文档链接、结构及 diff 空白检查通过；本机源码/日志及两份探针报告的 SHA-256 清单 /tmp/imv2-direct-control-connection-loss-sources-20260920.json。未提交或部署。


### 20260920-direct-authorization-owner-receipts

- 范围：D07 持久授权的房间侧原语，关联 B11/B27。schema 48 新增 direct_authorization_receipts；152 张表、356 个索引、28 个应用触发器、26 个函数。项目未上线，只修改当前新库合同，不新增旧库升级链。
- 原语：prepare 与现有单条发送共用操作锁，绑定操作/代次、接收者、owner shard/epoch 与 v3 摘要；finish 必须读取同事务的接受/业务拒绝事实才能生成证明，已有 aborted 会抛错；abort 等待同一操作锁，保存原结果或持久中止。跨代次不能更改命令摘要；数据库拒绝更新/删除，启动检查精确验证约束、索引及触发器函数。
- 新增真实 PostgreSQL 4 项测试、7 个场景通过，覆盖先中止后迟到准备/完成、原代次与新代次重放/改参、更新/删除拒绝、真实操作锁等待后的提交/回滚、无完成事实、旧 owner epoch，以及触发器禁用/约束缺失/函数改写的启动拒绝。测试以独立随机 schema 执行，原语测试的完成记录为受控数据库夹具，不能代替正式消息入口接线。
- 同轮原有 directSendControlAuthority 的 12 个实际发送场景通过。合计 5 项测试、19 个场景、2 个 suite，执行 9.859 秒；首次新增测试编译因仅含宏的事务闭包未显式声明 throws 失败，修正后完整结束并通过；没有将编译失败算作通过。
- 独立新库建库、schema-only 恢复与漂移检查通过；初次建库在 readiness 表清单更新前报告缺少新表，补齐后最终通过。文档链接、结构和差异检查通过。
- 日志：`/tmp/imv2-direct-authorization-owner-receipts.log`（首次编译失败）、`/tmp/imv2-direct-authorization-owner-receipts-final.log`（最终通过）、`/tmp/imv2-direct-authorization-schema-bootstrap-initial.log`（初次清单缺项）、`/tmp/imv2-direct-authorization-schema-bootstrap.log`（最终建库通过）。源码指纹：`/tmp/imv2-direct-authorization-owner-receipts-sources-20260920.json`。这些是本机临时证据，不是远端 CI 或干净 checkout 验收。
- 限制：正式消息接受、批量与转发尚未接入这些原语；控制授权意图、撤权协调及恢复工作器仍待完成。D07 控制断连后迟到发送的 P1 复现没有关闭，本轮未重复运行其已知失败测试。新记录当前不自动过期，完整保留/迁移仍由 B11/B27 跟踪。没有运行全仓测试、修改客户端、提交或部署。


### 20260920-direct-authorization-control-intents

- 范围：D07 持久授权的控制侧登记、撤权协调与恢复原语，关联 B11/B27。schema 49 新增 direct_authorization_intents，153 张表、360 个索引、29 个应用触发器、27 个函数；只修改当前新库合同。
- 实现：控制权限与整批授权登记同事务提交，登记行同时承担恢复任务。相同操作重试沿用原 owner、epoch、代次与权限事实，只有持久 aborted 被控制库确认后，新前台请求才能开启新代次并刷新事实；原命令摘要/接收者/初始时间不变。数据库保护 held 代次与终态，拒绝删除、非法结果/租约组合。
- 撤权原语在既有排他权限锁内读取 held，最多处理 128 项，通过 owner 操作锁取得已提交结果或持久中止记录；确认使用独立控制连接。外层撤权因批次上限或不可达回滚，不抹去已完成的确认进度；剩余 held 不为空不能报告成功。恢复最多认领 100 项，过期仅重新认领，owner 不可达时退避；旧租约不能清除新租约，旧代次不能释放新代次。
- 新增 5 项测试、8 个真实 PostgreSQL 场景通过：授权登记提交后终止实际控制 backend、重新连接重放并持久中止迟到代次；两项登记以每批一项排空，首轮外层事务失败后保留确认进度，第二轮成功才写入拉黑；owner 不可达、恢复租约过期/旧租约回调与新代次；8 个反序批量并发重试、改参导致整批回滚，以及数据库拒绝 held 代次/策略改写、无结果事件 ID 与删除；索引/约束/触发器/函数内容漂移的启动拒绝。
- 同轮房间侧回执 7 场景与原控制锁 4 场景回归通过。合计 10 项测试、19 个场景、3 个 suite，执行 7.253 秒，编译 233.39 秒。测试使用两个独立 PostgreSQL 数据库和随机 schema；撤权政策写入由受控 SQL 夹具执行，尚不能证明正式社交/偏好/账号停用入口已经接通。断连发生于控制授权登记提交之后，不替代原正式发送的控制事务中断 P1 复验。
- 独立当前新库建库、schema-only 恢复与漂移检查通过。日志：`/tmp/imv2-direct-authorization-intents.log`、`/tmp/imv2-direct-authorization-intent-schema.log`。源码指纹：`/tmp/imv2-direct-authorization-control-intents-sources-20260920.json`；最后仅校正权限快照的源码说明，未改动已测执行逻辑。这些为本机临时证据，不是远端 CI 或干净 checkout 验收。
- 限制：普通/批量/转发的 owner 同事务接线、权限写者与独立池配置、后台生命周期和实际 P1 断连回归仍未完成，D07 保持开放。完整记录保留和房间迁移承接仍由 B11/B27 跟踪。没有运行全仓测试、修改客户端、提交或部署。


### 20260920-direct-authorization-owner-entry

- 范围：D07 房间侧正式接受事务的持久授权接线，关联 B11/B27。schema 49 与协议 30 不变，没有新增历史兼容路径。
- 实现：PostgresV2RoomWriteStore 通过 usingAuthorizationGrants 绑定已提交的控制授权，校验命令摘要并保留 owner/epoch/接收者/代次。普通发送、标准/快速原子批量与转发导入的消息事务统一在返回前记录授权证明；失败回滚同事务的消息与序号。准入未形成接受或业务拒绝时不生成终态，继续 held 供重试/恢复。usingWorkloadDatabase 保留绑定。
- 锁顺序：checkAttempt 只取得与发送共用的操作锁并检查中止记录；既有源/目标房间按序加锁后才执行完整 prepare，避免同库转发提前锁目标房间。批量先取得完整操作锁集合，再校验房间归属与授权；中止代次始终抛错。
- 新增 3 项测试、14 个真实双数据库场景通过：单条接受/业务拒绝/预先中止/回执约束注入失败各两种缓存状态，证明回执失败使消息与房间序号回滚，修复约束后同操作可接受；中止后新代次接受，旧代次仍被拒绝；批量的前/后命令中止与冷/预热四种组合无部分提交，更新代次后两条消息与证明提交，预热批量确认实际快速追加计数；转发导入预先中止不能落消息，成功导入及精确重放保持一个接受证明。
- 同轮原有单条控制授权 12 场景、原子批量 4 场景、转发控制授权 1 场景，房间证明 7 场景、控制意图 8 场景回归通过。合计 15 项测试、46 个场景、3 个 suite，执行 25.013 秒，编译 220.05 秒。日志：`/tmp/imv2-direct-authorization-owner-entry.log`；源码指纹：`/tmp/imv2-direct-authorization-owner-entry-sources-20260920.json`。
- 限制：测试显式调用控制登记并把授权绑定到正式写存储；Gateway 仍需自动登记/绑定/确认，社交/偏好/账号停用等权限写者仍需接入 drain，后台生命周期仍需注册恢复。旧瞬时控制范围尚未被替换，原 D07 P1 断连复现未关闭，本轮未重复其已知失败测试；媒体转发、同库跨房间竞态与完整运行入口的故障矩阵仍需继续验证。没有把本轮结果表述为整体断连修复。
- 本轮只跑受影响的服务端专项；未运行全仓测试、改动客户端、提交或部署。本机证据不是远端 CI 或干净 checkout 结果。


### 20260920-direct-authorization-policy-writers

- 范围：D07 实际权限写者的持久授权排空及协议错误分类，关联 B11/B27。schema 49、协议 30 不变。
- 接线：关系变更/拉黑、陌生人权限、账号停用，在既有排他用户对/偏好/账号状态锁范围内先处理 held 意图，再改变控制事实与登记操作。精确操作重放先返回，不取消后来授权。协调器缺失时也读取 held 并拒绝有未完成授权的变更；owner 不可达不能假报成功。
- 新增 directDurablePolicyWriters 的 12 个真实双库场景通过（四类操作 × 已配置/缺失/不可达）：成功撤权阻止持久授权的迟到真实发送；配置缺失或不可达时，权限、好友状态及 held 不被错误改写；原发送可在失败撤权后真实接受，随后重试撤权确认原接受回执，旧发送仍幂等返回原结果；新授权读取新控制事实；旧权限操作重放不取消后来 held。
- 第一轮同时验证原社交并发重放 12 场景、原单条控制授权 12 场景、原控制权限锁 4 场景。合计 4 项测试、40 个数据库场景，执行 32.201 秒，通过。日志：`/tmp/imv2-direct-authorization-policy-writers.log`。
- 随后补齐网关映射：撤权未完成/owner 不可达/中止代次及内部持久化异常返回可重试 UNAVAILABLE；控制命令身份冲突返回不可重试 IDEMPOTENCY_CONFLICT，异常不逃出命令处理器。账号停用将排空失败映射为既有 unavailable，取消信号继续传播。
- 最终重跑受影响的 12 个撤权场景，新增网关 5 个错误映射场景（同处理器重复调用），并运行账号停用 HTTP 原有 5 个参数/非参数场景。合计 5 项测试、22 个场景、3 个 suite，执行 8.685 秒，通过。未重复第一轮未受后续错误分类影响的其余数据库专项。日志：`/tmp/imv2-direct-authorization-policy-writers-final.log`；源码指纹：`/tmp/imv2-direct-authorization-policy-writers-sources-20260920.json`。最后仅补充协调器连接池隔离说明，没有改变已测逻辑。
- 边界：测试显式传入协调器、登记并绑定授权；连接夹具允许多连接，尚不能证明最小连接池的运行组装。Gateway/Operator 自动授权登记/绑定/确认、独立于预留和权限写者的确认池、独立 owner 中止连接、后台恢复生命周期仍需接通并验证。原瞬时控制范围尚未替换，D07 P1 断连复现继续开放，本轮没有重复其已知失败测试。特殊账号和其他权限写者的完整入口清点、全转发/迁移故障矩阵仍需继续。
- 未运行全仓测试、修改客户端、提交或部署。本机结果不替代远端 CI、干净 checkout 和生产容量验收。


### 20260920-direct-authorization-runtime-pools

- 范围：D07 的 Gateway/Operator 协调器与处理连接池、Gateway 恢复任务接线；schema 49、协议 30 不变，不引入历史兼容。
- 运行组装：按控制库和 room owner 的不同 URL 注册专用池，每 event loop 1 条连接；逻辑别名复用池，用户独有分片不增加处理池。控制确认与 owner 中止可在同库共用处理池，两笔事务顺序完成。所有句柄验证会话策略，连接数计入进程总预算；Gateway 增加固定 direct_authorization_resolution 指标。社交/陌生人权限/账号停用写者注入协调器；Gateway 每轮恢复最多 8 条，退出时取消并加入既有有界任务排空。
- 首轮编译发现 Operator 的预算调用遗漏 connectionsPerEventLoopPerPhysicalStore，修正后重跑。第二轮两个应用编译通过，但新增 Gateway 配置夹具没有登记相应 direct/group shard ID，4 个参数场景报错；补全测试拓扑后重跑。两轮失败均不算通过。
- 最终配置测试覆盖隔离/共享模式、同库/独立 owner、多逻辑分片共用 URL、预算恰好足够/少一条；Operator 另覆盖用户独有数据库不多计授权处理池。新增 2 个真实 PostgreSQL 场景在同库/双库分别占满预留、权限写者、owner 前台三个单连接池，并持有实际排他权限锁，独立协调器仍完成 owner 中止和控制确认；新代次读到拉黑，随后有界恢复确认终态。
- 最终 42 项测试、3 个 suite 通过，执行 6.350 秒，增量编译 18.55 秒；包含原授权意图的断后端、撤权回滚、不可达/租约、并发/改参和 schema 漂移专项。只执行配置与授权意图相关测试，没有跑全仓套件。
- 日志：`/tmp/imv2-authorization-runtime-config-20260920.log`（编译失败）、`/tmp/imv2-authorization-runtime-config-final-20260920.log`（夹具配置失败，编译通过）、`/tmp/imv2-authorization-runtime-pools-20260920.log`（最终通过）。源码/日志指纹：`/tmp/imv2-direct-authorization-runtime-pools-sources-20260920.json`。
- 边界：数据库测试显式组装角色池，预留连接是被测试事务占用，未模拟真实预留等待权限锁；应用入口通过编译，不等于完整 Gateway 启停或强杀验收。正式普通/批量/转发仍需自动登记/绑定/确认并替换原 withControlPolicies 路径，原 P1 已知失败标记保留，D07 不关闭。未修改客户端、提交或部署；本机证据不替代远端 CI 与生产容量。


### 20260920-direct-automatic-authorization

- 范围：D07 普通/原子批量发送的自动持久授权；Gateway 使用既有独立确认池。schema 49、协议 30 不变，客户端未改动。
- 实现：只读发现 owner/epoch/接收者，按原命令身份和 v3 摘要登记并提交后绑定授权；接受/拒绝证明仍与消息同事务。完整发送返回（含缓存与命令额度记账）后读取不可变证明并确认控制记录；没有证明不结算，错误保留 held 并映射可重试 UNAVAILABLE，取消继续传播。普通改参返回原幂等冲突，批量重复/冲突保留既有标量回退。
- 故障探针：两个场景分别冷/预热，在 owner 房间锁阻塞时要求 held 授权已提交，终止确切的单连接预留池后端；真实拉黑通过协调器等待 owner 操作锁，阻塞期间 block=0。释放锁后原消息先提交，再由撤权读取证明并确认后提交拉黑；新请求拒绝。子探针的关键观测改为 require，不能因子进程直接退出而忽略断言失败。父测试去掉普通发送的 withKnownIssue；历史复现未覆盖或删除。
- 第一轮编译 240.62 秒、执行 30.148 秒；10 项测试（子探针默认跳过，由父显式启动）、37 个业务参数场景。普通断连 2、路由单连接 2、转发旧路径回归 1、显式 owner 事务 14、批量 4、发送控制权限 12 场景通过；新增 ACK 失败 2 场景因测试假设错误失败：冷路径直接使用数据库额度，本地 committedCredits 不递增；幂等重试可预取并归还未用令牌，整个本地 snapshot 不应要求相等。失败保留，不计通过。
- 修正专项为数据库已预扣减去本地空闲/在途后的实际消费守恒、已提交令牌不重复消费、消息唯一及改参冲突；预热分支另核对快速追加计数增加。注入控制终态 CHECK 拒绝，原消息仍提交、授权 held；解除故障后同参数重试幂等补确认。随后补齐确认故障的 retryable 映射和子探针强断言，仅重跑受影响的 20 个场景。
- 最终日志 5 项测试、1 个 suite（含默认跳过、由父显式启动的子探针），20 个业务参数场景全部通过；执行 16.291 秒，编译 215.97 秒。两份冷/预热报告均为 blocksWhileOwnerHeld=0、ownerAtRevocation=1、ownerCommitted=1、controlBlocks=1、callbackSettled=1。这表示消息在撤权完成前结算，不是允许撤权完成后的迟到写入。
- 日志：`/tmp/imv2-direct-automatic-authorization-20260920.log`（首次 ACK 测试假设失败）、`/tmp/imv2-direct-automatic-authorization-final-20260920.log`（最终通过）。源码/日志/探针指纹：`/tmp/imv2-direct-automatic-authorization-sources-20260920.json`。没有跑全仓测试；先前不受后续错误映射影响的 17 个场景未重复运行。
- 限制：转发仍调用 withControlPolicies，必须处理媒体就绪后的命令指纹、自动登记/确认与终态预查；完整进程启停/强杀、登记提交前故障、特殊账号写者清点及迁移承接继续开放。D07 保持 P1/实施中，关闭数不变；普通发送专项修复不代替整个问题关闭。未提交或部署，本机证据不是远端 CI。


### 20260920-forward-automatic-authorization

- 范围：D07 的正式转发自动授权，关联 B04/B11/B27。schema 49、协议 30 不变，未改客户端或增加历史兼容。
- 实现：幂等接收 inbox 后，短 owner 预检事务锁定收件箱和媒体映射。媒体未就绪直接 pending，不登记授权；就绪命令以稳定目标媒体 ID 形成指纹，预检提交后才执行控制登记。实际接受事务重新校验完整命令和 owner，保留消息/证明原子提交及既有接受/拒绝逻辑。预检不以当前文本上限阻止已有 accepted 的恢复，真正接受仍按当前上限拒绝新长文本。
- 终态：接线共用普通发送的提交后确认；完成标记成功、控制 ACK 失败时，重放按原操作读取控制授权，以不可变 owner 证明补确认，不重建命令或新代次，不读取已清理正文。没有消息证明的拒绝保持 held，后台通过 owner 中止证明再结算。控制身份冲突映射为转发幂等冲突。RoomWriteStore 中 withControlPolicies 和旧发现 DTO 已移除。
- 新增 directForwardAutomaticAuthorization：7 个场景 × 无附件/真实附件，共 14 个真实双库场景。包含媒体 pending 时零授权/零证明、实际文件复制与扫描、等待期间拉黑后拒绝、INVALID_ARGUMENT 及后台中止后终态重放、准入 pending 后同代次接受、消息已提交但 completion 标记失败后缩小文本上限仍恢复、接受/拒绝 ACK 失败及 inbox 正文压缩后补确认。核对消息/媒体引用唯一、授权/证明各一条、代次不增加、无遗留 held。
- 同轮相关 25 个回归通过：直接转发控制权限 1、显式 owner 授权转发 2、普通发送 ACK/额度 2、收件箱提交回滚及并发/收尾恢复 2、迁移写入边界 2、两类群目标资格/权限/epoch/准入/媒体 16。后面三个旧套件已绑定生产控制授权入口，群路径仍不登记单聊授权。
- 首轮 7 项测试、39 个场景，编译 237.61 秒、执行 31.397 秒；4 个新增附件成功场景在最后引用计数处查询了不存在的 im_v2.message_media，PostgreSQL 明确报 relation does not exist，整轮失败。修正为实际 message_media_references；服务端源码未再修改，仅重跑新增 14 个场景，最终全部通过，执行 14.126 秒、编译 211.79 秒。没有把初轮失败算成整轮通过，也未重复已通过且不受测试查询修正影响的 25 个回归。
- 日志：`/tmp/imv2-forward-automatic-authorization-20260920.log`（首次测试表名错误）、`/tmp/imv2-forward-automatic-authorization-final-20260920.log`（最终通过）；源码/日志指纹：`/tmp/imv2-forward-automatic-authorization-sources-20260920.json`。文档链接、结构与 diff 检查另行执行。
- 限制：没有进行实际转发进程强杀/断连及并发撤权故障矩阵，也未完成特殊账号权限写者清点、媒体状态变化并发窗口或完整迁移承接。D07 仍为 P1/实施中，问题关闭数量不变。仅运行受影响服务端专项，未运行全仓测试、提交或部署。本机证据不代替远端 CI 和生产容量。


### 20260920-forward-control-connection-loss

- 范围：D07 当前应用控制权限写者清点，以及真实转发授权登记后的控制连接中断/并发撤权。生产代码、schema 49 和协议 30 均未修改。
- 写者清点：按 V2DirectSendControlPolicyFence 读取的 public_user_profiles、account_disables、user_relationships、user_blocks、user_stranger_message_preferences、special_accounts，核对 Sources 内写入语句、方法及 Gateway/Operator 组装。关系/拉黑、陌生人权限、账号停用都在相应排他锁内先排空；分片偏好路由明确使用 controlStore。资料编辑只改展示字段；账号注册使用新 UUID；special_accounts 未发现应用写入接口，SpecialAccountMessagingService 写的是消息操作/审计。详细入口见[合同清点表](room-owner-migration-contract.md#当前控制权限写者清点2026-09-20)。这不是数据库不可变声明，不覆盖特权 SQL 或外部配置系统在线变更。
- 探针：把 directControlConnectionLoss 扩为普通/转发 × 冷/预热。转发先接收 inbox，再持有 owner 房间锁；实际导入必须先提交 held 授权再等待 owner。终止测试专用单连接预留池 backend，真实拉黑必须等待 owner 操作锁，且阻塞期间 user_blocks=0。释放锁后接受完成、撤权确认后提交拉黑；新发送拒绝。转发另验证终态重放不依赖当前更小文本限制，消息仍一条、控制 generation=1 且 accepted。
- 本轮只运行 directControlConnectionLoss；2 项测试、1 个 suite（子探针默认跳过，由父测试显式启动）、4 个业务场景全部通过。执行 3.835 秒，编译 211.50 秒。四份报告均为 blocksWhileOwnerHeld=0、ownerAtRevocation=1、ownerCommitted=1、controlBlocks=1、callbackSettled=1；关键子探针断言使用 require，未保留 known issue。
- 日志：`/tmp/imv2-forward-control-connection-loss-20260920.log`；源码、四份报告和子日志指纹：`/tmp/imv2-forward-control-connection-loss-sources-20260920.json`。未重跑已通过的媒体/ACK/配置专项或全仓套件。
- 边界：本次终止的是 PostgreSQL 后端连接，测试子进程正常写报告后退出，不是服务进程 SIGKILL。尚未覆盖登记提交前、owner 提交后确认前的完整进程中断、转发撤权先完成的相反顺序、媒体状态变化及迁移承接。D07 继续实施中，关闭数量不变；未改客户端、提交或部署，本机证据不替代远端 CI/生产环境。


### 20260920-direct-authorization-process-crash

- 范围：D07 持久授权的真实进程中断；只增加服务端测试和更新治理证据，生产代码、schema 49、协议 30 不变。
- 检查点：普通发送、双房间批量、无附件转发 × 登记事务提交前、登记提交后尚未接受、owner 提交后确认前、确认完成后，共 12 个参数场景。前三种在数据库锁等待可观测后由父进程 SIGKILL；最后一种要求子进程完成发送并写 ready 标记后 SIGKILL。父测试要求确实因 SIGKILL 退出，不能把正常退出当成崩溃。
- 恢复：每次重新启动独立进程，按过期恢复时钟调用实际协调器，然后使用同一 room/client 身份重放；转发使用原导出载荷与摘要。登记前无遗留；登记后恢复中止旧代次并用第二代接受；owner 提交后恢复原证明并保留第一代；确认后不领取恢复任务。核对消息唯一、所有控制授权 accepted、证明数量与代次、claimed/resolved 数量及 deferred=0。批量按正式接受入口及既有标量回退语义执行，owner 提交后断言两条消息已提交。
- 结果：2 项测试、1 个 suite（子探针默认跳过，由父显式启动）；12 个业务参数全部通过。编译 217.41 秒，执行 11.578 秒。仅运行 directAuthorizationProcessCrash 专项，未运行全仓套件。
- 日志：`/tmp/imv2-direct-authorization-process-crash-20260920.log`；源码/文档/输入身份/子进程日志/恢复报告指纹：`/tmp/imv2-direct-authorization-process-crash-sources-20260920.json`。各独立证据目录见日志中的 Authorization SIGKILL evidence，保留 ready 与 report 文件供核对。
- 限制：本机真实双库、Application 与存储组件的子进程强杀，不是完整 Gateway 网络服务部署或 Linux 崩溃验收；未覆盖附件状态并发变化、相反撤权顺序及完整迁移承接。D07 仍为 P1/实施中，20/47 已关闭计数不变。未改客户端、引入历史兼容、提交或部署。


### 20260920-forward-revocation-first

- 范围：D07 撤权先完成的转发顺序，仅扩展服务端测试及文档，生产代码、schema 49、协议 30 不变。
- 新增无附件/真实附件两个场景：正式导入因准入已满返回 pending，留下 held 授权且无 owner 证明。真实拉黑写者通过协调器保存 aborted 证明并确认后提交拉黑。释放准入后，旧授权迟到导入抛出 attemptAborted，消息与媒体引用为零；正式入口按原操作重试，第二代读取拉黑事实并持久拒绝，终态重放保持相同结果。最终控制操作一条、第二代 denied、owner 证明两条。
- 仅运行 directForwardAutomaticAuthorization：1 项测试、1 个 suite、16 个参数全部通过，包含新增 2 场景和原有 14 个回归。编译 211.78 秒，执行 12.832 秒。未跑全仓测试。
- 日志：`/tmp/imv2-forward-revocation-first-20260920.log`；源码与日志指纹：`/tmp/imv2-forward-revocation-first-sources-20260920.json`。
- 边界：确定排序的准入等待、拉黑完成、旧任务迟到和新代次重试，不代表任意在途竞争、媒体状态变化、完整 Gateway 生命周期或迁移验收。D07 保持实施中，关闭数不变；未改客户端、历史兼容或部署。


### 20260920-forward-media-window

- 范围：D07 转发预检提交后、实际接受前的媒体状态窗口；仅修改服务端测试和治理文档，生产代码、schema 49、协议 30 不变。
- 新增 2 场景都使用实际上传、复制并扫描就绪的附件。父任务持有 control 的 account-state 排他锁，启动正式导入，观察 pg_stat_activity 中共享权限锁等待，并确认尚无控制授权。这意味着 owner 预检已提交、控制登记尚未完成。
- 分别在 owner 库注入 state=expired，或保持 available 但 expires_at 等于请求时间。释放控制锁后，实际接受重新校验媒体并抛出 mediaUnavailable。断言消息、媒体引用和 owner 接受证明为零，控制授权仍 held；到期恢复 claimed=1/resolved=1/deferred=0，控制与 owner 均保存 aborted 终态。
- 仅运行 directForwardAutomaticAuthorization：1 项测试、1 个 suite、18 个参数全部通过（新增 2，原有回归 16）；编译 213.25 秒，执行 14.425 秒。未跑全仓测试。
- 日志：`/tmp/imv2-forward-media-window-20260920.log`；源码/文档/日志指纹：`/tmp/imv2-forward-media-window-sources-20260920.json`。
- 边界：媒体变化由数据库故障注入精确放入窗口，没有声称覆盖实际过期工作器、物理文件删除或映射身份修改的全部并发时序。完整 Gateway 生命周期、其他在途竞争及 owner 迁移仍开放；D07 关闭计数不变。


### 20260920-authorization-gateway-lifecycle

- 范围：D07 实际 IMV2ServerApp 的后台授权恢复与进程生命周期。新增 [可重复探针](../../scripts/test_v2_authorization_gateway_lifecycle.py)，只允许显式确认的本机临时 PostgreSQL 集群，创建独立随机数据库并在结束时清理。生产 Swift、schema 49、协议 30 不变。
- 探针使用当前 canonical schema、临时 TLS 证书和实际 Gateway 可执行文件，控制与 owner 共用物理数据库，运行时按正式配置创建独立角色池。预置三个合法 held 操作，分别验证启动后自动恢复、owner 房间锁等待期间 SIGKILL 后重启按租约恢复、等待期间 SIGTERM 正常停机后再启动恢复。
- SIGKILL 要求退出码对应信号 9。所有 SIGTERM 要求退出码 0 和服务任务 drained=true；在途等待场景在约 2 秒数据库锁超时后延后授权并完成退出，下次启动在 next_check_at 到期后恢复。最终三个 owner aborted 证明、消息零；未手动调用协调器替代实际后台任务。
- 真实入口增量构建通过（2.93 秒）；最终仓库脚本全部通过，证据目录 `/tmp/imv2-auth-gateway-abb8e085-ab13-4711-9839-18f49312d37e`，含四次进程日志、schema 日志与 report.json。总日志 `/tmp/imv2-auth-gateway-lifecycle-repository-20260920.log`，源码/日志指纹 `/tmp/imv2-auth-gateway-lifecycle-sources-20260920.json`。没有运行全仓测试。
- 首次临时夹具错误地把数据库线程数改为 1 却保留 4 线程的并发预算，启动检查拒绝；恢复正确配置后，强杀夹具仅终止 psql，数据库 sleep 事务仍持锁，重启恢复按预期延后但探针超时。修正为仅终止本次独立数据库内的持锁后端后通过；两次失败日志保留，不计通过。最终仓库脚本又加入在途 SIGTERM 场景并整体通过。
- 限制：这是 macOS、本机单物理库、预置 held 授权的真实 Gateway 后台生命周期；没有通过 TLS 发消息，不能替代前台普通/批量/转发的全进程故障矩阵、跨物理库部署、Linux、安全认证、生产容量或迁移接管验收。D07 保持实施中，关闭数不变。


### 20260927-bounded-room-log-pagination

- 日期：2026-09-27；对象：本次工作区的有界房间日志分页、候选部分索引与游标修改。
- 环境：本机 Apple Silicon、Swift 6.4、PostgreSQL 16.13；独立临时 PostgreSQL 实例及每轮新建的三个 disposable 数据库。
- 合同：[历史读取与扫描游标](message-mutation-read-contract.md)。
- 服务端定向回归：15 个测试函数通过（包含参数化场景），覆盖混合来源、空授权窗口、成员重入、撤回后的 accepted 记录、尾部空洞、不完整 lookahead、缺失接受事实、编辑/撤回/reaction 历史权限、Actor 读取与围栏、索引漂移及分页响应边界。
- 客户端：6 个 catch-up/已应用序号测试，以及空/非空两种扫描游标持久化、重开和坏载荷回滚场景通过；未修改客户端生产实现。
- schema：canonical 空库建库、索引缺失/错误谓词拒绝、结构漂移、pg_dump/restore、readiness 表覆盖均通过；文档链接和结构检查通过。
- 查询计划来自捕获后重新执行的实际生产 SQL 与参数，`EXPLAIN (ANALYZE, BUFFERS)`；每个序号有一条 message 行，仅每 100 条中的一条使用 `message_row`，其余事件走 `room_events`，用来验证部分索引确实跳过其他存储模式。

| 历史记录数 | 起始游标 | room_events 实际候选行 | messages 实际候选行 | shared hit | SQL 执行时间（ms） |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 0 | 101 | 10（已耗尽） | 25 | 0.335 |
| 1,000 | 500 | 101 | 5（已耗尽） | 20 | 0.304 |
| 50,000 | 0 | 101 | 101 | 118 | 0.431 |
| 50,000 | 25,000 | 101 | 101 | 119 | 0.434 |

页大小均为 100。候选来源使用有序索引；未出现 messages/room_events 全表扫描。
另以真实 `V2RoomTurnLane` 排入同房间读取和发送，读取走 `V2ActorRoomQueryExecutor`，发送走带同一激活围栏的写入存储。
1,000/50,000 条历史下，发送从读取轮次开始到取得轮次分别等待 10.047/9.395ms，读取加发送完成分别为 23.206/18.403ms；两次发送均成功提交。
这些是单次本机 Debug、热缓存和同期存在编译工作的结果，不代表生产 p95/p99、冷磁盘、多用户负载或整体容量。

复现（指向允许创建测试数据库的独立 PostgreSQL 实例）：

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test \
  bash scripts/test_v2_server_native_postgres.sh \
  --filter 'boundedRoomLog|currentSchemaRequiresRoomLogCandidateIndex|roomMutationHistoricalRead|V2GroupEventPageBoundsTests|V2ActorRoomQueryExecutorIntegrationTests'
bash scripts/run_v2_clientkit_native_tests.sh \
  --filter 'V2RoomLogCatchUpTests|V2RoomAppliedSequenceTests|scannedRoomCursorPersistence'
IMV2_SCHEMA_BOOTSTRAP_NATIVE=1 PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test \
  bash scripts/test_v2_postgres_schema_bootstrap.sh
```

本机原始日志位于 `/tmp/imv2-pagination-pg.5qoJw8/` 的 `tests-final.log`、`client.log`、`client-cursor.log`、`schema-r2.log`。
前几轮测试曾因夹具更新 append-only 事件、未同步时间线计数和过宽查询计划断言而失败；最终验证已修正这些夹具/断言。
索引 readiness 测试使用 canonical `im_v2` 夹具，避免无关资源合同对随机 schema 的既有硬编码限制；没有扩大修复范围去修改该资源合同。

### 20261008-current-client-server-functional-acceptance（执行中）

- 目标：当前客户端、服务端真实联调，并逐项核对 32 类持久业务操作及认证、同步、恢复、媒体、平台入口。尚未完成全量验收，不能据此宣称全部功能正常。
- 基线：`19165637`；测试启动夹具修复已提交为 `0ed2336b`。后续新增真实功能测试单独记录工作区状态；没有修改生产逻辑来让测试通过。
- 环境：macOS / Apple Silicon；PostgreSQL 16 本机独立临时实例；实际 Account / Gateway / Actor 进程；作用域内信任的本地 HTTPS、TLS TCP；iPhone 17 / iOS 27 模拟器。仅清理本次创建的资源。

| 验证层 | 当前结果 | 可证明范围 | 原始证据 |
| --- | --- | --- | --- |
| IMV2Core | 171 项、54 套件通过 | 核心类型与领域单元合同；不代表网络联调 | `/tmp/imv2-acceptance-core-20261008.log` |
| IMV2ClientKit 独立串行 | 1024 项、172 套件，14 条失败断言 | 客户端本地 SQLite、网络边界和恢复合同；真实联调用例默认关闭 | `/tmp/imv2-acceptance-client-isolated-20261008.log` |
| App 单元与 UI | xcresult 汇总 347 通过、1 失败、11 跳过；参数展开后设备汇总 429 通过；11 项 UI 用例通过 | App 状态、生命周期、UI 可达性；跳过的真实联调不计通过 | `/tmp/imv2-acceptance-app-full-20261008.xcresult` |
| 真实账号 SDK | 5 项、2 套件通过 | 真实注册/登录前置、刷新、远端设备撤销、当前退出、TLS 不可信保留会话、撤销重试 | `/tmp/imv2-acceptance-live-account-20261008/client.log` |
| 最小原生全栈 | 通过 | 独立 PG、HTTPS 注册/发凭据、真实 TLS Gateway 认证 | `/tmp/imv2-acceptance-native-smoke-fixed2-20261008.log` |
| 服务端七库真实 PG 全量尝试 | 退出 1，主测试包 signal 5 中止；其他测试目标也报告失败 | 不能声称全量完成；集成夹具也不替代真实 App 操作 | `/tmp/imv2-acceptance-server-full-20261008.log` |
| 真实账号 App / Gateway 联调 | R6两项撤销App及1项headless入口通过 | R5私聊持久提示和房间在线恢复失败仍保留 | `/tmp/imv2-acceptance-live-account-ui-r6-20261008/` |
| 真实资源、作者、授权联调 | R10完整启用套件仅群头像422失败 | 已安装typing开始/停止、消息/群/关系/设置/资源和搜索通过；冷订阅丢失仍列出 | `/tmp/imv2-acceptance-live-resources-extended-r10-20261008/` |

已确认的失败与解释边界：

1. 客户端路由测试仍强制要求已移除的 HTTP 消息发送端点；正常发送已使用 TCP，注册表中仍保留旧端点策略。属于测试/注册表与当前入口不一致，不能解释为 TCP 发送失败。
2. 本地 schema 指纹断言不匹配；需核对 schema 的实际变化，不能直接更换哈希掩盖差异。
3. 消息永久关闭替换测试抛 `invalidTransition`，仍需定位到具体状态转换。
4. 完成历史清理三项用例共 9 条失败断言，资源日志用例另有 2 条。实现明确要求 `accepted_projection_observed=1` 才能清理已接受消息；这些夹具只写接受/完成结果，尚未构造投影收敛证明。保持失败记录，不能直接认定为生产 GC 缺陷或放宽清理边界。
5. App `periodicRecoveryStillPulls` 超时 60 秒。实现当前明确将周期刷新用于活动到期，消息补偿由房间 head 和账号 runner 驱动；旧测试仍等待周期历史拉取。需要验证当前补偿链路，不能将旧用例改绿后替代丢通知验收。
6. 服务端发送回执、额度统计、写准入计数及媒体扫描时间边界已出现失败。部分断言仍针对拒绝持久化、逐条额度/通用写准入等历史路径；完整运行结束后逐项区分夹具残留和真实业务问题。

完整功能矩阵暂存于 `/tmp/imv2-functional-acceptance-20261008/manifest.json`，保留全部待验项。测试结果只用于其实际覆盖范围；跨安装多设备、离线发送、丢通知补偿及平台 Push 等尚不能据本记录关闭。

本次新增真实 SDK 验收覆盖（已编译，网络结果待回收）：

- 四类账号设置：读取初值、提交相反值、同命令重放、原身份恢复、重新读取持久化值和版本。
- 好友请求/接受/删除、拉黑/解除：读取双方关系，联系人备注设置/清空及原身份恢复，再校验删除和屏蔽状态。
- 消息：TCP 发送幂等/恢复、HTTP 编辑和表情增加/移除、TCP 会话置顶和消息收藏、群置顶、跨房间转发、历史内容、撤回后历史事件。
- 群：实际创建 API 的 begin/append/finalize/recover，公告、成员权限、管理员角色、成员加入/移除与 roster 回读。此处创建不使用 SQL 种房间替代 API。
- 管理：实际成员消息的管理删除、禁言/移除、原结果恢复及策略改变后的 TCP 发送拒绝。
- 群头像：真实上传、处理、设置、成员可见字节下载、移除及原身份恢复。
- 上述扩展由 `scripts/verify_v2_live_resource_authors.py --extended-acceptance` 显式启用。驱动器为每次 fixture 请求创建独立房间，标准 shard pool 在独立数据库内初始化；消息/资源等行为仍使用公开 API。未启用真实 fixture 的编译检查会跳过用例，绝不计为功能通过。
- 原生账号驱动新增 `--two-install-ui`，复用既有两安装 App 场景，明确指定两个独立模拟器；固定端口若被占用直接拒绝。仅在账号 App 联调释放端口后运行。

<!-- acceptance-matrix-start -->

| 编号 | 功能 | 当前验收结果 | 证据索引 |
|---|---|---|---|
| OP-01 | sendMessage | 真实TCP提交/幂等/恢复通过；真实App发送及双方消息恢复通过 | extendedLiveResourcesR4, twoInstallUIR13, extendedCurrentR1 |
| OP-02 | withdrawMessage | 真实HTTPS撤回/历史事件及App发送端提交、接收端撤回恢复通过；PG已撤回修订3 | extendedLiveResourcesR4, twoInstallUIR8, twoInstallUIR9, twoInstallUIR13, extendedCurrentR1 |
| OP-03 | editMessage | 真实HTTPS编辑/恢复及独立两安装普通UI编辑中间态冷恢复通过；PG唯一原消息修订2、未撤回，原消息ID与精确正文一致 | extendedLiveResourcesR4, twoInstallUIR8, twoInstallUIR9, twoInstallUIR13, directEditUIR5, extendedCurrentR1 |
| OP-04 | reaction | 真实HTTPS表情增删/恢复/回读及App普通表情提交通过；PG message.reaction_changed | extendedLiveResourcesR4, twoInstallUIR8, twoInstallUIR9, twoInstallUIR13, extendedCurrentR1 |
| OP-05 | readReceipt | 真实TCP已读提交、读者列表及隐私开关过滤通过；真实App私聊阅读→发送端冷启动同消息对方已读通过；App群主原消息读者页真实成员+已读通过 | extendedLiveResourcesR7, peerReadUIR1, groupReadUIR2, extendedCurrentR1 |
| OP-06 | directRoom | 真实HTTPS打开私聊通过；双向重复打开同房间已核对 | extendedLiveResourcesR9, extendedCurrentR1 |
| OP-07 | groupRoom | 真实SDK群创建/恢复及App普通UI建群、成员核对、群消息双向收发和@all投影通过 | extendedLiveResourcesR4, twoInstallUIR14, extendedCurrentR1 |
| OP-08 | membership | 修复后通过：核心/PG权限/Store/真实HTTPS及TCP、普通App退出和冷恢复；独立PG与原本地工作一致 | extendedLiveResourcesR4, membershipExitSourceInspection, fixSelfExitCoreR1, fixSelfExitPGR1, fixSelfExitAppUnitR2, fixSelfExitLiveR1, fixSelfExitAppLiveR4, extendedCurrentR1 |
| OP-09 | moderation | 真实管理删除和原结果恢复通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-10 | memberMute | 真实禁言/恢复及后续TCP拒绝通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-11 | moderatedMemberRemoval | 真实成员移除/恢复/roster及后续TCP拒绝通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-12 | strangerMessagePreference | 真实HTTPS提交/重放/恢复/版本回读通过；App设置提交及同账号第二设备恢复通过 | extendedLiveResourcesR2, multiDeviceUIR4, extendedCurrentR1 |
| OP-13 | userAddPreference | 真实HTTPS提交/重放/恢复/版本回读通过；App普通开关提交、另一安装冷恢复及独立PG关闭策略一致通过 | extendedLiveResourcesR2, multiDeviceUIR5, extendedCurrentR1 |
| OP-14 | readReceiptPreference | 真实HTTPS提交/重放/恢复/版本回读通过；App设置提交及同账号第二设备恢复通过 | extendedLiveResourcesR2, multiDeviceUIR4, extendedCurrentR1 |
| OP-15 | liveActivityPreference | 真实HTTPS提交/重放/恢复/版本回读通过；App普通开关提交、另一安装冷恢复及独立PG关闭策略一致通过 | extendedLiveResourcesR2, multiDeviceUIR5, extendedCurrentR1 |
| OP-16 | relationship | 真实好友申请/接受/删除及回读通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-17 | userBlock | 真实拉黑/解除/恢复及关系回读通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-18 | conversationPreference | 已验证：真实TCP及同账号两安装置顶/归档/静音双向冷恢复通过 | extendedLiveResourcesR7, conversationPreferenceUIR2, extendedCurrentR1 |
| OP-19 | messageFavorite | 真实TCP收藏/重放通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-20 | pinnedMessage | 真实群置顶/恢复通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-21 | groupAnnouncement | 真实公告提交/恢复通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-22 | groupPermission | 真实成员权限调整/恢复通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-23 | groupRole | 真实管理员角色调整/恢复/roster通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-24 | forwardMessage | 真实转发计划/恢复/目标历史内容通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-25 | profileUpdate | 真实个人资料更新、头像绑定及授权展示通过 | extendedLiveResourcesR7, extendedCurrentR1 |
| OP-26 | contactAlias | 真实备注设置/清空/恢复/回读通过 | extendedLiveResourcesR4, extendedCurrentR1 |
| OP-27 | groupNickname | 真实群昵称设置/清空/恢复、事件版本及目录租约通过 | extendedLiveResourcesR7, extendedCurrentR1 |
| OP-28 | groupInvite | 真实邀请创建/撤销及列表回读通过；App普通UI二维码创建/读取、撤销及另一安装原链接失效通过 | extendedLiveResourcesR9, groupJoinUIR2, groupJoinRejectUIR1, extendedCurrentR1 |
| OP-29 | groupJoinRequest | 真实入群申请/取消及审核可见性通过；App普通粘贴预览、申请、取消、同邀请再次申请和PG记录一致通过 | extendedLiveResourcesR9, groupJoinUIR4, extendedCurrentR1 |
| OP-30 | groupJoinDecision | 真实SDK及App批准/拒绝、原申请状态冷恢复通过；批准后发送即时正文投影修复后R10/R11完整通过，历史失败保留 | extendedLiveResourcesR15, groupJoinUIR4, groupJoinRejectUIR1, extendedCurrentR1, approvedMemberLiveProjectionR10, approvedMemberLiveProjectionR11 |
| OP-31 | mediaUpload | 真实个人头像/消息附件上传处理、下载和撤回授权收敛通过；后台与群头像另列 | extendedLiveResourcesR7, extendedCurrentR1 |
| OP-32 | groupAvatar | 修复后通过：入口允许并声明群头像，17项PG权限/恢复回归通过，真实HTTPS上传处理/绑定/字节下载/移除/原操作恢复通过，保留422历史失败 | extendedLiveResourcesR4, fixGroupAvatarPGR1, fixGroupAvatarLiveR1, extendedCurrentR1 |
| EX-01 | 注册与登录 | 真实SDK及App密码注册/密码登录通过；同账号两安装设备列表>=2已核对 | liveAccountSDK, nativeSmoke, multiDeviceUIR1, accountSwitchCurrentR1 |
| EX-02 | 凭据刷新 | 真实SDK及App业务401刷新、原15分钟令牌自然到期自动刷新、冷启动使用新凭据通过 | liveAccountSDK, nativeSmoke, appCredentialRefreshUIR1, appNaturalExpiryUIR2 |
| EX-03 | 当前设备登出 | 当前代码真实App两次首次退出无需重试、A→B→A及冷恢复隔离通过；注册与AX、两范围清理完整R1 exit0，22项回归通过，历史失败保留 | liveAccountSDK, accountSwitchUIR1, accountSwitchUIR4, fixSignOutUnitR2, fixSignOutAppR1, accountSwitchCurrentR1 |
| EX-04 | 远程设备撤销 | 真实SDK及App远端撤销、回到登录和重启保留终止态通过 | liveAccountUIR4, fixRestrictionLiveR2 |
| EX-05 | 账号封禁 | 通过：真实Operator封禁/幂等、原已认证TCP在8秒观察边界内由服务端终止、HTTP凭据清除、登录及TLS重新认证拒绝 | extendedLiveResourcesR16, extendedCurrentR1 |
| EX-06 | 账号切换与冷启动 | 当前代码A→B→A正常登录/首次退出/消息与投影隔离/正常冷恢复完整R1 exit0，4项通过0失败0跳过，历史需重试失败保留 | accountSwitchUIR4, fixSignOutAppR1, accountSwitchCurrentR1 |
| EX-07 | 陌生消息拒绝/允许 | 通过：无好友关系私聊预热发送成功；同一TLS连接策略关闭后新发送directPolicyDenied、重新允许后成功 | extendedLiveResourcesR16, extendedCurrentR1 |
| EX-08 | 拉黑后即时授权失效 | 修复后通过：PG按原消息身份提示去重/单侧隐私，真实App提示冷恢复及3次后台恢复、跨Gateway多设备投递、解除拉黑后发送全部通过；保留历史失败 | liveAccountUIR5, fixRestrictionPGR2, fixRestrictionLiveR1, fixRestrictionLiveR2 |
| EX-09 | 私聊唯一性 | 通过：双方并发首次创建及后续重新打开均得到同一私聊房间；真实HTTPS回执核对 | extendedLiveResourcesR16, extendedCurrentR1 |
| EX-10 | 实时收发与历史恢复 | 真实App私聊提交/撤回恢复及群消息双向收发/@all投影通过；离线自动重放失败单列；批准入群后原已提交消息正常App冷启动恢复唯一正文通过 | twoInstallUIR13, twoInstallUIR14, groupJoinColdSendUIR1, approvedMemberLiveProjectionR10, approvedMemberLiveProjectionR11 |
| EX-11 | 发送结果不确定后恢复 | 通过：真实App丢ACK前独立PG确认原提交，跨Gateway自动重连、原身份恢复、双端游标与SQLite重开一致 | appACKCutR5 |
| EX-12 | 离线发送持久化与重放 | 普通App离线入队/正常冷恢复及原身份验证通过；修复后R8完整UI与AX/contrast通过，PG唯一原消息/成功记录及双端唯一投影，历史失败保留 | twoInstallUIR14, multiDeviceUIR3, multiDeviceUIR4, fixOfflineAppR1, fixOfflineOriginalAppR4, fixOfflineOriginalAppR8 |
| EX-13 | 多设备编辑撤回同步 | 通过：真实同账号两安装编辑和撤回双端投影、前后台保持及Operator快照重置后重建验证，PG提交一致 | multiDeviceUIR4 |
| EX-14 | 多设备已读 | 已验证：同账号两设备progress/单条群用户已读与跨设备隐私暂停；独立接收阅读后私聊发送端冷恢复对方已读；群主读者页显示真实独立阅读成员与已读，PG一致 | multiDeviceUIR2, multiDeviceUIR4, peerReadUIR1, groupReadUIR2 |
| EX-15 | 目录分页与权限过滤 | 真实群昵称及258条/9页两独立设备SDK读取、拉黑过滤通过；两独立安装App登录和正常冷恢复完整258成员ID/名字、3页及PG两设备记录通过，历史UI遍历超时保留 | extendedLiveResourcesR7, largeNicknameDirectoryR2, largeNicknameDirectoryR3, appLargeDirectoryUIR3, appLargeDirectoryUIR4, appLargeDirectoryUIR6, appLargeDirectoryUIR8 |
| EX-16 | 消息搜索 | 真实TLS历史进入SQLite搜索通过；编辑旧文本消失，撤回命中消失 | extendedLiveResourcesR7, extendedCurrentR1 |
| EX-17 | 资源下载与撤销 | 真实下载字节/校验及撤回后拒绝新计划通过；拉黑后展示收敛通过 | extendedLiveResourcesR7, extendedCurrentR1 |
| EX-18 | 在线状态与输入提示 | 修复后真实TLS冷订阅ACK后立即开始/停止通过；激活期间连接撤销拒绝ACK及票据清理通过；原失败保留 | extendedLiveResourcesR9, extendedLiveResourcesR10, fixTypingAcknowledgementLiveR1, fixTypingAcknowledgementRevocationR2, extendedCurrentR1 |
| EX-19 | 通知丢失补偿 | 1000房间真实跨Gateway冷恢复/断线重连/在线更新、丢尾通知2次且无相关替代唤醒的自动补偿R14完整exit0，owned PG/服务/专用模拟器清理通过，原R12/R13失败保留 | liveAccountUIR8, roomScaleR10, roomScaleR12, roomScaleR13, roomScaleR14 |
| EX-20 | 断线重连 | 1000房间真实跨Gateway冷恢复/断线重连/在线更新、丢尾通知2次且无相关替代唤醒的自动补偿R14完整exit0，owned PG/服务/专用模拟器清理通过，原R12/R13失败保留 | liveAccountUIR8, appACKCutR5, roomScaleR12, roomScaleR13, roomScaleR14 |
| EX-21 | 本地持久化清理 | 相关41项回归及真实TCP投影后清理通过；未将全量回归标为通过 | clientRetentionR2, extendedLiveResourcesR18, extendedCurrentR1 |
| EX-22 | 后台上传下载 | 当前本机专项通过：真实挂起上传下载、原身份/字节校验、下载途中SIGKILL后原系统任务接管、冷缓存重新授权复用，以及撤回/登出取消排空；不代表真机锁屏或跨版本升级。 | extendedLiveResourcesR12, backgroundDownloadSourceAudit, appNativeBackgroundUploadUIR5, appNativeBackgroundUploadUIR6, appNativeBackgroundUploadUIR7, appNativeBackgroundDownloadUIR1, appNativeBackgroundDownloadWithdrawalR2, appNativeBackgroundDownloadLogoutR1, appNativeBackgroundDownloadRestartR1 |
| EX-23 | Push端点与唤醒 | 按用户要求排除 APNs 相关验证；保留失败记录，不计为通过或当前完成门槛 | liveAccountUIR6, systemPushLiveR9, systemPushLiveR10, systemPushDelegateExposureR2, systemPushDispatchR11, systemPushDispatchR12, systemPushUIKitRoutingControlR3, systemPushNewIOS27R13 |
| EX-24 | UI主流程 | 完整双安装普通消息/离线原身份及全部原AX修复后R8通过；冷URL邀请通过；终止ACK修复后批准入群即时消息投影R10/R11连续通过，原失败记录保留 | twoInstallUIR13, twoInstallUIR14, groupJoinUIR2, groupJoinUIR4, groupJoinColdSendUIR1, directEditUIR3, directEditUIR5, fixColdInviteAppR3, fixOfflineOriginalAppR8, approvedMemberLiveProjectionR10, approvedMemberLiveProjectionR11, accountSwitchCurrentR1 |

<!-- acceptance-matrix-end -->

2026-10-08 后续真实联调回收：

- R4 资源扩展真实用例中，消息、群创建和管理、禁言与移除、四类设置、好友与备注独立用例通过。主资源用例因消费订阅初始水位而出现两条断言，已改为等待对应房间消息水位，R5 复验中；不删断言。
- 群头像上传创建实际返回 422。`V2ResourceService.create` 明确抛出 `unsupportedCapability`，capabilities 也未公告群头像用途。当前属于未打通的业务功能，保留失败，不以其他头像上传替代。
- 账号 App R4 两项撤销 UI 场景通过；私聊限制场景仍要求恢复被拒绝消息。生产仅查询成功完成记录，拒绝结果按既定设计不持久化；测试更新为验证拒绝 proof 和恢复 unresolved，尚待复验。
- 两个新建、独立 iPhone 17 模拟器的真实双安装 App 场景已启动，结果待回收。

2026-10-08 R7/R9 与真实双安装回收：

- R7 主资源、管理、消息、群、四类设置、关系用例通过；完整启用套件仍退出 1，仅群头像上传 422。新增真实 TLS 历史至 SQLite 的搜索准备/索引维护验证：编辑旧文本不再命中，撤回后编辑文本也不再命中。置顶、归档、静音及幂等重放通过。
- R9 加测邀请撤销和批准入群，通过真实申请人 TCP roster 校验成员；此轮主资源用例通过。新增双向打开唯一私聊得到相同房间、在线状态读取通过；开始输入提交确认后，接收端 8 秒内未收到 typing=true，保留失败。不能根据源码中停止事件期限问题推定本次超时发生在 typing=false，日志明确停在 true。
- 双安装 R2 的 Xcode 栈等待 `collectSimulatorDiagnostics`，保留采样并终止本轮拥有的 Xcode。驱动新增 `-collect-test-diagnostics never` 与每项 300 秒超时；R3 9 秒内回收真实失败：`Dynamic Type font sizes are partially unsupported`。没有跳过审计或将后续双安装步骤计为通过；清理两安装随机作用域后关闭本轮服务。
- R5 App 联调启动，包含私聊限制新拒绝恢复边界、50 房间跨 Gateway 丢尾通知补偿与 headless Push 入口；尚待终态。所有失败轮次仍保留。

本轮证据索引：

| 索引 | 原始证据 |
| --- | --- |
| extendedLiveResourcesR7 | `/tmp/imv2-acceptance-live-resources-extended-r7-20261008/client.log` |
| extendedLiveResourcesR9 | `/tmp/imv2-acceptance-live-resources-extended-r9-20261008/client.log` |
| twoInstallUIR3 | `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.41X8dh/` |
| liveAccountUIR5 | `/tmp/imv2-acceptance-live-account-ui-r5-20261008/` |

R3 无障碍失败附件进一步定位到空会话页的“暂无会话”标题和装饰图。源码使用 SwiftUI `ContentUnavailableView`（`V2ConversationUI.swift`），附件说明为该 AccessibilityNode 字号不可调整；尚未做默认/放大字号的真实视觉对比，因此不能判定为 App 自定义字体错误或直接排除审计。附件保留于 `/tmp/imv2-acceptance-two-install-r3-attachments-20261008/`。

R5 私聊联调已越过拒绝恢复断言，但随后失败：期望一条可持久恢复的发送者单侧限制提示，SQLite 实际为 0 条。与“不持久化拒绝操作回执”属于不同观察项；仍保留这个断言，不能把恢复 unresolved 通过视为完整限制提示 UI 通过。生产消息 Owner 对 denied 正文执行 rollback，旧单侧提示写入点仍存在，是否为优化时丢失独立业务副作用需继续核对。

R5 已结束并清理独立服务/模拟器：两项撤销 App 用例通过；私聊持久提示缺失、50 房间恢复抛 unexpectedResponse 两项失败。headless 入口因驱动在 App 失败处退出而未执行，不能计通过。已单独启动不含上述故障场景的 R6 来核对该入口；并不替代或覆盖 R5 的失败。

R5 恢复阶段细分日志：50 房间初始补拉完成 5.8505 秒、第二周期重连补拉完成 1.2707 秒；明确失败阶段为 `online-change`，后续 `silent-tail` 注入尚未执行。只将已完成的两周期列为通过，丢尾通知补偿仍无通过证据。

R10 输入提示定位已启动：协议 `V2RealtimeCoverageState` 明确区分 Subscribe ACK 与安装完成通知；本轮先观察真实 `.typing` coverage 安装状态，再发送开始/停止事件，用于区分安装迟到与已安装后的投递故障。R9 的冷订阅超时仍保留，不能用安装后通过覆盖初始丢失。房间恢复测试新增发送前/确认后、收到 hint 和超时时实际消息数/游标日志，下一次将细分 `online-change` 的失败。

R10 已终态：9个测试函数（慢上传未启用），启用项仅群头像422失败；观察真实typing coverage从recovering到ready后，开始/停止均收到。R6已退出0：两个撤销App测试通过、headless Push入口1项通过且没有跳过。headless入口并不证明外部APNs真实投递。R7房间定位与R11真实Operator封禁验收已启动。

双安装驱动保留审计失败，同时继续业务覆盖：仅允许唯一失败文本为已记录的Dynamic Type审计时继续下一阶段，其他断言和其他失败立即停止；审计失败计数>0在最终返回1。测试只在审计调用作用域内允许XCTest继续，所有审计类别和失败仍在xcresult中，未将审计转为通过或skip。


2026-10-08 R11/R7/双安装 R4 终态回收：

- R11 真实 Operator 封禁用例通过：禁用重放时间戳一致，HTTP 转未认证并清除凭据，密码登录和旧凭据 TLS 认证拒绝；不证明已有 TCP 即时终止。完整套件 10 个函数、2 项失败：主资源 `throttled(retryAfter: 1)` 与群头像 422，R10 成功证据保留。证据：`/tmp/imv2-acceptance-live-resources-extended-r11-20261008/client.log`。
- 房间 R7 消息提交且收到水位 2，测试仅 `requestCatchUp` 未如生产 App 调用 `retainOnlineRoomHead`，游标停在 1。已修正，R8 复验 50 房间跨节点与丢尾通知。证据：`/tmp/imv2-acceptance-live-account-ui-r7-20261008/app.log`。
- 双安装 R4 保留 Dynamic Type 审计失败并继续业务；发送端私聊已创建且列表显示“会话已就绪”，测试却等待自动导航，30 秒没有输入框而失败。已改测试关闭创建弹窗、打开现有会话并普通输入，不重新提交建房操作，待复验。两个安装范围清理通过，独立服务及专属模拟器已清理。证据：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-j8ch85dp/two-install-ui.log`；附件：`/tmp/imv2-two-install-r4-sender-attachments`。

R8 已退出 0：两项 App 设备撤销与真实 SDK/数据库持久核对通过。50 房间冷补拉 5.946 秒、重连补拉 1.284 秒、跨 Gateway 在线更新与故意丢尾通知后的周期补偿均通过，投影和游标断言保留。独立服务和专属模拟器已清理。证据：`/tmp/imv2-acceptance-live-account-ui-r8-20261008/app.log`、`/tmp/imv2-acceptance-live-account-ui-r8-20261008.log`。

双安装 R5 已退出 1：首场景 Dynamic Type 问题保留，发送端发送、反应、编辑、撤回 UI 流程通过；接收端恢复原消息后仍显示原文，撤回 tombstone 断言失败，后续群与离线阶段未执行。发送端测试先前接受“撤回请求已安全保存”便退出，尚不能证明其提交，现增加关闭前实际 tombstone 投影等待，并让接收端等待对应 tombstone，待复验。没有删撤回断言。证据：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-1q1q4kj5/two-install-ui.log`；视频附件：`/tmp/imv2-two-install-r5-receiver-attachments`。独立服务、两个安装范围及专属模拟器已清理。

新增 `--app-ack-cut` 真实 App 验收入口：透明代理阻止下行 ACK，独立 PostgreSQL 会话确认原消息与成功完成记录提交且操作指纹一致后，切换 Gateway 并关闭旧物理连接；复用现有 App 持久队列与自动重连测试，要求原身份、恢复结果、SQLite 重开与收件投影一致。R1 执行中，未计通过。

丢 ACK R1 未执行目标用例（Xcode 显示成功但 Swift Testing 实际 0 项）；驱动按实际执行计数拒绝空成功并退出 1，专属模拟器与服务已清理。方法选择器补齐 `()` 后 R2 复验中。R12 资源验收新增入群拒绝决定并启用慢上传/并行控制与 TLS 进度，结果待回收。

R12 已退出 0：`--slow-resource` 实际仅执行慢上传用例 1 项，1.412 秒通过；共享账号调度器的真实上传体被保持时，TCP 提交/恢复/补拉、SQLite 投影仍可推进，释放后上传 finalize 完成。这不是 iOS 系统后台会话或挂起验收，也没有执行新增入群拒绝用例；后者由不带慢上传选择器的 R13 完整扩展套件验收。证据：`/tmp/imv2-acceptance-live-resources-extended-r12-20261008/client.log`。

主动退出群的源码核对：`V2RoomMembershipAction` 仅 add/remove，`V2ChangeRoomMembershipCommand` 在 `RoomMembership.swift:60` 禁止 actor 与 target 相同；App/Core/ClientKit 未发现独立退出入口。当前判为未实现，不再用管理者移除他人代表主动退出，也不列为退出成功。

R13 完整扩展套件 10 个函数、2 项失败：主资源在原始 profile HTTP 读取遇到 `throttled(retryAfter:1)`，群头像仍 422；新增入群拒绝位于主资源后段未执行，其余扩展用例通过。两个原始 profile 读取现复用已有 3 次、最多 5 秒 Retry-After 的有界测试调度，只处理明确限流，权限失败与 per-item retryable 仍失败，不提高服务端限额。R14 复验中。代理故障边界测试 1 项通过，记录：`/tmp/imv2-acceptance-ack-cut-proxy-tests-20261008.log`。

丢 ACK R2 实际执行 1 项，前置建房 `noReceipt` 失败，代理未 arm；测试 helper 原先只接受提交立即返回的最终结果，已加入原 command 的 processing proof 校验与有界 recover 查询，R3 复验中。不得把尚未触发故障称为消息恢复失败或成功。

资源 R14 已走完附件、拉黑、昵称、目录及发现验证，但新增入群扩展报 presentation；拒绝后的相同申请人/邀请终态不应按新批准申请重开。测试改为用独立真实账号验证批准，并同时核对批准者在 roster、拒绝者不在；R15 复验中。群头像仍 422，其他扩展用例通过。

资源 R15 已退出 1：10 个函数，仅群头像 422 失败；主资源 4.419 秒通过，包括真实入群取消、拒绝、独立账号批准、批准者在 roster 而拒绝者不在、邀请撤销。其余消息、群、管理、设置、关系、presence/typing、封禁通过。证据：`/tmp/imv2-acceptance-live-resources-extended-r15-20261009/client.log`。

丢 ACK R3 在前置建房恢复遇到 HTTP 429；代理最终 `fixture=null`、`opened=0`，故未执行故障。时序复核：Xcode 失败结束在 00:03:04，所有服务的 `self down` 在 00:03:08 清理阶段，不能作为运行中 Actor 故障原因。前置失败不能算成丢 ACK 恢复失败或通过。证据：`/tmp/imv2-acceptance-app-ack-cut-r3-20261008/ack-cut-app.log`、`account.log`、`ack-cut-proxy-summary.json`。独立服务和模拟器已清理。双安装 R6 使用真实撤回投影等待复验，尚未回收。

双安装 R6：发送端关闭前本地撤回 tombstone 等待通过，接收端仍显示原文，30 秒等待未收敛；后续 R7 独立 PostgreSQL 查询发现消息仍为修订 1、未撤回、房间序号 1，发送端可见 tombstone 不能证明服务端提交，故不能将原因归为接收端投影。将不依赖此结果的群创建、群消息和离线重放拆为独立测试阶段，驱动仅允许这个已知精确失败继续后续阶段，并在最终保留整体失败；R7 执行中。独立服务与安装范围清理完成，专属模拟器复用于 R7。

丢 ACK 前置查询已改用 `V2NetworkWorkPolicy.acceptedResultPollDelay` 的 2/5/10/30 秒退避，原操作与 processing proof 始终校验，90 秒总期限；避免测试自己的 100ms 轮询耗尽查询限额。没有修改服务端限流参数。

提交前补充：双安装 R7 的独立数据库证据为 `/tmp/imv2-two-install-r7-message-facts.txt`。新增清理前 HTTP 状态汇总和数据库消息快照，用于区分本地乐观投影与服务端提交；R8 驱动已失败退出，尚待完整回收诊断，不计通过。

双安装 R8 已失败退出：`http-summary.json` 无消息编辑、撤回、反应请求；`message-facts.json` 为消息修订1、未撤回、房间序号1。不能将发送端乐观UI视为已提交。独立群创建成功并实际打开群详情，但原生菜单“成员”按钮未保留identifier，导致测试卡在查询；附件 `/tmp/imv2-two-install-r8-group-all-attachments/2C805307-DC13-409F-B476-29A0486109A0.txt`。R9 限定该原生菜单动作按唯一label查找，并新增清理前只读SQLite工作状态快照，未导出正文、回执或凭据。

R9 完整活动与 SQLite 纠正：发送端实际只执行并提交 directRoom/sendMessage/readReceipt；长按整行中心落在正文气泡外，未打开反应菜单，测试在此断言停止。xcresult摘要只列Dynamic Type，活动却另有“反应入口必须…可点击”失败。此前称编辑/撤回UI通过或乐观投影可见均不成立，相关操作未执行；不能将无HTTP认定为业务实现故障。R10 改为长按真实正文，审计继续规则同时检查完整活动，业务失败不再被摘要隐藏。R9 独立群成员页已打开，群发送卡在提及placeholder识别；R10 识别placeholder后通过普通输入填入@all，保留精确断言。

R10 已失败退出并清理：更严格的活动核对发现注册阶段建群已完成反馈被旧断言误判；同时发现 Text clipped，均保留。R11 修正合法已完成反馈判断，所有功能阶段末尾记录明确完成标记；仅摘要与完整活动都只有已记录 DynamicType/Text clipped 且出现完成标记时，才继续独立阶段，整体仍失败。没有以审计失败掩盖未执行的业务。

R11 注册场景活动包含明确功能完成标记，真实建群提交、隐私与身份页导航完成，审计失败保留。发送端长按正文确实打开原生菜单（`/tmp/imv2-r11-sender-live.png`），但按identifier查询停滞超过5分钟；SQLite仅建房/发送/已读已提交，无编辑/撤回工作。主动对专属xcodebuild51975发SIGINT取消并等待正常驱动清理，不将存活进程误记为结束。下一轮改用原生按钮identifier或可见label查询；没有绕过业务命令。

R12 证据无效：执行期间编辑同一Shell文件触发EOF，清理后错误退出0，父驱动误打印整体PASS；没有最终“local two-install direct-and-group-message E2E: pass”标记，未执行完整业务，明确不计通过。已改每轮固定驱动副本，父驱动同时核对最终完成标记，R13重跑。此问题由本轮工具操作引入，不是产品业务失败。

R13 真正业务证据：Sender SQLite directRoom/sendMessage/readReceipt/reaction/editMessage/withdrawMessage全部committed，各1次；独立PG `3|t|4|message.reaction_changed,message.edited,message.withdrawn`，证据 `/tmp/imv2-r13-postgres-message-facts.txt`。Receiver撤回恢复已完成，完整活动有功能完成标记，无业务失败，仅Hit area与DynamicType审计。整体仍失败，群/离线未执行。R14 将这两个精确审计与已记录Text clipped保留后继续独立阶段，最终仍整体失败；不豁免任何业务断言。

R14 已失败退出并完成范围及服务清理。真实群创建、两成员roster、@all投影、成员收群主消息和群主收成员回复通过。离线q未恢复：清理前Sender工作快照中原sendMessage为awaitingConfirmation/needsAttention、attempt_count5、last_error_code MESSAGE_SEND_TRANSPORT_UNAVAILABLE；新群回复成功说明新连接可用。独立PG私聊仍1条原已撤回消息、head4，无q；群2条消息、head3。源码 `V2MessageSendWork.swift:215` 对 unavailableBeforeSubmission 应用有限重试，耗尽转needsAttention；`recoverOperationClaims`仅回收claimed，不重新激活此状态。此为真实自动重放缺口，保留失败，不通过提高重试限额伪造成功。证据：`/tmp/imv2-r14-postgres-message-counts.txt`、结果目录`im-v2-local-two-install-e2e.zAkvQC`中的Sender-work-state.json。ACK R4开始独立复验。

ACK R4 前置定位：独立PG显示direct handoff processing1、owner receipt0、direct pair0，尚无消息故障。初始化标准admission lease条件漏了app-ack-cut（此前仅private-hint/room-scale/exclusiveGateway），故建房未满足正常准入前置。已将ACK模式纳入原本的隔离标准lease初始化，未改生产限额。当前运行仍按原配置保留，结束后从正确前置重跑；证据 `/tmp/imv2-acceptance-app-ack-cut-r4-20261009/direct-room-facts.txt`。

ACK R5 已退出0：实际App1项、0失败、0跳过；独立PG原消息与成功结果同指纹提交确认后，代理切Gateway并关闭原连接。客户端unknownObserved=true、automaticReconnect=true、sameIdentity=true；双端游标2、SQLite重开与唯一投影一致，proxy switched=true、drained2、closeFailures0。用例3.639秒；这不是吞吐测量。专属服务与模拟器已清理。证据 `/tmp/imv2-acceptance-app-ack-cut-r5-20261009/ack-cut-commit-gate.json`、`ack-cut-app-summary.json`、`ack-cut-proxy-summary.json`及App proof。同账号多设备R1开始，原生Operator快照重置入口已准备，未计通过。

同账号多设备 R1：两台安装实际登录同账号，设备页>=2断言通过。关闭设备页仍在“我的”，测试直接找会话菜单失败，附件 `/tmp/imv2-multi-r1-device-attachments/37102867-F560-4D44-9A71-44236E12E304.txt` 显示我的tab Selected。补普通消息tab切换，R2复验；尚不能算多设备编辑/已读通过。服务和安装范围清理完成。

同账号R2：第二设备群消息通过，第一设备编辑committed。独立PG事实 `3|1|2|1|3|2`＝roomHead3/messageCount1/revision2/userReadReceiptCount1/readThrough3/deviceProgressCount2，记录 `/tmp/imv2-multi-r2-group-progress-facts.txt`。设置测试无设置HTTP/工作，辅助树证实外层Switch为整行370宽、内层原生Switch63宽，tap整行中心未切换，45s等待value0失败。R3改点唯一内层真实Switch，保留实际值和提交验证。

同账号R3六个业务阶段完成：设置跨设备恢复、群离线原工作attempt5 committed、第二设备撤回提交均通过；PG两消息/head5，原消息revision3 withdrawn。随后Operator重置404因驱动将scope误当deviceID。R4用初次注册与第二设备登录前后设备集合差异核对真实ID，q断言仅匹配消息正文；不将待发送文本视为已送达。R14私聊离线失败证据继续保留，不以群单轮成功覆盖。

同账号R4已退出1且清理完成：8个业务阶段全部完成，注册保留Dynamic Type审计失败，其他7个业务用例及2个范围清理用例通过，0跳过。q只匹配v2.message.body正文，原离线工作attempt5 committed；第二设备撤回后第一设备正式投影通过；Operator真实设备快照重置后撤回/离线消息重建通过。PG两消息/head5、原消息revision3 withdrawn；策略两项关闭、用户级已读1、设备progress2。证据：`/tmp/imv2-multi-r4-preference-progress-facts.json`、`im-v2-local-multi-device-e2e.nojmxp/all-stage-summary.json`、`imv2-native-e2e-952lpux1/message-facts.json`。EX13通过，EX12仍保留私聊R14真实失败，EX14不扩大为尚未验证的对端已读显示。

扩展资源R16：原生隔离PG、Actor节点、HTTPS资源和TLS Gateway真实联调；10个实际测试函数9通过、1失败，另slow专用测试未启用跳过（不作本轮通过证据）；参数化账号偏好4种通过。唯一失败群头像上传422，保留OP32。新增EX05原已认证TCP不主动断开、Operator封禁后8秒观察边界内服务端结束、随后HTTP凭据/登录/TLS拒绝通过；EX07无好友关系私聊scope先预热，同TLS策略deny返回directPolicyDenied、allow后成功；EX09双方不同操作并发首次建房和再次打开回执同房间。进程96833退出1、独立服务清理。证据 `/tmp/imv2-acceptance-live-resources-r16-20261009/client.log`、`summary.json`。编译预检opt-in未开启导致跳过，仅作编译通过，未算验收。

账号切换R1失败已清理：A注册建群及恢复通过，普通退出点击后30秒无登录表单，UI停正在完成退出登录/v2.sign-out.pending.retry，B未执行。附件 `/tmp/imv2-account-switch-r1-all-attachments/33EF30C6-12CD-4319-AED8-64F3FCC8D8A3.txt`。源码V2RootView账号页onDisappear取消signOutTask，V2AppStore清理中检查取消后进入待凭据删除，属尚未独立证明的原因候选。R2通过正常重试按钮继续账号隔离，每次重试记录明确活动，首次退出失败继续保留EX03，不以补偿后成功覆盖。

账号切换R2/R3均退出1并清理：普通退出重试可回到登录，开始填写B但未提交。R3录像真实显示iOS“使用强密码？”系统弹层遮挡，滚动不足以处理；纠正此前单纯键盘/滚动判断。证据 `/tmp/imv2-account-switch-r3-last.png`（从实际xcresult录像提取），结果 `im-v2-local-two-install-e2e.0HKOHN`。EX06尚未完成，EX03首次退出失败继续保留，下一轮需处理实际系统弹层，不关闭或绕过业务验收。

账号切换R4真实用例1通过、0失败、0跳过：B以公开注册API准备，实际App普通A→B→A密码登录、两账号各自建群发消息、B冷恢复及A重登/冷恢复自身消息存在、另一账号会话/正文不可见。完整活动两次手动退出重试，首次退出失败继续EX03；不把补偿成功计成普通退出正常。PG两群/两群主/两房间/两消息，消息revision1、head2。注册DynamicType失败仍使总驱动exit1；服务/范围已清理。证据 `/tmp/imv2-account-switch-r4-summary.json`、`/tmp/imv2-account-switch-r4-postgres-facts.json`、`im-v2-local-two-install-e2e.rh9sPD/account-switch-activities.json`。EX06隔离完成，EX03仍失败。

私聊已读UI R1四阶段业务完成：接收端普通恢复/阅读及发送端冷启动原消息旁“对方已读”2用例通过；注册和发送各保留DynamicType审计失败；2范围清理通过，0跳过。PG1私聊/1消息/双方用户读记录2，证据 `/tmp/imv2-peer-read-r1-postgres-facts.json`、`im-v2-local-two-install-e2e.Ty7lbn/all-stage-summary.json`。总驱动退出1、服务/范围清理。不将独立peer-read模式计为消息编辑/撤回通过；EX14仍保留群读者UI待验。

群读者UI R1仍执行中：Sender原建房/发送/已读SQLite全部committed attempt1，PG原消息revision1/未撤回；没有reaction/edit/withdraw工作，尚未进入群场景。当前UI测试停滞于后续私聊控制操作，不能记发送业务失败或群读者通过。证据 `/tmp/imv2-group-read-r1-sender-work-live.json`、`/tmp/imv2-group-read-r1-sender-live.png`，专属会话39401持续存活，等待既有阶段墙钟守卫。下一轮原始脚本已准备group-only路径，只完成必要私聊发送/阅读，然后真实群创建/成员阅读/群主读者断言；当前执行冻结副本未改。

群读者R1明确终止：完整活动长按正文/点击反应入口后“App animations complete notification not received”，XCTest等待空闲直到5分钟执行期限，功能完成标记缺失。摘要仅DynamicType不足以继续，保留失败。Sender建房/发送/已读committed，未创建变更工作，群阶段未执行，服务/范围清理。R2改用group专用路径，已有修改/撤回验证独立保留；不修改实时驱动副本。同步修正表格分类：私聊已读UI证据属于OP05(readReceipt)，从OP06(directRoom)移回；OP12/14已验证App设置的旧“待验”字样移除。

群读者UI R2完整回收：六业务阶段功能完成（注册/发送各保留DynamicType，其余4业务用例通过），2范围清理通过，0跳过。群主长按原群消息打开已读详情，真实独立成员Two install sender及value已读断言通过；PG不同读者2、最低readThrough2，终态群2条消息/head3；总驱动退出1、服务/范围清理。证据 `/tmp/imv2-group-read-r2-postgres-facts.json`、`im-v2-local-two-install-e2e.1v4JgE/all-stage-summary.json`、`imv2-native-e2e-o69rrtn3/message-facts.json`。EX14与OP05补群读者UI证据；私聊修改/撤回未在本轮执行，不扩大结论。

同账号隐私R5八业务阶段功能完成：7独立业务用例通过、注册DynamicType失败保留；2范围清理通过，0跳过。普通UI关闭允许他人添加我/在线状态/正在输入，另一安装冷恢复三个开关0值；PG独立userAddDenied1/liveActivityBothDisabled1/strangerDenied1/groupReadDisabled1。原编辑/群离线/撤回/Operator快照重建继续通过。总退出1、服务及范围清理。OP13/15 App待验补齐；本轮并未测试新的好友申请拒绝或在线/typing对端传播，不扩大为这些边界验证。证据 `/tmp/imv2-multi-r5-policy-facts.json`、`im-v2-local-multi-device-e2e.IT2TlZ/all-stage-summary.json`。


### 20261009-conversation-preference-ui-r1（测试断言失败）

- 使用隔离原生 PostgreSQL、Account、Gateway、Actor 服务和两台明确选定的模拟器，真实注册同一账号、第二安装登录并发送群消息。
- 首台 App 普通会话长按菜单提交置顶后，界面提示“会话设置已安全保存，连接恢复后会重试。”；测试仅等待“会话设置已提交，正在同步。”而在 30 秒后失败。清理前 SQLite 的该 `conversationPreference` 工作已为 `committed/finished`，提交次数 1。这是队列路径与测试提示断言不匹配，不能据此宣称完整偏好场景通过。
- 原始日志 `/tmp/imv2-acceptance-conversation-preferences-r1-20261009.log`；完整活动 `/tmp/imv2-conversation-pref-r1-activities.json`；结果目录 `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-multi-device-e2e.QTJxbt`。注册仍保留 Dynamic Type 审计失败。两范围清理通过，隔离服务已停止。
- R2 仅修正测试等待：允许普通持久队列提示，最终必须由 PostgreSQL 以及两台安装的会话状态表和列表索引共同证明，提示本身不作为发送成功或同步成功证据。


### 20261009-conversation-preference-ui-r2（功能通过，保留审计失败）

- 在隔离原生服务和同账号两个真实 App 安装中，普通会话长按菜单依次置顶、免打扰一小时、归档；第二安装冷启动验证收件箱不再显示该会话、归档列表可见且带免打扰状态。随后由第二安装普通菜单取消归档、免打扰、置顶；第一安装冷启动验证会话恢复收件箱，归档列表不再显示，免打扰关闭。
- 每个阶段只读核对 PostgreSQL `user_room_preferences`、对应安装 SQLite `v2_conversation_states` 和 `v2_conversation_list_entries`。正向两端三项均为 true，服务端 revision 3；反向两端三项均为 false，服务端 revision 6。置顶图标隐藏于无障碍层，因此没有把不可见图标或队列提示当作置顶成功证据，置顶由独立状态与列表索引核实。
- 全部 6 个业务阶段包含功能完成标记：5 个独立业务测试通过；初始注册保留 `Dynamic Type font sizes are partially unsupported` 审计失败。另两个范围清理测试通过，0 跳过。整体退出 1，不能报告整轮全绿；隔离服务和两台本轮账号范围已清理。
- 原始日志 `/tmp/imv2-acceptance-conversation-preferences-r2-20261009.log`；结果目录 `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-multi-device-e2e.ZOmU2E`，其中 `all-stage-summary.json`、逐阶段完整活动、8 份脱敏偏好快照和清理前工作状态均保留。
- OP-18 的跨安装待验项已更新为已验证。本轮没有代替群加入审核、系统后台资源传输、外部 APNs 等仍未完成的验收，也没有消除已有功能失败。


### 20261009-group-join-ui-r1（二维码定位失败）

- 隔离原生 PostgreSQL、Account、Gateway、Actor 和两个明确选定的模拟器中，群主普通注册、建群并从“邀请”页提交创建。SQLite `groupInvite` 工作为 `committed/finished/attempt1`。
- 测试仅查找 `v2.group-invite.qr.*`，45 秒后失败；实际失败无障碍树有可见 180×180“群邀请二维码”，其标识继承了外层 `v2.group-invite.link.*`。此处不能据测试定位失败认定邀请创建失败，也不能宣称后续申请/取消/批准通过，因为它们未执行。
- 日志 `/tmp/imv2-acceptance-group-join-r1-20261009.log`；结果目录 `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.YgTxhh`；完整附件 `/tmp/imv2-group-join-r1-attachments`。注册 Dynamic Type 失败保留，两个范围清理通过，隔离服务已停止。
- R2 依据实际树，限定二维码标签及邀请行标识进行定位；仍从 App 实际二维码提取本轮链接，不从数据库构造授权。


### 20261009-group-join-ui-r2（二维码通过，冷启动深链接失败）

- 群主 App 普通邀请创建测试通过，保留实际二维码截图，并以 Vision 读取唯一 `iim://group-invite` 链接；独立申请人普通注册通过。未从数据库读取或构造邀请 secret。
- 申请人安装冷启动后，正常 `simctl openurl` 调用返回成功，但 UI 等待 30 秒未出现“加入群聊”，失败层级树仍为“消息/暂无会话”；申请工作记录为空。不能证明申请/取消/审批，当前只确认深链接入口没有成功呈现，具体根因待定位。
- 日志 `/tmp/imv2-acceptance-group-join-r2-20261009.log`；結果目录 `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.q4tmdJ`；申请失败附件 `/tmp/imv2-group-join-r2-applicant-attachments`。原始邀请码只在本轮隔离结果目录保存，权限 0600，不打印到摘要。
- 注册 Dynamic Type 审计失败保留，两个范围清理通过、服务已停止。R3 改用普通“加入群聊”粘贴入口继续验证业务；此项冷启动深链接失败仍单列 EX-24，不因其他入口通过而删除。


### 20261009-group-join-ui-r3（粘贴菜单元素类型定位失败）

- App 实际二维码创建/读取、独立申请人注册再次通过；普通“加入群聊”入口及输入框长按完成。失败树明确显示系统 `MenuItem`“粘贴”，测试错误使用 `app.buttons` 查询，因此等待失败，申请尚未提交。
- 原始日志 `/tmp/imv2-acceptance-group-join-r3-20261009.log`；完整活动 `/tmp/imv2-group-join-r3-applicant-activities.json`；附件 `/tmp/imv2-group-join-r3-applicant-attachments`；结果目录 `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.ChM0oP`。两个范围清理通过、隔离服务已停止，原注册 Dynamic Type 失败保留。
- R4 将系统“粘贴”定位修正为 `menuItems`，实际邀请仍通过本轮 App 二维码和普通剪贴板传递，无数据库授权写入；此前冷启动深链接未呈现仍独立保留。


### 20261009-group-join-ui-r4（申请取消批准通过，最后消息正文投影失败）

- 群主普通 UI 创建邀请，保留实际二维码；Vision 从截图读取链接，另一安装通过普通加入群聊粘贴和预览提交申请。独立 PG 确认第一次 pending=1/members=1，取消后 cancelled=1/pending=0/members=1，再次申请 pending=1/cancelled=1/members=1，群主批准后 approved=1/pending=0/members=2。审批为真实 UI 按钮，没有直接修改数据库成员。
- 申请人冷启动、重新预览显示“你已经是该群成员。”，正常刷新并打开群，提交 Approved member message。清理前本地 sendMessage 为 committed/finished/attempt1；终态 PG message-facts.json 确认一条 accepted 消息、未撤回、内容修订1、房间head3，事件为 room.created/membership_changed/message.accepted。
- 最后用例仍失败：30秒内没有权威正文元素，失败树仅在 v2.message.pending-sends 中显示该文本，提示仍为“已安全保存，连接恢复后会重试。”。判定即时正文投影异常，不能因为数据库提交而报告用例通过，也不能判定数据库发送失败。冷恢复能否补齐该消息仍需验证。
- 8业务阶段6测试通过，注册保留Dynamic Type失败，最后正文投影测试失败；另2范围清理通过，0跳过。整体退出1，服务与范围清理完成。App管理员拒绝和邀请撤销仍待验；此前冷启动深链接未呈现继续保留。
- 日志 /tmp/imv2-acceptance-group-join-r4-20261009.log；结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.Wq9vIT，含all-stage-summary.json、完整活动、4份阶段PG事实和两端工作状态。终态消息事实 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-wsrvyvej/message-facts.json；失败附件 /tmp/imv2-group-join-r4-restored-attachments。


### 20261009-group-join-reject-ui-r1（拒绝与撤销功能通过，保留审计失败）

- 群主普通App创建真实邀请二维码，另一安装通过普通粘贴预览提交申请；群主App拒绝后，申请人冷启动重新预览显示已拒绝、不能再提交该申请，普通刷新后无群会话。
- 群主App随后撤销原邀请，申请人再次粘贴原链接读取时收到“邀请不存在、已撤销、已过期或次数已用完。”，没有申请按钮。每阶段独立PG核对：pending1/members1，拒绝后rejected1/pending0/members1，撤销后activeInvites0/rejected1/members1。
- 8业务阶段全部包含功能完成标记，7独立业务测试通过，注册保留Dynamic Type审计失败；2范围清理通过，0跳过，整体退出1。隔离服务和本轮账号范围已清理。此结果没有覆盖此前冷启动深链接入口和即时正文投影的失败。
- 日志 /tmp/imv2-acceptance-group-join-reject-r1-20261009.log；结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.cCLxa7，保留all-stage-summary.json、完整活动、PG阶段事实及两安装清理前工作状态。


### 20261009-group-join-cold-send-ui-r1（原已提交消息冷恢复通过）

- 使用另一套隔离原生服务和两真实App安装完成邀请、申请、取消、再次申请、群主批准。申请人冷启动确认已是成员，普通群会话提交原消息；持久化观察阶段只证明发送意图保存，不把安全保存提示当作数据库提交。
- 保持App运行，驱动以30秒上限独立读取PG直到messages=1，再核对SQLite唯一sendMessage工作为committed/finished/attempt1。随后普通终止并冷启动同一安装，进入原群显示唯一权威正文元素，未再提交消息。最终PG仍仅1条消息、成员2，证明恢复原提交而非重发制造新消息。
- 9业务阶段全部完成，8独立业务测试通过，注册保留Dynamic Type审计失败；另2范围清理通过，0跳过，整体退出1。隔离服务和本轮范围已清理。本轮没有重测或消除R4即时正文投影失败，只补齐其冷恢复证据。
- 日志 /tmp/imv2-acceptance-group-join-cold-send-r1-20261009.log；结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.SKR8ii，含all-stage-summary.json、完整活动、send-confirmation-join-facts.json、pre-cold-send-work.json和joined-message-join-facts.json。


### 20261009-local-retention-and-live-r18（清理夹具修正及真实TCP验证）

- 修正4个清理测试的夹具：成功回执之后，使用实际同步导入器应用匹配的权威投影，再验证历史清理。未修改生产清理条件；投影未收敛、未知结果、依赖和物理资源仍受保护。相关41项测试、5个套件通过，日志 /tmp/imv2-acceptance-client-retention-r2-20261009.log。首次编译缺少try已修正。
- 新增真实TLS/TCP发送、本地SQLite保存、权威房间事件拉取、8天后清理、SQLite重开及服务器原结果查询验证。R17夹具误用同一账号作为两名成员，触发成员主键冲突；已改为两个真实注册账号，R18新增用例通过。日志 /tmp/imv2-acceptance-live-resources-r18-20261009/client.log。
- R18整套运行仍退出1，唯一失败是已知群头像上传HTTP422；慢资源用例未启用。没有把整套验收或此前全量客户端回归标为通过。两份脚本bash语法、Python解析和git diff --check通过。

### 20261009-room-scale-r9（1000房间恢复通过，在线更新失败）

- 使用当前84612bf8原生服务、隔离PG、两个Gateway及专用iOS27模拟器，执行真实TLS客户端生产恢复流程。账号注册后夹具预置1000非空房间，后续所有读取及在线发送使用生产协议，没有将SQL种数据等同公开建群验收。
- 首轮本地列表23.361秒就绪、完整补拉121.589秒；重连列表0.020秒就绪、完整补拉12.317秒。两轮都逐房核对唯一预置正文、游标1、目录去重和总数1000。
- 后续按房间ID排序选取的第129个房间在线发送确认后，30秒窗口内本地仍messages1/cursor1，未出现新正文；online-change阶段失败，未进入故意丢尾通知场景。不能把两轮补拉通过扩大为较大规模实时链路或通知补偿通过，根因尚未定位。
- XCTest终态2通过、1失败、1未启用的独立后台重试场景跳过；两项App设备撤销通过。驱动exit1，专用模拟器删除、隔离进程及数据库清理完成。证据 /tmp/imv2-acceptance-room-scale-r9-20261009/app.log、app-summary.json、app.xcresult、scale-resource-samples.json及cleanup.log；启动日志 /tmp/imv2-acceptance-room-scale-r9-20261009.log。

- R9后续源代码核对：虽然启动两个Gateway，sendRecoveryOnlineMessage仍复用接收连接，不能证明跨Gateway发送；此前跨Gateway标记仅检查环境变量存在，证据不足。R9失败为实际同Gateway在线更新失败。R10改为在第二端口实际认证独立发送连接，并在超时时只读拉取服务端尾部、打印水位，不应用诊断页面、不把手动补拉计为通过。此前R8的跨Gateway在线发送结论同样撤回，保留其实际恢复与通知丢失证据。

### 20261009-room-scale-r10（真实跨Gateway在线更新通过，丢尾注入失败）

- 实际连接第二Gateway并完成TLS认证后，使用持久化命令/回执提交新消息。接收连接取得目标房间head2，SQLite新正文和游标2均一致，实际跨Gateway在线阶段通过。1000房间冷补拉121.846秒、重连11.406秒。
- 随后丢尾场景虽然恢复到3条消息/游标3，目标通知丢弃数为0；122条其他房间提示被旧夹具误计为替代唤醒。XCTest两条断言失败，整轮exit1，不因日志中的通过字符串标为通过。故障未注入，不能证明丢尾补偿。
- 保留两端房间订阅固定指标before/online.prom及app.log、app-summary.json、app.xcresult。两项App设备撤销通过，专用模拟器和服务已清理。R11在恢复完成后重新建立目标详情房间订阅，仅计目标房间新水位的丢弃/转发，并在故障前置不满足时立即抛错，避免继续打印通过标记。

### 20261009-room-scale-r11（只读验收触发限流）

- 本轮终态exit1，XCTest两项App设备撤销通过、规模用例失败、独立后台用例未启用跳过。恢复请求结束后，逐房验证的目录读取收到RATE_LIMITED/retryAfter1，原夹具未重试而直接退出；两轮验证和在线故障场景未完成，不计通过。
- 新增只读目录验证重试，仅处理明确可重试RATE_LIMITED并等待服务端retryAfter，使用原恢复deadline及取消检查；不关闭生产限流、不更改SQL或消息逻辑。诊断复测继续保留实际第二Gateway连接、恢复后详情订阅和严格目标丢弃计数。
- 证据 /tmp/imv2-acceptance-room-scale-r11-20261009/app.log、app-summary.json、app.xcresult、cleanup.log；专用模拟器及隔离服务已清理。R9/R10失败与局部通过证据保留，未覆盖为整体验收通过。

### 20261009-room-scale-r12（消息已持久化，实时提示缺失）

- 修正夹具后本轮终态exit1：两项App设备撤销通过，规模用例失败，独立后台场景未启用跳过。1000房间完整冷补拉122.771秒、重连11.345秒，逐房唯一预置正文及游标1、总数与去重通过。
- 普通订阅与恢复后重新订阅均返回目标head1；独立第二Gateway TLS认证/持久化提交及原结果查询确认成功，但30秒内接收端messages1/cursor1，未记录目标提示。失败诊断只读拉取服务端尾部next2/hasMorefalse，未应用该页面，证明新消息存在但实时链路未推进本地状态。
- R10相同规模实际跨Gateway阶段曾通过，因此不能宣称实时容量稳定；R12后续丢尾场景未执行。当前无法区分服务端提示发送与客户端消费的具体根因。驱动新增清理前两Gateway固定房间订阅阶段指标保存，成功或失败均保留，诊断失败只写错误类型、不改变验收结果。
- 证据 /tmp/imv2-acceptance-room-scale-r12-20261009/app.log、app-summary.json、app.xcresult及cleanup.log；专用模拟器及隔离进程已清理。新增Python驱动解析和git diff --check通过。

### 20261009-room-scale-r13（真实丢尾补偿功能通过，驱动清理失败已修复）

- XCTest3项通过、0失败、独立后台未启用跳过1项。1000房间完整冷补拉122.621秒，重连11.341秒；两轮逐房正文、游标、目录总数和去重核对通过。实际第二Gateway独立TLS发送后接收head2，正文/游标2通过。下一阶段目标尾通知实际丢弃2次、无目标新水位替代转发，客户端自行恢复3条消息/游标3，真实丢尾补偿通过。HTTP/PG驱动业务断言通过，不是仅凭日志标记。
- 两端固定订阅指标已保存primary-subscription-final.prom、secondary-subscription-final.prom。主Gateway有headOffered12/headEnqueueAccepted4、socketResponseBusy187、renewalAccepted15475、renewalCallOverloaded944；第二Gateway有pumpBindRefused4。指标为整轮进程计数，不能据此单独归因R12失败，也不能将本轮通过当成稳定性证明。
- 本次新增诊断变量data覆盖原数据库目录，导致最终pg_ctl清理使用错误参数，驱动exit1；已重命名subscription_metrics_text。专用模拟器和Gateway已退出，遗留的本轮PG postmaster由原隔离目录及端口确认，目录已删除不能使用pg_ctl，使用其fast-stop信号并确认进程及端口消失。既有5432数据库未触碰。cleanup-repair.log保存修复过程。整轮不能报告exit0。
- 证据 /tmp/imv2-acceptance-room-scale-r13-20261009/app-summary.json、app.log、app.xcresult、http-summary.json、两端subscription-final.prom及cleanup-repair.log。R9/R10/R11/R12失败记录保留；Python解析和git diff --check通过，生产实现未变。

### 20261009-direct-edit-ui-r1-r4（补跨安装编辑中间态，夹具诊断）

- 新增普通UI发送/表情/编辑后不撤回的专门流程。驱动保持发送端运行，独立PG要求唯一原消息revision2、edited事件1、未撤回；另一安装正常冷启动必须定位该服务器原消息ID的精确编辑正文，不能用待发送文本替代。
- R1在发送前DynamicType审计中止，未执行编辑；R2实际编辑committed/finished，但测试错误假设光标在末尾，实际在开头插入x。R3精确前缀x编辑及功能标记通过，审计出现Hit area/DynamicType/Text clipped/Contrast，原驱动拒绝Contrast而未继续接收验证。原始失败分别保留，不计跨安装通过。专门流程仍执行原审计，移动到功能标记后；驱动只在全为固定审计失败且功能标记存在时继续，整体仍exit1，不免除PG或接收端断言。
- R4独立PG确认唯一原消息revision2/editedEvent1/未撤回。接收端失败层级树已有同一UUID权威正文xtwo-install-direct-ui；App元素UUID大写，PG字符串小写导致精确定位超时。R5先解析UUID统一格式，继续精确核对身份和正文。R4不计自动验收通过。
- 日志 /tmp/imv2-acceptance-direct-edit-ui-r1-20261009.log 至 /tmp/imv2-acceptance-direct-edit-ui-r4-20261009.log。R4结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.BT0EYH，含edited-message-facts.json、两安装工作状态和完整活动；附件 /tmp/imv2-direct-edit-r4-receiver-attachments。四轮均终态exit1，隔离服务停止、两范围清理完成；当前R5运行中，生产实现未改。

### 20261009-direct-edit-ui-r5（跨独立安装编辑中间态通过，审计失败保留）

- 三个业务阶段均有功能完成标记：真实App接收账号注册/自建群，另一安装普通UI打开私聊、发送、表情、编辑；独立PG等待唯一原消息revision2/editedEvent1/未撤回；接收端正常冷启动和普通刷新，使用PG原消息ID解析UUID定位权威正文，精确文本为插入x后的原文本，唯一正文、没有撤回元素。接收端专门测试通过13.919秒，未再次发送消息。
- 终态PG仍唯一原消息、内容修订2、未撤回；SQLite发送端editMessage committed/finished，接收端使用自身同步投影。两端没有复制数据库或注入消息。
- 五测试3通过、2审计失败、0跳过：业务接收冷恢复通过，两范围清理通过，注册与发送端保留DynamicType/Hit area/Text clipped/Contrast审计失败。整体exit1，不称整轮全绿；OP03中间态待验已补齐，EX24审计失败仍保留。
- 日志 /tmp/imv2-acceptance-direct-edit-ui-r5-20261009.log；结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.QDaZMK，含all-stage-summary.json、完整活动、edited-message-facts.json与两安装工作状态；终态PG事实 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-4b2uua1j/message-facts.json。隔离服务和两个范围均已清理。bash语法、Python解析、git diff --check通过。


### 20261009-app-credential-refresh-ui-r1（真实App刷新与冷恢复通过，审计失败保留）

- 普通App注册真实账号后，通过独占测试Edge对一次真实设备列表HTTP200返回受控401，触发App原有认证刷新路径；刷新请求仍由真实账号服务处理，没有注入Keychain或数据库凭据。此验证证明业务401恢复，不代表自然到期。
- 独立PG同设备generation由1到2，refresh操作1、历史1；真实App普通设备页读取恢复通过。终止App后正常冷启动，Edge仅在进程内比较请求Bearer与真实刷新响应令牌的摘要，冷设备读取确实使用新凭据1次；日志未输出令牌或摘要。冷恢复PG仍generation2/operation1/history1，未额外刷新。
- 两个刷新用例通过；注册保留可访问性审计失败，两安装范围清理通过。全阶段5测试4通过1失败0跳过，整体exit1，隔离服务关闭。EX02更新为该范围已验，自然到期仍待验；完整56项及已有失败不变。
- 日志 /tmp/imv2-acceptance-app-refresh-ui-r1-20261009.log；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.q3vv0c，含all-stage-summary.json、before/rotated/cold-credential-facts.json和refresh-status.json。测试对应已推送提交e8c8a9f0。


### 20261009-app-natural-expiry-ui-r1（进行中，不计通过）

- 新增自然到期专门模式：普通App注册后关闭进程，仅只读查询原access token期限，等待服务端默认15分钟有效期自然结束；期限结束时要求generation仍1/refresh操作0，再普通冷启动。后续要求真实刷新到generation2、原设备身份不变，并再次冷启动验证使用新凭据。与401模式复用实际设备页断言，但不调用401注入入口；终态要求injected0。
- 本轮已启动且exec会话65121确认仍运行，尚无终态结论。日志 /tmp/imv2-acceptance-app-natural-expiry-ui-r1-20261009.log；隔离目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-etggm6_6；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.93PRit。EX02自然到期仍待验，不能使用新测试代码作为通过证据。bash语法和diff检查通过，新增Swift测试编译由本轮真实XCTest执行。

- R1后续终态exit1：注册后XCTest已关闭App，驱动simctl terminate遇到found nothing to terminate而提前退出，未等到原令牌到期。两范围清理及隔离服务回收完成；此失败不算认证刷新失败。驱动仅将明确的已停止结果作为幂等，其他终止错误仍拒绝继续。新增Swift测试已由本轮XCTest构建。
- R2使用修正后的同一自然到期模式启动，exec会话99630，日志 /tmp/imv2-acceptance-app-natural-expiry-ui-r2-20261009.log；自然到期仍待真实结果，不能标通过。


### 20261009-background-transfer-source-audit（识别实现边界，不代替真实后台验收）

- App真实组装V2URLSessionMediaByteTransfer（V2AppRealtimeRuntime.swift:1044）；适配器注释明确下载计划只授权前台读取（V2MediaTransfer.swift:173）。其V2RangeDownloadTransport使用dataTask，默认mediaProvider来自ephemeral URLSession（V2SecureURLSession.swift:22）。V2NativeBackgroundSession系统后台会话当前只创建uploadTask；两项目生产源码无downloadTask调用。系统后台下载为当前实现缺口，不能继续笼统写成仅待执行测试，更不能用前台断点续传或慢上传通过替代。
- 系统后台上传有真实实现：账号激活安装native协调器、能力检查、签发后台分片授权、先持久化映射再resume，UIKit处理系统完成回调。真实iOS挂起传输仍待执行，本源码核对不证明其正确性。
- devicectl只读清单存在3个connected iPhone记录，但是否可用于本轮及APNs测试环境尚待确认；未安装或操作这些设备，未读取其业务数据。EX23外部APNs继续待验。


### 20261009-large-nickname-directory-r1-r2（真实SDK大分页通过，UI边界保留）

- 新增独占native模式，只在该模式下准备257条隔离测试用户资料/群成员/昵称初始数据；另有真实注册作者与浏览者，浏览者再通过真实密码登录签发第二设备凭据。作者通过真实昵称操作及原回执恢复设置昵称，真实拉黑接口推进权限。257条资料是分页规模夹具，不证明257次真实注册或昵称写入。
- R1新用例错误传首次expectedRevision0，被非零版本类型拒绝，未进入分页；终态exit1、服务清理。修正为协议已有首次nil；不修改生产类型或版本约束。
- R2独立两设备读取，每页32条、每遍历9页/258唯一ID，完整集合一致，租约绑定各设备，无签名头像；真实拉黑后作者unavailable且无展示快照，目录不丢游标。27次真实GET全部200；PG blocks1。1专项2.979秒通过，驱动exit0及资源清理通过。
- R3进一步增加逐用户精确昵称与初始数据对应断言，运行中，不预先报告通过。此SDK专项没有正常App目录页、独立安装SQLite或UI冷恢复，EX15该边界仍待验。
- 证据 /tmp/imv2-acceptance-large-nickname-directory-r1-20261009 与 /tmp/imv2-acceptance-large-nickname-directory-r2-20261009，含client.log、summary.json、服务及清理日志。R3 /tmp/imv2-acceptance-large-nickname-directory-r3-20261009，exec会话50202。

- R3终态exit0：逐用户精确昵称与userID对应全部通过，仍27次真实分页读取200、258条9页/两独立设备、真实拉黑后作者不可见。1专项3.001秒，隔离服务及PG正常清理。EX15加入R3证据，App跨安装目录UI仍未验证。


### 20261009-app-natural-expiry-ui-r2（真实自然到期刷新通过，审计失败保留）

- 原默认15分钟access token仅等待实际时间流逝，数据库期限与服务器时钟未修改。App未运行期间只读PG确认原token1/expired true，generation仍1、refresh操作0/history0。
- 普通App冷启动，原设备身份不变，真实账号服务刷新到generation2/refresh操作1/history1；设备页功能用例通过12.802秒。App终止并再次普通冷启动，使用新凭据完成设备读取，PG仍同generation2；冷恢复用例通过12.100秒。Edge私有摘要比较只计数，不输出令牌或摘要：injected0、refreshResponses1、coldFreshDeviceReads1。没有受控401，不用SDK时钟替代App真实到期。
- 五测试4通过、1注册可访问性审计失败、0跳过，整体exit1；两范围清理通过，隔离服务停止。EX02自然到期待验已补齐，原审计失败继续列在EX24，不报告整轮全绿。
- 日志 /tmp/imv2-acceptance-app-natural-expiry-ui-r2-20261009.log；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.l8QQOw，含all-stage-summary.json、natural-expiry-facts.json、before/expired/rotated/cold-credential-facts.json、refresh-status.json及原始xcresult。R1夹具失败继续保留。


### 20261009-app-large-directory-ui-r1-r2（普通成员页大分页，进行中）

- 普通App真实注册建群后，仅在隔离库准备257条成员资料及同名昵称，加上原群主共258名；更新初始成员修订与人数。此规模夹具不证明257次公开成员添加已验，成员操作的真实接口验证另有已有证据。普通App成员页应实际点击两次加载更多、读取3页，逐UUID和对应精确名字核对全部成员；第二安装通过普通密码登录同账号，再正常冷启动重读，不能复制SQLite或凭据。
- R1终态exit1：测试进入真实成员页后，其BEGINSWITH选择器也匹配v2.group.member.role/remove按钮，XCTUnwrap预期成员名失败，尚未读完整集合。修改选择器为精确UUID成员行并规范化UUID，保留失败原证据。两范围及隔离服务已清理。
- R1日志 /tmp/imv2-acceptance-app-large-directory-ui-r1-20261009.log；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.bPQnES。R2日志 /tmp/imv2-acceptance-app-large-directory-ui-r2-20261009.log，exec会话38552，运行中不计通过；EX15 App待验状态不变。

- R2当前仍在首次成员目录遍历（exec会话38552已确认运行），结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.9LQu7F。源码V2AvatarPipeline成员名合并为无障碍元素、children ignore；下一轮将StaticText专用查询修正为原成员行内精确label查询，并记录遍历seen/load计数。当前运行二进制仍使用旧名称查询，未改变或并行重启该轮；没有业务通过结论。

- R2终态exit1：首次成员页专项超过5分钟，两范围及隔离服务清理完成。完整活动 /tmp/imv2-app-large-directory-r2-activities.json 末尾仍查询目录成员StaticText名称，之后查不存在/未呈现末尾成员isHittable出现retry；截图 /tmp/imv2-app-large-directory-r2-live.png 有真实正确成员名称，不代表完整集合通过。修正合并label定位及lastRow.exists前置，避免缺失元素的可点击查询等待；不是修改业务分页或缩减258成员范围。
- R3使用修正版真实重跑，exec会话50038，日志 /tmp/imv2-acceptance-app-large-directory-ui-r3-20261009.log。未有终态结论，EX15 App待验继续保留。

- R3当前已进入首次App冷恢复成员遍历，exec会话50038确认运行；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.9KNWjU，服务目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-a34_ar7h。新增progress-seen/loads活动用于实际失败定位。仍未终态，完整258成员和第二安装边界保持待验。

- R3终态exit1：首次成员遍历超过5分钟。活动 /tmp/imv2-app-large-directory-r3-activities.json：seen4→64→105→124→191→202→227，loads0→1→2，确认真实3页已加载；最后停留Swipe down与事件合成，仍有31个成员名未核对。不把此计数当全部通过，不据此判定SQL或认证失败。两范围/隔离服务清理完成；截图 /tmp/imv2-app-large-directory-r3-live.png 仅补充可见姓名。
- 整页flick存在跳过相邻快照之间成员行的风险。保持258人逐原ID与精确名字断言，改为当前成员sheet内慢速短拖动、前后视口重叠并停惯性；采用本机XCUIAutomation公有坐标拖动API。R4实际启动，exec会话83757，日志 /tmp/imv2-acceptance-app-large-directory-ui-r4-20261009.log；尚无结论。

- R4已编译并进入首次真实App冷恢复成员遍历，exec会话83757仍运行；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.g5OKBC，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-dnf20c2u。矩阵EX15明确列出App遍历超时与R3证据，直到新结果证明才更新；不将失败藏在待验分类后。

- R4首次安装正常冷恢复已通过：原258个成员UUID与对应精确名称全部核对，实际加载更多2次/3页，1测试通过、0失败/跳过，摘要时长262.547秒；证据 /tmp/imv2-app-large-directory-r4-first-summary.json 和 /tmp/imv2-app-large-directory-r4-first-activities.json。第二安装真实密码登录读取正在运行，后续正常冷恢复未完成；不能据首次通过关闭跨安装待验。

- R4终态exit1：第二安装真实登录后读取3页、核对253/258个成员，5分钟执行超时；最后活动是反向短拖动与远程无障碍查询。证据 /tmp/imv2-app-large-directory-r4-second-summary.json 和 /tmp/imv2-app-large-directory-r4-second-activities.json。后续冷恢复未执行，两安装清理通过，owned stack stopped。不能将首次安装通过扩展成跨安装通过。测试遍历对已验ID仍重复查询名字；下一轮仅跳过已经精确验证的ID/name组合并记录末尾未验集合，完整258断言和原时间限制保持不变。

- R5已实际启动（exec会话98882、进程28050），注册功能完成并保留原审计失败，进入首次冷恢复；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.q2BNlX，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-bvk92r_l，日志 /tmp/imv2-acceptance-app-large-directory-ui-r5-20261009.log。当前仅运行证据，不计通过。

- R5终态exit1：首次遍历5分钟超时，最后251/258，3页已加载；未验集合按夹具UUID排序为第64及253..258行，明确末尾6行未核对。测试使用末行isHittable作为反向条件，早于实际名字核对。摘要 /tmp/imv2-app-large-directory-r5-first-summary.json、活动 /tmp/imv2-app-large-directory-r5-first-activities.json；两范围清理结束且owned stack stopped。保留R4首次通过，不声称稳定。下一轮只排除已验行的重复AX查询，对可见新行等待精确名称2秒，并以末行ID/name已验才反向；完整258断言、两次加载更多和原5分钟上限不变。

- R6实际启动且已编译进入首次冷恢复（exec会话85992，xcode进程30498）；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.bfqMLq，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-u_yvtzi8，日志 /tmp/imv2-acceptance-app-large-directory-ui-r6-20261009.log。未有终态，不计通过。

- R6首次冷恢复终态通过：完整258原成员ID/name、加载更多2次/3页、功能完成标记均通过，1测试0失败0跳过，xcode elapsed298.030秒。摘要 /tmp/imv2-app-large-directory-r6-first-summary.json 与活动 /tmp/imv2-app-large-directory-r6-first-activities.json。第二安装真实登录读取已开始，仍须独立核对，不能提前判跨安装通过。

- R6终态exit1：首次通过；第二安装实际已核对258/258、两次加载更多、最终集合/名称断言及功能标记完成，但随后Terminate App发生5分钟超时，XCTest整项仍Failed，后续第二安装冷恢复未执行。5测试3通过2失败0跳过（含原注册审计），两范围清理通过、owned stack stopped。完整汇总 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.bfqMLq/all-stage-summary.json；第二安装摘要 /tmp/imv2-app-large-directory-r6-second-summary.json、活动 /tmp/imv2-app-large-directory-r6-second-activities.json。测试末尾去除昂贵全App快照，改存精确已验ID/name集合；去除重复App terminate，脚本每阶段launch --terminate-running-process仍确保冷启动。原集合和时间上限不变，后续真实重跑验证。

- R7已启动，exec会话54045，日志 /tmp/imv2-acceptance-app-large-directory-ui-r7-20261009.log。不得用R6的功能标记替代整项Passed，仍实际重跑三个目录阶段。

### 20261009-app-native-background-upload-preparation（已准备，未验收）

- 新增独占后台上传模式，只准备本轮Files本地提供方目录内512KiB普通文件；App经系统文件选择器、既有附件准备及消息发送入口推进，未注入业务消息、凭据或已上传资源。测试要求观察真实后台授权PUT开始、Home后实际runningBackgroundSuspended，再释放本轮有界网络观察；真实provider仍验证签名并持久化，观察输出只含字节/校验/完成状态计数。
- 后续必须验证真实服务端唯一原消息、completed上传与available媒体，正常冷启动App同原UUID正文及附件。失败时仅清理随机测试范围和自身Files目录，网络等待180秒有界。Shell/Python语法、diff检查通过；新增UI测试已随R6清理阶段编译，但尚未运行后台功能，不作为EX22通过证据。原系统后台下载实现缺口保留。

- R7终态exit1：首次遍历末次progress231/258、真实3页已加载，随后仍在向下短拖动，统一5分钟预算截断。未达到全部集合断言，不能算通过；第二安装及冷恢复未执行。2清理通过、2失败（含注册审计）、0跳过，owned stack stopped。摘要 /tmp/imv2-app-large-directory-r7-first-summary.json、活动 /tmp/imv2-app-large-directory-r7-first-activities.json、完整汇总 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.RDSzY3/all-stage-summary.json。
- 5分钟为脚本统一观察预算，不是用户要求的功能时延指标；258成员的逐行远程AX核对已实际接近此预算。仅三个大目录用例调整为600秒有界执行，驱动总观察2400秒；其他用例300秒不变。原全部成员ID/名称、实际3页、真实两设备登录和正常冷恢复范围均不变。此调整不宣称客户端或服务端性能提升，历史超时继续保留。后台真实链路先执行，随后使用明确目录预算复测跨安装冷恢复。

- 后台R1实际执行后终态exit1：普通注册建群功能完成，原审计失败保留；准备Files文件时simctl单组容器形式返回usage/117（帮助虽列出此形式），未进入附件测试。groups清单形式已实际读出唯一FileProvider.LocalStorage容器，驱动改为精确解析该清单，保留拥有设备和目录边界校验。两范围清理通过、owned stack stopped。日志 /tmp/imv2-acceptance-app-native-background-upload-ui-r1-20261009.log，结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.OY8Mf5。此为测试文件准备失败，不算真实上传业务失败，EX22仍待验。

- 后台R2已实际进入testRealAppUploadsAttachmentWhileSuspended（exec41825、xcode36189），Files清单准备文件成功。结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.MjQ5i9，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-rjuhb0jc；日志 /tmp/imv2-acceptance-app-native-background-upload-ui-r2-20261009.log。网络等待释放前只读核对本次mediaID的active系统任务映射与awaitingBackground任务，不读取凭据或原请求BLOB。此轮未终态，不计通过。

- 后台R2终态exit1：新测试错误地用TextView查找v2.message.draft，实际现有实现及其他已通过用例均用TextField；等待15秒失败，还未打开文件选择器或发起上传。摘要 /tmp/imv2-app-native-background-upload-r2-summary.json、活动 /tmp/imv2-app-native-background-upload-r2-activities.json；服务观察backgroundRequests0/foregroundHits0、持久化映射0。两范围清理通过、owned stack stopped，本轮Files随机目录已删除。仅修正新测试输入框定位，不改生产UI；此失败不算业务上传失败。

- 后台R3已启动，exec会话64445，日志 /tmp/imv2-acceptance-app-native-background-upload-ui-r3-20261009.log。输入框定位修正后仍必须通过普通系统文件选择器和完整挂起/映射/字节/持久化/冷恢复链路；未有终态结论。

- 后台R3终态exit1：已打开普通系统文件选择器，真实FileProvider.LocalStorage根目录有本轮精确文件夹及1项；点击文件夹长名称后仍在根目录，等待background-upload文件名10秒失败，未发起任何上传。完整实际层级 /tmp/imv2-background-upload-r3-attachments/53F43F9E-EF89-4D5B-8395-1EDA3072C8CC.txt 与自留picker附件，摘要 /tmp/imv2-app-native-background-upload-r3-summary.json、活动 /tmp/imv2-app-native-background-upload-r3-activities.json。选择器将文件夹暴露为带Folder后缀的Cell和独立Image图标，下一轮用已观察到的Cell/图标点击，同时避免误点本地位置标题。仍经普通文件选择器，无资源注入；两范围清理及本轮文件删除、owned stack stopped。

- 后台R4终态exit1：普通Files文件夹图标点击已进入目录，background-upload文件Cell存在且可点击；其缩略图Image可点击断言失败，尚未选择文件或请求上传，服务观察仍全0。摘要 /tmp/imv2-app-native-background-upload-r4-summary.json、活动 /tmp/imv2-app-native-background-upload-r4-activities.json。下一轮改用实际已确认可点击的文件Cell，并自留选择前界面；不变更生产导入/上传路径。两范围清理和本轮文件删除通过、owned stack stopped。

- 后台R5已实际启动，exec49817，日志 /tmp/imv2-acceptance-app-native-background-upload-ui-r5-20261009.log，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-aiql5qsd。普通Files文件Cell点击后仍需真实导入、系统任务映射/挂起、字节和原消息冷恢复验证，未有业务通过结论。

- 后台R5终态exit1：真实Files导入512KiB、普通发送、后台授权PUT及App runningBackgroundSuspended断言均已实际执行；释放等待后真实provider返回204，完整524288字节和校验一致。随后durableActiveMappings0断言失败，原消息冷恢复未执行。源码确认URL顶层mediaID是不可变分片ID，grant.mediaID.rawValue才是整资源ID；探针错误使用前者查询SQLite，0不能证明映射缺失。修正为原资源ID和partNumber关联，并用两个不同UUID及隔离SQLite验证查询正确；此探针回归不替代App验收。摘要 /tmp/imv2-app-native-background-upload-r5-summary.json、活动 /tmp/imv2-app-native-background-upload-r5-activities.json、服务 background-upload-observation.json。两范围清理与文件删除完成、owned stack stopped。EX22仅增加已观察局部证据，未判整链路通过。

- 后台R6终态exit1：真实App挂起、原资源active映射1、后台PUT524288字节/校验/204均通过，最终正文StaticText查询失败。生产V2ConversationUI正文使用独立accessibilityElement包装，并非StaticText；改为任意类型节点，保留精确identifier/正文断言。原消息冷恢复未执行；两范围清理通过、owned stack stopped。摘要 /tmp/imv2-app-native-background-upload-r6-summary.json、活动 /tmp/imv2-app-native-background-upload-r6-activities.json；不将局部成功计为整链路通过。

- 后台R7两个功能阶段均Passed/1通过/0失败/0跳过：真实App挂起、原资源持久化任务映射1、后台PUT524288字节/校验/204；独立PG唯一原消息01a11d77-962a-7f7d-901c-febc1cb4d56a、completed上传1、available媒体1；正常冷启动恢复同原UUID精确正文及附件通过。摘要 /tmp/imv2-app-native-background-upload-r7-upload-summary.json 和 /tmp/imv2-app-native-background-upload-r7-cold-summary.json，事实 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.Ub4pdP/background-message-facts.json 与 background-upload-observation.json。原注册无障碍审计失败保留，因此驱动整体不算全绿；系统后台下载未实现。

- 后台R7整轮已退出1，仅注册审计失败，5测试4通过1失败0跳过；两个后台功能和两范围清理均通过、owned stack stopped。完整汇总 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.Ub4pdP/all-stage-summary.json。
- 目录R8实际启动并进入首次冷恢复（exec82405，驱动43264，Xcode43764已确认运行），采用明确600秒目录观察预算；结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.3FRxWQ，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-ku7ribte，日志 /tmp/imv2-acceptance-app-large-directory-ui-r8-20261009.log。尚未终态，不计通过。完整矩阵与manifest核对56项、无缺失或重复编号，所有证据索引均存在。

- 20261009验收证据完整性复核：矩阵保留OP01..32和EX01..24共56项，无缺号/重复；manifest引用52个run键全部存在，引用的绝对路径记录均仍存在。重新读取资源R7原日志，8个真实用例仅群头像用途422失败，其余各命名用例有真实Passed记录；此整体Failed未改为Passed。重新核对实际App后台下载组装及NativeBackgroundSession源码，仅上传使用uploadTask，下载仍dataTask；EX22不扩展为系统后台下载通过。目录R8仍为首次冷恢复进行中（驱动43264/Xcode43764已实时确认），截图 /tmp/imv2-app-large-directory-r8-first-live.png，未计算为通过。

- 目录R8首次安装正常冷恢复已通过：XCTest1通过0失败0跳过，原258成员ID/精确名字、实际两次加载更多和完整集合断言均保留；Xcode elapsed300.951秒。摘要 /tmp/imv2-app-large-directory-r8-first-summary.json、活动 /tmp/imv2-app-large-directory-r8-first-activities.json。第二安装真实登录读取已进入（驱动43264、Xcode44777），正常第二安装冷恢复仍待运行，不能按首次通过关闭EX15。

- 20261009 EX23边界复核：liveAccountUIR6/headless-summary.json实际platform为iOS Simulator，1测试通过0失败0跳过，仅证明App headless Push入口；不证明外部APNs或真机唤醒。IMApp/Config/IMApp.entitlements的aps-environment为构建变量，GatewayMaintenanceAssembly只在apns配置下组装真实provider；源码存在不等于实际签名或服务端凭据可用。真实设备与测试环境确认仍未收到，未在未指定的物理设备上安装或发送Push。目录R8第二登录Xcode44777仍运行；保持原任务，不重复启动。

- 目录R8第二安装真实密码登录读取已通过：XCTest1通过0失败0跳过，完整258成员ID/name及两次加载更多断言，Xcode elapsed310.012秒。摘要 /tmp/imv2-app-large-directory-r8-second-summary.json、活动 /tmp/imv2-app-large-directory-r8-second-activities.json。第三阶段正常第二安装冷启动恢复已开始（驱动43264/Xcode46162），尚无终态；此前超时保留，不将前两阶段通过扩展成整个跨安装冷恢复通过。

- 目录R8终态：三个功能阶段每项Passed/1通过/0失败/0跳过，首次正常冷恢复300.951秒、第二安装真实密码登录310.012秒、第二安装正常冷恢复303.644秒；全部核对258原ID/精确名字、3页/两次加载更多。独立PG directory-device-facts.json设备数2，directory-members.json原集合258。整轮6测试5通过1注册无障碍审计失败0跳过、exit1；两个随机范围清理通过、owned stack stopped。第三阶段摘要 /tmp/imv2-app-large-directory-r8-cold-summary.json、活动 /tmp/imv2-app-large-directory-r8-cold-activities.json，完整汇总 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.3FRxWQ/all-stage-summary.json。历史R1..R7超时/定位错误保留；600秒为明确功能测试预算，实际约5分钟是逐行远程AX验收耗时，未宣称业务接口性能改善。EX15更新完整跨安装冷恢复证据。

- 20261009真实APNs环境审计：当前security只计数得到有效签名身份2；新devicectl清单物理设备5 unavailable/2 disconnected，connected的3条为simulated，没有已连接物理iPhone。当前测试进程六项Push/APNs配置均未设置；这不推定整机其他位置没有凭据，也不把签名身份存在视为entitlement/provisioning通过。证据 /tmp/imv2-acceptance-device-inventory-final-20261009.json。真实设备及配置位置的用户确认仍未收到，未操作未指定真机或发送APNs。所有本轮拥有的原服务/Xcode任务已结束；EX23仍待验。

- 20261009任务阻塞审计第三轮：新清单 /tmp/imv2-acceptance-device-inventory-blocked-20261009.json 再次确认已连接物理设备0，当前测试进程Push/APNs六项配置0；未收到指定真机及测试配置位置的确认，没有本轮拥有的测试进程仍运行。同一剩余真机APNs环境条件连续三轮未改变，任务标记blocked，完整56项范围、真实失败及已通过功能均保留，未标记整体完成。恢复条件为提供本轮可用真机和App签名/APNs测试环境；不要求在聊天中提交私钥或设备令牌。

### 20261009-acceptance-repair（进行中）

用户新目标为根据验收表修复问题，并通过本机模拟环境验证。保留此前真实失败证据，在各项修复及相应实测完成后再更新矩阵。完整修复范围：

- OP08主动退群；OP32群头像用途及授权/展示。
- EX03首次退出及EX06账号切换；EX08发送者持久拒绝提示；EX12私聊离线自动重放。
- EX18冷订阅后的typing投递；EX20规模重连及在线提示波动。
- EX22系统后台下载；EX23本机模拟Push/APNs请求与App唤醒路径（不声称真实APNs送达）。
- EX24动态字体/文本裁剪/点击区/对比度审计、邀请冷启动深链接、批准成员发送后的即时正文投影。

首次登出修复：V2SignedInRootView离开时取消页面signOutTask，而V2AppStore.signOut先切换route并随后检查取消，导致普通退出停在pending删除。新增App Store持有的单飞用户退出任务，UI仅提交请求，页面消失不取消账户收尾；既有受保护数据及失败marker保留。账号切换真实UI用例移除补偿重试，明确要求第一次退出成功。取消发起页面任务/重复点击的单元回归已加入。

单位回归R1编译通过，16通过6失败0跳过；6项Keychain失败均为本轮CODE_SIGNING_ALLOWED=NO导致unexpectedStatus(-34018)，不视为产品通过。R2恢复默认签名，exec18169，/tmp/imv2-fix-signout-unit-r2-20261009.log，尚未终态。

- 首次登出修复单元R2恢复默认签名后22通过0失败0跳过，摘要 /tmp/imv2-fix-signout-unit-r2-summary.json。真实App修复R1已启动，exec94792/驱动65141/Xcode65710，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-ioszyjgl，结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.C7z00e，日志 /tmp/imv2-fix-signout-app-r1-20261009.log；实际账号切换要求首次退出直接成功，不允许旧补偿重试。注册无障碍失败继续保留，整体尚未有终态。

- 首次退出修复App R1已完成：真实A→B→A普通登录/两次首次退出、两账号内容隔离和正常冷恢复通过，1功能测试0失败0跳过，Xcode elapsed96.530秒；用例明确断言没有pending重试入口，manual-retry标记0，功能标记1。摘要 /tmp/imv2-fix-signout-app-r1-summary.json、活动 /tmp/imv2-fix-signout-app-r1-activities.json。整轮4测试3通过1注册无障碍审计失败0跳过，exit1，两个测试范围清理和owned stack stopped。EX03/EX06补修复后通过证据，原失败和审计失败保留；其他修复项仍未完成。

- 私聊离线重放修复已实现、实测进行中：未开始网络提交的缺连接错误改为waitingForNetwork；认证连接拥有的恢复worker观察等待任务头的原身份/修订，处理恢复前已有等待、恢复后迟到及连续回调，避免仅Bool去重吞掉ready→parked变更。只唤醒本账号的缺连接/待认证状态（含旧版对应needsAttention）；保留冻结命令、首提截止期和submit/reconcile动作，恢复时建立新的有限尝试轮次。容量已满单独busyBeforeSubmission有退避，不当作断网无限重置预算；未知结果、拒绝和指纹冲突不按联网事件自动重试。
- 回归R1因新增夹具API引用及actor复合读取编译失败已修正，原日志保留；R2发送工作13项通过。最终R3共18项/2套件通过，包含SQLite冷重开原命令、恢复前/后/连续入队时序、旧暂停任务及未知/容量错误边界；/tmp/imv2-fix-offline-work-r3-20261009.log。真实双安装App R1已启动，exec13452，服务 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-rwohad_p，日志 /tmp/imv2-fix-offline-app-r1-20261009.log，尚未终态，EX12旧失败保留。

- 私聊离线修复App R1已终态exit1：离线普通UI入队、发送者正常冷恢复和最后接收者恢复阶段均通过；最后阶段testReceiverRestoresIndependentGroupMemberReply原xcresult摘要为1通过0失败0跳过。整轮仍保留3个无障碍审计失败阶段，不宣称全绿；两个范围清理完成，owned stack stopped。原结果目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.nWdkUn，进一步独立事实核对和矩阵更新仍待完成。

- EX08根因确认：operation标量路径遇到私聊限制直接抛出且回滚savepoint，旧私有时间线/能力投影未提交。修复将私有提示与拒绝操作结果分离：只保留timeline_activity和能力变化，不写direct_message_denials/成功记录，查询拒绝操作仍unresolved；提示使用room/sender/clientMessage三元组派生的稳定身份去重，同一命令重试无重复，新的受限命令可生成新提示以满足后台恢复验收。拒绝后的房间内存游标失效，避免私有时间线推进后使用旧缓存。
- 数据库回归R1按限制周期去重通过，但核对现有后台App验收要求新命令产生新提示，已改为按原命令身份去重，不采用R1设计。最终R2正在独立本机双数据库执行，session86912，日志 /tmp/imv2-fix-restriction-pg-r2-20261009.log。真实账号/双Gateway/SQLite重开及App后台提示R1已启动，session19458，日志 /tmp/imv2-fix-restriction-live-r1-20261009.log，结果 /tmp/imv2-fix-restriction-live-r1-20261009；两项均未终态，EX08不计通过。
- EX08最终数据库R2终态exit0，1测试/1套件通过，0.829秒；同一消息重试去重、不同消息两条私有提示、对方0提示、无拒绝/成功/消息持久结果、恢复查询unresolved全部通过。owned postgres stopped。真实账号与App R1仍运行（session19458/驱动73294），不得按数据库局部通过关闭EX08。
- EX08真实账号/App R1终态exit1：5个HTTPS SDK测试通过；原提示SQLite重开/重连及真实App冷恢复、精确原提示只显示一次、3次后台生成不同命令提示再回前台均通过（IMV2_THREE_FOREGROUND_RECOVERY_CYCLES_PASSED）。私聊整用例随后在另Gateway的account_room_changes_start收到UNAVAILABLE失败，Journal authority同时记录coverageChanged；尚未证明此波动的完整原因，不缩减跨Gateway范围。两项真实App撤销用例各通过（38.724/39.172秒）；整UI为2通过1失败0跳过。摘要 /tmp/imv2-fix-restriction-live-r1-summary.json、活动 /tmp/imv2-fix-restriction-live-r1-activities.json、原日志 /tmp/imv2-fix-restriction-live-r1-20261009/app.log。测试范围清理、专用模拟器移除已完成，拥有进程确认不存在。EX08仅记局部修复证据，后续需解决目录Ready波动后完整复测。
- EX08后续UNAVAILABLE根因细化：Registry的start仅观察账号拥有的异步bootstrap，未完成时按正式协议返回retryable UNAVAILABLE；真实账号用例旧代码仅请求一次。验收驱动改为10秒有界重试同一幂等start，只处理此明确可重试错误并保留Ready/跨Gateway消息/解除拉黑全部断言；不改变生产传输或伪造Ready。R2完整私聊用例已通过36.175秒，两个start实际attempts1/2；另外撤销与整轮清理尚待终态，session22070，日志 /tmp/imv2-fix-restriction-live-r2-20261009.log。
- OP32修复：V2ResourceService开启头像能力时声明groupAvatar，并移除入口无条件unsupportedCapability。保留路由Actor群主授权、事务内结构群主/角色/修订复核和能力关闭拒绝。数据库上传权限验收改为经过真正service而非直接调用持久Store，覆盖valid/disabled/owner-before/role-before/owner-after/role-after。本机隔离PG整套17测试通过（1.382秒），/tmp/imv2-fix-group-avatar-pg-r1-20261009.log；原字节上传/展示/移除/恢复真实HTTPS/TCP整套正在运行session2953，日志 /tmp/imv2-fix-group-avatar-live-r1-20261009.log，未关闭OP32。
- EX08真实R2终态exit0：5个HTTPS SDK测试通过；完整私聊限制/SQLite重开/原提示App冷恢复/三次后台新提示/跨Gateway多设备/解除拉黑后发送用例36.175秒通过，listener真实Ready attempts1/2。两项App撤销回归40.508/39.371秒通过；整UI3通过0失败1跳过（未启用B07_SCENE_RETRY专项，不以此证明EX12）。摘要 /tmp/imv2-fix-restriction-live-r2-summary.json、活动 /tmp/imv2-fix-restriction-live-r2-activities.json；范围清理和专用模拟器移除完成。EX08更新修复后通过，原R1及历史失败保留；这不是EX20规模重连全项通过证据。
- OP32真实资源R1终态exit0：实际群头像上传/图片处理/set/128px字节校验/download/remove/原操作recover用例1.515秒通过。整资源11个命名用例实际执行通过，2个独立opt-in（大昵称目录、slowResource）跳过，Swift Testing汇总13项/1套件passed18.723秒；不将跳过专项计为通过。原summary.clientExitCode0/requiredTestPassed=true；HTTP三次资源上传创建/最终化200和签名PUT204，群头像GET/POST/recovery200，独立PG resourceFacts保留，owned-service cleanup完成。证据 /tmp/imv2-fix-group-avatar-live-r1-20261009/client.log 与 summary.json；OP32修复后通过，保留旧422失败。

- OP08主动退出修复：仅允许remove自身，add自身仍由领域构造/解码拒绝；普通成员/管理员自退不要求移除他人权限，两处权威授权均禁止结构群主及owner角色移除。保留当前成员incarnation admission、修订检查、原操作回执重放/恢复。App独立退出确认入口，不放开管理/禁言自身；分页无需找到本人行即可自退，异步提交确认后清除旧权限，排队反馈不伪称已退出。核心3测试通过；隔离PG1测试/5参数通过2.017秒；最终模拟器Store2测试（自退3角色参数）通过，/tmp/imv2-self-exit-app-unit-r2-20261009.xcresult。真实HTTPS/TCP新用例1.165秒通过：群主拒绝、普通成员退出、原命令重放/query相同结果、名单移除、原已认证TCP发送立即拒绝；资源整套14命名测试汇总passed20.124秒，其中2独立opt-in跳过，实际12命名用例执行。证据 /tmp/imv2-self-exit-live-r1-20261009/client.log 与 summary.json，owned-service cleanup完成。普通App邀请加入后退出及冷恢复R1运行中session74881，服务根 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-e8xlr8k9，日志 /tmp/imv2-self-exit-app-live-r1-20261009.log；尚未关闭OP08。

- OP08普通App R1注册/建群功能完成，但该阶段真实无障碍审计仍失败：Dynamic Type font sizes are partially unsupported；原xcresult摘要 /tmp/imv2-self-exit-register-audit-r1-summary.json，未将失败改记通过。驱动按既有规则保留审计失败继续邀请/退群功能阶段，仍存活session74881/driver84206，不因首阶段失败重启。EX24仍需修复，OP08普通UI功能结论尚待后续终态。

- OP08普通App R1已终态exit1并清理owned stack；邀请创建、申请/取消/再次申请/审批通过，自退入口可见且打开确认弹层，但确认按钮节点的isHittable断言失败，尚未提交退出。原摘要 /tmp/imv2-self-exit-app-live-r1-leave-summary.json、活动 /tmp/imv2-self-exit-app-live-r1-leave-activities.json、录像提取 /tmp/imv2-self-exit-app-live-r1-confirmation.png 保留。改用原生alert含取消，UI测试定位实际UIAlert按钮。冷恢复增加已认证邀请预览（历史批准与当前成员区分）和独立SQLite原membership工作committed/finished检查，不把尚未恢复的空列表当证据。R2 session14995/root imv2-native-e2e-r71yd2nc 正在普通App流程。
- EX24会话空态/摘要搜索修复：实测定位两处系统ContentUnavailableView字体未随尺寸变化及UISearchBarTextField裁剪；替换为空态明确语义字体/可滚动布局、摘要搜索动态body字号/纵向扩展布局，清除按钮44点。原审计类别未删除。第二轮真实注册/会话/群详情/隐私与身份导航阶段passed1/failed0/skipped0，摘要 /tmp/imv2-self-exit-register-audit-r2-summary.json；不据此关闭整个EX24，其余主流程/对比度/深链/新成员即时投影仍待。

- OP08普通App R2终态exit1，owned stack stopped。注册/会话/群详情真实审计与邀请申请审批通过，自退仍停在原生alert确认按钮立即isHittable断言；未提交退群、不关闭OP08。摘要 /tmp/imv2-self-exit-app-live-r2-leave-summary.json、活动 /tmp/imv2-self-exit-app-live-r2-leave-activities.json。原录像精确15秒图 /tmp/imv2-self-exit-app-live-r2-confirmation-exact-15.png 确认alert两动作已显示；测试改为10秒有界等待hittable真实状态再点击，保留业务断言。R3运行session88818，日志 /tmp/imv2-self-exit-app-live-r3-20261009.log，继续完整普通邀请入群/退出/独立PG及SQLite/冷恢复范围。R2测试冷恢复预期按源代码修正：原批准历史仍存在，真实邀请预览应显示历史批准而非当前成员，不凭空要求旧邀请能重新申请；该阶段R2未执行，尚无通过证据。

- 提交前验证更新：OP08普通App R3已终态失败，失败阶段为testApplicantLeavesApprovedGroupThroughOrdinaryUI（passed0/failed1），尚不能关闭普通App退群验收；两安装清理阶段完成，owned stack stopped。原日志 /tmp/imv2-self-exit-app-live-r3-20261009.log，结果 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.yMY7Iq 保留。新增EX12只读身份验证脚本：离线原intent/冻结命令摘要、恢复后PG唯一消息与成功记录、双端SQLite投影关联；仅语法验证通过，完整原链路尚未运行，不计为验收通过。提交前git diff --check、shell bash -n、两Python文件py_compile通过。

- OP08普通App R4终态exit0：移除原生Alert动作上的SwiftUI accessibilityIdentifier后，实际按钮frame(205,473,140,48)、enabled/hittable均true；真实点击及退出反馈通过，PG成员由2降为1，原membership工作committed/finished，普通冷启动邀请预览保留历史批准但不显示当前成员，会话刷新后原群不存在。完整普通注册/邀请申请取消再申请审批/退出/冷恢复流程及两安装清理通过，owned stack stopped。证据 /tmp/imv2-self-exit-app-live-r4-summary.json、/tmp/imv2-self-exit-app-live-r4-20261009.log；保留R1/R2/R3失败，不把它们改记通过。EX12读取脚本隔离SQLite校验通过（原身份/恢复投影/冻结命令变化拒绝），仍待真实App完整链路。

- EX12原身份完整双安装R2已启动session32682，日志 /tmp/imv2-offline-original-app-r2-20261009.log；沿普通私聊发送/离线入队/冷恢复验证原intent、冻结命令、PG唯一消息及成功记录、双端独立SQLite投影，尚未有终态结论。

- EX12原身份双安装R2终态exit1，owned stack stopped：普通离线入队阶段通过，独立脚本误按旧单文件布局查找，实际账号隔离目录为sync-local-e2e-<scope>.sqlite.accounts/<账号目录>/V2.sqlite，因此身份/唯一性尚未证明。脚本改为只匹配本scope账号根并要求唯一V2.sqlite。私聊两阶段真实AX失败保留，发送端附件定位作者展示节点与暂无消息空态；改为combine可见文本语义及明确动态字体空态，尚待复验。冷邀请链接任务改为已登录页面挂载后拥有.task(id:URL)，保留待处理URL直到预览完成；新增OS openurl专项待执行。

- EX12原身份R3终态exit1并清理：发送前作者标题仍Dynamic Type失败，空态标题已不在失败附件，但新说明文字低对比度导致contrast抛出并提前结束，未运行离线核对。改为说明primary，导航principal显式沿用内容页dynamicTypeSize，避免导航宿主覆盖字号。R4 session37877启动，日志 /tmp/imv2-offline-original-app-r4-20261009.log；原失败保留，不删除审计类别。

- EX12原身份App R4终态exit1（2个真实AX失败，0撤回投影失败），owned stack stopped。关键业务独立证明通过：原intent/clientMessageID/roomID/immutableDigest与冻结commandDigest恢复前后相同；原工作awaitingConfirmation/waitingForNetwork转committed/finished；PG原消息1、该房间q消息1、原成功记录1；双方独立SQLite同一messageID、seq5、revision1未撤回且各仅1行。证据 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.JhjdYg/offline-{original,restored-sender,restored-receiver,pg-facts}.json；未以功能通过掩盖整UI失败。导航字号传递仍未解决principal名称DynamicType/裁剪，改为装饰头像留导航栏、可展开的授权作者名放内容区；消息时间44点区域；待复验。

- EX24冷恢复邀请链接专项R1已启动session73145，日志 /tmp/imv2-cold-invite-app-r1-20261009.log；真实二维码识别原链接，正常账号cold restore启动后立即OS openurl，普通申请按钮与PG pending证明，不注入预览状态；尚未终态。

- 冷邀请R1终态exit1、owned stack stopped：预览标题30秒未出现，原结果hOiSbU保留。UI树显示原App消息列表及隐私遮罩；指定模拟器已安装App中iim scheme仅com.stskcxfz.imapp一个处理者，排除另一安装接管。进一步将已登录页面邀请任务绑定scenePhase active，inactive期间保留URL，取消预览后活跃再处理；尚待实际复验，不将推断当确定根因。

- 冷邀请R2终态exit1、owned stack stopped，预览未出现；scene active gating未被证明确实解决。新路由日志在初始安装后才加入，不能凭无日志认定onOpenURL未调用。查阅本机Xcode XCUIApplication.h确认openURL同步启动并携带真实URL，R3改为测试内app.open(url)+原scope restore启动参数，避免外部投递发生在测试启动安装之前；不是注入预览状态。R3 session76738运行，日志 /tmp/imv2-cold-invite-app-r3-20261009.log，仍待终态。

- EX24冷邀请R3终态exit0，6 UI阶段0失败0跳过，owned stack stopped。XCTest官方app.open真实二维码URL同时冷启动原scope；路由日志10:06:03收到URL/活跃、10:06:03.703已登录页面打开、10:06:04.077预览返回未取消且presenting。普通申请按钮提交后PG pending1/members1，与原二维码群一致；摘要 /tmp/imv2-cold-invite-app-r3-summary.json，原结果KwkpCJ/first-pending-join-facts.json。关闭冷URL启动缺口，保留外部simctl投递R1/R2失败；不关闭整个EX24。

- 完整双安装R5运行session21947，日志 /tmp/imv2-offline-original-app-r5-20261009.log，验证最新作者内容区/导航装饰头像、时间44点、私聊控制操作/群双向/离线原身份及全部既有AX类别；不将冷邀请专项替代这套完整回归。

- 完整双安装R5终态exit1，owned stack stopped：发送端私聊全部AX/控制操作通过；接收端仅时间文字hitRegion失败，其余字号/裁剪通过；独立离线原identity/commandDigest/PG唯一性/双端投影再次通过。将整行contextMenu改挂到消息气泡，时间保持只读；R6启动日志 /tmp/imv2-offline-original-app-r6-20261009.log，原审计不删。EX18开始修复：registry取得原generation/lifecycle的typing票据并等待实际跨节点interest激活后再返回ACK，正常恢复复用票据；失败清理本mutation、拒绝成功ACK。Coordinator13项/网关59项回归通过；真实TLS立即ACK后typing start/stop（不先等Coverage Ready）R1 session44023运行，尚未关闭EX18。

- EX18真实TLS R1终态exit0：立即订阅ACK后发布开始/停止，收到两项真实typing事件后才验证Coverage Ready；directUniquenessPresenceTypingAcceptance实际通过，日志 /tmp/imv2-typing-ack-live-r1-20261009/client.log。此入口两客户端使用同一Gateway，不能替代跨两个Gateway专项证明。最终撤销边界R2实际1测试/2参数通过：激活期间撤销原lifecycle后拒绝ACK并清理票据；日志 /tmp/imv2-typing-ack-revocation-r2-20261009.log。

- 双安装R6终态exit1，owned stack stopped：全部功能阶段及离线原身份/PG唯一性/双端投影通过，保留1个接收端AX hitRegion失败，元素截图仍为时间10:13。仅移动contextMenu未解决。时间改为隐藏视觉Text并通过44点语义容器提供本地化时间label，原全部审计保留；R7运行session74724，日志 /tmp/imv2-offline-original-app-r7-20261009.log，尚未终态。

- 双安装R7终态exit1、owned stack stopped：离线身份/PG唯一性/两端投影通过，接收端时间10:19仍有1项hitRegion失败（原结果i1WkFA）。44点容器未解决原Text节点；改为正文accessibilityValue读出时间，纯附件由摘要读出时间，视觉时间不重复成为小节点。接收端新增断言原正文value非空，全部审计保留，R8启动日志 /tmp/imv2-offline-original-app-r8-20261009.log。

- 双安装R8终态exit0，全部9 UI阶段各1通过/0失败/0跳过、owned stack stopped。正文保留非空时间accessibilityValue，原完整AX和contrast通过；私聊编辑/撤回、群双向/提及、普通离线原身份重放、PG唯一消息/成功记录及两端唯一投影全部通过。摘要 /tmp/imv2-offline-original-app-r8-summary.json，日志 /tmp/imv2-offline-original-app-r8-20261009.log。EX24作者字号/裁剪/时间触达缺口修复验证通过，批准入群即时正文仍待R5原流程复验，不关闭整个EX24。

- ClientKit全量R1终态失败：1040项/172套件、3 issues；日志 /tmp/imv2-client-full-regression-20261009-r1.log。定位旧HTTP send断言、旧schema指纹（独立比对两真实SQLite schema仅3处成员版本约束>0改>=0）和expired unresolved后自动claim旧假设。移除已退役两HTTP策略，保留全量服务端路由登记检查并禁止旧路径；更新明确schema指纹；恢复测试保留原身份替换禁令并验证needsAttention/显式继续/原query结果。专项R1运行，尚未通过。

- ClientKit修复专项R1终态exit0：8项/3套件通过，日志 /tmp/imv2-client-contract-repair-20261009-r1.log。重新运行全量R2（/tmp/imv2-client-full-regression-20261009-r2.log），未用专项通过代替全量通过。批准成员即时投影R5普通App流程运行 /tmp/imv2-approved-member-live-projection-r5-20261009.log。

- ClientKit全量修复后R2终态exit0：Swift Testing汇总1040项/172套件通过，171.291秒，日志 /tmp/imv2-client-full-regression-20261009-r2.log。真实环境opt-in用例默认禁用，另有真实TLS/App专项证据；不将全量单元汇总当作所有真实环境专项执行证明。原R1的3项失败记录保留。

- 批准成员即时投影R5终态exit1、owned stack stopped，仍在testApplicantRestoresApprovedGroupAndSendsMessage等待原正文30秒失败。实际UI树正文完整位于accepted pending区域，时间线暂无消息、实时覆盖恢复中；PG唯一原消息accepted、roomHead3，不能归因输入截断。证据 /tmp/imv2-approved-member-r5-all-attachments/31D3E488-5688-457D-A9C2-A287BF8B3493.txt、/tmp/imv2-approved-member-live-projection-r5-20261009.log。新增只读精确scope房间恢复快照，清理前采集授权/成员/游标/恢复工作/原send接受ID，不输出凭据、命令及回执内容；真实schema查询与错误scope拒绝校验通过，shell语法/diff检查通过。R6 session79126运行 /tmp/imv2-approved-member-live-projection-r6-20261009.log，尚未终态。

- 批准成员即时投影R6终态exit0、owned stack stopped：原申请/取消/重申请/批准/正常恢复/发送/即时正文断言通过，PG原消息唯一、roomHead3；日志 /tmp/imv2-approved-member-live-projection-r6-20261009.log。同代码R5失败不删除，不能以单次通过关闭波动。R5服务端account_room_changes_start连续约70秒UNAVAILABLE，下一步定位覆盖bootstrap；R7原流程复测运行 /tmp/imv2-approved-member-live-projection-r7-20261009.log。

- 批准成员R7终态exit1、owned stack stopped，精确原scope快照成功：成员版本2且授权有效，原房间游标2，发送work committed/finished并确认accepted sequence3，但projectionObserved0、messages为空，room recovery等待state。个人游标已应用/确认1且ready；不能归因权限未恢复或消息未入库。证据 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/im-v2-local-two-install-e2e.bhwadF/failed-member-room-recovery.json。新增覆盖bootstrap阶段限频诊断（目录/Owner安装/Owner不可用重试），原账号服务23项通过、Gateway产品构建通过；R8原App流程使用新服务端复测 /tmp/imv2-approved-member-live-projection-r8-20261009.log。

- 批准成员R8终态exit1、owned stack stopped；实际限频日志elapsed35s/owner_retries645/owner_overloaded，Prometheus细分确认Owner catchUpRequired（busy/overloaded/pumpBindRefused均0），证据 /tmp/imv2-approved-member-r8-subscription-metrics-20261009.txt。进一步增加subscribe终止控制待确认/控制版本不一致/日志未追平三固定计数，未放宽权限或围栏。另修复详情页补拉失败被当作idle继而等待新通知的缺陷：失败保留durable-pull责任，采用已有退避并尊重服务器retryAfter，成功后仍等待通知；专项新增无通知首次失败重试测试已实际通过，整个xcodebuild终态仍待检查。

- Owner细分诊断相关回归R1终态exit0：68项/4套件通过，日志 /tmp/imv2-room-catchup-diagnostics-r1-20261009.log；Gateway产品构建exit0。App补拉修复R1实际135项/2套件汇总有1 issue：原periodicRecoveryStillPulls超时60秒，新增failedInitialRoomPullRetriesWithoutAnotherNotification实际1.423秒通过、整个ConversationStore套件通过。保留原断言，未用随后自动重试的0 tests输出充当通过；xcodebuild session45072仍活跃，待终态与该时序专项核对。新DerivedData构建因实际GitHub TLS取包失败主动终止exit143，改用已有依赖并禁止更新，不当作源码构建错误。

- 周期历史补拉旧测试单独R2仍超时，真实driver终态exit65（5项/1 issue）。源码9347d818明确activity refresh不得调度历史读取，消息补偿由账号runner与收到的head负责；旧测试仍无限等待不存在的timer wake。更新为观察两次实际roomCursor刷新后无消息wake、无重复载荷，保留原冷订阅/重连/成员撤销验证。R1原失败汇总后自动重试0 tests，主动结束owned driver exit143，未当作通过。R3命令test-iterations1被Xcode参数校验拒绝exit64、未执行测试；R4去掉该参数重新运行 /tmp/imv2-room-pull-retry-unit-r4-20261009.log。

- App补拉修复R4终态exit0：135项/2套件通过、2.152秒，新增无通知初始补拉失败重试1.377秒通过，周期活动刷新不唤醒历史0.330秒通过，日志 /tmp/imv2-room-pull-retry-unit-r4-20261009.log。测试编译期间补了run/nextWake的取消defer，因此最终测试源另用R5窄复测，不将R4覆盖后写出的清理行；R5日志 /tmp/imv2-room-subscription-app-unit-r5-20261009.log。

- App最终测试源R5终态exit0，5项/1套件通过（0.326秒），包含明确取消所属run/nextWake；原成员撤销、重连、宽限期租约及活动刷新无历史wake均保留。批准成员原真实流程R9 session85336运行，日志 /tmp/imv2-approved-member-live-projection-r9-20261009.log，使用补拉失败重试App及subscribeTerminalPending/subscribeControlCutMismatch/subscribeLogGap三固定计数的新服务端；尚未终态，不关闭EX24。

- 批准成员R9终态exit1、owned stack stopped，原流程仍即时正文失败；细分指标subscribeTerminalPending992、subscribeControlCutMismatch0、subscribeLogGap0，证据 /tmp/imv2-approved-member-r9-subscription-metrics-20261009.txt。确认旧授权终止ACK与新订阅之间的循环等待；详情页失败重试修复未单独消除此服务端缺陷。开始验证Gateway对同一已确认来源/围栏的终止控制在pause/expiry/local retirement后仍可实际应用并ACK，不能授予权限或延长有效期，旧围栏不得影响更高代次。

- 终止ACK确定性回归：首次测试编译被#expect宏的Sendable闭包限制拒绝，改成先求值再断言；R2旧实现实际1测试/3参数失败6次，均为pause/expiry/local retirement后无法应用/重复ACK终止控制，日志 /tmp/imv2-terminal-receipt-before-fix-r2-20261009.log。Gateway修复仅允许同一已知围栏及认证来源的terminal monotonic denial跨过已结束本地授权/缺失前序控制，保持拒绝普通授予/延长旧有效期、拒绝新围栏受旧terminal影响。专项4套件复测运行 /tmp/imv2-terminal-receipt-after-fix-r1-20261009.log。

- 终止ACK修复相关回归R1终态exit0：69项/4套件通过（0.867秒），暂停/过期/退休3参数实际ACK及重复ACK通过，原授权关闭/过期不可续/旧围栏不得影响新围栏继续验证。Gateway产品构建exit0，真实原批准成员流程R10运行 /tmp/imv2-approved-member-live-projection-r10-20261009.log，新增owned清理前固定订阅指标留存；未把单元回归当作真实App通过。

- 提交前证据核对：终止ACK网络回归通过，服务端34项/3套件及真实Cluster TCP 3项/1套件，日志 /tmp/imv2-terminal-receipt-network-regression-r1-20261009.log。真实批准成员R10日志显示PASS real two-install App messaging, offline recovery and group scenario及owned stack stopped，日志 /tmp/imv2-approved-member-live-projection-r10-20261009.log；原R5/R7/R8/R9失败记录保留，不以单次通过宣称稳定性验收完成。最终脚本owned Gateway存活检查仅完成Python语法校验，尚未单独运行复验。

- 批准入群即时投影R11终态exit0，原申请/取消/重申请/批准/正常恢复/发送/即时正文/独立PG核对及owned清理通过，日志 /tmp/imv2-approved-member-live-projection-r11-20261009.log；清理前指标subscribeTerminalPending/controlCutMismatch/logGap均0。修复后R10/R11连续通过，R9原terminalPending992的失败证据保留；最新脚本owned Gateway存活检查及指标留存实际运行通过。EX24这一缺口关闭，不将两轮通过泛化成任意长期稳定性保证。1000房间跨Gateway恢复及尾通知丢弃R14运行 /tmp/imv2-acceptance-room-scale-r14-20261009.log，尚未终态。

- 1000房间R14终态exit0：实际App 3项通过/0失败，原独立后台专项未启用跳过1，不将该跳过计入后台证明。真实第二Gateway在线更新、目标尾通知丢弃2次、无相关替代唤醒自动补回原消息/游标均通过，日志 /tmp/imv2-acceptance-room-scale-r14-20261009/app.log。独立PG/HTTPS校验通过，owned服务及PG停止、专用模拟器删除、私有临时材料清理通过，证据 /tmp/imv2-acceptance-room-scale-r14-20261009/cleanup.log；R13驱动清理错误修复得到实际运行验证。

- 系统Push实测R1终态exit1、owned stack stopped：实际App已挂起，本地初始room cursor1/messages为空；发送探针却仍走已移除HTTP消息提交，HTTP 404导致CalledProcessError，尚未执行simctl push。证据 /tmp/imv2-system-push-live-r1-20261009.log、独立root system-push-observation.json；不能把此失败归因OS唤醒。新增严格后台状态/原消息持久化断言的UI专项编译通过，准备将探针改为当前TCP messageSendOperation并校验原身份/指纹回执后复测。

- 系统Push R2终态exit1、owned stack stopped：TCP探针已实际发送，但Hello未声明supportsMessageSendOperations，服务端明确unsupported_command，PG messages为空、未执行系统Push。补齐消息能力协商并使用当前codec/原回执指纹验证；探针产品构建R3 exit0，日志 /tmp/imv2-system-push-probe-build-r3-20261009.log。R3真实UI流程运行 /tmp/imv2-system-push-live-r3-20261009.log，尚未终态。

- 系统Push R3/R4均exit1、owned stack stopped：消息能力协商已补齐，服务端实际处理message_send_operation但发送失败，PG原消息未落盘/未执行Push。R4固定阶段诊断确认tlsSend，未输出stderr、token或请求内容。探针进一步区分回执关联/类型/未决结果/身份指纹错误及安全错误码，构建R5 exit0；真实R5运行 /tmp/imv2-system-push-live-r5-20261009.log，尚未终态。

- 系统Push R5终态exit1、owned stack stopped，固定错误sendResponseCorrelation确认发送等待遇到非关联帧，PG仍无消息/未执行Push。当前真实负载客户端显式处理requestID0 realtimeCoverage，旧探针遗漏这一通知分支；补齐具体覆盖通知，不放宽发送应答请求号/原身份/指纹验证。探针构建R6 exit0，真实R6运行 /tmp/imv2-system-push-live-r6-20261009.log，尚未终态。

- 系统Push R6终态exit1、owned stack stopped：TCP原消息01a11ec4-779f-7b65-9203-4975dc86d2b0/sequence2唯一落盘，实际投递前App SQLite messages为空。发送修复已越过原失败点。simctl纯content-available载荷返回exit121/UNErrorDomain1401 Notification has no user visible content；独立同命令复现。驱动此前因非零返回提前结束，尚无实际后台结果证据；不能宣称OS回调成功或失败。R7保留此具体可见通知错误，继续实际原消息/游标观察，UI不得进入前台；其他工具错误仍失败，未加入alert或手动代理调用。日志 /tmp/imv2-system-push-live-r7-20261009.log。

- 系统Push R7终态exit1，owned stack stopped：真实TCP原消息01a11ec8-08ec-74b9-b9d0-e31395208ee3/sequence2已提交，投递前App SQLite仍为空；保留simctl exit121/1401后继续观察45秒，未出现后台原消息持久化，最终TimeoutError。日志 /tmp/imv2-system-push-live-r7-20261009.log。后续OS日志显示App without push registration；本轮UI尚未通过普通设置开启Push，需补齐注册前置后复验，不能据此认定模拟器不支持。构建产物Simulated.xcent包含aps-environment=development，普通模拟器签名无entitlements不足以判定能力缺失；系统Push验收仍未通过。

- 系统Push R8终态exit1、owned stack stopped：新增普通设置开启前置与实际注册状态展示后，UI最终仍显示后台同步唤醒已关闭，尚未启动消息/系统Push。外层SwiftUI Toggle点击未改变设置；改用已有隐私UI测试的内层Switch点击。日志 /tmp/imv2-system-push-live-r8-20261009.log，原结果保留，不判定OS注册失败。

- 系统Push R9终态exit1、owned stack stopped：普通隐私UI内层Switch开启成功，注册状态已就绪且系统确认令牌注册；App实际挂起。原TCP消息01a11ed3-d110-76f0-89e6-6a541a81cc04/sequence2落盘，45秒未后台投影。OS固定原因RequestDenied/Disabled：app does not declare proper UIBackgroundMode；安装包实查UIBackgroundModes含remote-notification。保留失败，下一轮补充fetch模式诊断且增加真实远程通知回调固定标记，不以其他回调替代验收。日志 /tmp/imv2-system-push-live-r9-20261009.log。

- 系统Push R10终态exit1、owned stack stopped：普通UI注册已就绪、系统挂起、原TCP消息01a11ed7-246a-704b-a06e-cbb26e3f937e/sequence2提交均通过，45秒后台投影超时。补充fetch模式后启动拒绝消失，但OS明确发送UIFetchContentInBackgroundAction、执行SBBackgroundFetchTask并返回NoNewDataAvailable；远程通知委托固定标记不存在。证据 /tmp/imv2-system-push-r10-fetch.log、/tmp/imv2-system-push-r10-delegate.log。撤回实验fetch模式，不增加performFetch替代处理骗过Push验收；保留普通注册前置、可访问注册状态及远程通知无敏感信息固定日志。系统Push与后台下载验收均仍未完成。

- EX-22系统后台下载改造阶段R1：新增明确GET委托V2ResourceBackgroundDownloadAuthorization，绑定原字节数/SHA256/整数毫秒期限，拒绝PUT、Range、凭据头、计划与委托不一致及无委托的系统请求。两套本地提供方将委托绑定进原签名对象能力；客户端保持前台无委托计划兼容。Core R2 14项/2套件通过，服务端R2 12项/2套件通过，日志 /tmp/imv2-background-download-core-r2-20261009.log、/tmp/imv2-background-download-server-r2-20261009.log。
- 独立系统下载会话imv2.background.download.UUID复用串行URLSession委托和不透明完成inbox，但与上传会话/恢复队列隔离；OS下载临时文件回调内接管，暂存字节保持Complete保护，先保留文件再记录不透明完成。下载目录沿用全局暂存预算；这里只完成驱动和iOS编译，尚无真实OS下载结果，不将组件构建视为验收通过。
- 下载原意图与每次尝试mapping UUID分离，任务ID复用也不能让旧回调推进新尝试。新增addV2BackgroundDownloadJobs独立GRDB迁移，保存媒体/消息身份、系统任务与授权字节事实，不保存URL/头/令牌。账户绑定检查、原意图重启、旧库迁移及取消后迟到回调测试通过。R6曾发现SQLite浮点Date读回精度丢失，已改为授权原整数毫秒；R7最终24项/4套件exit0，日志 /tmp/imv2-background-download-client-r7-20261009.log。R2测试曾因同套件并发修改进程级磁盘预算计数失败，已对共享预算套件声明serialized，未放宽产品预算；R5编译遗漏await已修复，旧失败日志保留。
- 真实资源边界回归 /tmp/imv2-background-download-contract-live-r1-20261009 终态exit0，独立PG/Actor/HTTPS资源/TLS Gateway及owned清理通过；必需的实际资源上传、头像授权与GET字节、拉黑撤销通过，客户端显式要求下载委托并构造受限GET。该轮未启用的11个专项跳过保留，不算整体14项业务验收通过。客户端日志client.log、summary.json与外层日志 /tmp/imv2-background-download-contract-live-r1-20261009.log。最新模拟器build-for-testing R3 exit0，日志 /tmp/imv2-background-download-app-build-r3-20261009.log。
- EX-22仍未完成：须将持久化下载任务接入账号运行时，在初始化时接管实际系统任务并占用/释放真实传输预算，完成后重新授权才发布受保护缓存，登出/撤回取消并排空；还须执行App实际挂起期间GET、恢复原任务与文件、取消清理的本机模拟器验收。EX-23纯系统远程通知回调证明仍未完成，不以后台fetch替代。

- 后台下载账号协调器已接入App运行时和缓存发布：先持久化映射再恢复系统任务，冷恢复接管原尝试，完成后重新授权，取消排空前保留传输预算。提交前最新源码验证8项/3套件exit0，日志 /tmp/imv2-background-download-precommit-20261009.log；App运行时build-for-testing exit0，日志 /tmp/imv2-background-download-runtime-app-build-r1-20261009.log。真实模拟器挂起下载、冷文件复用与完整取消场景尚未验收，EX-22仍未完成。

- EX-22冷缓存/重试修复：普通媒体在每次新授权后校验账号缓存完整SHA256与字节数，命中可复用原文件，校验期间持有文件使用预算并排空取消；撤销先取消前台等待者再等待系统任务排空。自动重试最多5次后暂停，新的用户请求可恢复同一原意图UUID，后台对账不重置计数。Client下载相关9项/3套件exit0，日志 /tmp/imv2-background-download-retry-r1-20261009.log。真实iOS27模拟器媒体生命周期/文件租约测试11项、14次运行、0失败/0跳过，xcodebuild exit0；xcresult Test-IMApp-2026.10.09_12-41-26-+0800，日志 /tmp/imv2-background-download-cold-cache-r1-20261009.log。此证据仍不等于真实系统挂起下载通过。

- EX-22真实系统后台下载R1终态exit0，owned账号范围清理与服务/PG关闭通过。普通UI注册、Files选取512KiB附件、真实挂起PUT、PG唯一原消息和冷恢复原UUID后，通过正常附件按钮发起GET；App确认runningBackgroundSuspended才释放剩余字节，保持后台期间实际文件校验成功。观察hits=1、foregroundHits=0、durableActiveMappings=1、persistedBytes=524288、artifactCount=1、checksumMatches=true；正常冷启动重新授权后复用原文件，没有第二次GET。5项实际UI功能阶段及2项范围清理均通过，未跳过。外层 /tmp/imv2-native-background-download-live-r1-20261009.log；证据 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-native-e2e-4we8q8fx 与 im-v2-local-two-install-e2e.q5PDap。外层旧通用PASS文案不代表执行了全量双安装业务，已改为输出实际专项成功标记。此轮未验证在途任务的进程终止恢复、撤回/登出期间实际下载排空，EX-22仍保留待验部分；EX-23及完整56项验收未完成。

- 后台下载撤回R1整轮exit1，owned清理通过；实际UI撤回下载场景通过、pendingJobs=0、artifactCount=0、服务端剩余响应被真实连接取消中断，PG原消息withdrawn=true。新测试SQL误将独立服务探针设备计入总数（activeDevices=2）导致断言失败；已将设备统计限定到原消息sender_user_id并重测，保留R1失败，不能将整轮标为通过。日志 /tmp/imv2-native-background-download-withdrawal-r1-20261009.log，证据 imv2-native-e2e-8goe00m5、im-v2-local-two-install-e2e.YT4aZe。

- 后台下载撤回R2整轮exit0，4项普通UI功能与2项账号范围清理均通过、0跳过，owned服务/PG关闭。原消息1条、withdrawn=true、发送账号activeDevices=1；下载真实GET已接收16KiB、原持久化任务映射1条，普通撤回后pendingJobs=0/artifactCount=0，释放余下响应后连接实际中断且无迟到文件。日志 /tmp/imv2-native-background-download-withdrawal-r2-20261009.log，证据 imv2-native-e2e-w4qg4ypi、im-v2-local-two-install-e2e.XgLXRR。
- 后台下载登出R1整轮exit0，4项普通UI功能与2项范围清理均通过、0跳过，owned服务/PG关闭。下载已接收16KiB且有1条原持久化映射，普通首次登出直接到登录页，无手动重试；映射/文件排空，释放余下响应后实际连接中断，未发布迟到文件。PG原消息仍1条/未撤回、原发送账号activeDevices=0。日志 /tmp/imv2-native-background-download-logout-r1-20261009.log，证据 imv2-native-e2e-43x5gv7y、im-v2-local-two-install-e2e.Kb2KF3。EX-22实际在途任务进程重启恢复与EX-23真实远程通知回调仍待验，完整56项目标保持未完成。

- 后台下载真实进程恢复R1整轮exit0，6项实际UI功能与2项账号范围清理均通过，0跳过，owned服务/PG关闭。普通原附件GET接收16KiB，App真实挂起；通过所选模拟器launchctl唯一App条目和实际可执行文件samefile双重核对，仅SIGKILL该App PID，确认notRunning。普通冷启动后原意图UUID、mapping UUID、系统session UUID与任务编号均与崩溃前一致；接管后释放剩余字节，完整512KiB/SHA256一致、GET总数1/无Range请求、发布后任务排空，再一次正常冷启动复用原文件仍无第二次GET。日志 /tmp/imv2-native-background-download-restart-r1-20261009.log；证据 imv2-native-e2e-dd2scxo3、im-v2-local-two-install-e2e.PZHl0d。当前EX-22本机专项已有挂起上传/下载、任务恢复、冷缓存复用、撤回及登出排空证据；不扩大为真机锁屏或跨版本升级证明。EX-23与完整56项最终审计仍未完成。
- Push资料核对：Apple Xcode11.4发布说明明确列出模拟器后台内容通知，https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes；后台通知文档要求content-available:1及UIApplicationDelegate远程通知fetchCompletionHandler回调，https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app。当前iOS27实测fetch分派异常不能据此推论所有模拟器不支持，也不以performFetch替代。下一步检查实际UIKit/SwiftUI委托selector暴露，再定位本机系统分派。

- Push回调暴露定位R1仅指定Swift Testing方法，xcodebuild虽exit0但xcresult实际0项/result unknown，不算验证。R2改跑完整V2PushWakeSettingsTests，10项、0失败/0跳过、exit0；实际systemDelegateCallbackExposure()测试节点Passed，业务委托与已安装UIKit/SwiftUI桥接委托均responds远程通知fetchCompletionHandler selector。证据 Test-IMApp-2026.10.09_13-05-40-+0800.xcresult，日志 /tmp/imv2-system-push-delegate-exposure-r2-20261009.log。此证据排除该构建中回调未暴露的假设，不是实际OS远程通知已送达证明；继续定位系统分派。

- 系统Push分派R11整轮exit1，普通UI注册就绪/真实挂起/原TCP消息提交通过，45秒后台原消息与游标未推进；owned范围清理与服务/PG关闭通过。新关联系统日志读取成功，remoteCallbackCount=0/fetchActionCount=0/remoteActionCount=0/missingBackgroundModeCount=1；simctl exit121/可见通知1401保留。实际安装包UIBackgroundModes=[remote-notification]，固定OS拒绝来自CoreSimulatorBr向SpringBoard发起后台启动，Disabled原因是未声明所需模式，尚未进入App。原消息01a11f10-8433-7276-94df-8769387bc547/sequence2。日志 /tmp/imv2-system-push-dispatch-r11-20261009.log，证据 imv2-native-e2e-oinzz097、im-v2-local-two-install-e2e.wTgSNf。当前通过门槛额外要求实际远程通知固定回调日志，其他消息到达不能冒充Push通过；下一轮仅改为文档规定的apns文件+Simulator Target Bundle入口，仍为纯content-available，不加入fetch或可见通知。

- 系统Push分派R12整轮exit1，owned清理通过。仅将stdin/显式Bundle参数改为Apple文档APNs文件入口，文件包含Simulator Target Bundle及原纯content-available:1；实际UI注册就绪/挂起、原消息01a11f14-230f-7f3e-a71f-22549abc8c1a/sequence2提交通过，仍无后台原消息投影。日志读取成功，remoteCallbackCount=0、missingBackgroundModeCount=1、simctl exit121/1401；入口形式未改变系统拒绝。日志 /tmp/imv2-system-push-dispatch-r12-20261009.log，证据 imv2-native-e2e-54xbgz3p、im-v2-local-two-install-e2e.om6Brt。下一步一次性最小UIKit对照用于区分项目SwiftUI路径和本机系统分派，不计业务验收。

- 独立UIKit分派对照R1未满足前置：直接UIKit旧入口在当前SDK被UIScene必需检查阻止，真实注册未发生；R2加入Scene后已连接但注册失败，缺少Xcode同等的模拟器__TEXT,__entitlements。两轮均卸载owned对照，仅作为失败前置，不计Push验证。
- UIKit对照R3有效完成：独立Bundle com.stskcxfz.imv2routingprobe、最小Scene/UIKit委托、声明remote-notification并嵌入aps-environment=development的模拟器entitlement；实际系统注册回调和Scene连接成功，实际Scene进入后台成功。纯apns文件投递前台/后台均exit121，远程回调0，SpringBoard所需后台模式拒绝2次；同一iOS27.0/24A434另一所选模拟器复现，排除问题仅存在IMApp SwiftUI路径的假设，仍不能把对照当作IMApp业务验收通过。owned对照已卸载。可复核源码/构建产物/纯payload/运行脚本/汇总位于 /tmp/imv2-system-push-routing-probe-20261009，summary-r1/r2/r3.json保留。
- 当前外部条件只读复核：已安装可用运行时iOS18.5/22F77与iOS27.0/24A434，App最低26.2不能用18.5替代；当前已连接实体设备0，本次进程APNS环境变量0。不降低部署版本、不增加后台fetch或可见通知替代原验收。EX-23当前系统通知证据仍未通过；后续须继续完整56项证据审计，不能据后台下载专项完成标记整个目标完成。

- 当前合并扩展验收R1：提交4ffe6a34下真实HTTPS/TLS执行，14个测试方法，群头像/自退/管理/消息操作/账号策略与封禁全部通过，独立服务与PG清理完成。目录规模与慢资源两项显式opt-in本轮跳过，沿用其独立专项证据，不将跳过视作通过。日志 /tmp/imv2-functional-acceptance-current-extended-r1-20261009.log，完整结果 /tmp/imv2-functional-acceptance-current-extended-r1-20261009/client.log 与 summary.json。矩阵补齐最新合并证据及离线R8、房间规模R14的既有实际结果；Push仍未通过。

- 当前验收证据审计直接读取25个关联运行的157个原xcresult摘要，真实失败和跳过数均保留；资料 /tmp/imv2-functional-acceptance-20261008/referenced-ui-result-audit-20261009.json。早期目录/上传/偏好业务通过与注册审计失败明确分开；原批准成员即时正文失败不再作为当前完成证据，矩阵补入修复后完整通过的R10/R11索引。账号切换当前轮注册/无障碍1项通过，切换与清理仍等待终态。

- 当前账号切换R1完整exit0：注册及AX审计、A→B→A实际登录/两次首次退出无重试、各自原消息与投影隔离、正常冷恢复和两个范围清理共4项通过0失败0跳过，owned服务/PG关闭。日志 /tmp/imv2-account-switch-current-r1-20261009.log；四份实际xcresult摘要 /tmp/imv2-account-switch-current-r1-summary.json。EX03/EX06补入当前代码完整证据，不覆盖早期整轮审计失败。系统Push当前OS拒绝条件未改变，完整目标未完成。

- Push跨运行时诊断：本机仅18.5/27.0，当前剩余磁盘约14GiB；独立UIKit程序18.5目标（不改App最低26.2）R1实际Scene启动但远程通知注册前置失败，因此不算通知分派证据。专属新模拟器及诊断App已删除，原模拟器不变。R2保留原失败后补入旧运行时可读取的真实代码签名entitlement并复测；根目录 /tmp/imv2-system-push-routing-probe-ios185-20261009。

- 18.5 UIKit对照R2终态：补入真实代码签名entitlement后，启动/注册前置仍未取得有效成功证据（CalledProcessError）；保持失败，不用低版本对照替代App验收。诊断App卸载及专属模拟器关闭/删除成功，r1/r2各自summary与cleanup保留。现有可运行App的27.0纯后台Push仍保持R11/R12的OS拒绝证据；未得到另一兼容运行时的有效对照。

- 当前修复目标阻塞审计：最近三轮持续遇到同一EX23本机OS远程通知分派条件，现有有效27.0对照在进入App前被拒绝，18.5不能运行最低26.2的App，独立低版本注册前置也未通过。当前所有本轮测试/诊断句柄已终态，无存活验收进程；已安装运行时仍仅18.5/27.0，Spotlight未发现另一本机iOS运行时DMG，未收到可导入路径。完整56项范围和原失败保留，未标记完成。状态应为blocked，恢复条件为提供另一兼容本机运行时或修复当前模拟器系统投递环境，再继续实际Push回调及后台原消息投影验收；资料 /tmp/imv2-functional-acceptance-20261008/push-blocker-current-audit-20261009.json。

- 用户要求重新选择现有iOS27模拟器，实际选用此前未用于App专项的iPhone18Pro（4F260618-7381-44E2-AEB8-1A2B10985753），R13完整执行并终态exit1。普通App注册/AX通过；挂起后原TCP消息01a11fba-8898-7607-ab0e-adb6b9fb9f5b/sequence2提交成功，45秒后台投影未完成；系统日志读取成功，remoteCallbackCount=0、missingBackgroundModeCount=1、simctl返回121。实际xcresult共3通过1失败0跳过，两个范围清理通过，owned服务与PG关闭。日志 /tmp/imv2-system-push-new-ios27-r13-20261009.log，摘要 /tmp/imv2-system-push-new-ios27-r13-summary.json，原观察 system-push-observation.json保留。换设备后同样失败，不能据此宣称所有模拟器不支持；EX23未通过，恢复后阻塞审计重新计数，不复用此前blocked轮次。

### 本次修复验收收尾（排除 APNs）

用户明确要求“不验证和apns相关的”。原56项保留编号，EX23标为用户排除，系统Push失败不改为通过；当前55项本机功能验收完成。逐项证据与范围核对见 /tmp/imv2-functional-acceptance-20261008/final-non-apns-acceptance-audit-20261009.json。已核对最新真实HTTPS/TLS扩展套件、各命名App功能阶段的实际xcresult、原消息/工作身份与PG/SQLite事实；后台下载四轮所有实际UI结果再次读取均通过。原聚合失败、注册审计历史及未选择的opt-in跳过保持原样，不视作通过；共用注册/AX及主要UI流程由修复后完整R8、当前账号切换R1和原生下载整轮补足。

主要修复包括首次登出任务所有权、离线原命令重放、私聊拒绝提示与去重、主动退群和群头像、typing订阅ACK、终止订阅ACK与成员入群即时投影、界面无障碍/冷邀请恢复、账号后台下载持久任务接管、缓存重新授权与字节校验、撤回/登出取消排空。本机范围含1000房间跨Gateway恢复及尾通知补偿、真实丢ACK自动重连、两安装多设备同步与权限变更、后台挂起传输及实际SIGKILL后原任务恢复；不扩展为生产容量、真机或APNs送达验证。本轮owned服务/PG测试已关闭；本次收尾只更新验收记录，不自动提交推送。
