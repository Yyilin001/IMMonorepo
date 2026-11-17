part of 'workspace.dart';

String _generateRecoveryCode() {
  final random = Random.secure();
  return List.generate(32, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

class _AccountSecurityPage extends StatefulWidget {
  const _AccountSecurityPage();

  @override
  State<_AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<_AccountSecurityPage> {
  final account = TextEditingController();
  final current = TextEditingController();
  final next = TextEditingController();
  final confirmation = TextEditingController();
  final code = TextEditingController();
  var action = 'change';
  var generatedCode = '';
  var savedCode = false;
  var busy = false;
  String? message, error;

  @override
  void dispose() {
    account.dispose();
    current.dispose();
    next.dispose();
    confirmation.dispose();
    code.dispose();
    super.dispose();
  }

  String? validate() {
    if (account.text.trim().isEmpty) return '请输入登录账号';
    if (action != 'recover' && current.text.isEmpty) return '请输入当前密码';
    if (action != 'recovery-code') {
      if (next.text.length < 12) return '新密码至少 12 个字符';
      if (next.text != confirmation.text) return '两次输入的新密码不一致';
    }
    if (action == 'recovery-code') {
      if (generatedCode.isEmpty) return '请先生成恢复码';
      if (!savedCode) return '请确认已安全保存恢复码';
    }
    if (action == 'recover') {
      final value = code.text.trim();
      if (value.length != 64 ||
          !RegExp(r'^[0-9a-z]{64}$').hasMatch(value)) {
        return '恢复码须为 64 位小写字母和数字';
      }
    }
    return null;
  }

  Future<void> submit() async {
    if (busy) return;
    final invalid = validate();
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    final sdk = _SdkScope.of(context)!;
    try {
      await sdk.client!.passwordLifecycle(
        account: account.text.trim(),
        action: action,
        currentPassword: action == 'recover' ? null : current.text,
        newPassword: action == 'recovery-code' ? null : next.text,
        recoveryCode: action == 'recovery-code'
            ? generatedCode
            : action == 'recover'
            ? code.text.trim()
            : null,
      );
      if (!mounted) return;
      if (action == 'recovery-code') {
        setState(() {
          busy = false;
          message = '恢复码已启用。请把副本放在安全位置，旧恢复码已失效。';
          generatedCode = '';
          savedCode = false;
        });
        return;
      }
      setState(() {
        busy = false;
        message = action == 'change'
            ? '密码已更新，全部设备已退出登录，请使用新密码登录。'
            : '密码已重置，全部设备已退出登录，请使用新密码登录。';
      });
      sdk.signOut();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = _accountSecurityError(failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final recoverySetup = action == 'recovery-code';
    final recover = action == 'recover';
    return _ProfileScaffold(
      title: '账号安全',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'change', label: Text('修改密码')),
              ButtonSegment(value: 'recovery-code', label: Text('恢复码')),
              ButtonSegment(value: 'recover', label: Text('找回账号')),
            ],
            selected: {action},
            onSelectionChanged: busy
                ? null
                : (value) => setState(() {
                    action = value.first;
                    error = null;
                    message = null;
                  }),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(
            '请只在仍记得密码时设置离线恢复码。密码和恢复码都丢失后，账号将无法找回。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
        _InfoCard(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline, color: green),
              title: TextField(
                key: const Key('security-account'),
                controller: account,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '登录账号'),
              ),
            ),
            if (!recover)
              ListTile(
                leading: const Icon(Icons.lock_outline, color: green),
                title: TextField(
                  key: const Key('security-current-password'),
                  controller: current,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
              ),
          ],
        ),
        if (!recoverySetup) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              ListTile(
                leading: const Icon(Icons.lock_reset, color: green),
                title: TextField(
                  key: const Key('security-new-password'),
                  controller: next,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.lock_reset, color: green),
                title: TextField(
                  key: const Key('security-confirm-password'),
                  controller: confirmation,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                ),
              ),
            ],
          ),
        ],
        if (recover) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              ListTile(
                leading: const Icon(Icons.key_outlined, color: green),
                title: TextField(
                  key: const Key('security-recovery-code'),
                  controller: code,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '已保存的恢复码'),
                ),
              ),
            ],
          ),
        ],
        if (recoverySetup) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              if (generatedCode.isEmpty)
                ListTile(
                  key: const Key('generate-recovery-code'),
                  leading: const Icon(Icons.vpn_key_outlined, color: green),
                  title: const Text('生成恢复码'),
                  trailing: const Icon(Icons.chevron_right_rounded, color: muted),
                  onTap: busy
                      ? null
                      : () => setState(() => generatedCode = _generateRecoveryCode()),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    generatedCode,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 14,
                      height: 1.5,
                      color: ink,
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const Key('saved-recovery-code'),
                  title: const Text('我已在应用外安全保存恢复码'),
                  value: savedCode,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => savedCode = value),
                ),
              ],
            ],
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E), height: 1.5),
            ),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              message!,
              style: const TextStyle(color: green, height: 1.5),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
          child: FilledButton(
            key: const Key('submit-account-security'),
            onPressed: busy ? null : submit,
            child: Text(
              recoverySetup
                  ? '启用恢复码'
                  : recover
                  ? '重置密码'
                  : '更新密码',
            ),
          ),
        ),
      ],
    );
  }
}

