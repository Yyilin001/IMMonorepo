part of 'workspace.dart';

// Match the native iOS device build. The integration driver supplies its local endpoints at build time.
const _deviceHost = '120.77.66.38';
const _accountUrl = String.fromEnvironment(
  'IM_ACCOUNT_URL',
  defaultValue: 'https://$_deviceHost',
);
const _gatewayHost = String.fromEnvironment(
  'IM_GATEWAY_HOST',
  defaultValue: _deviceHost,
);
const _gatewayPort = int.fromEnvironment('IM_GATEWAY_PORT', defaultValue: 7443);

class SdkWorkspace extends StatefulWidget {
  const SdkWorkspace({super.key, this.settings});
  final SettingsPersistence? settings;
  @override
  State<SdkWorkspace> createState() => _SdkWorkspaceState();
}

class _SdkWorkspaceState extends State<SdkWorkspace>
    with WidgetsBindingObserver {
  ImClient? client;
  StreamSubscription<ImSession>? sessions;
  StreamSubscription<List<ImConversation>>? list;
  List<ImConversation> rooms = const [];
  ContactDirectory directory = ContactDirectory.fromEntries([]);
  Map<int, ImDirectoryEntry> entries = {};
  final Map<String, ImProfile> profiles = {};
  final Set<String> _profilesRequested = {};
  String? directoryError;
  bool loadingDirectory = false;

  void _rebuildDirectory() {
    if (!mounted) return;
    final titles = {
      for (final room in rooms)
        if (room.peerId != null) room.peerId!: room.title,
    };
    directory = ContactDirectory.fromEntries([
      for (final MapEntry(:key, :value) in entries.entries)
        ContactSummary(
          id: key,
          accountId: value.id,
          name:
              profiles[value.id]?.name ??
              (value.isGroup ? value.title : titles[value.id]) ??
              value.title,
          isGroup: value.isGroup,
        ),
    ]);
  }

  /// Loads bounded, authorized profile cards for visible rows. Missing or denied
  /// rows stay on their conversation title; a failure is retried on the next refresh.
  Future<void> loadProfiles(
    String page,
    Iterable<String> ids, {
    String context = 'relationship',
    String? roomId,
  }) async {
    if (client == null || userId == null) return;
    final wanted = <String>{};
    for (final id in ids) {
      if (id.isNotEmpty && !_profilesRequested.contains(id) && !profiles.containsKey(id)) {
        wanted.add(id);
        if (wanted.length == 50) break;
      }
    }
    if (wanted.isEmpty) return;
    _profilesRequested.addAll(wanted);
    try {
      final rows = await client!.profiles(
        page: page,
        context: context,
        roomId: roomId,
        userIds: wanted.toList(growable: false),
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          profiles[row.userId] = row;
        }
        _rebuildDirectory();
      });
    } catch (_) {
      _profilesRequested.removeAll(wanted);
    }
  }

  void forgetProfile(String id) {
    profiles.remove(id);
    _profilesRequested.remove(id);
  }

  void applyProfile(ImProfile value) {
    setState(() {
      profiles[value.userId] = value;
      _rebuildDirectory();
    });
  }

  ImContactScope contactScope = ImContactScope.accepted;
  bool moreContacts = false, moreGroups = false;
  Future<void> refreshDirectory({
    bool? nextGroups,
    ImContactScope? scope,
  }) async {
    final sessionNavigator = navigator;
    if (userId == null || loadingDirectory) return;
    setState(() {
      if (scope != null && scope != contactScope) {
        contactScope = scope;
        entries = {};
        directory = ContactDirectory.fromEntries([]);
        moreContacts = moreGroups = false;
      }
      loadingDirectory = true;
      directoryError = null;
    });
    try {
      final page = await client!.directoryPage(
        nextGroups: nextGroups,
        scope: contactScope,
      );
      if (!mounted || navigator != sessionNavigator) return;
      entries = {
        if (nextGroups != null) ...entries,
        for (final row in page.entries) keyFor('${row.isGroup}/${row.id}'): row,
      };
      moreContacts = page.moreContacts;
      moreGroups = page.moreGroups;
      setState(_rebuildDirectory);
      final contactIds = [
        for (final value in page.entries)
          if (!value.isGroup) value.id,
      ];
      unawaited(loadProfiles('contacts-ui', contactIds));
    } catch (e) {
      if (mounted && navigator == sessionNavigator) {
        directoryError = _errorText(e);
      }
    } finally {
      if (mounted && navigator == sessionNavigator) {
        setState(() => loadingDirectory = false);
      }
    }
  }

  String? userId, error, listError, accountName;
  bool loadingRooms = false, busy = true;
  var navigator = GlobalKey<NavigatorState>();
  // The reference UI uses integer keys for drafts and avatars. Room identity stays with Swift.
  final _keys = <String, int>{};
  int keyFor(String room) => _keys.putIfAbsent(room, () => _keys.length);
  bool get active => !{
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  }.contains(WidgetsBinding.instance.lifecycleState);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_open));
  }

  Future<void> _open() async {
    if (client != null) return;
    final value = await ImClient.open(
      accountUrl: Uri.parse(_accountUrl),
      gatewayHost: _gatewayHost,
      gatewayPort: _gatewayPort,
    );
    try {
      await value.setForeground(active);
      await value.restoreSession();
    } catch (_) {
      await value.close();
      rethrow;
    }
    if (!mounted) {
      await value.close();
      return;
    }
    client = value;
    sessions = value.sessions.listen(
      _session,
      onError: (Object e) {
        if (mounted) setState(() => error = _errorText(e));
      },
    );
    _session(value.session);
  }

  void _session(ImSession session) {
    if (!mounted) return;
    if (userId != session.userId) {
      userId = session.userId;
      navigator = GlobalKey<NavigatorState>();
      _keys.clear();
      contactScope = ImContactScope.accepted;
      entries = {};
      profiles.clear();
      _profilesRequested.clear();
      _SdkAvatarCache.clear();
      _SdkGroupAvatarCache.clear();
      moreContacts = moreGroups = false;
      directory = ContactDirectory.fromEntries([]);
      directoryError = null;
      loadingDirectory = false;
      rooms = const [];
      listError = null;
      unawaited(list?.cancel());
      list = null;
      final user = userId;
      loadingRooms = user != null;
      if (user != null) {
        list = client!.watchConversations().listen(
          (rows) {
            if (mounted && userId == user) {
              setState(() {
                rooms = rows;
                loadingRooms = false;
                listError = null;
                _rebuildDirectory();
              });
            }
          },
          onError: (Object e) {
            if (mounted && userId == user) {
              setState(() {
                listError = _errorText(e);
                loadingRooms = false;
              });
            }
          },
        );
      } else {
        accountName = null;
      }
    }
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) error = _errorText(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> signIn(String name, String password) async {
    if (busy) return;
    await _run(() async {
      await _open();
      if (!mounted || client!.session.userId != null) return;
      await client!.signIn(name.trim(), password);
      accountName = name.trim();
    });
  }

  /// Patches the visible row before the server projection arrives, then restores
  /// the previous list if the shared runtime rejects the command.
  Future<bool> applyConversationState(
    ImConversation room, {
    bool? pinned,
    bool? archived,
    int? muteUntil,
  }) async {
    if (client == null) return false;
    final previous = rooms;
    void patch(List<ImConversation> rows) => setState(() {
      rooms = rows;
      listError = null;
    });
    patch(_patchConversation(previous, room, pinned, archived, muteUntil));
    try {
      await client!.setConversationState(
        room.id,
        isPinned: pinned,
        isArchived: archived,
        muteUntil: muteUntil,
      );
      return true;
    } catch (e) {
      if (mounted) {
        patch(previous);
        setState(() => listError = _errorText(e));
      }
      return false;
    }
  }

  static List<ImConversation> _patchConversation(
    List<ImConversation> rows,
    ImConversation room,
    bool? pinned,
    bool? archived,
    int? muteUntil,
  ) {
    final patched = [
      for (final row in rows)
        if (row.id != room.id)
          row
        else
          (
            id: row.id,
            title: row.title,
            preview: row.preview,
            unread: row.unread,
            isGroup: row.isGroup,
            isPinned: pinned ?? row.isPinned,
            isArchived: archived ?? row.isArchived,
            updatedAt: row.updatedAt,
            peerId: row.peerId,
            muteUntil: muteUntil ?? row.muteUntil,
          ),
    ];
    patched.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0);
    });
    return patched;
  }

  void signOut() {
    if (!busy) unawaited(_run(client!.signOut));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      unawaited(
        client?.setForeground(state == AppLifecycleState.resumed).catchError((
          Object e,
        ) {
          if (mounted) setState(() => error = _errorText(e));
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(sessions?.cancel());
    unawaited(list?.cancel());
    unawaited(client?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    key: ValueKey(userId),
    overrides: [
      contactDirectoryProvider.overrideWithValue(directory),
      if (widget.settings case final settings?)
        settingsPersistenceProvider.overrideWithValue(settings),
    ],
    child: _SdkScope(
      owner: this,
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (result) => navigator.currentState?.pop(result),
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const _MobileWorkspace()),
        ),
      ),
    ),
  );
}

