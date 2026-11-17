part of 'workspace.dart';

extension _SectionPresentation on WorkspaceSection {
  String get label => switch (this) {
    WorkspaceSection.messages => '消息',
    WorkspaceSection.contacts => '联系人',
    WorkspaceSection.me => '我',
  };
  IconData get icon => switch (this) {
    WorkspaceSection.messages => Icons.chat_bubble_outline_rounded,
    WorkspaceSection.contacts => Icons.people_outline_rounded,
    WorkspaceSection.me => Icons.person_outline_rounded,
  };
}

class _NavigationIcon extends StatelessWidget {
  const _NavigationIcon({required this.tab, this.color});
  final WorkspaceSection tab;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final icon = Icon(tab.icon, color: color);
    if (tab != WorkspaceSection.messages) return icon;
    return Consumer(
      builder: (_, ref, _) {
        final showBadge = ref.watch(
          appSettingsProvider.select((s) => s.unreadBadge),
        );
        if (!showBadge) return icon;
        final sdk = _SdkScope.of(context);
        final unread = sdk == null
            ? ref.watch(totalUnreadProvider)
            : sdk.rooms.fold<int>(0, (count, room) => count + room.unread);
        return Semantics(
          label: unread == 0 ? '没有未读消息' : '$unread 条未读消息',
          child: Badge(
            key: const Key('total-unread-badge'),
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: icon,
          ),
        );
      },
    );
  }
}

void _showContactProfile(
  BuildContext context,
  int id, {
  ValueChanged<int>? onMessage,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/profile/$id'),
        builder: (pageContext) => ContactProfilePage(
          id: id,
          onMessage: (targetId) {
            if (onMessage == null) {
              final container = ProviderScope.containerOf(
                pageContext,
                listen: false,
              );
              Navigator.of(pageContext).pop();
              if (container.read(selectedConversationProvider) != targetId) {
                container
                    .read(selectedConversationProvider.notifier)
                    .select(targetId);
              }
            } else {
              onMessage(targetId);
            }
          },
        ),
      ),
    ),
  );
}

void _showMyProfile(BuildContext context) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/me/profile'),
      builder: (_) => const MyProfilePage(),
    ),
  ),
);

void _editMyProfile(BuildContext context) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/me/edit'),
      builder: (_) => const EditProfilePage(),
    ),
  ),
);

class ContactsPane extends ConsumerStatefulWidget {
  const ContactsPane({
    super.key,
    required this.onOpen,
    this.searchPage = false,
  });
  final ValueChanged<int> onOpen;
  final bool searchPage;
  @override
  ConsumerState<ContactsPane> createState() => _ContactsPaneState();
}

