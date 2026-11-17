part of 'workspace.dart';

class _CreateGroupPage extends StatefulWidget {
  const _CreateGroupPage();

  @override
  State<_CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<_CreateGroupPage> {
  final handle = TextEditingController();
  final selected = <String, String>{};
  String title = '';
  String? error;
  bool busy = false;

  @override
  void dispose() {
    handle.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context)!;
    final friends = sdk.directory.friends;
    final names = {for (final friend in friends) friend.accountId: friend.name};
    final canAdd = !busy && selected.length < 100;
    return _ProfileScaffold(
      title: '新建群聊',
      actions: [
        TextButton(
          onPressed: busy || title.isEmpty
              ? null
              : () => run(() async {
                  await sdk.client!.createGroup(title, selected.keys.toList());
                  if (context.mounted) Navigator.pop(context, true);
                }),
          child: const Text('创建'),
        ),
      ],
      children: [
        TextField(
          enabled: !busy,
          decoration: const InputDecoration(labelText: '群名称'),
          onChanged: (value) => setState(() => title = value.trim()),
        ),
        Text('群成员（含自己共 ${selected.length + 1} 人）'),
        TextField(
          controller: handle,
          enabled: canAdd,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '通过公开 ID 添加',
            suffixIcon: IconButton(
              tooltip: '添加成员',
              icon: const Icon(Icons.person_add_alt),
              onPressed: !canAdd
                  ? null
                  : () {
                      final value = handle.text.trim();
                      if (value.isEmpty) return;
                      run(() async {
                        final user = await sdk.client!.resolveUserId(value);
                        if (!mounted) return;
                        if (user != sdk.userId) selected[user] = value;
                        handle.clear();
                      });
                    },
            ),
          ),
        ),
        if (error != null) Text(error!),
        for (final member in selected.entries.where(
          (entry) => !names.containsKey(entry.key),
        ))
          CheckboxListTile(
            title: Text(member.value),
            value: true,
            onChanged: busy
                ? null
                : (_) => setState(() => selected.remove(member.key)),
          ),
        for (final friend in friends)
          if (friend.accountId case final user? when user != sdk.userId)
            CheckboxListTile(
              title: Text(friend.name),
              value: selected.containsKey(user),
              onChanged: busy || (!canAdd && !selected.containsKey(user))
                  ? null
                  : (checked) => setState(() {
                      if (checked == true) {
                        selected[user] = friend.name;
                      } else {
                        selected.remove(user);
                      }
                    }),
            ),
        if (sdk.directoryError != null)
          TextButton(
            onPressed: busy || sdk.loadingDirectory
                ? null
                : () => sdk.refreshDirectory(),
            child: Text('${sdk.directoryError} · 重试'),
          )
        else if (sdk.moreContacts)
          TextButton(
            onPressed: busy || sdk.loadingDirectory
                ? null
                : () => sdk.refreshDirectory(nextGroups: false),
            child: const Text('加载更多好友'),
          ),
      ],
    );
  }
}

class _GroupDetailsButton extends StatelessWidget {
  const _GroupDetailsButton({required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context) => ListTile(
    title: const Text('群公告与成员'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _GroupDetailsPage(roomId: roomId),
      ),
    ),
  );
}

class _GroupDetailsPage extends StatefulWidget {
  const _GroupDetailsPage({required this.roomId});
  final String roomId;
  @override
  State<_GroupDetailsPage> createState() => _GroupDetailsPageState();
}

class _GroupDetailsPageState extends State<_GroupDetailsPage> {
  final members = <String, String>{};
  bool initialized = false, loading = false, more = false;
  String announcement = '';
  int? editableAnnouncementRevision, membershipRevision;
  String actorRole = '';
  Set<String> permissions = {};
  bool submitting = false;

