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
      final page = await _SdkScope.of(context)!.client!
          .groupMembers(widget.roomId, next: next);
      if (!mounted) return;
      if (!next) members.clear();
      members.addAll(page.members);
      announcement = page.announcement;
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
    children: [
      if (announcement.isNotEmpty)
        ListTile(title: const Text('群公告'), subtitle: Text(announcement)),
      for (final member in members.entries)
        ListTile(
          title: Text(member.key),
          trailing: Text(switch (member.value) {
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
          onPressed: () => load(next: true),
          child: const Text('更多成员'),
        ),
    ],
  );
}
