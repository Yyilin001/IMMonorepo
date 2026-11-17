import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart' show openFiles;
import 'package:cross_file/cross_file.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:open_filex/open_filex.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/im_providers.dart';
import '../state/photo_library.dart';
import '../state/attachment_export.dart';
import '../state/recent_searches.dart';
import '../core/models.dart';
import '../core/history.dart';
import '../core/profiles.dart' show MyProfile, ContactSummary, ContactDirectory;
import '../mock/group_members.dart';

part 'mobile_workspace.dart';
part 'sdk_workspace.dart';
part 'sdk_avatars.dart';
part 'sdk_community.dart';
part 'sdk_account.dart';
part 'sdk_chat.dart';
part 'sdk_transfers.dart';
part 'sdk_create_group.dart';
part 'reading_viewport.dart';
part 'directory_search.dart';
part 'people_pages.dart';
part 'chat_settings_page.dart';
part 'context_menus.dart';
part 'image_message.dart';
part 'mobile_metrics.dart';
part 'message_entrance.dart';
part 'app_settings_page.dart';
part 'contact_details.dart';

const ink = Color(0xFF183D32);
const green = Color(0xFF19846A);
const muted = Color(0xFF82928B);
const line = Color(0xFFE7ECE9);
const mint = Color(0xFFEDF6F0);

bool _usesMobileWorkspace(double width) =>
    defaultTargetPlatform == TargetPlatform.iOS || width < 900;

String number(num value) => value.round().toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);
String clockLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