String _accountSecurityError(Object failure) {
  final code = failure is PlatformException ? failure.code : '';
  return switch (code) {
    'invalidRecoveryCode' => '恢复码须为保存时的 64 位小写字母和数字',
    'invalidPassword' => '密码须为 12–1024 个 UTF-8 字节',
    'rateLimited' => '尝试过于频繁，请稍后重试',
    'authenticationRequired' => '账号、当前密码或恢复码不正确，或已被更换',
    'invalidInput' => '请检查账号和输入的格式',
    _ => '结果尚未确认。若修改的是密码，请先用新密码尝试登录；不要重复提交恢复码。',
  };
}

class _DeviceSessionsPage extends StatefulWidget {
  const _DeviceSessionsPage();

  @override
  State<_DeviceSessionsPage> createState() => _DeviceSessionsPageState();
}

class _DeviceSessionsPageState extends State<_DeviceSessionsPage> {
  final sessions = <ImDeviceSession>[];
  String? nextCursor, error;
  bool loading = true, more = false, revoking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  Future<void> load({bool next = false}) async {
    if (loading || more || revoking) return;
    setState(() {
      if (next) {
        more = true;
      } else {
        loading = true;
      }
      error = null;
    });
    try {
      final page = await _SdkScope.of(
        context,
      )!.client!.deviceSessions(cursor: next ? nextCursor : null);
      if (!mounted) return;
      setState(() {
        if (!next) sessions.clear();
        sessions.addAll(page.sessions);
        nextCursor = page.nextCursor;
        loading = false;
        more = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
        more = false;
      });
    }
  }

