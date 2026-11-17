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
  String? directoryError;
  bool loadingDirectory = false;

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
                (value.isGroup ? value.title : titles[value.id]) ?? value.title,
            isGroup: value.isGroup,
          ),
      ]);
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