class Workspace extends ConsumerStatefulWidget {
  const Workspace({super.key});
  @override
  ConsumerState<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<Workspace> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_composePhoto(context, ref));
      });
    }
    // Bootstrap once outside widget build. Live messages themselves are never deferred.
    Future.microtask(() {
      if (mounted) ref.read(mockRuntimeProvider.notifier).start();
    });
  }

  void _showMetrics() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFFF5F7F6),
    builder: (_) => SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .9,
        child: _usesMobileWorkspace(MediaQuery.sizeOf(context).width)
            ? const _MobileMetricsPanel()
            : SingleChildScrollView(
                child: SizedBox(width: double.infinity, child: MetricsPanel()),
              ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _usesMobileWorkspace(constraints.maxWidth)
        ? _MobileWorkspace(onMetrics: _showMetrics)
        : _desktop(),
  );

  final _visited = {WorkspaceSection.messages};
  int _desktopLastId = 0;

  void _selectDesktop(WorkspaceSection section) {
    final id = ref.read(selectedConversationProvider);
    if (section != WorkspaceSection.messages && id != null) {
      _desktopLastId = id;
      ref.read(selectedConversationProvider.notifier).select(null);
    } else if (section == WorkspaceSection.messages && id == null) {
      ref.read(selectedConversationProvider.notifier).select(_desktopLastId);
    }
    ref.read(workspaceSectionProvider.notifier).select(section);
  }

  void _openDesktop(int id) {
    _desktopLastId = id;
    ref.read(selectedConversationProvider.notifier).select(id);
    ref
        .read(workspaceSectionProvider.notifier)
        .select(WorkspaceSection.messages);
  }

  Widget _desktop() => Consumer(
    builder: (context, ref, _) {
      final section = ref.watch(workspaceSectionProvider);
      _visited.add(section);
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showMetrics = constraints.maxWidth >= 1250;
              return Row(
                children: [
                  _Rail(
                    onMetrics: _showMetrics,
                    selected: section,
                    onSelect: _selectDesktop,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        if (section == WorkspaceSection.messages)
                          _Header(compact: false, onMetrics: _showMetrics)
                        else
                          const SizedBox(height: 24),
                        Consumer(
                          builder: (_, ref, _) {
                            final error = ref.watch(
                              mockRuntimeProvider.select((s) => s.error),
                            );
                            return error == null
                                ? const SizedBox.shrink()
                                : MaterialBanner(
                                    content: Text('Mock 通道异常：$error'),
                                    actions: const [SizedBox.shrink()],
                                  );
                          },
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: line),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: IndexedStack(
                                  index: section.index,
                                  children: [
                                    for (final tab in WorkspaceSection.values)
                                      !_visited.contains(tab)
                                          ? const SizedBox.shrink()
                                          : TickerMode(
                                              enabled: section == tab,
                                              child: switch (tab) {
                                                WorkspaceSection.messages => Row(
                                                  children: [
                                                    const SizedBox(
                                                      width: 300,
                                                      child: ConversationPane(),
                                                    ),
                                                    const VerticalDivider(
                                                      width: 1,
                                                      color: line,
                                                    ),
                                                    const Expanded(
                                                      child: ChatPane(),
                                                    ),
                                                    if (showMetrics) ...[
                                                      const VerticalDivider(
                                                        width: 1,
                                                        color: line,
                                                      ),
                                                      const SizedBox(
                                                        width: 255,
                                                        child:
                                                            SingleChildScrollView(
                                                              child:
                                                                  MetricsPanel(),
                                                            ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                                WorkspaceSection.contacts =>
                                                  ContactsPane(
                                                    onOpen: (id) =>
                                                        _showContactProfile(
                                                          context,
                                                          id,
                                                          onMessage: (id) {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            _openDesktop(id);
                                                          },
                                                        ),
                                                  ),
                                                WorkspaceSection.me =>
                                                  PersonalPane(
                                                    onMetrics: _showMetrics,
                                                  ),
                                              },
                                            ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.onMetrics,
    required this.selected,
    required this.onSelect,
  });
  final VoidCallback onMetrics;
  final WorkspaceSection selected;
  final ValueChanged<WorkspaceSection> onSelect;
  @override
  Widget build(BuildContext context) => Container(
    width: 76,
    color: ink,
    child: Column(
      children: [
        const SizedBox(height: 27),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFD5EEAD),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(Icons.waves_rounded, color: ink, size: 29),
        ),
        const SizedBox(height: 40),
        for (final tab in WorkspaceSection.values) ...[
          Container(
            decoration: BoxDecoration(
              color: selected == tab
                  ? Colors.white.withValues(alpha: .12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: IconButton(
              key: Key('nav-${tab.name}'),
              onPressed: () => onSelect(tab),
              tooltip: tab.label,
              icon: _NavigationIcon(
                tab: tab,
                color: selected == tab
                    ? const Color(0xFFD5EEAD)
                    : const Color(0xFF99B5A9),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const Spacer(),
        IconButton(
          onPressed: onMetrics,
          tooltip: '运行监控',
          icon: const Icon(Icons.insights_rounded, color: Color(0xFF99B5A9)),
        ),
        const SizedBox(height: 24),
      ],
    ),
  );
}

class _Header extends ConsumerWidget {
  const _Header({required this.compact, required this.onMetrics});
  final bool compact;
  final VoidCallback onMetrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: EdgeInsets.all(compact ? 16 : 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '涟漪 ${compact ? '' : '/  Local IM'}',
                    style: TextStyle(
                      fontSize: compact ? 22 : 27,
                      fontWeight: FontWeight.w700,
                      color: ink,
                      letterSpacing: -.7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '连接有序，消息自由。',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!compact)
              const _Tag(
                label: '100% 本地 Mock',
                icon: Icons.lock_outline_rounded,
              ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: onMetrics,
              tooltip: '查看性能指标',
              icon: const Icon(Icons.tune_rounded, size: 20, color: green),
            ),
          ],
        ),
        SizedBox(height: compact ? 16 : 23),
        Consumer(
          builder: (_, ref, _) {
            final stats = ref.watch(metricsProvider);
            final cards = [
              _Metric(
                label: '会话总量',
                value: number(ref.watch(totalConversationCountProvider)),
                unit: '个',
                icon: Icons.chat_bubble_outline_rounded,
              ),
              _Metric(
                label: '实时接收',
                value: number(stats.rate),
                unit: '条 / 秒',
                icon: Icons.bolt_rounded,
              ),
              _Metric(
                label: '累计接收',
                value: number(stats.received),
                unit: '条',
                icon: Icons.move_to_inbox_outlined,
              ),
              _Metric(
                label: '渲染 P95',
                value: stats.frameSamples == 0
                    ? '—'
                    : stats.frameP95.toStringAsFixed(1),
                unit: 'ms',
                icon: Icons.speed_rounded,
              ),
            ];
            if (compact) {
              return SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => SizedBox(width: 160, child: cards[i]),
                ),
              );
            }
            return Row(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Expanded(child: cards[i]),
                ],
              ],
            );
          },
        ),
      ],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });
  final String label, value, unit;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: green),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: muted, fontSize: 10)),
          ],
        ),
        const SizedBox(height: 5),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  color: ink,
                  height: 1.1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 5),
              Text(unit, style: const TextStyle(fontSize: 10, color: muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

class ConversationPane extends ConsumerStatefulWidget {
  const ConversationPane({
    super.key,
    this.mobile = false,
    this.searchPage = false,
    this.onMetrics,
    this.onOpen,
    this.onSdkOpen,
  });
  final bool mobile;
  final bool searchPage;
  final VoidCallback? onMetrics;
  final ValueChanged<int>? onOpen;
  final ValueChanged<ImConversation>? onSdkOpen;
  @override
  ConsumerState<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends ConsumerState<ConversationPane> {
  String liveQuery = '';
  bool liveUnread = false;
  bool get live => context.getInheritedWidgetOfExactType<_SdkScope>() != null;
  String get query =>
      live ? liveQuery : ref.read(conversationListProvider).query;
  bool get unreadOnly =>
      live ? liveUnread : ref.read(conversationListProvider).unreadOnly;
  final scroll = ScrollController();
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final _slotWidgets = <int, Widget>{};

  @override
  void initState() {
    super.initState();
    search.text = query;
    searchFocus.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  Future<void> _openSearch() async {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    await _openDirectorySearch(
      context,
      ConversationPane(
        mobile: true,
        searchPage: true,
        onOpen: widget.onOpen,
        onSdkOpen: widget.onSdkOpen,
      ),
      '/search/conversations',
    );
    if (!mounted) return;
    _filter(text: '');
    _restoreDirectoryOffset(scroll, offset);
  }

  void _rememberSearch() => _rememberDirectoryQuery(
    context,
    ref,
    SearchDirectory.conversations,
    search.text,
  );

  void _openResult(int id) {
    _rememberSearch();
    if (widget.onOpen case final open?) {
      open(id);
    } else {
      ref.read(selectedConversationProvider.notifier).select(id);
    }
  }

  void _cancelSearch() {
    if (widget.searchPage) {
      Navigator.of(context).pop();
      return;
    }
    _rememberSearch();
    search.clear();
    _filter(text: '');
    searchFocus.unfocus();
  }

  void _filter({String? text, bool? unread}) {
    if (live) {
      setState(() {
        liveQuery = text?.trim().toLowerCase() ?? liveQuery;
        liveUnread = unread ?? liveUnread;
      });
    } else {
      ref
          .read(conversationListProvider.notifier)
          .filter(query: text, unreadOnly: unread);
    }
  }

  Widget _slot(int index) {
    final child =
        _slotWidgets.remove(index) ??
        _ConversationSlot(
          key: ValueKey(index),
          index: index,
          mobile: widget.mobile,
          onOpen: _openResult,
        );
    _slotWidgets[index] = child;
    // Widget configuration reuse is bounded; render elements remain lazy.
    if (_slotWidgets.length > 256) _slotWidgets.remove(_slotWidgets.keys.first);
    return child;
  }

  Widget _liveRows(_SdkWorkspaceState sdk) {
    if (sdk.userId == null) {
      return Center(
        child: FilledButton(
          key: const Key('open-login'),
          onPressed: sdk.busy ? null : () => _openSdkLogin(context),
          child: const Text('登录'),
        ),
      );
    }
    if (sdk.listError case final message?) return Center(child: Text(message));
    if (sdk.loadingRooms) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = sdk.rooms
        .where(
          (row) =>
              !row.isArchived &&
              (!unreadOnly || row.unread > 0) &&
              (row.title.toLowerCase().contains(query) ||
                  row.id.toLowerCase().contains(query)),
        )
        .toList();
    if (rows.isEmpty) {
      return Center(
        child: Text(
          query.isNotEmpty
              ? '没有找到会话'
              : unreadOnly
              ? '暂无未读消息'
              : '暂无会话',
          style: const TextStyle(color: muted),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: sdk.syncNow,
      child: ListView.builder(
      key: const Key('conversation-list'),
      controller: scroll,
      physics: const AlwaysScrollableScrollPhysics(),
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
              row.muteUntil! > DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt ?? 0),
        );
        return InkWell(
          key: ValueKey(row.id),
          onTap: () {
            _rememberSearch();
            widget.onSdkOpen?.call(row);
          },
          onLongPress: () => _showSdkConversationMenu(context, ref, row),
          child: Dismissible(
            key: ValueKey('swipe-${row.id}'),
            background: Container(
              color: green,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    row.isPinned
                        ? Icons.push_pin_outlined
                        : Icons.push_pin_rounded,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    row.isPinned ? '取消置顶' : '置顶',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            secondaryBackground: Container(
              color: const Color(0xFF3F51B5),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('隐藏', style: TextStyle(color: Colors.white)),
                  SizedBox(width: 6),
                  Icon(Icons.visibility_off_outlined, color: Colors.white),
                ],
              ),
            ),
            confirmDismiss: (direction) async {
              if (direction == DismissDirection.startToEnd) {
                await sdk.applyConversationState(row, pinned: !row.isPinned);
              } else {
                await sdk.applyConversationState(row, archived: true);
              }
              return false;
            },
            child: _ConversationRow(
              item: item,
              selected: false,
              mobile: true,
              avatar: row.isGroup
                  ? SdkGroupAvatar(
                      roomId: row.id,
                      name: item.displayName,
                      size: 50,
                    )
                  : row.peerId != null
                  ? SdkAvatar(
                      userId: row.peerId!,
                      name: item.displayName,
                      context: 'direct',
                      size: 50,
                    )
                  : null,
            ),
          ),
        );
      },
      ),
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    searchFocus.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context);
    if (sdk == null) {
      ref.watch(
        conversationListProvider.select((s) => (s.query, s.unreadOnly)),
      );
    }
    final searching =
        widget.searchPage ||
        (!widget.mobile && (searchFocus.hasFocus || query.isNotEmpty));
    return _SearchScope(
      active: searching && !widget.searchPage,
      onPageExit: widget.searchPage ? _rememberSearch : null,
      onCancel: _cancelSearch,
      child: Column(
        children: [
          if (!searching)
            Padding(
              padding: EdgeInsets.fromLTRB(20, widget.mobile ? 12 : 20, 12, 10),
              child: Row(
                children: [
                  Text(
                    '消息',
                    style: TextStyle(
                      fontSize: widget.mobile ? 30 : 20,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!widget.mobile)
                    Consumer(
                      builder: (_, ref, _) => Text(
                        number(ref.watch(totalConversationCountProvider)),
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ),
                  const Spacer(),
                  if (sdk == null)
                    IconButton(
                      onPressed: ref
                          .read(conversationListProvider.notifier)
                          .markAllRead,
                      tooltip: '全部标为已读',
                      icon: const Icon(
                        Icons.done_all_rounded,
                        size: 19,
                        color: green,
                      ),
                    ),
                  if (widget.mobile)
                    IconButton(
                      onPressed: sdk == null
                          ? widget.onMetrics
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const AppSettingsPage(),
                              ),
                            ),
                      tooltip: sdk == null ? '查看性能指标' : '设置',
                      icon: const Icon(
                        Icons.tune_rounded,
                        color: green,
                        size: 22,
                      ),
                    ),
                ],
              ),
            ),
          if (widget.mobile && !widget.searchPage)
            _SearchEntry(
              entryKey: const Key('open-chat-search'),
              tag: _SearchBarTag.conversations,
              hint: '搜索',
              onTap: _openSearch,
            )
          else
            _DirectorySearchField(
              autofocus: widget.searchPage,
              fieldKey: const Key('search'),
              tag: _SearchBarTag.conversations,
              onSubmitted: _rememberSearch,
              controller: search,
              focus: searchFocus,
              active: searching,
              hint: searching || !widget.mobile ? '搜索会话名称、备注或编号' : '搜索',
              onChanged: (text) => _filter(text: text),
              onCancel: _cancelSearch,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 18, 10),
            child: Row(
              children: [
                _Filter(
                  label: '全部',
                  mobile: widget.mobile,
                  selected: !unreadOnly,
                  onTap: () {
                    searchFocus.unfocus();
                    _filter(unread: false);
                  },
                ),
                const SizedBox(width: 7),
                _Filter(
                  label: '未读',
                  mobile: widget.mobile,
                  selected: unreadOnly,
                  onTap: () {
                    searchFocus.unfocus();
                    _filter(unread: true);
                  },
                ),
                const Spacer(),
                if (sdk?.client != null && sdk!.userId != null)
                  IconButton(
                    key: const Key('open-archived-conversations'),
                    tooltip: '隐藏的聊天',
                    icon: const Icon(Icons.visibility_off_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _ArchivedConversationsPage(),
                      ),
                    ),
                  ),
                if (sdk?.client != null && sdk!.userId != null)
                  IconButton(
                    tooltip: '搜索全部聊天记录',
                    icon: const Icon(Icons.manage_search),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => _MessageSearchPage(
                        client: sdk.client!,
                        roomTitles: {for (final room in sdk.rooms) if (room.title.isNotEmpty) room.id: room.title},
                      ),
                    )),
                  ),
                const Icon(Icons.swap_vert_rounded, size: 17, color: muted),
              ],
            ),
          ),
          if (searching && query.isNotEmpty)
            const _SearchResultsLabel('会话搜索结果'),
          Expanded(
            child: searching && query.isEmpty
                ? _RecentSearchPanel(
                    directory: SearchDirectory.conversations,
                    hint: '输入会话名称、备注或编号',
                    controller: search,
                    focus: searchFocus,
                    onChanged: (text) => _filter(text: text),
                  )
                : sdk != null
                ? _liveRows(sdk)
                : Consumer(
                    builder: (_, ref, _) {
                      final count = ref.watch(conversationCountProvider);
                      if (count == 0) {
                        return const Center(
                          child: Text('没有找到会话', style: TextStyle(color: muted)),
                        );
                      }
                      return NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.depth == 0 && n is ScrollUpdateNotification) {
                            ref
                                .read(conversationListProvider.notifier)
                                .freeze(n.metrics.pixels > 20);
                          }
                          return false;
                        },
                        child: Scrollbar(
                          controller: scroll,
                          child: ListView.builder(
                            key: const Key('conversation-list'),
                            controller: scroll,
                            itemExtent: 82,
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              164,
                            ),
                            itemCount: count,
                            itemBuilder: (_, index) => _slot(index),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (!searching && sdk == null)
            Consumer(
              builder: (_, ref, _) {
                final frozen = ref.watch(
                  conversationListProvider.select((s) => s.frozen),
                );
                if (widget.mobile && !frozen) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: line)),
                  ),
                  child: Text(
                    frozen ? '回到顶部，恢复会话排序' : '仅渲染可见会话 · 逐条即时更新',
                    style: TextStyle(
                      fontSize: 10,
                      color: frozen ? green : muted,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter({
    this.mobile = false,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool mobile;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(7),
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: mobile ? 10 : 7),
      decoration: BoxDecoration(
        color: selected ? mint : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? green : muted,
          fontSize: mobile ? 14 : 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    ),
  );
}

class _ConversationRow extends ConsumerWidget {
  const _ConversationRow({
    super.key,
    this.mobile = false,
    required this.item,
    required this.selected,
    this.avatar,
  });
  final bool mobile;
  final Conversation item;
  final bool selected;
  final Widget? avatar;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: mobile ? line : Colors.transparent,
          width: .5,
        ),
        left: BorderSide(
          color: selected ? green : Colors.transparent,
          width: mobile ? 0 : 3,
        ),
      ),
    ),
    padding: EdgeInsets.fromLTRB(mobile ? 20 : 14, 15, 20, 15),
    child: Row(
      children: [
        avatar ??
            ChatAvatar(
              id: item.id,
              name: item.displayName,
              group: item.isGroup,
              size: mobile ? 50 : 43,
            ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: mobile ? 16 : 12,
                        color: ink,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    clockLabel(item.updatedAt),
                    style: TextStyle(fontSize: mobile ? 11 : 9, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ref.watch(contactDeletedProvider(item.id))
                          ? '联系人已删除 · 聊天记录已保留'
                          : ref.watch(
                              appSettingsProvider.select(
                                (s) => s.messagePreview,
                              ),
                            )
                          ? item.preview
                          : '消息内容已隐藏',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: mobile ? 14 : 11,
                        color: muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (item.muted) ...[
                    const Icon(
                      Icons.notifications_off_outlined,
                      size: 13,
                      color: muted,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (item.unread > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: item.muted ? muted : green,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.unread > 99 ? '99+' : '${item.unread}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                        ),
                      ),
                    )
                  else if (item.pinned)
                    const Icon(Icons.push_pin_rounded, size: 12, color: muted),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.id,
    required this.name,
    this.group = false,
    this.size = 43,
    this.avatar,
  });
  final int id;
  final String name;
  final bool group;
  final double size;
  final Uint8List? avatar;
  @override
  Widget build(BuildContext context) {
    const backgrounds = [
      Color(0xFFDCEBDC),
      Color(0xFFF1E7DA),
      Color(0xFFE1E9F1),
      Color(0xFFECE2ED),
      Color(0xFFF0E5DB),
    ];
    const foregrounds = [
      Color(0xFF487158),
      Color(0xFF98764D),
      Color(0xFF5C7D9A),
      Color(0xFF8C6D94),
      Color(0xFFA37F61),
    ];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgrounds[id % backgrounds.length],
        borderRadius: BorderRadius.circular(size * .3),
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: avatar == null
          ? group
                ? Icon(
                    Icons.forum_rounded,
                    size: size * .47,
                    color: foregrounds[id % foregrounds.length],
                  )
                : Text(
                    name.characters.first,
                    style: TextStyle(
                      fontSize: size * .38,
                      color: foregrounds[id % foregrounds.length],
                      fontWeight: FontWeight.w600,
                    ),
                  )
          : Image.memory(
              avatar!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              gaplessPlayback: true,
            ),
    );
  }
}

class ChatPane extends ConsumerWidget {
  const ChatPane({super.key, this.mobile = false, this.onBack});
  final bool mobile;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedConversationProvider);
    return id == null
        ? const Center(
            child: Text('选择一个会话，开始交流', style: TextStyle(color: muted)),
          )
        : _ConversationChatPane(
            key: ValueKey(id),
            id: id,
            mobile: mobile,
            onBack: onBack,
          );
  }
}

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.outlined = false,
    this.turns = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool outlined;
  final double turns;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final diameter = outlined ? 28.0 : 32.0;
    final faceColor = enabled ? green : const Color(0xFFE9EEEB);
    final symbolColor = outlined
        ? green
        : enabled
        ? Colors.white
        : const Color(0xFFA0AEA7);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      icon: Container(
        width: diameter,
        height: diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: outlined ? null : faceColor,
          border: outlined ? Border.all(color: faceColor, width: 1.5) : null,
        ),
        child: AnimatedRotation(
          turns: turns,
          duration: const Duration(milliseconds: 160),
          child: Icon(icon, size: outlined ? 20 : 22, color: symbolColor),
        ),
      ),
    );
  }
}

