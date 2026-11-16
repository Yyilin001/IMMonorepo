part of 'workspace.dart';

void _showAppSettings(BuildContext context) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/me/settings'),
      builder: (_) => const AppSettingsPage(),
    ),
  ),
);

class _SettingsButton extends StatelessWidget {
  const _SettingsButton();
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('open-app-settings'),
    tooltip: '设置',
    onPressed: () => _showAppSettings(context),
    icon: const Icon(Icons.settings_outlined, color: ink),
  );
}

void _showAboutRipple(BuildContext context) => showAboutDialog(
  context: context,
  applicationName: '涟漪',
  applicationVersion: _SdkScope.of(context) == null ? '1.0.0' : '1.0.1',
  applicationIcon: const Icon(
    Icons.chat_bubble_outline_rounded,
    color: green,
    size: 36,
  ),
  children: [
    Text(
      _SdkScope.of(context) == null
          ? '完全本地运行的即时通讯体验。联系人和消息均为模拟数据，无需登录。'
          : '涟漪即时通讯 · 共享 Swift SDK',
    ),
  ],
);

class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => _ProfileScaffold(
    title: '设置',
    children: [
      if (_SdkScope.of(context) == null) ...[
        const _SettingsHeading('账号'),
        _InfoCard(
          children: [
            _SettingsLink(
              id: 'settings-edit-profile',
              icon: Icons.person_outline_rounded,
              title: '编辑个人资料',
              subtitle: '昵称、地区和个性签名',
              onTap: () => _editMyProfile(context),
            ),
          ],
        ),
      ],
      const _SettingsHeading('通用'),
      _InfoCard(
        children: [
          _SettingsLink(
            id: 'settings-appearance',
            icon: Icons.palette_outlined,
            title: '聊天外观',
            subtitle: '字体大小、默认背景与消息动画',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _AppearanceSettingsPage(),
              ),
            ),
          ),
          const Divider(height: 1, indent: 18, endIndent: 18),
          _SettingsLink(
            id: 'settings-privacy',
            icon: Icons.notifications_none_rounded,
            title: '消息与隐私',
            subtitle: '未读角标、会话内容预览',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _MessageSettingsPage(),
              ),
            ),
          ),
          const Divider(height: 1, indent: 18, endIndent: 18),
          Consumer(
            builder: (_, ref, _) => _SettingsSwitch(
              id: 'settings-haptics',
              title: '操作触感',
              subtitle: '长按会话或消息时轻微振动',
              value: ref.watch(appSettingsProvider.select((s) => s.haptics)),
              onChanged: (value) => ref
                  .read(appSettingsProvider.notifier)
                  .update(
                    ref.read(appSettingsProvider).copyWith(haptics: value),
                  ),
            ),
          ),
        ],
      ),
      const _SettingsHeading('更多'),
      _InfoCard(
        children: [
          _SettingsLink(
            id: 'settings-about',
            icon: Icons.info_outline_rounded,
            title: '关于涟漪',
            subtitle: '版本 1.0.0',
            onTap: () => _showAboutRipple(context),
          ),
          const Divider(height: 1, indent: 18, endIndent: 18),
          _SettingsLink(
            id: 'settings-reset',
            icon: Icons.restore_rounded,
            title: '恢复默认设置',
            subtitle: '恢复本页偏好，保留消息和个人资料',
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('恢复默认设置？'),
                  content: const Text(
                    '将恢复聊天外观、消息预览、未读角标和操作触感。聊天消息、个人资料及单独设置的会话背景会保留。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      key: const Key('confirm-reset-settings'),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                await ref.read(appSettingsProvider.notifier).reset();
              }
            },
          ),
        ],
      ),
      const _SettingsPersistenceNotice(),
    ],
  );
}

class _SettingsHeading extends StatelessWidget {
  const _SettingsHeading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        color: muted,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String id, title, subtitle;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    key: Key(id),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    leading: Icon(icon, color: green),
    title: Text(title, style: const TextStyle(fontSize: 16, color: ink)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        subtitle,
        style: const TextStyle(fontSize: 13, color: muted, height: 1.4),
      ),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, color: muted),
    onTap: onTap,
  );
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String id, title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    key: Key(id),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    title: Text(title, style: const TextStyle(fontSize: 16, color: ink)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        subtitle,
        style: const TextStyle(fontSize: 13, color: muted, height: 1.4),
      ),
    ),
    value: value,
    onChanged: onChanged,
  );
}

