part of 'workspace.dart';

extension _ChatBackgroundPresentation on ChatBackground {
  Color get color => switch (this) {
    ChatBackground.light => const Color(0xFFFAFCFA),
    ChatBackground.mint => const Color(0xFFEAF4EE),
    ChatBackground.warm => const Color(0xFFFAF1E5),
  };
  String get label => switch (this) {
    ChatBackground.light => '浅白',
    ChatBackground.mint => '薄荷',
    ChatBackground.warm => '暖杏',
  };
}

class ChatSettingsPage extends ConsumerWidget {
  const ChatSettingsPage({
    super.key,
    required this.id,
    required this.onHistory,
  });
  final int id;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(contactProfileProvider(id)).contact;
    final pinned = ref.watch(chatSessionProvider(id).select((s) => s.pinned));
    final quiet = ref.watch(chatSessionProvider(id).select((s) => s.muted));
    final background = ref.watch(chatBackgroundProvider(id));
    return _ProfileScaffold(
      title: '聊天设置',
      children: [
        const SizedBox(height: 20),
        _InfoCard(
          children: [
            ListTile(
              key: const Key('settings-profile'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: ChatAvatar(
                id: id,
                name: contact.name,
                group: contact.isGroup,
                size: 48,
              ),
              title: Text(
                contact.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(contact.isGroup ? '查看群聊资料' : '查看个人资料'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _showContactProfile(
                context,
                id,
                onMessage: (targetId) {
                  if (targetId != id) {
                    ref
                        .read(selectedConversationProvider.notifier)
                        .select(targetId);
                  }
                  Navigator.of(context).pop();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            SwitchListTile.adaptive(
              key: const Key('settings-pin'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              title: const Text('置顶聊天'),
              subtitle: const Text('在会话列表顶部显示'),
              value: pinned,
              onChanged: (_) =>
                  ref.read(chatSessionProvider(id).notifier).togglePinned(),
            ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            SwitchListTile.adaptive(
              key: const Key('settings-mute'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              title: const Text('消息免打扰'),
              subtitle: const Text('消息照常接收，未读标记使用灰色'),
              value: quiet,
              onChanged: ref.read(chatSessionProvider(id).notifier).setMuted,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            ListTile(
              key: const Key('settings-history'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: const Icon(Icons.history_rounded, color: green),
              title: const Text('查看聊天记录'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).pop();
                onHistory();
              },
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
                            key: ValueKey('chat-background-${choice.name}'),
                            label: Text(choice.label),
                            avatar: CircleAvatar(
                              backgroundColor: choice.color,
                              radius: 10,
                            ),
                            selected: background == choice,
                            onSelected: (_) => ref
                                .read(chatBackgroundProvider(id).notifier)
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
          '设置仅保存在本次运行中，重启后恢复默认。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
  }
}
