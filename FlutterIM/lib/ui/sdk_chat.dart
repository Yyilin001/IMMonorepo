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
  late final Stream<List<ImMessage>> messages;
  bool initialized = false, sending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sdk = _SdkScope.of(context)!;
    if (!initialized) {
      initialized = true;
      id = sdk.keyFor(widget.room.id);
      input.text = ref.read(draftProvider(id));
      messages = sdk.client!.watchMessages(widget.room.id);
    }
  }

  Future<void> send() async {
    final text = input.text;
    if (sending || text.trim().isEmpty) return;
    setState(() => sending = true);
    try {
      await _SdkScope.of(context)!.client!.sendText(widget.room.id, text);
      if (mounted && input.text == text) {
        input.clear();
        ref.read(draftProvider(id).notifier).save('');
        if (scroll.hasClients) scroll.jumpTo(0);
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
                if (scroll.hasClients) {
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
                final rows = snapshot.data!;
                return ListView.builder(
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
                      null => '已发送',
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
                );
              },
            ),
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
