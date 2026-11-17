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
  final downloads = <(String, String)>{};
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

  Future<void> attach() async {
    if (sending || replyTarget != null) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => sending = true);
    try {
      final photo = await showModalBottomSheet<bool>(
        context: context,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('相册'),
                onTap: () => Navigator.pop(sheet, true),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('文件'),
                onTap: () => Navigator.pop(sheet, false),
              ),
            ],
          ),
        ),
      );
      if (!mounted || photo == null) return;
      final file = photo
          ? await ImagePicker().pickImage(
              source: ImageSource.gallery,
              requestFullMetadata: false,
            )
          : await openFile();
      if (!mounted || file == null) return;
      final bytes = await file.length();
      if (!mounted) return;
      if (bytes < 1 || bytes > 33554432) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请选择非空且不超过 32 MiB 的附件')));
        return;
      }
      final caption = input.text;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('发送附件'),
          content: Text(
            [file.name, if (caption.isNotEmpty) caption].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('发送'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await client.sendAttachment(
        widget.room.id,
        path: file.path,
        name: file.name,
        contentType:
            file.mimeType ??
            lookupMimeType(file.name) ??
            'application/octet-stream',
        text: caption,
      );
      if (!mounted) return;
      if (input.text == caption) {
        input.clear();
        ref.read(draftProvider(id).notifier).save('');
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('附件已加入发送队列')));
      final page = currentPage;
      if (page != null && !page.isLatest) await changePage(page, latest: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  bool exporting = false;

  Future<void> export(ImMessage message, ImAttachment attachment) async {
    if (exporting) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => exporting = true);
    try {
      final saved = await saveAttachmentCopy(
        name: attachment.name,
        write: (path) => client.exportAttachment(
          widget.room.id,
          message.id,
          attachment.id,
          path,
        ),
        chooseDestination: (path) async {
          if (!mounted ||
              ModalRoute.isCurrentOf(context) == false ||
              currentPage?.messages.any(
                    (m) =>
                        m.id == message.id &&
                        !m.withdrawn &&
                        m.attachments.any((a) => a.id == attachment.id),
                  ) !=
                  true) {
            return null;
          }
          return FlutterFileDialog.saveFile(
            params: SaveFileDialogParams(sourceFilePath: path),
          );
        },
      );
      if (mounted && saved != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('附件已保存')));
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请确认附件已下载，再重试保存。 ${_errorText(failure)}')),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> download(ImMessage message, ImAttachment attachment) async {
    final key = (message.id, attachment.id);
    if (!downloads.add(key)) return;
    setState(() {});
    try {
      await _SdkScope.of(context)!.client!
          .downloadAttachment(widget.room.id, message.id, attachment.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已提交附件下载请求')));
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(failure))));
      }
    } finally {
      if (mounted) setState(() => downloads.remove(key));
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
            const _TransfersLink(),
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
                              : item.hasMedia &&
                                    item.attachments.isEmpty &&
                                    item.text.isEmpty
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
                              attachmentList:
                                  item.withdrawn || item.attachments.isEmpty
                                  ? null
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (final attachment
                                            in item.attachments) ...[
                                          ListTile(
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(attachment.name),
                                            subtitle: Text(
                                              '${attachment.contentType} · ${number(attachment.bytes)} 字节',
                                            ),
                                            trailing:
                                                attachment.bytes > 33554432
                                                ? null
                                                : IconButton(
                                                    tooltip: '下载附件',
                                                    icon: const Icon(
                                                      Icons.download_outlined,
                                                    ),
                                                    onPressed:
                                                        downloads.contains((
                                                          item.id,
                                                          attachment.id,
                                                        ))
                                                        ? null
                                                        : () => download(
                                                            item,
                                                            attachment,
                                                          ),
                                                  ),
                                          ),
                                          if (attachment.bytes <= 33554432)
                                            TextButton.icon(
                                              onPressed: exporting
                                                  ? null
                                                  : () => export(
                                                      item,
                                                      attachment,
                                                    ),
                                              icon: const Icon(Icons.save_alt),
                                              label: const Text('保存到文件'),
                                            ),
                                          if (attachment.contentType.startsWith(
                                            'image/',
                                          ))
                                            AttachmentImagePreview(
                                              key: ValueKey((
                                                widget.room.id,
                                                item.id,
                                                attachment.id,
                                              )),
                                              name: attachment.name,
                                              load: () =>
                                                  sdk.client!.previewAttachment(
                                                    widget.room.id,
                                                    item.id,
                                                    attachment.id,
                                                  ),
                                            ),
                                        ],
                                      ],
                                    ),
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
          attachmentButton: _ComposerActionButton(
            tooltip: '发送附件',
            icon: Icons.add_rounded,
            outlined: true,
            onPressed: sending || replyTarget != null ? null : attach,
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

class AttachmentImagePreview extends StatefulWidget {
  const AttachmentImagePreview({
    super.key,
    required this.name,
    required this.load,
  });
  final String name;
  final Future<({Uint8List bytes, Duration remaining})> Function() load;

  @override
  State<AttachmentImagePreview> createState() => _AttachmentImagePreviewState();
}

class _AttachmentImagePreviewState extends State<AttachmentImagePreview>
    with WidgetsBindingObserver {
  MemoryImage? image;
  Timer? expiry;
  int generation = 0;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void release() {
    generation++;
    expiry?.cancel();
    final current = image;
    image = null;
    if (current != null) unawaited(current.evict());
    loading = false;
    error = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) release();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) setState(release);
  }

  Future<void> show() async {
    if (loading) return;
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.load();
      if (!mounted || generation != request) return;
      image = MemoryImage(result.bytes);
      expiry = Timer(result.remaining, () => setState(release));
    } catch (failure) {
      if (mounted && generation == request) error = _errorText(failure);
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (image case final preview?)
        Image(
          image: preview,
          height: 180,
          fit: BoxFit.contain,
          semanticLabel: widget.name,
          errorBuilder: (_, _, _) => const Text('无法显示图片'),
        ),
      if (error != null) Text(error!),
      TextButton(
        onPressed: loading
            ? null
            : image == null
            ? show
            : () => setState(release),
        child: Text(
          loading
              ? '正在读取预览…'
              : image == null
              ? '查看图片'
              : '收起图片',
        ),
      ),
    ],
  );
}
