part of 'workspace.dart';

String _inviteExpiry(int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int input) => input.toString().padLeft(2, '0');
  return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

class _GroupInvitesPage extends StatefulWidget {
  const _GroupInvitesPage({
    required this.roomId,
    required this.membershipRevision,
  });
  final String roomId;
  final int membershipRevision;

  @override
  State<_GroupInvitesPage> createState() => _GroupInvitesPageState();
}

class _GroupInvitesPageState extends State<_GroupInvitesPage> {
  ImCommunity? community;
  final Map<String, ImProfile> profiles = {};
  late int revision = widget.membershipRevision;
  bool loading = true, working = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  Future<void> load({bool more = false}) async {
    if (!mounted || working) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final client = _SdkScope.of(context)!.client!;
      final page = more
          ? await client.nextInvitations(widget.roomId)
          : await client.invitations(widget.roomId);
      if (!mounted) return;
      setState(() {
        community = page;
        loading = false;
      });
      unawaited(_loadRequestProfiles(page.requests));
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> _loadRequestProfiles(List<ImJoinRequest> requests) async {
    final ids = requests
        .map((request) => request.userId)
        .where((id) => id.isNotEmpty && !profiles.containsKey(id))
        .take(50)
        .toList(growable: false);
    if (ids.isEmpty) return;
    try {
      final rows = await _SdkScope.of(context)!.client!.profiles(
        page: 'join:${widget.roomId}',
        context: 'joinReview',
        roomId: widget.roomId,
        userIds: ids,
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          profiles[row.userId] = row;
        }
      });
    } catch (_) {
      // Applicant names are optional; the public ID remains visible.
    }
  }

  Future<void> _refreshRevision() async {
    try {
      final page = await _SdkScope.of(
        context,
      )!.client!.groupMembers(widget.roomId);
      if (mounted) revision = page.membershipRevision;
    } catch (_) {
      // Keep the displayed revision; the server remains authoritative.
    }
  }

  Future<void> act(
    String action, {
    String? intentId,
    String? label,
    String? note,
  }) async {
    if (working) return;
    setState(() => working = true);
    try {
      final client = _SdkScope.of(context)!.client!;
      if (revision == 0) await _refreshRevision();
      await client.inviteAction(
        widget.roomId,
        revision,
        action,
        intentId: intentId,
        note: note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${label ?? '邀请操作'}已提交')),
      );
      await _refreshRevision();
      await load();
    } catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = community;
    return _ProfileScaffold(
      title: '邀请与审批',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: loading || working ? null : load,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: FilledButton.icon(
            key: const Key('create-group-invite'),
            onPressed: loading || working
                ? null
                : () => act('create', label: '创建邀请链接'),
            icon: const Icon(Icons.link_rounded),
            label: const Text('创建 7 天邀请链接'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '链接有效期 7 天、最多批准 100 次。审批结果以服务器为准。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
        if (value != null && value.invites.isNotEmpty)
          const _CommunityHeading('有效邀请链接'),
        for (final invite in value?.invites ?? const <ImInvite>[])
          ListTile(
            key: ValueKey('invite-${invite.id}'),
            isThreeLine: true,
            leading: SizedBox.square(
              dimension: 64,
              child: QrImageView(
                data: invite.url,
                size: 64,
                padding: EdgeInsets.zero,
              ),
            ),
            title: Text(
              '剩余 ${invite.maximum - invite.used} 次 · ${_inviteExpiry(invite.expires)} 到期',
            ),
            subtitle: Text(
              invite.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Wrap(
              spacing: 0,
              children: [
                IconButton(
                  tooltip: '复制邀请链接',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: working
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: invite.url),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('邀请链接已复制')),
                            );
                          }
                        },
                ),
                IconButton(
                  tooltip: '撤销邀请链接',
                  icon: const Icon(Icons.link_off_rounded),
                  onPressed: working
                      ? null
                      : () => act(
                          'revoke',
                          intentId: invite.id,
                          label: '撤销邀请链接',
                        ),
                ),
              ],
            ),
          ),
        if (value != null && value.invites.isEmpty && !loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              '暂无有效邀请链接',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        const _CommunityHeading('待审批'),
        for (final request in value?.requests ?? const <ImJoinRequest>[])
          ListTile(
            key: ValueKey('join-${request.id}'),
            leading: SdkAvatar(
              userId: request.userId,
              name: profiles[request.userId]?.name ?? request.userId,
              context: 'joinReview',
              roomId: widget.roomId,
              size: 44,
            ),
            title: Text(profiles[request.userId]?.name ?? request.userId),
            subtitle: Text(
              request.note.isEmpty ? '申请加入群聊' : request.note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: working
                      ? null
                      : () =>
                            act('reject', intentId: request.id, label: '拒绝申请'),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: working
                      ? null
                      : () =>
                            act('approve', intentId: request.id, label: '批准申请'),
                  child: const Text('批准'),
                ),
              ],
            ),
          ),
        if (value != null && value.requests.isEmpty && !loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              '暂无入群申请',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (value?.hasMore == true)
          TextButton(
            onPressed: working ? null : () => load(more: true),
            child: const Text('加载更多申请'),
          ),
      ],
    );
  }
}