class _ConversationChatPane extends ConsumerStatefulWidget {
  const _ConversationChatPane({
    super.key,
    required this.id,
    required this.mobile,
    this.onBack,
  });
  final int id;
  final bool mobile;
  final VoidCallback? onBack;
  @override
  ConsumerState<_ConversationChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<_ConversationChatPane> {
  final input = TextEditingController();
  final _messagesKey = GlobalKey<_MessageListState>();
  late final ScrollController scroll;
  final inputFocus = FocusNode();
  bool _attachmentsOpen = false;
  int get id => widget.id;
  @override
  void initState() {
    super.initState();
    scroll = ScrollController(
      initialScrollOffset: ref.read(chatSessionProvider(id)).scrollOffset,
      keepScrollOffset: false,
    );
    inputFocus.addListener(_handleInputFocus);
    input.text = ref.read(draftProvider(id));
    ref.listenManual(draftProvider(id), (_, text) {
      if (input.text != text) input.text = text;
    });
  }

  void _openHistory() {
    unawaited(_messagesKey.currentState?.openHistory());
  }

  void _send() {
    if (input.text.trim().isEmpty || ref.read(contactDeletedProvider(id))) {
      return;
    }
    ref.read(messageActionsProvider).send(input.text);
    input.clear();
    ref.read(draftProvider(id).notifier).save('');
    if (scroll.hasClients) scroll.jumpTo(0);
    inputFocus.requestFocus();
  }

  void _closeAttachments() {
    if (_attachmentsOpen) setState(() => _attachmentsOpen = false);
  }

  void _handleInputFocus() {
    if (inputFocus.hasFocus) _closeAttachments();
  }

  void _toggleAttachments() {
    if (!_attachmentsOpen) inputFocus.unfocus();
    setState(() => _attachmentsOpen = !_attachmentsOpen);
  }

  Future<void> _sendImage(ImageSource source) async {
    if (ref.read(contactDeletedProvider(id))) return;
    inputFocus.unfocus();
    _closeAttachments();
    final sent = await _composePhoto(
      context,
      ref,
      conversationId: id,
      source: source,
    );
    if (sent && mounted && scroll.hasClients) scroll.jumpTo(0);
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Consumer(
    builder: (_, ref, _) {
      final conversation = ref.read(engineProvider).conversation(id);
      final displayName = ref.watch(contactDisplayNameProvider(id));
      final deleted = ref.watch(contactDeletedProvider(id));
      final showAttachments = _attachmentsOpen && !deleted;
      final attachmentButton = _ComposerActionButton(
        key: const Key('chat-attachments'),
        tooltip: showAttachments ? '收起附件' : '添加附件',
        icon: Icons.add_rounded,
        outlined: true,
        turns: showAttachments ? 0.125 : 0,
        onPressed: _toggleAttachments,
      );
      final header = _ChatHeading(
        id: id,
        displayName: displayName,
        group: conversation.isGroup,
        mobile: widget.mobile,
        subtitle: conversation.isGroup
            ? '${widget.mobile ? '' : '本地群聊 · '}${mockGroupMemberCount(id, ref.read(engineProvider).initialConversationCount)} 位成员'
            : widget.mobile
            ? '本地会话'
            : '在线 · 本地模拟联系人',
        onProfile: () => _showContactProfile(context, id),
        onHistory: _openHistory,
        onSettings: () {
          FocusManager.instance.primaryFocus?.unfocus();
          unawaited(
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: RouteSettings(name: '/conversation/$id/settings'),
                builder: (_) =>
                    ChatSettingsPage(id: id, onHistory: _openHistory),
              ),
            ),
          );
        },
      );
      return Column(
        children: [
          widget.mobile
              ? SizedBox(
                  height: kToolbarHeight,
                  child: AppBar(
                    primary: false,
                    centerTitle: false,
                    titleSpacing: 0,
                    leading: BackButton(
                      key: const Key('back'),
                      onPressed:
                          widget.onBack ??
                          () => ref
                              .read(selectedConversationProvider.notifier)
                              .select(null),
                    ),
                    title: header,
                  ),
                )
              : Container(
                  color: Theme.of(context).appBarTheme.backgroundColor,
                  padding: const EdgeInsets.fromLTRB(22, 18, 14, 18),
                  child: header,
                ),
          Expanded(
            child: Consumer(
              builder: (_, ref, child) => Listener(
                onPointerDown: showAttachments
                    ? (_) => _closeAttachments()
                    : null,
                child: ColoredBox(
                  key: const Key('chat-background'),
                  color: ref.watch(chatBackgroundProvider(id)).color,
                  child: child!,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: _MessageList(
                      key: _messagesKey,
                      scroll: scroll,
                      conversation: conversation,
                    ),
                  ),
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 65,
                    child: _NewerHistoryStatus(id: id),
                  ),
                  Consumer(
                    builder: (_, ref, _) {
                      final frozen = ref.watch(
                        chatSessionProvider(id).select((s) => s.frozen),
                      );
                      return frozen
                          ? Positioned(
                              right: 18,
                              bottom: 14,
                              child: FilledButton.tonalIcon(
                                onPressed: () =>
                                    _messagesKey.currentState?.showLatest(),
                                icon: const Icon(
                                  Icons.arrow_downward_rounded,
                                  size: 15,
                                ),
                                key: const Key('latest-messages'),
                                label: Consumer(
                                  builder: (_, ref, _) {
                                    final count = ref.watch(
                                      chatSessionProvider(id)
                                          .select((s) => s.pending),
                                    );
                                    return Text(
                                      count == 0
                                          ? '回到最新消息'
                                          : '${number(count)} 条新消息 · 回到最新',
                                    );
                                  },
                                ),
                              ),
                            )
                          : const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),
          if (deleted)
            _DeletedContactComposer(id: id)
          else if (widget.mobile)
            _MobileComposer(
              id: id,
              input: input,
              focus: inputFocus,
              onSend: _send,
              attachmentButton: attachmentButton,
            )
          else
            Container(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: line)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.edit_note_rounded,
                        color: muted,
                        size: 20,
                      ),
                      const SizedBox(width: 7),
                      const Text(
                        '写点什么，开启对话',
                        style: TextStyle(color: muted, fontSize: 10),
                      ),
                      const Spacer(),
                      if (!widget.mobile)
                        const Text(
                          'Enter 发送 · Shift + Enter 换行',
                          style: TextStyle(color: muted, fontSize: 9),
                        ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox.square(dimension: 48, child: attachmentButton),
                      const SizedBox(width: 10),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: {
                            const SingleActivator(LogicalKeyboardKey.enter):
                                _send,
                          },
                          child: TextField(
                            key: const Key('composer'),
                            onChanged: (text) {
                              ref.read(draftProvider(id).notifier).save(text);
                            },
                            controller: input,
                            focusNode: inputFocus,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 2000,
                            textInputAction: TextInputAction.newline,
                            style: TextStyle(
                              fontSize:
                                  13 +
                                  ref.watch(
                                    appSettingsProvider.select(
                                      (s) => s.fontDelta,
                                    ),
                                  ),
                            ),
                            decoration: const InputDecoration(
                              hintText: '发送一条本地消息…',
                              counterText: '',
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox.square(
                        dimension: 48,
                        child: _ComposerActionButton(
                          tooltip: '发送消息',
                          icon: Icons.arrow_upward_rounded,
                          onPressed: _send,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          PopScope(
            canPop: !widget.mobile || !showAttachments,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _closeAttachments();
            },
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: showAttachments
                  ? _AttachmentPanel(onPick: _sendImage)
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      );
    },
  );
}

class _ChatHeading extends StatelessWidget {
  const _ChatHeading({
    required this.id,
    required this.displayName,
    required this.group,
    required this.mobile,
    required this.subtitle,
    required this.onProfile,
    required this.onHistory,
    required this.onSettings,
    this.avatar,
  });
  final int id;
  final String displayName, subtitle;
  final bool group, mobile;
  final VoidCallback onProfile, onHistory, onSettings;
  final Widget? avatar;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Tooltip(
        message: '查看资料',
        child: InkWell(
          key: const Key('chat-profile'),
          borderRadius: BorderRadius.circular(14),
          onTap: onProfile,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child:
                avatar ??
                ChatAvatar(
                  id: id,
                  name: displayName,
                  group: group,
                  size: mobile ? 32 : 38,
                ),
          ),
        ),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: mobile ? 17 : 14,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              style: TextStyle(fontSize: mobile ? 12 : 10, color: muted),
            ),
          ],
        ),
      ),
      IconButton(
        key: const Key('open-history'),
        tooltip: '查看历史记录',
        onPressed: onHistory,
        icon: Icon(
          Icons.history_rounded,
          size: 20,
          color: mobile ? null : green,
        ),
      ),
      IconButton(
        key: const Key('chat-settings'),
        tooltip: '聊天设置',
        icon: Icon(Icons.more_horiz_rounded, color: mobile ? null : muted),
        onPressed: onSettings,
      ),
    ],
  );
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.conversation,
    this.sdkSender,
    this.sdkStatus,
    this.attachmentList,
    this.replyPreview,
    this.onOpenReply,
    this.onReply,
    this.onForward,
    this.recovery,
    this.onCancelSend,
    this.onEdit,
    this.onWithdraw,
    this.onReaders,
    this.onFavorite,
    this.onEnterSelection,
    this.mentionSummary,
    this.entities = const [],
    this.isPinned = false,
    this.onPin,
    this.onCopyAttachments,
    this.onModerateRemove,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelect,
    this.isForwarded = false,
    this.showTime = true,
  });
  final String? sdkSender, sdkStatus, replyPreview;
  final bool isForwarded;
  final Widget? attachmentList;
  final ({String label, VoidCallback action})? recovery;
  final VoidCallback? onCancelSend, onOpenReply;
  final VoidCallback? onReply, onForward, onEdit, onWithdraw, onReaders;
  final VoidCallback? onFavorite, onEnterSelection, onToggleSelect;
  final bool selecting, selected;
  final String? mentionSummary;
  final List<ImEntity> entities;
  final bool isPinned;
  final VoidCallback? onPin, onCopyAttachments, onModerateRemove;
  final bool showTime;
  final ChatMessage message;
  final Conversation conversation;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontDelta = ref.watch(appSettingsProvider.select((s) => s.fontDelta));
    final mine = message.isMine;
    final ownGroupMessage = mine && conversation.isGroup;
    final senderId = message.senderId ?? conversation.id;
    final String displayName =
        sdkSender ??
        (ownGroupMessage
            ? ref.watch(myProfileProvider.select((profile) => profile.name))
            : mine
            ? '我'
            : ref.watch(contactDisplayNameProvider(senderId)));
    final mobile = _usesMobileWorkspace(MediaQuery.sizeOf(context).width);
    final avatarSize = mobile ? 44.0 : 36.0;
    final avatar = Semantics(
      button: sdkSender == null,
      label: '查看$displayName的资料',
      child: InkWell(
        borderRadius: BorderRadius.circular(avatarSize * .3),
        onTap: sdkSender != null
            ? null
            : () => ownGroupMessage
                  ? _showMyProfile(context)
                  : _showContactProfile(context, senderId),
        child: ExcludeSemantics(
          child: ChatAvatar(
            id: ownGroupMessage ? MyProfile.avatarId : senderId,
            name: displayName,
            size: avatarSize,
          ),
        ),
      ),
    );
    final content = message.type == MessageType.image
        ? _MessageImage(key: ValueKey('image-${message.id}'), message: message)
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: mine
                  ? (mobile ? green : const Color(0xFFE1EED5))
                  : Colors.white,
              border: Border.all(
                color: mine ? (mobile ? green : const Color(0xFFD5E4C8)) : line,
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(mine ? 12 : 3),
                topRight: Radius.circular(mine ? 3 : 12),
                bottomLeft: const Radius.circular(12),
                bottomRight: const Radius.circular(12),
              ),
            ),
            child: entities.isEmpty
                ? Text(
                    message.text,
                    style: TextStyle(
                      fontSize: (mobile ? 16 : 12) + fontDelta,
                      height: mobile ? 1.4 : 1.6,
                      color: mobile && mine ? Colors.white : ink,
                    ),
                  )
                : Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: (mobile ? 16 : 12) + fontDelta,
                        height: mobile ? 1.4 : 1.6,
                        color: mobile && mine ? Colors.white : ink,
                      ),
                      children: _richMessageSpans(
                        message.text,
                        entities,
                        TextStyle(
                          fontSize: (mobile ? 16 : 12) + fontDelta,
                          height: mobile ? 1.4 : 1.6,
                          color: mobile && mine ? Colors.white : ink,
                        ),
                      ),
                    ),
                  ),
          );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selecting ? onToggleSelect : null,
      child: Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Checkbox(
                value: selected,
                onChanged: onToggleSelect == null
                    ? null
                    : (_) => onToggleSelect!(),
              ),
            ),
          if (!mine) ...[avatar, const SizedBox(width: 10)],
          Flexible(
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: (mobile ? 15 : 13) + fontDelta,
                            fontWeight: FontWeight.w600,
                            color: ink,
                          ),
                        ),
                      ),
                      if (onModerateRemove != null ||
                          onCopyAttachments != null ||
                          onPin != null ||
                          onEnterSelection != null ||
                          onCancelSend != null ||
                          recovery != null ||
                          onReply != null ||
                          onForward != null ||
                          onEdit != null ||
                          onWithdraw != null)
                        PopupMenuButton<VoidCallback>(
                          tooltip: '消息操作',
                          onSelected: (action) => action(),
                          itemBuilder: (_) => [
                            if (recovery case final recovery?)
                              PopupMenuItem(
                                value: recovery.action,
                                child: Text(recovery.label),
                              ),
                            if (onCancelSend != null)
                              PopupMenuItem(
                                value: onCancelSend,
                                child: const Text('取消发送'),
                              ),
                            if (onReply != null)
                              PopupMenuItem(
                                value: onReply,
                                child: const Text('回复'),
                              ),
                            if (onForward != null)
                              PopupMenuItem(
                                value: onForward,
                                child: const Text('转发'),
                              ),
                            if (onReaders != null)
                              PopupMenuItem(
                                value: onReaders,
                                child: const Text('查看已读'),
                              ),
                            if (onFavorite != null)
                              PopupMenuItem(
                                value: onFavorite,
                                child: const Text('收藏'),
                              ),
                            if (onModerateRemove != null)
                              PopupMenuItem(
                                value: onModerateRemove,
                                child: const Text(
                                  '移除消息',
                                  style: TextStyle(color: Color(0xFFB3261E)),
                                ),
                              ),
                            if (onCopyAttachments != null)
                              PopupMenuItem(
                                value: onCopyAttachments,
                                child: const Text('复制附件到会话'),
                              ),
                            if (onPin != null)
                              PopupMenuItem(
                                value: onPin,
                                child: Text(isPinned ? '取消置顶' : '置顶消息'),
                              ),
                            if (onEnterSelection != null)
                              PopupMenuItem(
                                value: onEnterSelection,
                                child: const Text('多选'),
                              ),
                            if (onEdit != null)
                              PopupMenuItem(
                                value: onEdit,
                                child: const Text('编辑'),
                              ),
                            if (onWithdraw != null)
                              PopupMenuItem(
                                value: onWithdraw,
                                child: const Text('撤回'),
                              ),
                          ],
                        ),
                      const SizedBox(width: 8),
                      if (showTime)
                        Text(
                          clockLabel(message.timestamp),
                          style: TextStyle(
                            fontSize: mobile ? 11 : 10,
                            color: muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (isForwarded) const Text('转发的消息'),
                if (isPinned)
                  const Text(
                    '已置顶',
                    style: TextStyle(fontSize: 11, color: Color(0xFFD79A2B)),
                  ),
                for (final link in {
                  for (final entity in entities)
                    if (entity.kind == 'link' && entity.url != null) entity.url!,
                })
                  InkWell(
                    onTap: () => launchUrl(
                      Uri.parse(link),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '打开链接：${Uri.tryParse(link)?.host ?? link}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF1D6FD8),
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                if (mentionSummary case final summary?)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      summary,
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                if (replyPreview case final preview?)
                  InkWell(
                    onTap: onOpenReply,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('回复 · $preview', maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                if (sdkSender == null)
                  _MessageActionsRegion(message: message, child: content)
                else if (message.text.isNotEmpty || attachmentList == null)
                  SelectionArea(child: content),
                ?attachmentList,
                if (mine)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      sdkStatus ?? (mobile ? '已送达' : '已送达 · Mock ✓'),
                      style: const TextStyle(fontSize: 9, color: muted),
                    ),
                  ),
              ],
            ),
          ),
          if (ownGroupMessage) ...[
            const SizedBox(width: 10),
            avatar,
          ] else
            SizedBox(width: mine ? 4 : 16),
        ],
      ),
      ),
    );
  }
}

