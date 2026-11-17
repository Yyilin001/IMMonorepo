part of 'workspace.dart';

class _SdkChat extends ConsumerStatefulWidget {
  const _SdkChat({super.key, required this.room});
  final ImConversation room;
  @override
  ConsumerState<_SdkChat> createState() => _SdkChatState();
}

class _SdkChatState extends ConsumerState<_SdkChat> {
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  late final int id;
  late final Stream<ImTimelinePage> messages;
  ImTimelinePage? currentPage;
  bool paging = false;
  ImMessage? replyTarget;
  final activeMutations = <String>{};
  bool initialized = false, sending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sdk = _SdkScope.of(context)!;
    if (!initialized) {
      initialized = true;
      id = sdk.keyFor(widget.room.id);
      input.text = ref.read(draftProvider(id));
      messages = sdk.client!.watchTimeline(widget.room.id).map((page) {
        currentPage = page;
        return page;
      });
    }
  }

  Future<void> changePage(ImTimelinePage page, {required bool latest}) async {
    if (paging) return;
    setState(() => paging = true);
    try {
      await _SdkScope.of(context)!.client!
          .changeWindowPage(page.windowId, latest: latest);
      if (mounted && scroll.hasClients) scroll.jumpTo(0);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => paging = false);
    }
  }

  Future<void> send() async {
    final text = input.text;
    if (sending || text.trim().isEmpty) return;
    setState(() => sending = true);
    final reply = replyTarget;
    try {
      await _SdkScope.of(context)!.client!
          .sendText(widget.room.id, text, replyToMessageId: reply?.id);
      if (mounted && replyTarget == reply) replyTarget = null;
      if (mounted && input.text == text) {
        input.clear();
        ref.read(draftProvider(id).notifier).save('');
        final page = currentPage;
        if (page != null && !page.isLatest) {
          await changePage(page, latest: true);
        } else if (scroll.hasClients) {
          scroll.jumpTo(0);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(e))));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> mutate(ImMessage item, {required bool editing}) async {
    final revision = item.mutableRevision;
    if (revision == null || !activeMutations.add(item.id)) return;
    setState(() {});
    final client = _SdkScope.of(context)!.client!;
    try {
      if (editing) {
        await showDialog<bool>(
          context: context,
          builder: (_) => _EditTextDialog(
            title: '编辑消息',
            original: item.text,
            save: (text) =>
                client.editMessage(widget.room.id, item.id, revision, text),
          ),
        );
      } else {
        await client.withdrawMessage(widget.room.id, item.id, revision);
        if (mounted && replyTarget?.id == item.id) replyTarget = null;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => activeMutations.remove(item.id));
    }
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _SdkScope.of(context)!;
    final room =
        sdk.rooms.where((r) => r.id == widget.room.id).firstOrNull ??
        widget.room;
    final name = room.title.isEmpty ? '会话' : room.title;
    final conversation = Conversation(
      id: id,
      name: name,
      preview: room.preview,
      isGroup: room.isGroup,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(room.updatedAt ?? 0),
    );
    void profile() => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ProfileScaffold(
          title: '会话资料',
          children: [
            _ProfileHeader(
              id: id,
              name: name,
              handle: room.peerId ?? room.id,
              group: room.isGroup,
            ),
            if (room.isGroup) _GroupDetailsButton(roomId: room.id),
          ],
        ),
      ),
    );
    return Column(
      children: [
        SizedBox(
          height: kToolbarHeight,
          child: AppBar(
            primary: false,
            centerTitle: false,
            titleSpacing: 0,
            leading: const BackButton(key: Key('back')),
            title: _ChatHeading(
              id: id,
              displayName: name,
              group: room.isGroup,
              mobile: true,
              subtitle: room.isGroup ? '群聊' : '会话',
              onProfile: profile,
              onHistory: () {
                final page = currentPage;
                if (page != null && page.hasOlder) {
                  unawaited(changePage(page, latest: false));
                } else if (scroll.hasClients) {
                  scroll.animateTo(
                    scroll.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOut,
                  );
                }
              },
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _AppearanceSettingsPage(),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: ref.watch(chatBackgroundProvider(id)).color,
            child: StreamBuilder(
              stream: messages,
              builder: (_, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text(_errorText(snapshot.error!)));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final page = snapshot.data!;
                final rows = page.messages;
                return Column(
                  children: [
                    if (page.hasOlder || !page.isLatest)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (page.hasOlder)
                            TextButton(
                              onPressed: paging
                                  ? null
                                  : () => changePage(page, latest: false),
                              child: const Text('更早消息'),
                            ),
                          if (!page.isLatest)
                            TextButton(
                              onPressed: paging
                                  ? null
                                  : () => changePage(page, latest: true),
                              child: const Text('返回最新'),
                            ),
                        ],
                      ),
                    Expanded(
                      child: ListView.builder(
                        key: const Key('shared-timeline'),
                        controller: scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        itemCount: rows.length,
                        itemBuilder: (_, index) {
                          final item = rows[rows.length - 1 - index];
                          final mine = item.senderId == sdk.userId;
                          final text = item.withdrawn
                              ? '消息已撤回'
                              : item.hasMedia && item.text.isEmpty
                              ? '[附件]'
                              : item.text;
                          final caption = switch (item.pendingStatus) {
                            null => item.readByPeer ? '已读' : '已发送',
                            ImSendStatus.rejected ||
                            ImSendStatus.expiredUnsubmitted ||
                            ImSendStatus.needsAttention => '发送未完成',
                            ImSendStatus.waitingForNetwork => '等待网络',
                            _ => '发送中',
                          };
                          return KeyedSubtree(
                            key: ValueKey(item.id),
                            child: _MessageBubble(
                              key: ValueKey(
                                item.pendingStatus == null
                                    ? 'projected-message'
                                    : 'pending-message',
                              ),
                              conversation: conversation,
                              sdkSender: mine
                                  ? '我'
                                  : room.isGroup
                                  ? item.senderId
                                  : name,
                              sdkStatus: caption,
                              onEdit:
                                  item.mutableRevision != null &&
                                      !activeMutations.contains(item.id)
                                  ? () => mutate(item, editing: true)
                                  : null,
                              onWithdraw:
                                  item.mutableRevision != null &&
                                      !activeMutations.contains(item.id)
                                  ? () => mutate(item, editing: false)
                                  : null,
                              onReply:
                                  !sending &&
                                      item.pendingStatus == null &&
                                      !item.withdrawn
                                  ? () {
                                      setState(() => replyTarget = item);
                                      focus.requestFocus();
                                    }
                                  : null,
                              replyPreview: item.replyPreview,
                              isForwarded: item.isForwarded,
                              showTime: item.createdAt != null,
                              message: ChatMessage(
                                id: item.id,
                                conversationId: id,
                                senderId: room.isGroup
                                    ? sdk.keyFor(item.senderId)
                                    : id,
                                isMine: mine,
                                timestamp: DateTime.fromMillisecondsSinceEpoch(
                                  item.createdAt ?? 0,
                                ),
                                text: text,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        if (replyTarget case final target?)
          ListTile(
            leading: const Icon(Icons.reply),
            title: Text(
              target.text.isEmpty ? '[附件]' : target.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '取消回复',
              icon: const Icon(Icons.close),
              onPressed: sending
                  ? null
                  : () => setState(() => replyTarget = null),
            ),
          ),
        _MobileComposer(
          id: id,
          input: input,
          focus: focus,
          onSend: sending ? null : send,
          attachmentButton: const _ComposerActionButton(
            tooltip: '当前支持文本消息',
            icon: Icons.add_rounded,
            outlined: true,
            onPressed: null,
          ),
        ),
      ],
    );
  }
}

class _EditTextDialog extends StatefulWidget {
  const _EditTextDialog({
    required this.original,
    required this.save,
    required this.title,
    this.allowEmpty = false,
  });
  final String title;
  final bool allowEmpty;
  final String original;
  final Future<void> Function(String) save;

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late String text = widget.original;
  bool busy = false;
  String? error;

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.save(text);
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
    title: Text(widget.title),
    content: TextFormField(
      initialValue: widget.original,
      autofocus: true,
      enabled: !busy,
      maxLines: null,
      decoration: InputDecoration(errorText: error),
      onChanged: (value) => setState(() => text = value),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed:
            busy ||
                (!widget.allowEmpty && text.trim().isEmpty) ||
                text == widget.original
            ? null
            : submit,
        child: const Text('保存'),
      ),
    ],
  );
}