class _SdkScope extends InheritedWidget {
  const _SdkScope({required this.owner, required super.child});
  final _SdkWorkspaceState owner;
  static _SdkWorkspaceState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SdkScope>()?.owner;
  @override
  bool updateShouldNotify(_SdkScope oldWidget) => true;
}

void _openSdkLogin(BuildContext context) =>
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const _SdkLogin()));

class _SdkLogin extends StatefulWidget {
  const _SdkLogin();
  @override
  State<_SdkLogin> createState() => _SdkLoginState();
}

class _SdkLoginState extends State<_SdkLogin> {
  final account = TextEditingController(), password = TextEditingController();
  @override
  void dispose() {
    account.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context)!;
    void submit() {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(sdk.signIn(account.text, password.text));
    }

    return _ProfileScaffold(
      title: '登录',
      children: [
        const SizedBox(height: 24),
        _InfoCard(
          children: [
            for (final secret in [false, true])
              ListTile(
                leading: Icon(
                  secret ? Icons.lock_outline : Icons.person_outline,
                  color: green,
                ),
                title: TextField(
                  key: ValueKey(secret ? '密码' : '账号'),
                  controller: secret ? password : account,
                  enabled: !sdk.busy,
                  obscureText: secret,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: secret
                      ? TextInputAction.done
                      : TextInputAction.next,
                  onSubmitted: secret ? (_) => submit() : null,
                  decoration: InputDecoration(hintText: secret ? '密码' : '账号'),
                ),
              ),
          ],
        ),
        if (sdk.error case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(message),
          ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('submit-login'),
          onPressed: sdk.busy ? null : submit,
          child: const Text('登录'),
        ),
      ],
    );
  }
}