class MetricsPanel extends ConsumerWidget {
  const MetricsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 17, color: green),
            SizedBox(width: 8),
            Text(
              '运行监控',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '让每一条消息，都井然有序。',
          style: TextStyle(fontSize: 10, color: muted),
        ),
        const SizedBox(height: 23),
        Consumer(
          builder: (_, ref, _) {
            final running = ref.watch(
              mockRuntimeProvider.select((s) => s.running),
            );
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: mint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: running ? green : muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      running ? '模拟消息接收中' : '模拟已暂停',
                      style: const TextStyle(fontSize: 11, color: ink),
                    ),
                  ),
                  Text(
                    'MOCK',
                    style: TextStyle(
                      fontSize: 9,
                      color: green.withValues(alpha: .7),
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 23),
        const Text('消息分布', style: TextStyle(fontSize: 11, color: muted)),
        const SizedBox(height: 10),
        Consumer(
          builder: (_, ref, _) {
            final pattern = ref.watch(
              mockRuntimeProvider.select((s) => s.pattern),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (final mode in TrafficPattern.values) ...[
                      if (mode != TrafficPattern.values.first)
                        const SizedBox(width: 6),
                      Expanded(
                        child: _Filter(
                          label: mode == TrafficPattern.hotspot
                              ? '热点模式'
                              : '全量均匀随机',
                          selected: pattern == mode,
                          onTap: () => ref
                              .read(mockRuntimeProvider.notifier)
                              .setPattern(mode),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  pattern == TrafficPattern.uniform
                      ? '每个会话等概率接收，置顶会话仍排在前面。'
                      : '优先模拟当前会话及前 100 个热点会话。',
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        const _NewChatBurstControl(),
        const SizedBox(height: 12),
        const Text('目标吞吐量', style: TextStyle(fontSize: 11, color: muted)),
        const SizedBox(height: 10),
        Consumer(
          builder: (_, ref, _) {
            final selected = ref.watch(
              mockRuntimeProvider.select((s) => s.rate),
            );
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final rate in messageRates)
                  _Filter(
                    label: rate < 1
                        ? '3 秒/条'
                        : rate < 1000
                        ? '$rate / s'
                        : '${rate ~/ 1000}k / s',
                    selected: rate == selected,
                    onTap: () =>
                        ref.read(mockRuntimeProvider.notifier).setRate(rate),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 13),
        Consumer(
          builder: (_, ref, _) {
            final running = ref.watch(
              mockRuntimeProvider.select((s) => s.running),
            );
            return SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('toggle-load'),
                onPressed: ref.read(mockRuntimeProvider.notifier).toggleRunning,
                style: FilledButton.styleFrom(
                  backgroundColor: ink,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 17),
                ),
                icon: Icon(
                  running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 17,
                ),
                label: Text(
                  running ? '暂停模拟' : '开始模拟',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 26),
        Consumer(
          builder: (_, ref, _) {
            final stats = ref.watch(metricsProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '接收速率',
                      style: TextStyle(color: muted, fontSize: 11),
                    ),
                    const Spacer(),
                    Text(
                      '${number(stats.rate)} / s',
                      style: const TextStyle(
                        color: green,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 80,
                  width: double.infinity,
                  child: CustomPaint(painter: _Sparkline(stats.history)),
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '最近 30 秒',
                      style: TextStyle(fontSize: 9, color: muted),
                    ),
                    Text('现在', style: TextStyle(fontSize: 9, color: muted)),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 19),
                  child: Divider(height: 1, color: line),
                ),
                _DataRow(
                  label: '单条处理 · 峰值',
                  value: '${stats.messageMs.toStringAsFixed(2)} ms',
                ),
                _DataRow(
                  label: '状态通知 · 峰值',
                  value: '${stats.notificationMs.toStringAsFixed(2)} ms',
                ),
                _DataRow(
                  label: '慢帧 / 采样帧',
                  value: '${stats.slowFrames} / ${stats.frameSamples}',
                ),
                _DataRow(label: '缓存消息', value: '${number(stats.cached)} / 40k'),
                _DataRow(label: '已淘汰消息', value: number(stats.evicted)),
                _DataRow(label: '未读消息', value: number(stats.unread)),
                _DataRow(label: '手动发送', value: number(stats.sent)),
              ],
            );
          },
        ),
        const SizedBox(height: 17),
        _HistoryScenarios(),
        const SizedBox(height: 17),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F7F4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '轻量运行，有界内存',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
              const SizedBox(height: 7),
              const Text(
                '独立 Isolate 逐条生成 · 即时接收\n逐条更新排序 · 按需渲染列表\n实时窗口 200 条 · 历史分页可加载',
                style: TextStyle(fontSize: 9, height: 1.9, color: muted),
              ),
              const SizedBox(height: 9),
              Text(
                '${kDebugMode
                    ? 'DEBUG · 性能请以 Profile 实测为准'
                    : kProfileMode
                    ? 'PROFILE · 性能采样已启用'
                    : 'RELEASE · 本地运行'}\nP95 = 最近 240 帧 max(UI, Raster)\n慢帧阈值 16.67ms（60Hz 参考）',
                style: const TextStyle(fontSize: 9, height: 1.7, color: green),
              ),
            ],
          ),
        ),
        const SizedBox(height: 19),
        const Center(
          child: Text(
            'NO SERVER. JUST FLOW.',
            style: TextStyle(fontSize: 8, letterSpacing: 1.6, color: muted),
          ),
        ),
      ],
    ),
  );
}