class _SettingsPersistenceNotice extends ConsumerWidget {
  const _SettingsPersistenceNotice();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(settingsSaveErrorProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Text(
            error ?? '应用偏好自动保存到本机。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: error == null ? muted : const Color(0xFFAC6046),
            ),
          ),
          if (error != null)
            TextButton(
              onPressed: () =>
                  ref.read(appSettingsProvider.notifier).retrySave(),
              child: const Text('重试保存'),
            ),
        ],
      ),
    );
  }
}

class _AppearanceSettingsPage extends ConsumerWidget {
  const _AppearanceSettingsPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    void update(AppPreferences value) =>
        unawaited(ref.read(appSettingsProvider.notifier).update(value));
    return _ProfileScaffold(
      title: '聊天外观',
      children: [
        const _SettingsHeading('预览'),
        Container(
          key: const Key('settings-chat-preview'),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: settings.background.color,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('涟漪', style: TextStyle(fontSize: 13, color: muted)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '把聊天调成你喜欢的样子。',
                  style: TextStyle(
                    fontSize: 16 + settings.fontDelta,
                    color: ink,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const _SettingsHeading('聊天字体'),
        _InfoCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final size in ChatTextSize.values)
                      ChoiceChip(
                        key: ValueKey('settings-font-${size.name}'),
                        label: Text(switch (size) {
                          ChatTextSize.small => '小',
                          ChatTextSize.standard => '标准',
                          ChatTextSize.large => '大',
                          ChatTextSize.extraLarge => '特大',
                        }, style: const TextStyle(fontSize: 15)),
                        selected: settings.textSize == size,
                        onSelected: (_) => update(
                          ref
                              .read(appSettingsProvider)
                              .copyWith(textSize: size),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const _SettingsHeading('默认聊天背景'),
        _InfoCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final background in ChatBackground.values)
                      ChoiceChip(
                        key: ValueKey(
                          'settings-default-background-${background.name}',
                        ),
                        avatar: CircleAvatar(
                          backgroundColor: background.color,
                          radius: 10,
                        ),
                        label: Text(
                          background.label,
                          style: const TextStyle(fontSize: 15),
                        ),
                        selected: settings.background == background,
                        onSelected: (_) => update(
                          ref
                              .read(appSettingsProvider)
                              .copyWith(background: background),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 10, 4, 20),
          child: Text(
            '已单独设置背景的会话继续使用自己的背景。',
            style: TextStyle(fontSize: 13, color: muted, height: 1.5),
          ),
        ),
        _InfoCard(
          children: [
            _SettingsSwitch(
              id: 'settings-message-animation',
              title: '新消息动画',
              subtitle: '新消息轻微淡入；高速接收和阅读历史时自动跳过',
              value: settings.messageAnimations,
              onChanged: (value) => update(
                ref
                    .read(appSettingsProvider)
                    .copyWith(messageAnimations: value),
              ),
            ),
          ],
        ),
        const _SettingsPersistenceNotice(),
      ],
    );
  }
}

class _MessageSettingsPage extends ConsumerWidget {
  const _MessageSettingsPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    void update(AppPreferences value) =>
        unawaited(ref.read(appSettingsProvider.notifier).update(value));
    return _ProfileScaffold(
      title: '消息与隐私',
      children: [
        const _SettingsHeading('消息显示'),
        _InfoCard(
          children: [
            _SettingsSwitch(
              id: 'settings-unread-badge',
              title: '显示未读总数',
              subtitle: '在消息导航入口显示未读角标',
              value: settings.unreadBadge,
              onChanged: (value) => update(
                ref.read(appSettingsProvider).copyWith(unreadBadge: value),
              ),
            ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            _SettingsSwitch(
              id: 'settings-message-preview',
              title: '显示会话内容预览',
              subtitle: '关闭后，会话列表隐藏最后一条消息内容',
              value: settings.messagePreview,
              onChanged: (value) => update(
                ref.read(appSettingsProvider).copyWith(messagePreview: value),
              ),
            ),
          ],
        ),
        const _SettingsPersistenceNotice(),
      ],
    );
  }
}
