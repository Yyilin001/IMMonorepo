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
  final Map<String, ImProfile> senderProfiles = {};
  final Set<String> _senderProfilesRequested = {};
  final Set<String> selected = {};
  final List<String> mentions = [];
  bool initialized = false, sending = false, selecting = false, forwarding = false;

  void enterSelection(ImMessage item) {
    setState(() {
      selecting = true;
      selected
        ..clear()
        ..add(item.id);
    });
  }

  void toggleSelection(ImMessage item) {
    if (!selecting) return;
    setState(() {
      if (!selected.remove(item.id)) selected.add(item.id);
    });
  }

  void exitSelection() {
    setState(() {
      selecting = false;
      selected.clear();
    });
  }

  Future<List<String>?> pickForwardTargets() async {
    final sdk = _SdkScope.of(context)!;
    final targets = sdk.rooms.where((r) => r.id != widget.room.id).toList();
    final chosen = <String>{};
    return showModalBottomSheet<List<String>>(
      context: context,
      builder: (sheet) => StatefulBuilder(
        builder: (_, update) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('转发到'),
                trailing: TextButton(
                  onPressed: chosen.isEmpty
                      ? null
                      : () => Navigator.pop(sheet, chosen.toList()),
                  child: Text('转发（${chosen.length}/10）'),
                ),
              ),
              if (targets.isEmpty)
                const ListTile(title: Text('暂无其他会话')),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: targets.length,
                  itemBuilder: (_, index) {
                    final room = targets[index];
                    final checked = chosen.contains(room.id);
                    return CheckboxListTile(
                      key: ValueKey('forward-target-${room.id}'),
                      title: Text(room.title.isEmpty ? room.id : room.title),
                      value: checked,
                      onChanged: !checked && chosen.length >= 10
                          ? null
                          : (value) => update(() {
                              if (value == true) {
                                chosen.add(room.id);
                              } else {
                                chosen.remove(room.id);
                              }
                            }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pickMentions() async {
    final controller = TextEditingController(text: mentions.join(', '));
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('提及成员'),
        content: TextField(
          key: const Key('mentions-input'),
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '@all 或 @handle，逗号分隔，最多 20 个',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;
    final values = <String>[];
    for (final part in text.split(RegExp(r'[,，\s]+'))) {
      final handle = part.trim();
      if (handle.isEmpty || values.contains(handle)) continue;
      values.add(handle);
      if (values.length == 20) break;
    }
    setState(() {
      mentions
        ..clear()
        ..addAll(values);
    });
  }

  Future<void> copyAttachments(ImMessage message) async {
    final attachments = message.attachments;
    if (attachments.isEmpty) return;
    final sdk = _SdkScope.of(context)!;
    final targets = sdk.rooms.where((r) => r.id != widget.room.id).toList();
    final target = await showModalBottomSheet<ImConversation>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('复制附件到会话')),
            if (targets.isEmpty) const ListTile(title: Text('暂无其他会话')),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: targets.length,
                itemBuilder: (_, index) {
                  final room = targets[index];
                  return ListTile(
                    key: ValueKey('copy-attachment-target-${room.id}'),
                    title: Text(room.title.isEmpty ? room.id : room.title),
                    onTap: () => Navigator.pop(sheet, room),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    final client = sdk.client!;
    final directory = await Directory.systemTemp.createTemp('im-copy-');
    var copied = 0, failed = 0;
    try {
      for (final attachment in attachments) {
        final safe = attachment.name.replaceAll(RegExp(r'[/\\]'), '_');
        final path = '${directory.path}/$safe';
        try {
          await client.exportAttachment(
            widget.room.id,
            message.id,
            attachment.id,
            path,
          );
          await client.sendAttachment(
            target.id,
            path: path,
            name: attachment.name,
            contentType: attachment.contentType,
          );
          copied += 1;
        } catch (_) {
          failed += 1;
        }
      }
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '已复制 $copied 个附件到「${target.title}」'
              : '已复制 $copied 个附件，$failed 个未能提交',
        ),
      ),
    );
  }

  Future<void> forwardSelected() async {
    final page = currentPage;
    if (page == null || forwarding) return;
    final items = [
      for (final item in page.messages)
        if (selected.contains(item.id) &&
            !item.withdrawn &&
            item.revision != null)
          item,
    ];
    if (items.isEmpty) return;
    if (items.length > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('一次最多转发 100 条消息')),
      );
      return;
    }
    final chosen = await pickForwardTargets();
    if (chosen == null || chosen.isEmpty || !mounted) return;
    final client = _SdkScope.of(context)!.client!;
    setState(() => forwarding = true);
    var ok = 0, failed = 0;
    for (final item in items) {
      try {
        await client.forwardMessageToRooms(
          widget.room.id,
          item.id,
          item.revision!,
          chosen,
        );
        ok += 1;
      } catch (_) {
        failed += 1;
      }
    }
    if (!mounted) return;
    setState(() {
      forwarding = false;
      selecting = false;
      selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '已转发 $ok 条消息到 ${chosen.length} 个会话'
              : '已转发 $ok 条，$failed 条未能提交',
        ),
      ),
    );
  }

  Future<void> loadSenderProfiles(Iterable<String> ids) async {
    final sdk = _SdkScope.of(context);
    if (sdk?.client == null) return;
    final wanted = <String>{};
    for (final id in ids) {
      if (id.isNotEmpty &&
          !_senderProfilesRequested.contains(id) &&
          !senderProfiles.containsKey(id)) {
        wanted.add(id);
        if (wanted.length == 50) break;
      }
    }
    if (wanted.isEmpty) return;
    _senderProfilesRequested.addAll(wanted);
    try {
      final rows = await sdk!.client!.profiles(
        page: 'room:${widget.room.id}',
        context: widget.room.isGroup ? 'room' : 'direct',
        roomId: widget.room.isGroup ? widget.room.id : null,
        userIds: wanted.toList(growable: false),
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          senderProfiles[row.userId] = row;
        }
      });
    } catch (_) {
      _senderProfilesRequested.removeAll(wanted);
    }
  }

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
        final ids = <String>{
          for (final message in page.messages)
            if (message.senderId != sdk.userId) message.senderId,
          if (widget.room.peerId != null) widget.room.peerId!,
        };
        unawaited(loadSenderProfiles(ids));
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
      await _SdkScope.of(context)!.client!.sendText(
        widget.room.id,
        text,
        replyToMessageId: reply?.id,
        mentions: List<String>.of(mentions),
      );
      if (mounted && replyTarget == reply) replyTarget = null;
      if (mounted) setState(() => mentions.clear());
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

  Future<void> forwardMessage(ImMessage item, int revision) async {
    if (!activeMutations.add(item.id)) return;
    setState(() {});
    final sdk = _SdkScope.of(context)!;
    final client = sdk.client!;
    final targets = sdk.rooms.where((r) => r.id != widget.room.id).toList();
    try {
      final selected = <String>{};
      final chosen = await showModalBottomSheet<List<String>>(
        context: context,
        builder: (sheet) => StatefulBuilder(
          builder: (_, update) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('转发到'),
                  trailing: TextButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => Navigator.pop(sheet, selected.toList()),
                    child: Text('转发（${selected.length}/10）'),
                  ),
                ),
                if (targets.isEmpty) const ListTile(title: Text('暂无其他会话')),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    itemBuilder: (_, index) {
                      final room = targets[index];
                      final checked = selected.contains(room.id);
                      return CheckboxListTile(
                        key: ValueKey('forward-target-${room.id}'),
                        title: Text(room.title.isEmpty ? room.id : room.title),
                        value: checked,
                        onChanged: !checked && selected.length >= 10
                            ? null
                            : (value) => update(() {
                                if (value == true) {
                                  selected.add(room.id);
                                } else {
                                  selected.remove(room.id);
                                }
                              }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (chosen == null || !mounted || sdk.client != client) return;
      await client.forwardMessageToRooms(
        widget.room.id,
        item.id,
        revision,
        chosen,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已提交转发')));
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

  Future<void> updatePendingSend(
    String id,
    Future<void> Function(ImClient) apply,
  ) async {
    if (!activeMutations.add(id)) return;
    setState(() {});
    try {
      await apply(_SdkScope.of(context)!.client!);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => activeMutations.remove(id));
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
    final peerName = room.peerId == null
        ? null
        : senderProfiles[room.peerId!]?.name;
    final name = room.isGroup
        ? (room.title.isEmpty ? '群聊' : room.title)
        : (peerName ?? (room.title.isEmpty ? '会话' : room.title));
    final conversation = Conversation(
      id: id,
      name: name,
      preview: room.preview,
      isGroup: room.isGroup,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(room.updatedAt ?? 0),
    );
    void profile() => _openSdkConversationProfile(context, sdk, room, id, name);
    void history() {
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
    }
    return Column(
      children: [
        if (selecting)
          SizedBox(
            height: kToolbarHeight,
            child: AppBar(
              primary: false,
              leading: IconButton(
                key: const Key('exit-selection'),
                icon: const Icon(Icons.close),
                tooltip: '取消多选',
                onPressed: forwarding ? null : exitSelection,
              ),
              title: Text('已选 ${selected.length} 条'),
              actions: [
                TextButton(
                  key: const Key('forward-selected'),
                  onPressed: forwarding || selected.isEmpty
                      ? null
                      : forwardSelected,
                  child: Text(forwarding ? '转发中…' : '转发'),
                ),
              ],
            ),
          )
        else
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
              avatar: room.isGroup
                  ? SdkGroupAvatar(roomId: room.id, name: name, size: 32)
                  : room.peerId != null
                  ? SdkAvatar(
                      userId: room.peerId!,
                      name: name,
                      context: 'direct',
                      size: 32,
                    )
                  : null,
              onProfile: profile,
              onHistory: history,
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _SdkChatSettings(
                    room: room,
                    avatarId: id,
                    onHistory: () {
                      Navigator.of(context).maybePop();
                      history();
                    },
                    onProfile: profile,
                  ),
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
                            ImSendStatus.rejected => '消息未能发送',
                            ImSendStatus.expiredUnsubmitted => '未提交，已超过发送期限',
                            ImSendStatus.closed => '已确认未发送',
                            ImSendStatus.needsAttention => '发送结果未知，确认已暂停',
                            ImSendStatus.confirmingOutcome => '正在确认发送结果',
                            ImSendStatus.acceptedAwaitingProjection =>
                              '服务器已受理，等待同步',
                            ImSendStatus.waitingForAuthentication => '等待登录恢复',
                            ImSendStatus.preparing => '正在准备附件',
                            ImSendStatus.preparationWaiting => '等待发送',
                            ImSendStatus.preparationPaused => '上传已暂停，可重试',
                            ImSendStatus.preparationUserPaused => '附件准备已暂停',
                            ImSendStatus.preparationExpired => '发送准备已过期',
                            ImSendStatus.preparationRejected => '附件处理失败',
                            ImSendStatus.preparationProcessing => '正在安全处理',
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
                                  ? (senderProfiles[item.senderId]?.name ??
                                        item.senderId)
                                  : name,
                              sdkStatus: switch ((
                                item.preparedAttachments,
                                item.totalAttachments,
                              )) {
                                (final int ready, final int total)
                                    when total > 0 =>
                                  '$caption · 附件 $ready/$total',
                                _ => caption,
                              },
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
                              recovery: activeMutations.contains(item.id)
                                  ? null
                                  : switch (item.pendingStatus) {
                                      ImSendStatus.needsAttention => (
                                        label: '继续确认',
                                        action: () => updatePendingSend(
                                          item.id,
                                          (client) => client.recoverSend(
                                            item.id,
                                            resend: false,
                                          ),
                                        ),
                                      ),
                                      ImSendStatus.preparationPaused ||
                                      ImSendStatus.preparationExpired ||
                                      ImSendStatus.expiredUnsubmitted ||
                                      ImSendStatus.closed ||
                                      ImSendStatus.rejected => (
                                        label: switch (item.pendingStatus) {
                                          ImSendStatus.preparationPaused =>
                                            '重试准备',
                                          ImSendStatus.preparationExpired =>
                                            '重新准备',
                                          _ => '重新发送',
                                        },
                                        action: () => updatePendingSend(
                                          item.id,
                                          (client) => client.recoverSend(
                                            item.id,
                                            resend: true,
                                          ),
                                        ),
                                      ),
                                      _ => null,
                                    },
                              onCancelSend:
                                  !activeMutations.contains(item.id) &&
                                      switch (item.pendingStatus) {
                                        ImSendStatus.preparing ||
                                        ImSendStatus.preparationWaiting ||
                                        ImSendStatus.preparationPaused ||
                                        ImSendStatus.preparationUserPaused ||
                                        ImSendStatus.preparationExpired ||
                                        ImSendStatus.preparationRejected ||
                                        ImSendStatus.preparationProcessing ||
                                        ImSendStatus.expiredUnsubmitted ||
                                        ImSendStatus.closed ||
                                        ImSendStatus.rejected => true,
                                        _ => false,
                                      }
                                  ? () => updatePendingSend(
                                      item.id,
                                      (client) =>
                                          client.cancelPendingSend(item.id),
                                    )
                                  : null,
                              onForward:
                                  !item.withdrawn &&
                                      item.revision != null &&
                                      !activeMutations.contains(item.id)
                                  ? () => forwardMessage(item, item.revision!)
                                  : null,
                              onEnterSelection:
                                  !item.withdrawn &&
                                      item.revision != null &&
                                      !selecting
                                  ? () => enterSelection(item)
                                  : null,
                              selecting: selecting,
                              selected: selected.contains(item.id),
                              onToggleSelect: () => toggleSelection(item),
                              mentionSummary: item.mentionSummary,
                              entities: item.entities,
                              isPinned: item.isPinned ?? false,
                              onCopyAttachments:
                                  !item.withdrawn && item.attachments.isNotEmpty
                                  ? () => copyAttachments(item)
                                  : null,
                              onPin:
                                  room.isGroup &&
                                      !item.withdrawn &&
                                      item.roomSequence != null
                                  ? () async {
                                      try {
                                        await sdk.client!.pinMessage(
                                          room.id,
                                          item.id,
                                          roomSequence: item.roomSequence!,
                                          isPinned: !(item.isPinned ?? false),
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('已提交置顶变更'),
                                            ),
                                          );
                                        }
                                        final page = currentPage;
                                        if (page != null) {
                                          await changePage(page, latest: true);
                                        }
                                      } catch (failure) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                _errorText(failure),
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  : null,
                              onFavorite:
                                  !item.withdrawn &&
                                      item.pendingStatus == null
                                  ? () async {
                                      try {
                                        await sdk.client!.setFavorite(
                                          room.id,
                                          item.id,
                                          favorited: true,
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('已加入收藏'),
                                            ),
                                          );
                                        }
                                      } catch (failure) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                _errorText(failure),
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  : null,
                              onReaders:
                                  room.isGroup &&
                                      mine &&
                                      !item.withdrawn &&
                                      item.revision != null
                                  ? () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => _MessageReadersPage(
                                          roomId: room.id,
                                          messageId: item.id,
                                        ),
                                      ),
                                    )
                                  : null,
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
                              onOpenReply: item.replyToId == null
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => _LocatedMessagePage(
                                          client: sdk.client!,
                                          roomId: widget.room.id,
                                          messageId: item.replyToId!,
                                        ),
                                      ),
                                    ),
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
        if (widget.room.isGroup)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                TextButton.icon(
                  key: const Key('add-mentions'),
                  onPressed: sending ? null : pickMentions,
                  icon: const Icon(Icons.alternate_email, size: 18),
                  label: const Text('提及'),
                ),
                if (mentions.isNotEmpty)
                  Expanded(
                    child: Text(
                      mentions.join(' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ),
                if (mentions.isNotEmpty)
                  IconButton(
                    tooltip: '清除提及',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: sending
                        ? null
                        : () => setState(() => mentions.clear()),
                  ),
              ],
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

class _MessageSearchPage extends StatefulWidget {
  const _MessageSearchPage({
    required this.client,
    this.room,
    this.roomTitles = const {},
  });
  final ImClient client;
  final ImConversation? room;
  final Map<String, String> roomTitles;
  @override
  State<_MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends State<_MessageSearchPage> {
  final input = TextEditingController();
  final hits = <(String, String), ImSearchHit>{};
  bool busy = false, hasNext = false;
  String? status;

  Future<void> search({bool next = false}) async {
    final query = input.text.trim();
    if (busy || query.isEmpty) return;
    setState(() {
      busy = true;
      if (!next) hits.clear();
      hasNext = false;
      status = null;
    });
    try {
      final page = await widget.client.searchMessages(
        widget.room?.id,
        query,
        next: next,
      );
      if (!mounted) return;
      setState(() {
        for (final hit in page.hits) {
          hits[(hit.roomId, hit.id)] = hit;
        }
        hasNext = page.hasNext;
        status = switch (page.status) {
          'ready' => hits.isEmpty ? '没有匹配的消息' : null,
          'refreshRequired' => '结果已变化，请重新搜索',
          _ => '搜索索引暂不可用，请稍后重试',
        };
      });
    } catch (error) {
      if (mounted) setState(() => status = _errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    unawaited(widget.client.clearMessageSearch().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.room == null ? '搜索全部聊天记录' : '搜索聊天记录')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: input,
            autofocus: true,
            readOnly: busy,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => search(),
            onChanged: (_) => setState(() {
              hits.clear();
              hasNext = false;
              status = null;
            }),
            decoration: InputDecoration(
              hintText: '输入消息正文',
              suffixIcon: IconButton(
                tooltip: '搜索',
                icon: const Icon(Icons.search),
                onPressed: busy || input.text.trim().isEmpty
                    ? null
                    : () => search(),
              ),
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (status != null) Text(status!),
        Expanded(
          child: ListView(
            children: [
              for (final hit in hits.values)
                ListTile(
                  key: ValueKey(('search-hit', hit.roomId, hit.id)),
                  title: Text(hit.text),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _LocatedMessagePage(
                        client: widget.client,
                        roomId: hit.roomId,
                        messageId: hit.id,
                      ),
                    ),
                  ),
                  subtitle: widget.room == null
                      ? Text(widget.roomTitles[hit.roomId] ?? hit.roomId)
                      : null,
                ),
              if (hasNext)
                TextButton(
                  onPressed: busy ? null : () => search(next: true),
                  child: const Text('更多结果'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _LocatedMessagePage extends StatefulWidget {
  const _LocatedMessagePage({
    required this.client,
    required this.roomId,
    required this.messageId,
  });
  final ImClient client;
  final String roomId, messageId;
  @override
  State<_LocatedMessagePage> createState() => _LocatedMessagePageState();
}

class _LocatedMessagePageState extends State<_LocatedMessagePage> {
  late final messages = widget.client.locateMessage(
    widget.roomId,
    widget.messageId,
  );
  final center = GlobalKey();

  Widget row(ImMessage item) => ListTile(
    key: ValueKey(item.id),
    selected: item.id == widget.messageId,
    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
    title: Text(item.senderId),
    subtitle: SelectableText(
      item.withdrawn
          ? '消息已撤回'
          : [
              if (item.text.isNotEmpty) item.text,
              for (final attachment in item.attachments) attachment.name,
              if (item.hasMedia && item.attachments.isEmpty) '[附件]',
            ].join('\n'),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('消息上下文')),
    body: FutureBuilder<List<ImMessage>>(
      future: messages,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('无法定位原消息。 ${_errorText(snapshot.error!)}'));
        }
        final items = snapshot.data;
        if (items == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final index = items.indexWhere((item) => item.id == widget.messageId);
        if (index < 0) return const Center(child: Text('原消息已不可用'));
        return CustomScrollView(
          center: center,
          anchor: .35,
          slivers: [
            SliverList.builder(
              itemCount: index,
              itemBuilder: (_, i) => row(items[index - i - 1]),
            ),
            SliverList.builder(
              key: center,
              itemCount: items.length - index,
              itemBuilder: (_, i) => row(items[index + i]),
            ),
          ],
        );
      },
    ),
  );
}

/// The reference chat settings layout, backed by the shared conversation
/// state instead of the local demo stores.
class _SdkChatSettings extends ConsumerWidget {
  const _SdkChatSettings({
    required this.room,
    required this.avatarId,
    required this.onHistory,
    required this.onProfile,
  });
  final ImConversation room;
  final int avatarId;
  final VoidCallback onHistory;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sdk = _SdkScope.of(context)!;
    final live = sdk.rooms.where((r) => r.id == room.id).firstOrNull ?? room;
    final name = live.title.isEmpty ? '会话' : live.title;
    final isMuted = _sdkMuted(live.muteUntil);
    final background = ref.watch(chatBackgroundProvider(avatarId));
    return _ProfileScaffold(
      title: '聊天设置',
      children: [
        const SizedBox(height: 20),
        _InfoCard(
          children: [
            ListTile(
              key: const Key('sdk-settings-profile'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: ChatAvatar(
                id: avatarId,
                name: name,
                group: live.isGroup,
                size: 48,
              ),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(live.isGroup ? '查看群聊资料' : '查看个人资料'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onProfile,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            SwitchListTile.adaptive(
              key: const Key('sdk-settings-pin'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              title: const Text('置顶聊天'),
              subtitle: const Text('在会话列表顶部显示'),
              value: live.isPinned,
              onChanged: (value) =>
                  sdk.applyConversationState(live, pinned: value),
            ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            SwitchListTile.adaptive(
              key: const Key('sdk-settings-mute'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              title: const Text('消息免打扰'),
              subtitle: const Text('消息照常接收，未读标记使用灰色'),
              value: isMuted,
              onChanged: (value) => sdk.applyConversationState(
                live,
                muteUntil: value
                    ? DateTime.now()
                          .add(_sdkMuteHorizon)
                          .millisecondsSinceEpoch
                    : 0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            ListTile(
              key: const Key('sdk-settings-archive'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: Icon(
                live.isArchived
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: green,
              ),
              title: Text(live.isArchived ? '取消隐藏聊天' : '隐藏聊天'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final value = !live.isArchived;
                final applied = await sdk.applyConversationState(
                  live,
                  archived: value,
                );
                if (value && applied && context.mounted) {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                }
              },
            ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            ListTile(
              key: const Key('sdk-settings-history'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: const Icon(Icons.history_rounded, color: green),
              title: const Text('查看聊天记录'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onHistory,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '聊天背景',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final choice in ChatBackground.values)
                          ChoiceChip(
                            key: ValueKey('sdk-chat-background-${choice.name}'),
                            label: Text(choice.label),
                            avatar: CircleAvatar(
                              backgroundColor: choice.color,
                              radius: 10,
                            ),
                            selected: background == choice,
                            onSelected: (_) => ref
                                .read(chatBackgroundProvider(avatarId).notifier)
                                .select(choice),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          '置顶、免打扰与隐藏会同步到账号内的其他设备。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
  }
}

void _openSdkConversationProfile(
  BuildContext context,
  _SdkWorkspaceState sdk,
  ImConversation room,
  int id,
  String name,
) => Navigator.of(context).push(
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
        ListTile(
          leading: const Icon(Icons.search),
          title: const Text('搜索聊天记录'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _MessageSearchPage(client: sdk.client!, room: room),
            ),
          ),
        ),
        const _TransfersLink(),
        if (room.isGroup) _GroupDetailsButton(roomId: room.id, name: room.title),
      ],
    ),
  ),
);