  Future<void> change(
    ImMembershipAction action,
    String label, {
    String? target,
    String? role,
  }) async {
    final revision = membershipRevision;
    if (revision == null || submitting || loading) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => submitting = true);
    try {
      final bool? submitted;
      if (action == ImMembershipAction.add) {
        submitted = await showDialog<bool>(
          context: context,
          builder: (_) => _EditTextDialog(
            title: '通过公开 ID 添加成员',
            original: '',
            save: (handle) async {
              final id = await client.resolveUserId(handle.trim());
              await client.changeMembership(
                widget.roomId,
                revision,
                action,
                target: id,
              );
            },
          ),
        );
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text('确认$label？'),
            content: Text(target ?? widget.roomId),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(label),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
        await client.changeMembership(
          widget.roomId,
          revision,
          action,
          target: target,
          role: role,
        );
        submitted = true;
      }
      if (!mounted || submitted != true) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已提交「$label」')));
      await load();
    } catch (failure) {
      if (mounted) setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget? memberMenu(String user, String role) {
    if (role == 'owner' || user == _SdkScope.of(context)!.userId) return null;
    final actions = {
      if (permissions.contains('change_member_roles'))
        ImMembershipAction.role: role == 'admin' ? '设为成员' : '设为管理员',
      if (permissions.contains('remove_members'))
        ImMembershipAction.remove: '移除成员',
      if (actorRole == 'owner') ImMembershipAction.transfer: '转让群主',
    };
    if (actions.isEmpty) return null;
    return PopupMenuButton<ImMembershipAction>(
      tooltip: '成员操作',
      enabled: !loading && !submitting && error == null,
      itemBuilder: (_) => [
        for (final action in actions.entries)
          PopupMenuItem(value: action.key, child: Text(action.value)),
      ],
      onSelected: (action) => change(
        action,
        actions[action]!,
        target: user,
        role: action == ImMembershipAction.role
            ? (role == 'admin' ? 'member' : 'admin')
            : null,
      ),
    );
  }

  String? error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      unawaited(load());
    }
  }

  Future<void> load({bool next = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final client = _SdkScope.of(context)!.client!;
      var page = await client.groupMembers(widget.roomId, next: next);
      if (!mounted) return;
      final changed = next && page.membershipRevision != membershipRevision;
      if (changed) {
        page = await client.groupMembers(widget.roomId);
        if (!mounted) return;
      }
      if (!next || changed) members.clear();
      members.addAll(page.members);
      announcement = page.announcement;
      editableAnnouncementRevision = page.editableAnnouncementRevision;
      membershipRevision = page.membershipRevision;
      actorRole = page.actorRole;
      permissions = page.permissions;
      more = page.hasMore;
    } catch (failure) {
      if (mounted) error = _errorText(failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => _ProfileScaffold(
    title: '群公告与成员',
    actions: [
      IconButton(
        tooltip: '刷新',
        onPressed: loading || submitting ? null : load,
        icon: const Icon(Icons.refresh),
      ),
    ],
    children: [
      if (announcement.isNotEmpty || editableAnnouncementRevision != null)
        ListTile(
          title: const Text('群公告'),
          subtitle: Text(announcement.isEmpty ? '暂无公告' : announcement),
          trailing: editableAnnouncementRevision == null
              ? null
              : IconButton(
                  tooltip: '编辑群公告',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: loading || submitting || error != null
                      ? null
                      : () async {
                          final revision = editableAnnouncementRevision!;
                          final client = _SdkScope.of(context)!.client!;
                          final saved = await showDialog<bool>(
                            context: context,
                            builder: (_) => _EditTextDialog(
                              title: '编辑群公告',
                              original: announcement,
                              allowEmpty: true,
                              save: (text) => client.updateAnnouncement(
                                widget.roomId,
                                revision,
                                text,
                              ),
                            ),
                          );
                          if (saved == true && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已提交公告更新')),
                            );
                            await load();
                          }
                        },
                ),
        ),

      if (permissions.contains('invite_members'))
        TextButton(
          onPressed: loading || submitting || error != null
              ? null
              : () => change(ImMembershipAction.add, '添加成员'),
          child: const Text('添加成员'),
        ),
      for (final member in members.entries)
        ListTile(
          title: Text(member.key),
          trailing: memberMenu(member.key, member.value),
          subtitle: Text(switch (member.value) {
            'owner' => '群主',
            'admin' => '管理员',
            _ => '成员',
          }),
        ),
      if (loading)
        const Center(child: CircularProgressIndicator())
      else if (error != null)
        TextButton(onPressed: load, child: Text('$error · 重新加载'))
      else if (more)
        TextButton(
          onPressed: submitting ? null : () => load(next: true),
          child: const Text('更多成员'),
        ),
      if (membershipRevision != null && error == null)
        TextButton(
          onPressed: submitting || loading
              ? null
              : () => actorRole == 'owner'
                    ? change(ImMembershipAction.dissolve, '解散群聊')
                    : change(ImMembershipAction.leave, '退出群聊'),
          child: Text(actorRole == 'owner' ? '解散群聊' : '退出群聊'),
        ),
    ],
  );
}