class _DataRow extends StatelessWidget {
  const _DataRow({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: muted)),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            fontSize: 10,
            color: ink,
            fontWeight: FontWeight.w500,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.icon});
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFDCE6DF)),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: green),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 10, color: green)),
      ],
    ),
  );
}

class _Sparkline extends CustomPainter {
  _Sparkline(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.length < 2) return;
    final ceiling = max(1.0, values.reduce(max) * 1.2);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - values[i] / ceiling * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x332D9B78), Color(0x002D9B78)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_Sparkline oldDelegate) => oldDelegate.values != values;
}

class _HistoryBoundary extends ConsumerWidget {
  const _HistoryBoundary({super.key, required this.conversationId});
  final int conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Consumer(
    builder: (_, ref, _) {
      final state = ref
          .watch(
            chatSessionProvider(conversationId)
                .select((s) => HistoryPresentation(s.history)),
          )
          .value;
      return SizedBox(
        height: state.hasExpiredGap ? 120 : 96,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (state.loading) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 9),
              const Text(
                '正在加载历史记录…',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ] else if (state.error != null) ...[
              Text(
                state.error!,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Color(0xFFAC6046)),
              ),
              TextButton.icon(
                key: const Key('history-retry'),
                onPressed: () => unawaited(
                  ref
                      .read(chatSessionProvider(conversationId).notifier)
                      .loadOlder(),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试加载'),
              ),
            ] else if (state.atWindowLimit) ...[
              const Text(
                '当前已展开 2,000 条历史记录',
                style: TextStyle(fontSize: 11, color: muted),
              ),
              const Text(
                '回到最新消息后可重新浏览',
                style: TextStyle(fontSize: 10, color: muted),
              ),
            ] else if (state.hasMore) ...[
              TextButton.icon(
                key: const Key('load-history'),
                onPressed: () {
                  ref
                      .read(chatSessionProvider(conversationId).notifier)
                      .freeze(true);
                  unawaited(
                    ref
                        .read(chatSessionProvider(conversationId).notifier)
                        .loadOlder(),
                  );
                },
                icon: const Icon(Icons.history_rounded, size: 16),
                label: const Text('加载更早记录'),
              ),
              Text(
                '已展开 ${state.loaded} 条 · 每页 30 条',
                style: const TextStyle(fontSize: 9, color: muted),
              ),
            ] else ...[
              Text(
                state.loaded == 0 ? '暂无消息，发送一条开始对话' : '没有更早的消息了',
                key: const Key('history-end'),
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
            if (state.hasExpiredGap)
              const Text(
                '部分实时记录已超过本次模拟的保留范围',
                style: TextStyle(fontSize: 9, color: Color(0xFFAC6046)),
              ),
          ],
        ),
      );
    },
  );
}

