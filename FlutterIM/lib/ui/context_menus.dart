part of 'workspace.dart';

enum _MessageMenuAction { copy, preview, delete }

enum _ConversationMenuAction { pin, mute, read }

RelativeRect _contextMenuPosition(BuildContext context, Offset globalPosition) {
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()
          as RenderBox;
  final point = overlay.globalToLocal(globalPosition);
  return RelativeRect.fromRect(
    Rect.fromLTWH(point.dx, point.dy, 0, 0),
    Offset.zero & overlay.size,
  );
}

class _ConversationMenuEntry {
  const _ConversationMenuEntry(this.action, this.key, this.icon, this.label);
  final _ConversationMenuAction action;
  final String key, label;
  final IconData icon;
}

List<_ConversationMenuEntry> _conversationEntries(Conversation target) => [
  _ConversationMenuEntry(
    _ConversationMenuAction.pin,
    'conversation-menu-pin',
    target.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
    target.pinned ? '取消置顶' : '置顶聊天',
  ),
  _ConversationMenuEntry(
    _ConversationMenuAction.mute,
    'conversation-menu-mute',
    target.muted
        ? Icons.notifications_active_outlined
        : Icons.notifications_off_outlined,
    target.muted ? '关闭免打扰' : '消息免打扰',
  ),
  const _ConversationMenuEntry(
    _ConversationMenuAction.read,
    'conversation-menu-read',
    Icons.done_all_rounded,
    '标为已读',
  ),
];

class _ConversationActionLabel extends StatelessWidget {
  const _ConversationActionLabel(this.entry);
  final _ConversationMenuEntry entry;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: mint,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(entry.icon, size: 20, color: green),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Text(
          entry.label,
          style: const TextStyle(
            fontSize: 16,
            color: ink,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );
}

class _ConversationActionSheet extends StatelessWidget {
  const _ConversationActionSheet(this.target);
  final Conversation target;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                key: const Key('conversation-action-sheet'),
                color: Colors.white,
                borderRadius: BorderRadius.circular(26),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                      child: Row(
                        children: [
                          ChatAvatar(
                            id: target.id,
                            name: target.displayName,
                            group: target.isGroup,
                            size: 46,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  target.displayName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    color: ink,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  target.unread == 0
                                      ? '没有未读消息'
                                      : '${number(target.unread)} 条未读消息',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(
                      height: 1,
                      color: line,
                      indent: 20,
                      endIndent: 20,
                    ),
                    for (final entry in _conversationEntries(target))
                      InkWell(
                        key: Key(entry.key),
                        onTap: () => Navigator.of(context).pop(entry.action),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 13,
                          ),
                          child: _ConversationActionLabel(entry),
                        ),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('conversation-menu-cancel'),
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 17),
                    child: Text(
                      '取消',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _showConversationMenu(
  BuildContext context,
  WidgetRef ref,
  Conversation target,
  Offset position,
) async {
  // Own the target and actions independently of a row that may be recycled.
  final actions = ref.read(conversationActionsProvider);
  final navigator = Navigator.of(context, rootNavigator: true);
  final mobile = _usesMobileWorkspace(MediaQuery.sizeOf(context).width);
  if (mobile && ref.read(appSettingsProvider).haptics) {
    unawaited(HapticFeedback.selectionClick());
  }
  final action = mobile
      ? await showModalBottomSheet<_ConversationMenuAction>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          barrierColor: const Color(0x4D10271F),
          elevation: 0,
          builder: (_) => _ConversationActionSheet(target),
        )
      : await showMenu<_ConversationMenuAction>(
          context: context,
          useRootNavigator: true,
          position: _contextMenuPosition(context, position),
          semanticLabel: '${target.displayName}的会话操作',
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 12,
          shadowColor: const Color(0x29102C22),
          constraints: const BoxConstraints(minWidth: 248, maxWidth: 320),
          menuPadding: const EdgeInsets.symmetric(vertical: 8),
          items: [
            PopupMenuItem(
              enabled: false,
              child: Text(
                target.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 13),
              ),
            ),
            const PopupMenuDivider(),
            for (final entry in _conversationEntries(target))
              PopupMenuItem(
                key: Key(entry.key),
                value: entry.action,
                height: 60,
                child: _ConversationActionLabel(entry),
              ),
          ],
        );
  if (!navigator.mounted || action == null) return;
  switch (action) {
    case _ConversationMenuAction.pin:
      actions.setPinned(target.id, !target.pinned);
    case _ConversationMenuAction.mute:
      actions.setMuted(target.id, !target.muted);
    case _ConversationMenuAction.read:
      actions.markRead(target.id);
  }
}

class _MessageToolbar extends StatelessWidget {
  const _MessageToolbar({
    required this.bubble,
    required this.press,
    required this.isImage,
    required this.animation,
  });