  Future<void> revoke(ImDeviceSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('退出此设备？'),
        content: Text('${session.deviceName} 将立即退出登录。之后登录的设备不会被加入这次请求。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('退出设备'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _revoke(deviceId: session.deviceId, all: false);
  }

  Future<void> revokeOthers() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('退出其他所有设备？'),
        content: const Text('只退出当前已观察到的其他设备，后来登录的设备不会被加入这次请求。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('退出其他设备'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _revoke(deviceId: null, all: true);
  }

  Future<void> _revoke({String? deviceId, required bool all}) async {
    setState(() => revoking = true);
    try {
      await _SdkScope.of(context)!.client!.revokeDevice(
        deviceId: deviceId,
        all: all,
      );
      if (!mounted) return;
      setState(() => revoking = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('退出请求已确认')));
      await load();
    } catch (failure) {
      if (!mounted) return;
      setState(() => revoking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '退出结果尚未确认，请刷新设备列表后再试：${_errorText(failure)}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => _ProfileScaffold(
    title: '登录设备',
    actions: [
      IconButton(
        tooltip: '刷新',
        onPressed: loading || more || revoking ? null : load,
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    children: [
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            error!,
            style: const TextStyle(color: Color(0xFFB3261E)),
          ),
        ),
      if (loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      for (final session in sessions)
        ListTile(
          key: ValueKey('device-${session.deviceId}'),
          leading: Icon(
            session.platform.toLowerCase().contains('ipad')
                ? Icons.tablet_mac_outlined
                : session.platform.toLowerCase().contains('android')
                ? Icons.phone_android_outlined
                : Icons.phone_iphone_outlined,
            color: green,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  session.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (session.isCurrentDevice) ...[
                const SizedBox(width: 8),
                const Text(
                  '此设备',
                  style: TextStyle(fontSize: 12, color: green),
                ),
              ],
            ],
          ),
          subtitle: Text(
            '${session.platform} · 最近活跃 ${_relativeSessionTime(session.lastActiveAt)}',
          ),
          trailing: session.isCurrentDevice
              ? null
              : TextButton(
                  onPressed: loading || more || revoking ? null : () => revoke(session),
                  child: const Text('退出此设备'),
                ),
        ),
      if (!loading && sessions.isEmpty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('没有其他登录设备', style: TextStyle(color: muted)),
        ),
      if (sessions.any((session) => !session.isCurrentDevice))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            key: const Key('revoke-other-devices'),
            onPressed: loading || more || revoking ? null : revokeOthers,
            child: const Text('退出其他所有设备'),
          ),
        ),
      if (more && nextCursor != null)
        TextButton(
          onPressed: () => load(next: true),
          child: const Text('加载更多设备'),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Text(
          '设备列表来自账号服务。退出请求只包含当前已观察到的设备，结果未知时请刷新列表核对。',
          style: TextStyle(fontSize: 12, color: muted, height: 1.5),
        ),
      ),
    ],
  );
}

String _relativeSessionTime(int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final delta = DateTime.now().difference(value);
  if (delta.inMinutes < 1) return '刚刚';
  if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
  if (delta.inDays < 1) return '${delta.inHours} 小时前';
  return '${delta.inDays} 天前';
}

class _PrivacySettingsPage extends StatefulWidget {
  const _PrivacySettingsPage();