class _HistoryScenarios extends ConsumerWidget {
  const _HistoryScenarios();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(color: line),
      const SizedBox(height: 12),
      const Text(
        '历史记录场景',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: ink),
      ),
      const SizedBox(height: 8),
      Consumer(
        builder: (_, ref, _) {
          final mode = ref.watch(
            historyScenarioProvider.select((s) => s.network),
          );
          return DropdownButton<HistoryNetwork>(
            key: const Key('history-network'),
            value: mode,
            isExpanded: true,
            style: const TextStyle(fontSize: 11, color: ink),
            items: const [
              DropdownMenuItem(
                value: HistoryNetwork.normal,
                child: Text('正常 · 100ms 响应'),
              ),
              DropdownMenuItem(
                value: HistoryNetwork.slow,
                child: Text('慢速 · 1.5s 响应'),
              ),
              DropdownMenuItem(
                value: HistoryNetwork.offline,
                child: Text('历史服务离线'),
              ),
              DropdownMenuItem(
                value: HistoryNetwork.overlapping,
                child: Text('重复与乱序回包'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                ref.read(historyScenarioProvider.notifier).setNetwork(value);
              }
            },
          );
        },
      ),
      Consumer(
        builder: (_, ref, _) {
          final armed = ref.watch(
            historyScenarioProvider.select((s) => s.failNext),
          );
          return OutlinedButton.icon(
            key: const Key('fail-next-history'),
            onPressed: armed
                ? null
                : ref.read(historyScenarioProvider.notifier).failNextRequest,
            icon: const Icon(Icons.error_outline_rounded, size: 15),
            label: Text(
              armed ? '下次请求将失败' : '模拟下次请求失败',
              style: const TextStyle(fontSize: 10),
            ),
          );
        },
      ),
      const SizedBox(height: 8),
      const Text(
        '设置仅影响历史请求，实时消息继续逐条接收。\n上滑或点击聊天顶部的历史按钮体验。',
        style: TextStyle(fontSize: 10, color: muted, height: 1.7),
      ),
    ],
  );
}