  final Rect bubble;
  final Offset press;
  final bool isImage;
  final Animation<double> animation;
  static const pointerHeight = 7.0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final labelSize = media.textScaler.scale(13);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport =
            (media.padding + media.viewInsets + const EdgeInsets.all(8))
                .deflateRect(Offset.zero & constraints.biggest);
        if (viewport.isEmpty) return const SizedBox.shrink();
        final width = min(
          viewport.width,
          2.0 * max(72.0, 2.0 * labelSize + 24) + 1,
        );
        final height = min(
          viewport.height,
          46 + labelSize * 1.3 + pointerHeight,
        );
        final aboveSpace = bubble.top - viewport.top;
        final belowSpace = viewport.bottom - bubble.bottom;
        final above = aboveSpace >= height + 3 || aboveSpace >= belowSpace;
        final center = press.dx.clamp(bubble.left, bubble.right);
        final left = (center - width / 2).clamp(
          viewport.left,
          viewport.right - width,
        );
        final top = (above ? bubble.top - height - 3 : bubble.bottom + 3).clamp(
          viewport.top,
          viewport.bottom - height,
        );
        final inset = min(18.0, width / 2);
        final tip = (center - left).clamp(inset, width - inset);
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  alignment: Alignment(2 * tip / width - 1, above ? 1 : -1),
                  scale: animation.drive(Tween(begin: .94, end: 1.0)),
                  child: PhysicalShape(
                    key: const Key('message-toolbar'),
                    color: const Color(0xFFFBFCFB),
                    elevation: 7,
                    shadowColor: const Color(0x5515201B),
                    clipBehavior: Clip.antiAlias,
                    clipper: _MessageToolbarShape(above, tip),
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: above ? 0 : pointerHeight,
                        bottom: above ? pointerHeight : 0,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Row(
                          children: [
                            _action(
                              context,
                              isImage
                                  ? _MessageMenuAction.preview
                                  : _MessageMenuAction.copy,
                              isImage
                                  ? Icons.open_in_full_rounded
                                  : Icons.copy_rounded,
                              isImage ? '查看' : '复制',
                            ),
                            Container(
                              width: 1,
                              height: 24,
                              color: const Color(0xFFE2E6E3),
                            ),
                            _action(
                              context,
                              _MessageMenuAction.delete,
                              Icons.delete_outline_rounded,
                              '删除',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _action(
    BuildContext context,
    _MessageMenuAction action,
    IconData icon,
    String label,
  ) {
    final color = action == _MessageMenuAction.delete
        ? const Color(0xFFB54541)
        : ink;
    return Expanded(
      child: InkWell(
        key: Key('message-menu-${action.name}'),
        onTap: () => Navigator.of(context).pop(action),
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// One silhouette keeps the pointer and its shadow continuous at the rounded edge.
class _MessageToolbarShape extends CustomClipper<Path> {
  const _MessageToolbarShape(this.above, this.tip);
  final bool above;
  final double tip;

  @override
  Path getClip(Size size) {
    const h = _MessageToolbar.pointerHeight;
    final edge = above ? size.height - h : h;
    final sign = above ? 1.0 : -1.0;
    final body = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            0,
            above ? 0 : h,
            size.width,
            above ? edge : size.height,
          ),
          const Radius.circular(15),
        ),
      );
    final pointer = Path()
      ..moveTo(tip - 8, edge - sign)
      ..lineTo(tip - 2, edge + sign * (h - 2))
      ..quadraticBezierTo(tip, edge + sign * h, tip + 2, edge + sign * (h - 2))
      ..lineTo(tip + 8, edge - sign)
      ..close();
    return Path.combine(PathOperation.union, body, pointer);
  }

  @override
  bool shouldReclip(_MessageToolbarShape old) =>
      above != old.above || tip != old.tip;
}

class _MessageActionsRegion extends ConsumerStatefulWidget {
  const _MessageActionsRegion({required this.message, required this.child});
  final ChatMessage message;
  final Widget child;

  @override
  ConsumerState<_MessageActionsRegion> createState() =>
      _MessageActionsRegionState();
}

class _MessageActionsRegionState extends ConsumerState<_MessageActionsRegion> {
  ChatMessage? _pressedMessage;
  int? _pointer;
  Offset? _pressPosition;
  Rect? _pressBounds;

  Future<void> _showMenu(Offset position, ChatMessage target) async {
    final actions = ref.read(messageActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final isImage = target.type == MessageType.image;
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()
            as RenderBox;
    final box = context.findRenderObject() as RenderBox;
    final bounds = _pointer == null
        ? box.localToGlobal(Offset.zero) & box.size
        : _pressBounds ?? box.localToGlobal(Offset.zero) & box.size;
    final media = MediaQuery.of(context);
    final bubble = Rect.fromPoints(
      overlay.globalToLocal(bounds.topLeft),
      overlay.globalToLocal(bounds.bottomRight),
    );
    final press = overlay.globalToLocal(position);
    if (_usesMobileWorkspace(media.size.width) && ref.read(appSettingsProvider).haptics) {
      unawaited(HapticFeedback.selectionClick());
    }
    final action = await showGeneralDialog<_MessageMenuAction>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: Duration(
        milliseconds: media.disableAnimations ? 0 : 130,
      ),
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (_, animation, _) => Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: '消息操作',
        child: _MessageToolbar(
          bubble: bubble,
          press: press,
          isImage: isImage,
          animation: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
        ),
      ),
    );
    if (action == null) return;
    if (action == _MessageMenuAction.delete) {
      actions.deleteMessage(target);
      return;
    }
    if (action == _MessageMenuAction.preview) {
      if (navigator.mounted) _showImagePreview(navigator.context, target);
      return;
    }
    await Clipboard.setData(ClipboardData(text: target.text));
    if (messenger.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('已复制消息')));
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (_pointer == null &&
          (event.buttons == kPrimaryButton ||
              event.buttons == kSecondaryButton)) {
        _pointer = event.pointer;
        _pressedMessage = widget.message;
        _pressPosition = event.position;
        final box = context.findRenderObject() as RenderBox;
        _pressBounds = box.localToGlobal(Offset.zero) & box.size;
      }
    },
    onPointerUp: (event) {
      if (event.pointer == _pointer) _pointer = null;
    },
    onPointerCancel: (event) {
      if (event.pointer == _pointer) {
        _pointer = null;
        _pressedMessage = null;
        _pressPosition = null;
        _pressBounds = null;
      }
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.message.type == MessageType.image
          ? () => _showImagePreview(context, widget.message)
          : null,
      onLongPress: () => _showMenu(
        _pointer == null
            ? (context.findRenderObject() as RenderBox).localToGlobal(
                Offset.zero,
              )
            : _pressPosition!,
        _pointer == null ? widget.message : _pressedMessage ?? widget.message,
      ),
      onSecondaryTapUp: (details) =>
          _showMenu(details.globalPosition, _pressedMessage ?? widget.message),
      child: widget.child,
    ),
  );
}
