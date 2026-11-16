part of 'workspace.dart';

/// Phone navigation keeps the conversation list mounted underneath the chat,
/// preserving its search and scroll position across back-button/edge gestures.
class _MobileWorkspace extends ConsumerStatefulWidget {
  const _MobileWorkspace({this.onMetrics});
  final VoidCallback? onMetrics;

  @override
  ConsumerState<_MobileWorkspace> createState() => _MobileWorkspaceState();
}

// A phone in landscape still uses one pane. Read the window before the
// Scaffold deducts the keyboard, so typing never changes the column count.
bool _usesChatSidebar(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return defaultTargetPlatform == TargetPlatform.iOS &&
      size.shortestSide >= 600;
}

class _MobileWorkspaceState extends ConsumerState<_MobileWorkspace> {
  bool _opening = false;
  final _visited = {WorkspaceSection.messages};

  @override
  void initState() {
    super.initState();
    // Initial navigation only; incoming messages never wait for this callback.
    Future.microtask(() {
      if (mounted && _SdkScope.of(context) == null) {
        ref.read(selectedConversationProvider.notifier).select(null);
      }
    });
  }

  Widget _panes(
    BuildContext context, {
    required Widget list,
    required Widget chat,
  }) {
    final split = _usesChatSidebar(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final listWidth = (constraints.maxWidth * .34).clamp(222.0, 320.0);
        return Row(
          children: [
            if (split) ...[
              SizedBox(width: listWidth, child: list),
              const VerticalDivider(width: 1, color: line),
            ],
            Expanded(key: const ValueKey('conversation-detail'), child: chat),
          ],
        );
      },
    );
  }

  void _open(int id) {
    if (_opening) return;
    _opening = true;
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(selectedConversationProvider.notifier).select(id);
    final route = MaterialPageRoute<void>(
      settings: RouteSettings(name: '/conversation/$id'),
      builder: (routeContext) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            child: _panes(
              routeContext,
              list: ConversationPane(
                mobile: true,
                onMetrics: widget.onMetrics,
                onOpen: (target) {
                  Navigator.of(routeContext)
                      .popUntil((r) => r == ModalRoute.of(routeContext));
                  if (ref.read(selectedConversationProvider) != target) {
                    ref
                        .read(selectedConversationProvider.notifier)
                        .select(target);
                  }
                },
              ),
              chat: ChatPane(
                mobile: true,
                onBack: () => Navigator.of(routeContext).pop(),
              ),
            ),
          ),
        ),
      ),
    );
    unawaited(Navigator.of(context).push(route));
    // Keep the chat's selection until the interactive return transition ends.
    unawaited(
      route.completed.then((_) {
        _opening = false;
        if (mounted) {
          ref.read(selectedConversationProvider.notifier).select(null);
        }
      }),
    );
  }

  void _openSdk(ImConversation room) {
    if (_opening) return;
    _opening = true;
    FocusManager.instance.primaryFocus?.unfocus();
    final selection = ValueNotifier(room);
    final route = MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: _panes(
            context,
            list: ConversationPane(
              mobile: true,
              onSdkOpen: (next) => selection.value = next,
            ),
            chat: ValueListenableBuilder(
              valueListenable: selection,
              builder: (_, current, _) =>
                  _SdkChat(key: ValueKey(current.id), room: current),
            ),
          ),
        ),
      ),
    );
    Navigator.of(context).push(route);
    route.completed.whenComplete(() {
      _opening = false;
      selection.dispose();
    });
  }

  void _openEntry(_SdkWorkspaceState sdk, int id) {
    final entry = sdk.entries[id];
    if (entry == null) return;
    final room = sdk.rooms
        .where((r) => entry.isGroup ? r.id == entry.id : r.peerId == entry.id)
        .firstOrNull;
    final title = room?.title ?? entry.title;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _ProfileScaffold(
          title: entry.isGroup ? '群聊资料' : '联系人资料',
          children: [
            _ProfileHeader(
              id: id,
              name: title,
              handle: entry.id,
              group: entry.isGroup,
            ),
            if (room != null || entry.isGroup)
              FilledButton(
                child: const Text('发消息'),
                onPressed: () {
                  Navigator.pop(context);
                  _openSdk(
                    room ??
                        (
                          id: entry.id,
                          title: title,
                          preview: '',
                          unread: 0,
                          isGroup: true,
                          updatedAt: null,
                          peerId: null,
                        ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _conversationHome(BuildContext context) {
    final list = ConversationPane(
      mobile: true,
      onMetrics: widget.onMetrics,
      onOpen: _open,
      onSdkOpen: _openSdk,
    );
    if (!_usesChatSidebar(context)) return list;
    return _panes(
      context,
      list: list,
      chat: const Center(
        child: Text('选择一个会话，开始交流', style: TextStyle(color: muted)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context);
    final section = ref.watch(workspaceSectionProvider);
    _visited.add(section);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: Colors.white,
        bottomNavigationBar: NavigationBar(
          key: const Key('main-navigation'),
          height: 64,
          backgroundColor: Colors.white,
          indicatorColor: mint,
          selectedIndex: section.index,
          onDestinationSelected: (index) {
            FocusManager.instance.primaryFocus?.unfocus();
            if (index != WorkspaceSection.messages.index) {
              unawaited(sdk?.refreshDirectory());
            }
            ref
                .read(workspaceSectionProvider.notifier)
                .select(WorkspaceSection.values[index]);
          },
          destinations: [
            for (final tab in WorkspaceSection.values)
              NavigationDestination(
                key: Key('nav-${tab.name}'),
                icon: _NavigationIcon(tab: tab),
                label: tab.label,
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (sdk == null)
                Consumer(
                  builder: (_, ref, _) {
                    final error = ref.watch(
                      mockRuntimeProvider.select((s) => s.error),
                    );
                    return error == null
                        ? const SizedBox.shrink()
                        : MaterialBanner(
                            content: Text('模拟消息已暂停：$error'),
                            actions: const [SizedBox.shrink()],
                          );
                  },
                ),
              Expanded(
                child: IndexedStack(
                  index: section.index,
                  children: [
                    for (final tab in WorkspaceSection.values)
                      !_visited.contains(tab)
                          ? const SizedBox.shrink()
                          : TickerMode(
                              enabled: section == tab,
                              child: switch (tab) {
                                WorkspaceSection.messages => _conversationHome(
                                  context,
                                ),
                                WorkspaceSection.contacts => ContactsPane(
                                  onOpen: (id) => sdk != null
                                      ? _openEntry(sdk, id)
                                      : _showContactProfile(
                                          context,
                                          id,
                                          onMessage: _open,
                                        ),
                                ),
                                WorkspaceSection.me => PersonalPane(
                                  onMetrics: widget.onMetrics,
                                ),
                              },
                            ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileComposer extends ConsumerWidget {
  const _MobileComposer({
    required this.id,
    required this.input,
    required this.focus,
    required this.onSend,
    required this.attachmentButton,
  });
  final int id;
  final TextEditingController input;
  final FocusNode focus;
  final VoidCallback? onSend;
  final Widget attachmentButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
    key: const Key('mobile-composer-bar'),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: line, width: .5)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox.square(dimension: 44, child: attachmentButton),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F5F3),
              borderRadius: BorderRadius.circular(22),
            ),
            child: TextField(
              key: const Key('composer'),
              controller: input,
              focusNode: focus,
              onChanged: (text) =>
                  ref.read(draftProvider(id).notifier).save(text),
              minLines: 1,
              maxLines: 4,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.newline,
              style: TextStyle(
                fontSize:
                    16 +
                    ref.watch(appSettingsProvider.select((s) => s.fontDelta)),
                height: 1.4,
                color: ink,
              ),
              decoration: const InputDecoration(
                hintText: '发送消息…',
                counterText: '',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Consumer(
          builder: (_, ref, _) {
            final canSend = ref.watch(
              draftProvider(id).select((s) => s.trim().isNotEmpty),
            );
            return SizedBox.square(
              dimension: 44,
              child: _ComposerActionButton(
                key: const Key('send-message'),
                tooltip: '发送消息',
                icon: Icons.arrow_upward_rounded,
                onPressed: canSend ? onSend : null,
              ),
            );
          },
        ),
      ],
    ),
  );
}