String _errorText(Object error) {
  final code = error is PlatformException ? error.code : '';
  return switch (code) {
    'authenticationRequired' => '登录失败，请检查账号和密码',
    'networkUnavailable' => '无法连接服务器，请检查网络后重试',
    'identityUnavailable' => '未找到该公开账号',
    'previewUnavailable' => '图片预览已失效，请重新查看',
    'storageUnavailable' => '本地存储暂不可用',
    'busy' => '当前会话正忙，请重试',
    _ =>
      error is FormatException ||
              error is ArgumentError ||
              code == 'invalidConfiguration'
          ? '无法连接服务器，应用的连接配置有误'
          : '操作失败，请重试${code.isEmpty ? '' : '（$code）'}',
  };
}

/// Mirrors the native “隐藏的聊天” list: a second, independent conversation
/// window so archived rows update without disturbing the main list.
class _ArchivedConversationsPage extends ConsumerStatefulWidget {
  const _ArchivedConversationsPage();

  @override
  ConsumerState<_ArchivedConversationsPage> createState() =>
      _ArchivedConversationsPageState();
}

class _ArchivedConversationsPageState
    extends ConsumerState<_ArchivedConversationsPage> {
  Stream<List<ImConversation>>? stream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    stream ??= _SdkScope.of(context)!.client!.watchConversations(
      archived: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context)!;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '隐藏的聊天',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: StreamBuilder<List<ImConversation>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(_errorText(snapshot.error!)));
            }
            final rows = snapshot.data;
            if (rows == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (rows.isEmpty) {
              return const Center(
                child: Text('暂无隐藏的聊天', style: TextStyle(color: muted)),
              );
            }
            return ListView.builder(
              key: const Key('archived-conversation-list'),
              itemCount: rows.length,
              itemExtent: 82,
              itemBuilder: (_, index) {
                final row = rows[index];
                final item = Conversation(
                  id: sdk.keyFor(row.id),
                  name: row.title.isEmpty ? '会话' : row.title,
                  preview: row.preview,
                  unread: row.unread,
                  isGroup: row.isGroup,
                  pinned: row.isPinned,
                  muted:
                      row.muteUntil != null &&
                      row.muteUntil! >
                          DateTime.now().millisecondsSinceEpoch,
                  updatedAt: DateTime.fromMillisecondsSinceEpoch(
                    row.updatedAt ?? 0,
                  ),
                );
                return InkWell(
                  key: ValueKey(row.id),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        backgroundColor: Colors.white,
                        body: SafeArea(child: _SdkChat(room: row)),
                      ),
                    ),
                  ),
                  onLongPress: () =>
                      _showSdkConversationMenu(context, ref, row),
                  child: _ConversationRow(
                    item: item,
                    selected: false,
                    mobile: true,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

}

/// Authorized contact card. The shared runtime resolves the remark, avatar and
/// expiry; this page only renders names and sends a revision-bound alias save.
class _SdkContactProfilePage extends StatefulWidget {
  const _SdkContactProfilePage({
    required this.entry,
    required this.room,
    required this.fallbackName,
    required this.avatarId,
    this.onMessage,
    this.context = 'relationship',
    this.roomId,
  });
  final ImDirectoryEntry entry;
  final ImConversation? room;
  final String fallbackName;
  final int avatarId;
  final VoidCallback? onMessage;
  final String context;
  final String? roomId;

  @override
  State<_SdkContactProfilePage> createState() =>
      _SdkContactProfilePageState();
}

class _SdkContactProfilePageState extends State<_SdkContactProfilePage> {
  ImProfile? profile;
  String? alias;
  String? error;
  Timer? expiry;
  bool initialized = false, loading = true, saving = false;

  @override
  void dispose() {
    expiry?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      unawaited(load());
    }
  }

  Future<void> load() async {
    final sdk = _SdkScope.of(context);
    if (sdk?.client == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rows = await sdk!.client!.openProfile(
        widget.entry.id,
        context: widget.context,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      final value = rows.firstOrNull;
      expiry?.cancel();
      setState(() {
        profile = value;
        alias = value?.alias;
        loading = false;
      });
      if (value != null) {
        sdk.applyProfile(value);
        expiry = Timer(
          Duration(milliseconds: value.remainingMilliseconds),
          () {
            if (!mounted) return;
            setState(() {
              profile = null;
              alias = null;
            });
            unawaited(load());
          },
        );
      }
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = _errorText(failure);
        loading = false;
      });
    }
  }

  Future<void> editAlias() async {
    if (saving) return;
    final controller = TextEditingController(text: alias ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('设置备注'),
        content: TextField(
          key: const Key('contact-alias-input'),
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '备注名',
            hintText: '留空使用对方昵称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;
    final sdk = _SdkScope.of(context);
    final current = profile;
    if (sdk?.client == null || current == null) return;
    final clean = text.trim();
    setState(() => saving = true);
    try {
      await sdk!.client!.saveAlias(
        widget.entry.id,
        alias: clean.isEmpty ? null : clean,
        revision: current.aliasRevision,
      );
      if (!mounted) return;
      final revertedName =
          current.alias != null && current.name == current.alias
          ? widget.fallbackName
          : current.name;
      final updated = (
        page: current.page,
        userId: current.userId,
        name: clean.isEmpty ? revertedName : clean,
        handle: current.handle,
        alias: clean.isEmpty ? null : clean,
        aliasRevision: current.aliasRevision,
        groupNickname: current.groupNickname,
        groupNicknameRevision: current.groupNicknameRevision,
        remainingMilliseconds: current.remainingMilliseconds,
        avatar: current.avatar,
      );
      setState(() {
        profile = updated;
        alias = clean.isEmpty ? null : clean;
        saving = false;
      });
      sdk.applyProfile(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('备注已保存，正在同步')),
      );
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
    final sdk = _SdkScope.of(context);
    final displayName = alias?.isNotEmpty == true
        ? alias!
        : (profile?.name ?? widget.fallbackName);
    return _ProfileScaffold(
      title: '联系人资料',
      actions: [
        IconButton(
          tooltip: '刷新资料',
          onPressed: loading || saving ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        _ProfileHeader(
          id: widget.avatarId,
          name: displayName,
          handle: widget.entry.id,
          avatar: profile?.avatar,
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ),
        if (loading && profile == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        ListTile(
          key: const Key('contact-alias'),
          leading: const Icon(Icons.edit_note_rounded, color: green),
          title: const Text('备注'),
          subtitle: Text(alias?.isNotEmpty == true ? alias! : '未设置备注'),
          trailing: saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded, color: muted),
          onTap: loading || saving ? null : editAlias,
        ),
        if (widget.onMessage != null)
          FilledButton(
            onPressed: widget.onMessage,
            child: const Text('发消息'),
          ),
        if (sdk != null)
          _ContactRelationshipActions(
            userId: widget.entry.id,
            name: displayName,
            scope: sdk.contactScope,
          ),
      ],
    );
  }
}

/// Own profile card backed by the shared avatar/profile intent service. The
/// revision is captured when the page opens and revalidated by the runtime.
class _SdkMyProfilePage extends StatefulWidget {
  const _SdkMyProfilePage();

  @override
  State<_SdkMyProfilePage> createState() => _SdkMyProfilePageState();
}

class _SdkMyProfilePageState extends State<_SdkMyProfilePage> {
  ImAvatarEditor? editor;
  String? name;
  String? error;
  bool initialized = false, loading = true, saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      unawaited(load());
    }
  }

  Future<void> load() async {
    final client = _SdkScope.of(context)?.client;
    if (client == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await client.openAvatarEditor();
      if (!mounted) return;
      setState(() {
        editor = value;
        name = value?.name ?? _SdkScope.of(context)?.accountName;
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

  Future<void> editName() async {
    final value = editor;
    if (value == null || saving) return;
    final controller = TextEditingController(text: name ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          key: const Key('my-profile-name-input'),
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(labelText: '昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final clean = text?.trim();
    if (clean == null || clean.isEmpty || !mounted) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => saving = true);
    try {
      await client.changeAvatar(
        revision: value.revision,
        displayName: clean,
      );
      if (!mounted) return;
      setState(() {
        name = clean;
        saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('昵称已提交，正在同步')),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    }
  }

  Future<void> changeAvatar() async {
    final value = editor;
    if (value == null || saving) return;
    final jpeg = await pickSquareAvatar(context);
    if (jpeg == null || !mounted) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => saving = true);
    try {
      await client.changeAvatar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('头像已提交，正在同步')),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorText(failure))));
    }
  }

  Future<void> removeAvatar() async {
    final value = editor;
    if (value == null || !value.hasAvatar || saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除头像？'),
        content: const Text('移除后，联系人和群成员将看到默认头像。'),
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
    final client = _SdkScope.of(context)!.client!;
    setState(() => saving = true);
    try {
      await client.changeAvatar(
        revision: value.revision,
        action: 'remove',
      );
      if (!mounted) return;
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
    final sdk = _SdkScope.of(context);
    final displayName = name ?? sdk?.accountName ?? '我的资料';
    final handle = editor?.handle ?? sdk?.userId ?? '';
    return _ProfileScaffold(
      title: '个人资料',
      actions: [
        IconButton(
          tooltip: '刷新资料',
          onPressed: loading || saving ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  ChatAvatar(
                    id: 0,
                    name: displayName,
                    size: 88,
                    avatar: editor?.image,
                  ),
                  if (!loading)
                    IconButton.filledTonal(
                      key: const Key('change-my-avatar'),
                      tooltip: '更换头像',
                      onPressed: saving ? null : changeAvatar,
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                displayName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    handle,
                    style: const TextStyle(fontSize: 14, color: muted),
                  ),
                  IconButton(
                    tooltip: '复制公开 ID',
                    icon: const Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: muted,
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: handle));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('公开 ID 已复制')),
                        );
                      }
                    },
                  ),
                ],
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
        if (loading && editor == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        ListTile(
          key: const Key('edit-my-name'),
          leading: const Icon(Icons.badge_outlined, color: green),
          title: const Text('昵称'),
          subtitle: Text(displayName),
          trailing: saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded, color: muted),
          onTap: loading || saving || editor == null ? null : editName,
        ),
        ListTile(
          key: const Key('remove-my-avatar'),
          leading: const Icon(Icons.hide_image_outlined, color: green),
          title: const Text('移除头像'),
          enabled: editor?.hasAvatar == true && !saving,
          onTap: removeAvatar,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Text(
            '公开 ID 用于查找和添加好友，目前不可修改。昵称和头像的修改会同步到账号内的其他设备。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
      ],
    );
  }
}

Uint8List? _squareAvatarJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final side = min(decoded.width, decoded.height);
  if (side < 1) return null;
  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized = img.copyResize(
    cropped,
    width: 512,
    height: 512,
    interpolation: img.Interpolation.average,
  );
  var encoded = img.encodeJpg(resized, quality: 88);
  if (encoded.length > 512 * 1024) {
    encoded = img.encodeJpg(resized, quality: 70);
  }
  return Uint8List.fromList(encoded);
}