class _JoinGroupPage extends StatefulWidget {
  const _JoinGroupPage();

  @override
  State<_JoinGroupPage> createState() => _JoinGroupPageState();
}

class _JoinGroupPageState extends State<_JoinGroupPage> {
  final input = TextEditingController();
  final note = TextEditingController();
  ImCommunity? community;
  bool loading = false, working = false;
  String? error;

  @override
  void dispose() {
    input.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> read() async {
    if (loading || working || input.text.trim().isEmpty) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await _SdkScope.of(
        context,
      )!.client!.previewInvite(input.text);
      if (!mounted) return;
      setState(() {
        community = value;
        loading = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> refresh() async {
    if (working) return;
    setState(() => working = true);
    try {
      final value = await _SdkScope.of(context)!.client!.refreshInvite();
      if (!mounted) return;
      setState(() => community = value);
    } catch (failure) {
      if (mounted) setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> submit() async {
    if (working) return;
    setState(() => working = true);
    try {
      await _SdkScope.of(context)!.client!.submitJoin(note.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('入群申请已提交')));
      await refresh();
    } catch (failure) {
      if (!mounted) return;
      setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> cancel() async {
    final preview = community?.preview;
    if (working || preview == null) return;
    setState(() => working = true);
    try {
      await _SdkScope.of(context)!.client!.cancelJoin(preview.roomId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('入群申请已取消')));
      await refresh();
    } catch (failure) {
      if (!mounted) return;
      setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = community?.preview;
    return _ProfileScaffold(
      title: '加入群聊',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const Key('join-invite-input'),
            controller: input,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '邀请链接或令牌',
              hintText: 'iim://group-invite?token=...',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('read-invite'),
                  onPressed: loading || working ? null : read,
                  child: const Text('读取邀请'),
                ),
              ),
              if (preview != null) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: working ? null : refresh,
                  child: const Text('刷新'),
                ),
              ],
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (preview != null) ...[
          const SizedBox(height: 12),
          ListTile(
            title: Text(preview.title),
            subtitle: Text(
              preview.member
                  ? '你已经是该群成员'
                  : preview.state == null
                  ? '可以申请加入'
                  : '申请状态：${preview.state}',
            ),
          ),
          if (preview.canSubmit) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                key: const Key('join-invite-note'),
                controller: note,
                maxLength: 500,
                decoration: const InputDecoration(labelText: '申请说明（可选）'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                key: const Key('submit-join'),
                onPressed: working ? null : submit,
                child: const Text('提交入群申请'),
              ),
            ),
          ],
          if (preview.canCancel)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: OutlinedButton(
                onPressed: working ? null : cancel,
                child: const Text('取消申请'),
              ),
            ),
        ],
      ],
    );
  }
}

class _CommunityHeading extends StatelessWidget {
  const _CommunityHeading(this.text);
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

class _GroupAvatarPage extends StatefulWidget {
  const _GroupAvatarPage({required this.roomId, required this.name});
  final String roomId, name;