class _ConversationSlot extends ConsumerStatefulWidget {
  const _ConversationSlot({
    super.key,
    required this.index,
    this.mobile = false,
    this.onOpen,
  });
  final int index;
  final bool mobile;
  final ValueChanged<int>? onOpen;

  @override
  ConsumerState<_ConversationSlot> createState() => _ConversationSlotState();
}

class _ConversationSlotState extends ConsumerState<_ConversationSlot> {
  int? _pressedPointer;
  int? _pressedId;
  int? _confirmedTapId;
  Conversation? _longPressTarget;
  Offset? _pressPosition;

  void _open(int displayedId) {
    // Accessibility/keyboard activation has no pointer down/up sequence.
    final id = _confirmedTapId ?? displayedId;
    _confirmedTapId = null;
    _pressedId = null;
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.onOpen != null) {
      widget.onOpen!(id);
    } else {
      ref.read(selectedConversationProvider.notifier).select(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(conversationRowProvider(widget.index));
    if (state == null) return const SizedBox.shrink();
    final item = state.item;
    final selected = !widget.mobile && state.selected;
    // Keep the recognizer attached to the slot, outside the keyed row content.
    // Capture the displayed identity on raw down: onTapDown can arrive only
    // after another message has already rebuilt this slot. Never read the live
    // index to decide which conversation the user pressed.
    return Listener(
      onPointerDown: (event) {
        if ((event.buttons == kPrimaryButton ||
                event.buttons == kSecondaryButton) &&
            _pressedPointer == null) {
          _pressedPointer = event.pointer;
          _pressedId = item.id;
          _longPressTarget = item;
          _pressPosition = event.position;
        }
      },
      onPointerUp: (event) {
        if (event.pointer == _pressedPointer) _pressedPointer = null;
      },
      onPointerCancel: (event) {
        if (event.pointer == _pressedPointer) {
          _pressedPointer = null;
          _pressedId = null;
          _longPressTarget = null;
          _pressPosition = null;
        }
      },
      child: Material(
        color: selected
            ? mint
            : widget.mobile && item.pinned
            ? const Color(0xFFF7F9F8)
            : Colors.white,
        child: InkWell(
          onLongPress: () => _showConversationMenu(
            context,
            ref,
            _pressedPointer == null ? item : _longPressTarget ?? item,
            _pressPosition ??
                (context.findRenderObject() as RenderBox).localToGlobal(
                  Offset.zero,
                ),
          ),
          onSecondaryTapUp: (details) => _showConversationMenu(
            context,
            ref,
            _longPressTarget ?? item,
            details.globalPosition,
          ),
          onTapUp: (_) => _confirmedTapId = _pressedId ?? item.id,
          onTap: () => _open(item.id),
          onTapCancel: () {
            _pressedId = null;
            _confirmedTapId = null;
          },
          child: _ConversationRow(
            key: ValueKey(item.id),
            item: item,
            selected: selected,
            mobile: widget.mobile,
          ),
        ),
      ),
    );
  }
}

class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({
    super.key,

    required this.scroll,
    required this.conversation,
  });
  final ScrollController scroll;
  final Conversation conversation;
  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  int get conversationId => widget.conversation.id;
  final Map<String, Widget> _items = {};
  final Map<String, _MessageEntranceTicket> _entrances = {};
  static const _centerKey = ValueKey('history-scroll-center');
  int? _builtNewestSequence;
  int? _builtOldestSequence;
  int? _laidOutOldestSequence;
  bool _seekingHistoryTop = false;
  int _historySeekGeneration = 0;
  late final Widget _boundary = _HistoryBoundary(
    key: const ValueKey<int>(-1),
    conversationId: conversationId,
  );

  @override
  void initState() {
    super.initState();
    ref.listenManual(appSettingsProvider.select((s) => s.messageAnimations), (
      _,
      enabled,
    ) {
      if (!enabled) _finishEntrances();
    });
    ref.listenManual(timelineStructureProvider(conversationId), (_, _) {
      final id = ref
          .read(timelineStructureProvider(conversationId).notifier)
          .lastLiveMessageId;
      if (id == null ||
          _items.containsKey(id) ||
          _entrances.length >= 4 ||
          !ref.read(appSettingsProvider).messageAnimations ||
          MediaQuery.disableAnimationsOf(context) ||
          ModalRoute.of(context)?.isCurrent != true ||
          !widget.scroll.hasClients ||
          widget.scroll.position.isScrollingNotifier.value ||
          ref.read(chatSessionProvider(conversationId)).frozen ||
          widget.scroll.offset > widget.scroll.position.minScrollExtent + .5) {
        return;
      }
      final message = ref
          .read(timelineStoreProvider(conversationId))
          .message(id);
      if (message == null) return;
      final runtime = ref.read(mockRuntimeProvider);
      // Only visual decoration is skipped at load-test rates. Every arrival has
      // already been committed and published synchronously before this callback.
      if (!message.isMine && runtime.running && runtime.rate >= 100) return;
      late final _MessageEntranceTicket ticket;
      ticket = _MessageEntranceTicket(() {
        if (identical(_entrances[id], ticket)) _entrances.remove(id);
      });
      _entrances[id] = ticket;
    });
  }

  void _finishEntrances() {
    for (final ticket in _entrances.values.toList()) {
      ticket.finish();
    }
  }

  @override
  void dispose() {
    _finishEntrances();
    super.dispose();
  }