  @override
  State<_PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<_PrivacySettingsPage> {
  ImPrivacy? privacy;
  final Map<String, ImProfile> profiles = {};
  bool loading = true, saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await _SdkScope.of(context)!.client!.privacy();
      if (!mounted) return;
      setState(() {
        privacy = value;
        loading = false;
      });
      unawaited(_loadBlockedProfiles(value?.blockedUsers ?? const []));
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> _loadBlockedProfiles(List<String> ids) async {
    final wanted = ids
        .where((id) => !profiles.containsKey(id))
        .take(50)
        .toList(growable: false);
    if (wanted.isEmpty) return;
    try {
      final rows = await _SdkScope.of(context)!.client!.profiles(
        page: 'blocked',
        context: 'relationship',
        userIds: wanted,
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          profiles[row.userId] = row;
        }
      });
    } catch (_) {
      // Raw public IDs remain visible if cards are unavailable.
    }
  }

  Future<void> setPrivacy(
    String kind, {
    bool? flag1,
    bool? flag2,
  }) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final value = await _SdkScope.of(context)!.client!.setPrivacy(
        kind,
        flag1: flag1,
        flag2: flag2,
      );
      if (!mounted) return;
      setState(() {
        privacy = value;
        saving = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置已提交但尚未确认：${_errorText(failure)}')),
      );
    }
  }

  Future<void> unblock(String userId) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await _SdkScope.of(
        context,
      )!.client!.socialAction(userId, ImSocialAction.unblock);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已提交解除屏蔽')));
      setState(() => saving = false);
      await load();
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    }
  }

  Future<void> blockByHandle({required bool block}) async {
    final controller = TextEditingController();
    final handle = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(block ? '按公开 ID 屏蔽' : '按公开 ID 解除屏蔽'),
        content: TextField(
          key: const Key('privacy-handle-input'),
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '公开 ID（例如 @alice）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: Text(block ? '屏蔽' : '解除屏蔽'),
          ),
        ],
      ),
    );
    if (handle == null || handle.trim().isEmpty || !mounted) return;
    setState(() => saving = true);
    try {
      final client = _SdkScope.of(context)!.client!;
      final userId = await client.resolveUserId(handle.trim());
      await client.socialAction(
        userId,
        block ? ImSocialAction.block : ImSocialAction.unblock,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(block ? '已提交屏蔽' : '已提交解除屏蔽')),
      );
      setState(() => saving = false);
      await load();
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = privacy;
    return _ProfileScaffold(
      title: '消息接收设置',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: loading || saving ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (value != null) ...[
          SwitchListTile(
            key: const Key('privacy-stranger'),
            title: const Text('陌生人消息'),
            subtitle: const Text('关闭后，非好友无法向你发起新的陌生人消息。'),
            value: value.allowsStrangerMessages ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy('strangerMessage', flag1: enabled),
          ),
          SwitchListTile(
            key: const Key('privacy-user-add'),
            title: const Text('添加权限'),
            subtitle: const Text('关闭后，新的添加请求会被拒绝；已有好友不受影响。'),
            value: value.allowsUserAdd ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy('userAdd', flag1: enabled),
          ),
          SwitchListTile(
            key: const Key('privacy-direct-receipt'),
            title: const Text('单聊已读回执'),
            subtitle: const Text('关闭后，双方都不会看到彼此的已读状态。'),
            value: value.allowsDirectReadReceipts ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy(
                    'readReceipt',
                    flag1: enabled,
                    flag2: value.allowsGroupReadReceipts,
                  ),
          ),
          SwitchListTile(
            key: const Key('privacy-group-receipt'),
            title: const Text('群聊已读回执'),
            subtitle: const Text('关闭后，群成员不会看到你的已读状态。'),
            value: value.allowsGroupReadReceipts ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy(
                    'readReceipt',
                    flag1: value.allowsDirectReadReceipts,
                    flag2: enabled,
                  ),
          ),
          SwitchListTile(
            key: const Key('privacy-online'),
            title: const Text('在线状态'),
            subtitle: const Text('关闭后，不再向会话成员共享你的在线状态。'),
            value: value.allowsOnlinePresence ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy(
                    'liveActivity',
                    flag1: enabled,
                    flag2: value.allowsTypingIndicators,
                  ),
          ),
          SwitchListTile(
            key: const Key('privacy-typing'),
            title: const Text('正在输入'),
            subtitle: const Text('关闭后，不再向会话成员共享正在输入提示。'),
            value: value.allowsTypingIndicators ?? true,
            onChanged: saving
                ? null
                : (enabled) => setPrivacy(
                    'liveActivity',
                    flag1: value.allowsOnlinePresence,
                    flag2: enabled,
                  ),
          ),
          const _AccountHeading('已屏蔽用户'),
          for (final user in value.blockedUsers)
            ListTile(
              key: ValueKey('blocked-$user'),
              leading: SdkAvatar(
                userId: user,
                name: profiles[user]?.name ?? user,
                size: 40,
              ),
              title: Text(profiles[user]?.name ?? user),
              trailing: TextButton(
                onPressed: saving ? null : () => unblock(user),
                child: const Text('解除屏蔽'),
              ),
            ),
          if (value.blockedUsers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('暂无已屏蔽用户', style: TextStyle(color: muted)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: OutlinedButton.icon(
              key: const Key('privacy-block-handle'),
              onPressed: saving ? null : () => blockByHandle(block: true),
              icon: const Icon(Icons.person_off_outlined),
              label: const Text('按公开 ID 屏蔽'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: saving ? null : () => blockByHandle(block: false),
              icon: const Icon(Icons.person_add_alt_outlined),
              label: const Text('按公开 ID 解除屏蔽'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Text(
              '屏蔽会解除已有好友关系并阻止新的私聊消息；解除屏蔽不会自动恢复好友。',
              style: TextStyle(fontSize: 12, color: muted, height: 1.5),
            ),
          ),
        ],
      ],
    );
  }
}

class _AccountHeading extends StatelessWidget {
  const _AccountHeading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: muted,
      ),
    ),
  );
}