  @override
  State<_GroupAvatarPage> createState() => _GroupAvatarPageState();
}

class _GroupAvatarPageState extends State<_GroupAvatarPage> {
  ImAvatarEditor? editor;
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
      final value = await _SdkScope.of(
        context,
      )!.client!.openAvatarEditor(roomId: widget.roomId);
      if (!mounted) return;
      setState(() {
        editor = value;
        loading = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> change() async {
    final value = editor;
    if (value == null || !value.canManage || saving) return;
    final jpeg = await pickSquareAvatar(context);
    if (jpeg == null || !mounted) return;
    setState(() => saving = true);
    try {
      await _SdkScope.of(context)!.client!.changeAvatar(
        roomId: widget.roomId,
        revision: value.revision,
        jpeg: jpeg,
        width: 512,
        height: 512,
      );
      if (!mounted) return;
      setState(() {
        editor = (
          roomId: value.roomId,
          revision: value.revision,
          canManage: value.canManage,
          remainingMilliseconds: value.remainingMilliseconds,
          hasAvatar: true,
          name: value.name,
          handle: value.handle,
          image: jpeg,
        );
        saving = false;
      });
      _SdkGroupAvatarCache.invalidate(widget.roomId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('群头像已提交，正在同步')),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    }
  }

  Future<void> remove() async {
    final value = editor;
    if (value == null || !value.canManage || !value.hasAvatar || saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除群头像？'),
        content: const Text('移除后，群成员将看到默认群头像。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => saving = true);
    try {
      await _SdkScope.of(context)!.client!.changeAvatar(
        roomId: widget.roomId,
        revision: value.revision,
        action: 'remove',
      );
      if (!mounted) return;
      _SdkGroupAvatarCache.invalidate(widget.roomId);
      setState(() {
        editor = (
          roomId: value.roomId,
          revision: value.revision,
          canManage: value.canManage,
          remainingMilliseconds: value.remainingMilliseconds,
          hasAvatar: false,
          name: value.name,
          handle: value.handle,
          image: null,
        );
        saving = false;
      });
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
    final value = editor;
    return _ProfileScaffold(
      title: '群头像',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: loading || saving ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Column(
            children: [
              ChatAvatar(
                id: widget.roomId.hashCode & 0x7fffffff,
                name: widget.name,
                group: true,
                size: 96,
                avatar: value?.image,
              ),
              const SizedBox(height: 12),
              Text(
                widget.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ),
        if (loading && value == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (value != null && value.canManage) ...[
          FilledButton.icon(
            key: const Key('change-group-avatar'),
            onPressed: saving ? null : change,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('更换群头像'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: saving || !value.hasAvatar ? null : remove,
            icon: const Icon(Icons.hide_image_outlined),
            label: const Text('移除群头像'),
          ),
        ] else if (value != null)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '只有群主可以更改群头像。',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Text(
            '群头像会同步到所有成员的会话列表和聊天页。上传后仍需服务器校验，失败时保留原头像。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _MessageReadersPage extends StatefulWidget {
  const _MessageReadersPage({required this.roomId, required this.messageId});
  final String roomId, messageId;

  @override
  State<_MessageReadersPage> createState() => _MessageReadersPageState();
}

class _MessageReadersPageState extends State<_MessageReadersPage> {
  final List<String> users = [];
  final Map<String, ImProfile> profiles = {};
  bool loading = true, more = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  Future<void> load({bool next = false}) async {
    if (loading || more) return;
    setState(() {
      if (next) {
        more = true;
      } else {
        loading = true;
      }
      error = null;
    });
    try {
      final page = await _SdkScope.of(context)!.client!.messageReaders(
        widget.roomId,
        widget.messageId,
        next: next,
      );
      if (!mounted) return;
      setState(() {
        if (!next) users.clear();
        for (final user in page.users) {
          if (!users.contains(user)) users.add(user);
        }
        more = page.hasNext;
        loading = false;
      });
      unawaited(_loadProfiles());
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> _loadProfiles() async {
    final ids = users
        .where((id) => id.isNotEmpty && !profiles.containsKey(id))
        .take(50)
        .toList(growable: false);
    if (ids.isEmpty) return;
    try {
      final rows = await _SdkScope.of(context)!.client!.profiles(
        page: 'readers:${widget.roomId}:${widget.messageId}',
        context: 'room',
        roomId: widget.roomId,
        userIds: ids,
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          profiles[row.userId] = row;
        }
      });
    } catch (_) {
      // Public IDs remain visible when profile cards are unavailable.
    }
  }

  @override
  Widget build(BuildContext context) => _ProfileScaffold(
    title: '已读成员',
    actions: [
      IconButton(
        tooltip: '刷新',
        onPressed: loading || more ? null : load,
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
      else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(
            '${users.length} 位成员已读',
            style: const TextStyle(fontSize: 13, color: muted),
          ),
        ),
        for (final user in users)
          ListTile(
            leading: SdkAvatar(
              userId: user,
              name: profiles[user]?.name ?? user,
              context: 'room',
              roomId: widget.roomId,
              size: 40,
            ),
            title: Text(profiles[user]?.name ?? user),
          ),
        if (more)
          TextButton(
            onPressed: () => load(next: true),
            child: const Text('加载更多'),
          ),
        if (users.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('暂无已读成员', style: TextStyle(color: muted)),
          ),
      ],
    ],
  );
}

const _groupPermissionLabels = <String, String>{
  'send_messages': '发送消息',
  'invite_members': '添加成员',
  'remove_members': '移除成员',
  'change_member_roles': '设置角色',
  'pin_messages': '置顶消息',
  'manage_announcements': '管理公告',
  'moderate_messages': '管理消息',
  'mute_members': '管理禁言',
};

class _GroupPermissionsPage extends StatefulWidget {
  const _GroupPermissionsPage({
    required this.roomId,
    required this.membershipRevision,
    required this.actorRole,
    required this.policies,
    required this.policiesReady,
  });
  final String roomId;
  final int membershipRevision;
  final String actorRole;
  final List<({String role, Set<String> permissions, int revision})> policies;
  final bool policiesReady;

  @override
  State<_GroupPermissionsPage> createState() => _GroupPermissionsPageState();
}

class _GroupPermissionsPageState extends State<_GroupPermissionsPage> {
  late final Map<String, Set<String>> values = {
    for (final policy in widget.policies)
      policy.role: policy.permissions.toSet(),
    if (!widget.policies.any((policy) => policy.role == 'admin'))
      'admin': {...?widget.policies
          .where((policy) => policy.role == 'admin')
          .firstOrNull
          ?.permissions},
    if (!widget.policies.any((policy) => policy.role == 'member'))
      'member': {
        'send_messages',
        'invite_members',
        'manage_announcements',
        'pin_messages',
      },
  };
  String role = 'member';
  bool saving = false;
  String? error;

  Future<void> save() async {
    if (saving || widget.actorRole != 'owner' || !widget.policiesReady) return;
    setState(() => saving = true);
    try {
      await _SdkScope.of(context)!.client!.updateGroupPermissions(
        widget.roomId,
        widget.membershipRevision,
        role,
        values[role] ?? const {},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('群权限已提交')),
      );
      Navigator.of(context).pop(true);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = values[role] ?? <String>{};
    return _ProfileScaffold(
      title: '群权限',
      actions: [
        if (widget.actorRole == 'owner' && widget.policiesReady)
          TextButton(
            key: const Key('save-group-permissions'),
            onPressed: saving ? null : save,
            child: saving ? const Text('保存中') : const Text('保存'),
          ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'member', label: Text('普通成员')),
              ButtonSegment(value: 'admin', label: Text('管理员')),
            ],
            selected: {role},
            onSelectionChanged: (value) => setState(() => role = value.first),
          ),
        ),
        if (!widget.policiesReady)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '群权限正在同步，暂不能保存。',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          )
        else if (widget.actorRole != 'owner')
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '只有群主可以修改群权限。',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        for (final entry in _groupPermissionLabels.entries)
          SwitchListTile(
            key: Key('group-permission-${entry.key}'),
            title: Text(entry.value),
            value: selected.contains(entry.key),
            onChanged: widget.actorRole == 'owner' && widget.policiesReady
                ? (enabled) => setState(() {
                    final next = {...selected};
                    if (enabled) {
                      next.add(entry.key);
                    } else {
                      next.remove(entry.key);
                    }
                    values[role] = next;
                  })
                : null,
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Text(
            '权限只影响新操作，服务端会按提交时的策略再次校验。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
      ],
    );
  }
}