class _ContactsPaneState extends ConsumerState<ContactsPane> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    search.text = ref.read(contactFilterProvider).query;
    searchFocus.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  Future<void> _openSearch() async {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    await _openDirectorySearch(
      context,
      ContactsPane(searchPage: true, onOpen: widget.onOpen),
      '/search/contacts',
    );
    if (!mounted) return;
    ref.read(contactFilterProvider.notifier).filter(query: '');
    _restoreDirectoryOffset(scroll, offset);
  }

  SearchDirectory get _directory => ref.read(contactFilterProvider).groups
      ? SearchDirectory.groups
      : SearchDirectory.friends;
  void _rememberSearch() =>
      _rememberDirectoryQuery(context, ref, _directory, search.text);

  void _cancelSearch() {
    if (widget.searchPage) {
      Navigator.of(context).pop();
      return;
    }
    _rememberSearch();
    search.clear();
    _filter(query: '');
    searchFocus.unfocus();
  }

  @override
  void dispose() {
    searchFocus.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _filter({String? query, bool? groups}) {
    ref
        .read(contactFilterProvider.notifier)
        .filter(query: query, groups: groups);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(contactFilterProvider);
    final groups = filter.groups;
    final mobile = _usesMobileWorkspace(MediaQuery.sizeOf(context).width);
    final searching =
        widget.searchPage ||
        (!mobile && (searchFocus.hasFocus || filter.query.isNotEmpty));
    final directory = ref.watch(contactDirectoryProvider);
    final owner = _SdkScope.of(context);
    return _SearchScope(
      active: searching && !widget.searchPage,
      onPageExit: widget.searchPage ? _rememberSearch : null,
      onCancel: _cancelSearch,
      child: Material(
        color: Colors.white,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!searching)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '联系人',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${number(directory.friends.length)} ${owner != null && owner.contactScope != ImContactScope.accepted ? '条关系记录' : '位好友'} · ${number(directory.groups.length)} 个群聊',
                          style: const TextStyle(fontSize: 13, color: muted),
                        ),
                      ],
                    ),
                  ),
                if (mobile && !widget.searchPage)
                  _SearchEntry(
                    entryKey: const Key('open-contact-search'),
                    tag: _SearchBarTag.contacts,
                    hint: '搜索昵称、备注、标签或账号',
                    onTap: _openSearch,
                  )
                else
                  _DirectorySearchField(
                    autofocus: widget.searchPage,
                    fieldKey: const Key('contact-search'),
                    tag: _SearchBarTag.contacts,
                    onSubmitted: _rememberSearch,
                    controller: search,
                    focus: searchFocus,
                    active: searching,
                    hint: '搜索昵称、备注、标签或账号',
                    onChanged: (text) => _filter(query: text),
                    onCancel: _cancelSearch,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                  child: Row(
                    children: [
                      _Filter(
                        mobile: true,
                        label: owner == null
                            ? '好友'
                            : _scopeLabel(owner.contactScope),
                        selected: !groups,
                        onTap: () {
                          searchFocus.unfocus();
                          _filter(groups: false);
                        },
                      ),
                      const SizedBox(width: 8),
                      _Filter(
                        mobile: true,
                        label: '群聊',
                        selected: groups,
                        onTap: () {
                          searchFocus.unfocus();
                          _filter(groups: true);
                        },
                      ),
                      if (owner?.userId != null && groups)
                        IconButton(
                          tooltip: '新建群聊',
                          icon: const Icon(Icons.group_add_outlined),
                          onPressed: owner!.loadingDirectory
                              ? null
                              : () async {
                                  if (owner.contactScope !=
                                      ImContactScope.accepted) {
                                    await owner.refreshDirectory(
                                      scope: ImContactScope.accepted,
                                    );
                                  }
                                  if (!context.mounted) return;
                                  final created = await Navigator.of(context)
                                      .push<bool>(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const _CreateGroupPage(),
                                        ),
                                      );
                                  if (created == true && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已提交建群请求')),
                                    );
                                    await owner.refreshDirectory();
                                  }
                                },
                        )
                      else if (owner?.userId != null)
                        IconButton(
                          tooltip: '添加好友',
                          icon: const Icon(Icons.person_add_outlined),
                          onPressed: () async {
                            final requested = await showDialog<bool>(
                              context: context,
                              builder: (_) =>
                                  _RequestContactDialog(client: owner!.client!),
                            );
                            if (requested == true && context.mounted) {
                              _filter(groups: false);
                              await owner!.refreshDirectory(
                                scope: ImContactScope.outgoing,
                              );
                            }
                          },
                        ),
                      if (owner?.userId != null)
                        PopupMenuButton<ImContactScope>(
                          tooltip: '切换联系人分类',
                          enabled: !owner!.loadingDirectory,
                          onSelected: (scope) {
                            _filter(groups: false);
                            unawaited(owner.refreshDirectory(scope: scope));
                          },
                          itemBuilder: (_) => [
                            for (final scope in ImContactScope.values)
                              PopupMenuItem(
                                value: scope,
                                child: Text(_scopeLabel(scope)),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (searching && filter.query.isNotEmpty)
                  _SearchResultsLabel(groups ? '群聊搜索结果' : '联系人搜索结果'),
                Expanded(
                  child: searching && filter.query.isEmpty
                      ? _RecentSearchPanel(
                          directory: _directory,
                          hint: groups ? '输入群名称或账号' : '输入昵称、备注、标签或账号',
                          controller: search,
                          focus: searchFocus,
                          onChanged: (text) => _filter(query: text),
                        )
                      : Consumer(
                          builder: (_, ref, _) {
                            final sdk = _SdkScope.of(context);
                            if (sdk != null && sdk.userId == null) {
                              return Center(
                                child: TextButton(
                                  onPressed: () => _openSdkLogin(context),
                                  child: const Text('登录后查看联系人'),
                                ),
                              );
                            }
                            if (sdk?.loadingDirectory == true &&
                                sdk!.entries.isEmpty) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            if (sdk?.directoryError case final error?) {
                              return Center(
                                child: TextButton(
                                  onPressed: sdk!.refreshDirectory,
                                  child: Text('$error · 重试'),
                                ),
                              );
                            }
                            final index = ref.watch(contactIndexProvider);
                            final more =
                                sdk != null &&
                                (groups ? sdk.moreGroups : sdk.moreContacts);
                            if (index.rows.isEmpty && !more) {
                              return const Center(
                                child: Text(
                                  '没有找到联系人',
                                  key: Key('contacts-empty'),
                                  style: TextStyle(color: muted, fontSize: 15),
                                ),
                              );
                            }
                            return Row(
                              children: [
                                Expanded(
                                  child: ListView.builder(
                                    key: const Key('contacts-list'),
                                    controller: scroll,
                                    keyboardDismissBehavior:
                                        ScrollViewKeyboardDismissBehavior
                                            .onDrag,
                                    itemExtentBuilder: (row, _) =>
                                        row == index.rows.length
                                        ? 52
                                        : index.rows[row].extent,
                                    itemCount:
                                        index.rows.length + (more ? 1 : 0),
                                    itemBuilder: (_, row) {
                                      if (row == index.rows.length) {
                                        return TextButton(
                                          onPressed: sdk!.loadingDirectory
                                              ? null
                                              : () => sdk.refreshDirectory(
                                                  nextGroups: groups,
                                                ),
                                          child: Text(
                                            sdk.loadingDirectory
                                                ? '正在加载…'
                                                : groups
                                                ? '加载更多群聊'
                                                : '加载更多${_scopeLabel(sdk.contactScope)}',
                                          ),
                                        );
                                      }
                                      final entry = index.rows[row];
                                      final c = entry.contact;
                                      if (c == null) {
                                        return Container(
                                          key: ValueKey(
                                            'contact-section-${entry.letter}',
                                          ),
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                          ),
                                          color: const Color(0xFFF3F6F4),
                                          child: Text(
                                            entry.letter!,
                                            style: const TextStyle(
                                              color: green,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        );
                                      }
                                      return ListTile(
                                        key: ValueKey('contact-${c.id}'),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 6,
                                            ),
                                        leading: _contactListAvatar(
                                          context,
                                          c,
                                        ),
                                        title: Text(
                                          c.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: ink,
                                          ),
                                        ),
                                        subtitle: Text(
                                          c.handle,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: muted,
                                          ),
                                        ),
                                        trailing: const Icon(
                                          Icons.chevron_right_rounded,
                                          size: 20,
                                          color: muted,
                                        ),
                                        onTap: () {
                                          _rememberSearch();
                                          widget.onOpen(c.id);
                                        },
                                      );
                                    },
                                  ),
                                ),
                                if (!searching)
                                  _ContactAlphabet(
                                    available: index.letterOffsets.keys.toSet(),
                                    onSelect: (letter) {
                                      FocusManager.instance.primaryFocus
                                          ?.unfocus();
                                      if (scroll.hasClients) {
                                        scroll.jumpTo(
                                          index.letterOffsets[letter]!.clamp(
                                            0.0,
                                            max(
                                              0.0,
                                              index.totalExtent -
                                                  scroll
                                                      .position
                                                      .viewportDimension,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactAlphabet extends StatelessWidget {
  const _ContactAlphabet({required this.available, required this.onSelect});
  final Set<String> available;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 28,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ#'.split(''))
              Semantics(
                label: '跳到 $letter',
                button: true,
                enabled: available.contains(letter),
                child: SizedBox(
                  height: 18,
                  width: 28,
                  child: InkWell(
                    key: ValueKey('contact-letter-$letter'),
                    onTap: available.contains(letter)
                        ? () => onSelect(letter)
                        : null,
                    child: Center(
                      child: Text(
                        letter,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: available.contains(letter)
                              ? green
                              : const Color(0xFFC5CECA),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class PersonalPane extends ConsumerWidget {
  const PersonalPane({super.key, required this.onMetrics});
  final VoidCallback? onMetrics;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sdk = _SdkScope.of(context);
    final profile = sdk == null
        ? ref.watch(myProfileProvider)
        : MyProfile(
            name: sdk.accountName ?? (sdk.userId == null ? '未登录' : '我的账号'),
            bio: '',
          );
    final directory = ref.watch(contactDirectoryProvider);
    return ColoredBox(
      color: const Color(0xFFF5F7F6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            key: const Key('personal-page'),
            padding: const EdgeInsets.all(20),
            children: [
              const Row(
                children: [
                  Expanded(
                    child: Text(
                      '我',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                  _SettingsButton(),
                ],
              ),
              const SizedBox(height: 24),
              Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('my-profile-card'),
                  onTap: sdk == null
                      ? () => _showMyProfile(context)
                      : sdk.userId == null
                      ? () => _openSdkLogin(context)
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const _SdkMyProfilePage(),
                          ),
                        ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        ChatAvatar(
                          id: MyProfile.avatarId,
                          name: profile.name,
                          size: 64,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                sdk == null
                                    ? '账号：${profile.handle}'
                                    : sdk.userId ?? '登录账号',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                sdk != null
                                    ? (sdk.userId == null
                                          ? ''
                                          : sdk.client!.session.state ==
                                                ImSessionState.connected
                                          ? '已连接'
                                          : '等待连接')
                                    : profile.bio.isEmpty
                                    ? '还没有填写签名'
                                    : profile.bio,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: muted),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _InfoCard(
                children: [
                  _ProfileInfo(
                    label: '好友',
                    value: '${number(directory.friends.length)} 位',
                  ),
                  _ProfileInfo(
                    label: '群聊',
                    value: '${number(directory.groups.length)} 个',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _InfoCard(
                children: [
                  if (sdk?.userId != null) const _TransfersLink(),
                  if (sdk != null)
                    ListTile(
                      key: const Key('account-action'),
                      leading: Icon(
                        sdk.userId == null ? Icons.login : Icons.logout,
                        color: green,
                      ),
                      title: Text(sdk.userId == null ? '登录' : '退出登录'),
                      onTap: sdk.busy
                          ? null
                          : sdk.userId == null
                          ? () => _openSdkLogin(context)
                          : sdk.signOut,
                    ),
                  if (sdk == null)
                    ListTile(
                      key: const Key('edit-my-profile'),
                      leading: const Icon(Icons.edit_outlined, color: green),
                      title: const Text('编辑资料'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _editMyProfile(context),
                    ),
                  if (sdk == null)
                    ListTile(
                      leading: const Icon(Icons.tune_rounded, color: green),
                      title: const Text('运行监控'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onMetrics,
                    ),
                  ListTile(
                    leading: const Icon(
                      Icons.info_outline_rounded,
                      color: green,
                    ),
                    title: const Text('关于涟漪'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showAboutRipple(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (sdk == null)
                const Text(
                  '当前为本地体验账号，资料修改在重启后恢复默认。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: muted, height: 1.5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: line),
    ),
    child: Column(children: children),
  );
}

class _ProfileInfo extends StatelessWidget {
  const _ProfileInfo({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 85,
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, color: muted),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '未填写' : value,
            style: const TextStyle(fontSize: 15, color: ink, height: 1.4),
          ),
        ),
      ],
    ),
  );
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.id,
    required this.name,
    required this.handle,
    this.group = false,
    this.avatar,
  });
  final int id;
  final String name, handle;
  final bool group;
  final Uint8List? avatar;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Column(
      children: [
        ChatAvatar(
          id: id,
          name: name,
          group: group,
          size: 80,
          avatar: avatar,
        ),
        const SizedBox(height: 16),
        Text(
          name,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                handle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: muted),
              ),
            ),
            IconButton(
              tooltip: '复制账号',
              icon: const Icon(Icons.copy_rounded, size: 17, color: muted),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: handle));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('账号已复制')));
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _ProfileScaffold extends StatelessWidget {
  const _ProfileScaffold({
    required this.title,
    required this.children,
    this.actions,
  });
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF5F7F6),
    appBar: AppBar(
      title: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      actions: actions,
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: children,
          ),
        ),
      ),
    ),
  );
}

class ContactProfilePage extends ConsumerWidget {
  const ContactProfilePage({
    super.key,
    required this.id,
    required this.onMessage,
  });
  final int id;
  final ValueChanged<int> onMessage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(contactProfileProvider(id));
    final notes = ref.watch(contactNotesProvider(id));
    final c = profile.contact;
    final date = profile.addedAt;
    return _ProfileScaffold(
      title: c.isGroup ? '群聊资料' : '个人资料',
      actions: [
        IconButton(
          key: const Key('contact-profile-settings'),
          tooltip: '资料设置',
          icon: const Icon(Icons.more_horiz_rounded, color: ink),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: RouteSettings(name: '/contact/$id/settings'),
              builder: (_) => ContactOptionsPage(
                id: id,
                onDeleted: () {
                  if (context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true &&
                      Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ),
          ),
        ),
      ],
      children: [
        _ProfileHeader(
          id: id,
          name: c.name,
          handle: c.handle,
          group: c.isGroup,
        ),
        if (notes.deleted) ...[
          const Text(
            '已删除该联系人',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: muted),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('profile-restore-contact'),
            onPressed: () => _restoreContact(context, ref, id),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('重新添加联系人', style: TextStyle(fontSize: 16)),
          ),
          TextButton(
            key: const Key('profile-view-deleted-chat'),
            onPressed: () => onMessage(id),
            child: const Text('查看已有聊天记录'),
          ),
        ] else
          FilledButton.icon(
            key: const Key('profile-send-message'),
            onPressed: () => onMessage(id),
            style: FilledButton.styleFrom(
              backgroundColor: green,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
            label: Text(
              c.isGroup ? '进入群聊' : '发消息',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        if (c.isGroup)
          _GroupMembers(
            groupId: id,
            count: profile.memberCount!,
            onMessage: onMessage,
          ),
        const _SettingsHeading('备注与联系信息'),
        _InfoCard(
          children: [
            if (notes.deleted) ...[
              _ProfileInfo(label: '原备注', value: notes.remark),
              if (notes.tags.isNotEmpty)
                _ProfileInfo(label: '标签', value: notes.tags.join(' · ')),
            ] else
              _SettingsLink(
                id: 'contact-edit-notes',
                icon: Icons.edit_note_rounded,
                title: notes.remark.isEmpty ? '设置备注与标签' : notes.remark,
                subtitle: notes.tags.isEmpty
                    ? '添加标签、联系方式和补充说明'
                    : notes.tags.join(' · '),
                onTap: () => _editContactNotes(context, id),
              ),
            if (notes.phone.isNotEmpty)
              _ContactCopyInfo(label: '电话号码', value: notes.phone),
            if (notes.description.isNotEmpty)
              _ProfileInfo(label: '补充说明', value: notes.description),
          ],
        ),
        const _SettingsHeading('基本资料'),
        _InfoCard(
          children: [
            _ProfileInfo(
              label: c.isGroup ? '群名称' : '昵称',
              value: c.originalName,
            ),
            if (!c.isGroup) _ProfileInfo(label: '地区', value: profile.region),
            _ProfileInfo(label: c.isGroup ? '群介绍' : '个性签名', value: profile.bio),
          ],
        ),
        const _SettingsHeading('更多信息'),
        _InfoCard(
          children: [
            _ProfileInfo(label: '来源', value: profile.source),
            _ProfileInfo(
              label: c.isGroup ? '加入时间' : '添加时间',
              value: '${date.year}年${date.month}月${date.day}日',
            ),
          ],
        ),
        const _ContactNotesNotice(),
        const Text(
          '本地模拟资料',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
  }
}

class _GroupMembers extends ConsumerStatefulWidget {
  const _GroupMembers({
    required this.groupId,
    required this.count,
    required this.onMessage,
  });
  final int groupId, count;
  final ValueChanged<int> onMessage;
  @override
  ConsumerState<_GroupMembers> createState() => _GroupMembersState();
}

class _GroupMembersState extends ConsumerState<_GroupMembers>
    with AutomaticKeepAliveClientMixin {
  bool expanded = false;
  @override
  bool get wantKeepAlive => expanded;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final total = ref.watch(
      imConfigProvider.select((c) => c.conversationCount),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SettingsHeading('群成员')),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 24, 4, 10),
              child: Text(
                '${widget.count} 人',
                style: const TextStyle(color: muted),
              ),
            ),
          ],
        ),
        _InfoCard(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columnCount = (constraints.maxWidth / 76).floor().clamp(
                    1,
                    6,
                  );
                  final limit = columnCount * 2;
                  final count = expanded
                      ? widget.count
                      : min(limit, widget.count);
                  return Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          runSpacing: 4,
                          children: [
                            for (var index = 0; index < count; index++)
                              SizedBox(
                                width: constraints.maxWidth / columnCount,
                                child: _GroupMemberTile(
                                  id: mockGroupMemberAt(
                                    widget.groupId,
                                    index,
                                    total,
                                  ),
                                  onMessage: widget.onMessage,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (widget.count > limit)
                        TextButton(
                          onPressed: () {
                            setState(() => expanded = !expanded);
                            updateKeepAlive();
                          },
                          child: Text(expanded ? '收起成员' : '查看全部成员'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _GroupMemberTile extends ConsumerWidget {
  const _GroupMemberTile({required this.id, required this.onMessage});
  final int? id;
  final ValueChanged<int> onMessage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memberId = id;
    final name = memberId == null
        ? ref.watch(myProfileProvider.select((p) => p.name))
        : ref.watch(contactDisplayNameProvider(memberId));
    return InkWell(
      key: ValueKey('group-member-${memberId ?? "me"}'),
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        if (memberId == null) {
          _showMyProfile(context);
          return;
        }
        final navigator = Navigator.of(context);
        _showContactProfile(
          context,
          memberId,
          onMessage: (targetId) {
            // Close the member profile, then use the group page's entry point.
            navigator.pop();
            onMessage(targetId);
          },
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        child: Column(
          children: [
            ExcludeSemantics(
              child: ChatAvatar(
                id: memberId ?? MyProfile.avatarId,
                name: name,
                size: 44,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: ink),
            ),
          ],
        ),
      ),
    );
  }
}

class MyProfilePage extends ConsumerWidget {
  const MyProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(myProfileProvider);
    return _ProfileScaffold(
      title: '我的资料',
      actions: const [_SettingsButton()],
      children: [
        _ProfileHeader(id: MyProfile.avatarId, name: p.name, handle: p.handle),
        _InfoCard(
          children: [
            _ProfileInfo(label: '昵称', value: p.name),
            _ProfileInfo(label: '地区', value: p.region),
            _ProfileInfo(label: '个性签名', value: p.bio),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('profile-edit'),
          onPressed: () => _editMyProfile(context),
          style: FilledButton.styleFrom(
            backgroundColor: green,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
          ),
          icon: const Icon(Icons.edit_outlined, size: 20),
          label: const Text('编辑资料', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});
  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, region, bio;
  @override
  void initState() {
    super.initState();
    final p = ref.read(myProfileProvider);
    name = TextEditingController(text: p.name);
    region = TextEditingController(text: p.region);
    bio = TextEditingController(text: p.bio);
  }

  @override
  void dispose() {
    name.dispose();
    region.dispose();
    bio.dispose();
    super.dispose();
  }

  void _save() {
    if (!form.currentState!.validate()) return;
    ref
        .read(myProfileProvider.notifier)
        .save(name: name.text, region: region.text, bio: bio.text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _ProfileScaffold(
    title: '编辑资料',
    actions: [
      TextButton(
        key: const Key('save-profile'),
        onPressed: _save,
        child: const Text('保存', style: TextStyle(fontSize: 16, color: green)),
      ),
    ],
    children: [
      const SizedBox(height: 24),
      Form(
        key: form,
        child: Column(
          children: [
            _field('昵称', 'profile-name', name, 24, required: true),
            const SizedBox(height: 20),
            _field('地区', 'profile-region', region, 32),
            const SizedBox(height: 20),
            _field('个性签名', 'profile-bio', bio, 120, lines: 3),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        '保存后立即更新个人页；重启后恢复默认资料。',
        style: TextStyle(fontSize: 12, color: muted),
      ),
    ],
  );
  Widget _field(
    String label,
    String key,
    TextEditingController controller,
    int limit, {
    bool required = false,
    int lines = 1,
  }) => TextFormField(
    key: Key(key),
    controller: controller,
    maxLength: limit,
    minLines: lines,
    maxLines: lines,
    validator: (value) =>
        required && (value?.trim().isEmpty ?? true) ? '请输入昵称' : null,
    style: const TextStyle(fontSize: 16, color: ink),
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: line),
      ),
    ),
  );
}

String _scopeLabel(ImContactScope scope) => switch (scope) {
  ImContactScope.accepted => '好友',
  ImContactScope.incoming => '收到的申请',
  ImContactScope.outgoing => '发出的申请',
  ImContactScope.blocked => '黑名单',
};

class _ContactRelationshipActions extends StatefulWidget {
  const _ContactRelationshipActions({
    required this.userId,
    required this.name,
    required this.scope,
  });
  final String userId, name;
  final ImContactScope scope;

  @override
  State<_ContactRelationshipActions> createState() =>
      _ContactRelationshipActionsState();
}

class _ContactRelationshipActionsState
    extends State<_ContactRelationshipActions> {
  bool busy = false;
  String? error;

  Future<void> submit(ImSocialAction action, String label) async {
    if (busy) return;
    final sdk = _SdkScope.of(context)!;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('确认$label？'),
          content: Text(widget.name),
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
      if (confirmed != true || !mounted) return;
      await sdk.client!.socialAction(widget.userId, action);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已提交「$label」')));
      unawaited(sdk.refreshDirectory());
      Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = _errorText(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = switch (widget.scope) {
      ImContactScope.accepted => {
        ImSocialAction.remove: '删除好友',
        ImSocialAction.block: '加入黑名单',
      },
      ImContactScope.incoming => {
        ImSocialAction.accept: '接受申请',
        ImSocialAction.reject: '拒绝申请',
        ImSocialAction.block: '加入黑名单',
      },
      ImContactScope.outgoing => {ImSocialAction.block: '加入黑名单'},
      ImContactScope.blocked => {ImSocialAction.unblock: '移出黑名单'},
    };
    return Column(
      children: [
        if (widget.scope == ImContactScope.outgoing) const Text('等待对方处理'),
        for (final entry in actions.entries)
          TextButton(
            onPressed: busy ? null : () => submit(entry.key, entry.value),
            child: Text(entry.value),
          ),
        if (error != null) Text(error!),
      ],
    );
  }
}

class _RequestContactDialog extends StatefulWidget {
  const _RequestContactDialog({required this.client});
  final ImClient client;

  @override
  State<_RequestContactDialog> createState() => _RequestContactDialogState();
}

class _RequestContactDialogState extends State<_RequestContactDialog> {
  String handle = '';
  String? error;
  bool busy = false;

  Future<void> submit() async {
    if (busy || handle.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.client.requestContact(handle);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = _errorText(failure);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加好友'),
    content: TextField(
      enabled: !busy,
      autofocus: true,
      autocorrect: false,
      decoration: InputDecoration(labelText: '对方的公开账号', errorText: error),
      onChanged: (value) => setState(() => handle = value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy || handle.isEmpty ? null : submit,
        child: const Text('发送申请'),
      ),
    ],
  );
}

Widget _contactListAvatar(BuildContext context, ContactSummary contact) {
  final sdk = _SdkScope.of(context);
  if (sdk != null && !contact.isGroup && contact.accountId != null) {
    return SdkAvatar(
      userId: contact.accountId!,
      name: contact.name,
      context: 'relationship',
      size: 48,
    );
  }
  return ChatAvatar(
    id: contact.id,
    name: contact.name,
    group: contact.isGroup,
    size: 48,
  );
}