  void showLatest() {
    _finishEntrances();
    final generation = ++_historySeekGeneration;
    _seekingHistoryTop = false;
    ref.read(chatSessionProvider(conversationId).notifier).returnToLatest();
    if (widget.scroll.hasClients) widget.scroll.jumpTo(0);
    // Changing the reading origin can correct pixels during sliver layout.
    // Finish this explicit navigation against the new coordinates, without
    // delaying any message publication or overriding a subsequent user drag.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _historySeekGeneration ||
          !widget.scroll.hasClients ||
          ref.read(chatSessionProvider(conversationId)).frozen) {
        return;
      }
      widget.scroll.jumpTo(0);
    });
  }

  Future<void> openHistory() async {
    if (_seekingHistoryTop) return;
    _finishEntrances();
    final generation = ++_historySeekGeneration;
    final session = ref.read(chatSessionProvider(conversationId).notifier);
    session.freeze(true);
    _seekingHistoryTop = true;
    try {
      // Mixed text/image heights make the lazy list's extent an estimate.
      // Resolve the existing history edge before appending a new older page.
      // These layout passes move only this explicit navigation; ingestion and
      // provider publication remain synchronous for every incoming message.
      for (var attempt = 0; attempt < 16; attempt++) {
        if (!mounted ||
            generation != _historySeekGeneration ||
            !widget.scroll.hasClients) {
          return;
        }
        widget.scroll.jumpTo(widget.scroll.position.maxScrollExtent);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted ||
            generation != _historySeekGeneration ||
            !widget.scroll.hasClients) {
          return;
        }
        if ((widget.scroll.offset - widget.scroll.position.maxScrollExtent)
                .abs() <=
            .5) {
          break;
        }
      }
      session.saveScrollOffset(widget.scroll.offset);
    } finally {
      if (generation == _historySeekGeneration) _seekingHistoryTop = false;
    }
    if (mounted && generation == _historySeekGeneration) {
      await session.loadOlder();
    }
  }

  void _rebaseAtEdge(ChatSessionNotifier session) {
    // Both origins describe the same visible newest edge. Rebase coordinates
    // before the next layout, without jumping to a different message.
    final position = widget.scroll.position;
    if (position is ScrollPositionWithSingleContext) position.goIdle();
    position.correctPixels(0);
    session.anchorAtNewerEdge();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _finishEntrances();
      _historySeekGeneration++;
      _seekingHistoryTop = false;
    }
    final session = ref.read(chatSessionProvider(conversationId).notifier);
    if (n is ScrollUpdateNotification) {
      session.saveScrollOffset(n.metrics.pixels);
      final current = ref.read(chatSessionProvider(conversationId));
      if (!current.frozen &&
          (n.scrollDelta ?? 0) > 0 &&
          n.metrics.pixels > n.metrics.minScrollExtent + 0.5) {
        _finishEntrances();
        session.freeze(true);
      }
      // Keep roughly three viewports ahead of fast scrolling through history.
      // Distance-based prefetch is immediate; the session guards in-flight,
      // exhausted and bounded-window requests without timers or batching.
      final prefetchDistance = (n.metrics.viewportDimension * 3).clamp(
        1200.0,
        3600.0,
      );
      if ((n.scrollDelta ?? 0) > 0 &&
          !_seekingHistoryTop &&
          n.metrics.extentAfter <= prefetchDistance &&
          // A page may finish before this frame lays out its new extent. Do not
          // request another page using the previous page's scroll metrics.
          current.history.before == _laidOutOldestSequence &&
          current.history.error == null) {
        unawaited(session.loadOlder());
      }
    }
    final movingNewer =
        n is ScrollUpdateNotification && (n.scrollDelta ?? 0) < 0 ||
        n is OverscrollNotification && n.overscroll < 0;
    if (movingNewer && n.metrics.pixels <= n.metrics.minScrollExtent + 0.5) {
      // Input can arrive after synchronous publication but before the next
      // layout. Old metrics cannot prove the user reached the new latest edge.
      final messages = ref.read(timelineStoreProvider(conversationId)).value;
      final latest = messages.isEmpty ? null : messages.first.historySequence;
      if (latest != _builtNewestSequence) return false;
      final current = ref.read(chatSessionProvider(conversationId));
      if (current.frozen &&
          !current.newer.loading &&
          !current.history.loading) {
        if (current.unloadedNewer > 0 && current.newer.error == null) {
          if (session.needsNewerRebase) _rebaseAtEdge(session);
          unawaited(session.loadNewer());
        } else if (current.unloadedNewer == 0) {
          _rebaseAtEdge(session);
          session.followFromNewerEdge();
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Consumer(
    builder: (_, ref, _) {
      ref.watch(timelineStructureProvider(conversationId));
      final anchor = ref.watch(
        chatSessionProvider(conversationId).select((s) => s.readingAnchor),
      );
      final feed = ref.read(timelineStoreProvider(conversationId));
      final messages = feed.value;
      _builtNewestSequence = messages.isEmpty
          ? null
          : messages.first.historySequence;
      _builtOldestSequence = messages.isEmpty
          ? null
          : messages.last.historySequence;
      final newerCount = anchor == null
          ? 0
          : messages.takeWhile((m) => m.historySequence! > anchor).length;
      _items.removeWhere((id, _) => feed.positionOf(id) == null);
      for (final entry in _entrances.entries.toList()) {
        if (feed.positionOf(entry.key) == null) entry.value.finish();
      }
      if (_entrances.isNotEmpty) {
        final tickets = _entrances.values.toList();
        // Reclaim visual tickets that did not mount in this layout. Offscreen
        // arrivals must never queue an animation for a later scroll into view.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final ticket in tickets) {
            if (!ticket.claimed) ticket.finish();
          }
        });
      }
      Widget item(int index) {
        final id = messages[index].id;
        return _items.putIfAbsent(
          id,
          () => _MessageItem(
            key: ValueKey(id),
            id: id,
            conversation: widget.conversation,
            entrance: _entrances[id],
          ),
        );
      }

      final horizontal = _usesMobileWorkspace(MediaQuery.sizeOf(context).width)
          ? 12.0
          : 20.0;
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) {
            _laidOutOldestSequence = _builtOldestSequence;
          }
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Scrollbar(
            key: const Key('message-scrollbar'),
            controller: widget.scroll,
            thumbVisibility: false,
            thickness: _usesMobileWorkspace(MediaQuery.sizeOf(context).width)
                ? 3
                : 6,
            radius: const Radius.circular(3),
            scrollbarOrientation: ScrollbarOrientation.right,
            child: ScrollConfiguration(
              // This list owns its indicator on every platform.
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: _ReadingScrollView(
                preserveReadingPosition: anchor != null,
                key: const Key('message-list'),
                controller: widget.scroll,
                reverse: true,
                center: _centerKey,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  // Grow towards newer messages below the stable reading origin.
                  // Negative scroll offsets are intentional and retained per session.
                  if (newerCount > 0)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontal,
                        0,
                        horizontal,
                        12,
                      ),
                      sliver: _ReadingSliver.builder(
                        itemCount: newerCount,
                        findChildIndexCallback: (key) {
                          final position = key is ValueKey<String>
                              ? feed.positionOf(key.value)
                              : null;
                          return position != null && position < newerCount
                              ? newerCount - position - 1
                              : null;
                        },
                        itemBuilder: (_, index) => item(newerCount - index - 1),
                      ),
                    ),
                  SliverPadding(
                    key: _centerKey,
                    padding: EdgeInsets.fromLTRB(
                      horizontal,
                      20,
                      horizontal,
                      12,
                    ),
                    sliver: _ReadingSliver.builder(
                      itemCount: messages.length - newerCount + 1,
                      findChildIndexCallback: (key) {
                        if (key == const ValueKey<int>(-1)) {
                          return messages.length - newerCount;
                        }
                        final position = key is ValueKey<String>
                            ? feed.positionOf(key.value)
                            : null;
                        return position != null && position >= newerCount
                            ? position - newerCount
                            : null;
                      },
                      itemBuilder: (_, index) =>
                          index == messages.length - newerCount
                          ? _boundary
                          : item(index + newerCount),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _NewerHistoryStatus extends ConsumerWidget {
  const _NewerHistoryStatus({required this.id});
  final int id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final newer = ref.watch(chatSessionProvider(id).select((s) => s.newer));
    if (!newer.loading && newer.error == null) return const SizedBox.shrink();
    return Material(
      color: mint,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                newer.loading ? '正在接续新消息…' : newer.error!,
                style: const TextStyle(fontSize: 12, color: ink),
              ),
            ),
            if (!newer.loading && !newer.hasExpiredGap)
              TextButton(
                key: const Key('newer-retry'),
                onPressed: () =>
                    ref.read(chatSessionProvider(id).notifier).loadNewer(),
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageItem extends ConsumerWidget {
  const _MessageItem({
    super.key,
    required this.id,
    required this.conversation,
    this.entrance,
  });
  final String id;
  final Conversation conversation;
  final _MessageEntranceTicket? entrance;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      messageProvider((conversationId: conversation.id, messageId: id)),
    );
    if (message == null) return const SizedBox.shrink();
    final bubble = _MessageBubble(
      key: ValueKey(id),
      message: message,
      conversation: conversation,
    );
    return entrance == null
        ? bubble
        : _MessageEntrance(
            key: ValueKey('message-entrance-$id'),
            ticket: entrance!,
            child: bubble,
          );
  }
}


List<InlineSpan> _richMessageSpans(
  String text,
  List<ImEntity> entities,
  TextStyle base,
) {
  if (entities.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: base)];
  }
  final boundaries = <int>{0, text.length};
  for (final entity in entities) {
    final start = entity.offset.clamp(0, text.length);
    final end = (entity.offset + entity.length).clamp(0, text.length);
    if (start < end) boundaries.addAll([start, end]);
  }
  final points = boundaries.toList()..sort();
  final spans = <InlineSpan>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final start = points[i], end = points[i + 1];
    if (start == end) continue;
    var style = base;
    for (final entity in entities) {
      final entityStart = entity.offset.clamp(0, text.length);
      final entityEnd = (entity.offset + entity.length).clamp(0, text.length);
      if (start < entityStart || end > entityEnd) continue;
      switch (entity.kind) {
        case 'bold':
          style = style.copyWith(fontWeight: FontWeight.w700);
        case 'italic':
          style = style.copyWith(fontStyle: FontStyle.italic);
        case 'code':
        case 'preformatted':
          style = style.copyWith(
            fontFamily: 'Menlo',
            fontFamilyFallback: const ['Courier'],
            backgroundColor: base.color == Colors.white
                ? const Color(0x1A000000)
                : const Color(0x33FFFFFF),
          );
        case 'link':
          style = style.copyWith(
            color: base.color == Colors.white
                ? const Color(0xFFCDE9FF)
                : const Color(0xFF1D6FD8),
            decoration: TextDecoration.underline,
          );
      }
    }
    spans.add(
      TextSpan(text: text.substring(start, end), style: style),
    );
  }
  return spans;
}
