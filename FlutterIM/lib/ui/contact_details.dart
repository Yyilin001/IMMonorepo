part of 'workspace.dart';

void _editContactNotes(BuildContext context, int id) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '/contact/$id/edit'),
      builder: (_) => EditContactNotesPage(id: id),
    ),
  ),
);

class ContactOptionsPage extends ConsumerWidget {
  const ContactOptionsPage({super.key, required this.id, this.onDeleted});
  final int id;
  final VoidCallback? onDeleted;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(contactProfileProvider(id));
    final preferences = ref.watch(conversationPreferencesProvider(id));
    final deleted = ref.watch(contactDeletedProvider(id));
    final actions = ref.read(conversationActionsProvider);
    return _ProfileScaffold(
      title: profile.contact.isGroup ? '群聊资料设置' : '联系人设置',
      children: [
        const _SettingsHeading('资料'),
        _InfoCard(
          children: [
            if (deleted)
              const _ProfileInfo(label: '状态', value: '联系人已删除，已有会话和记录仍保留。')
            else
              _SettingsLink(
                id: 'contact-settings-edit',
                icon: Icons.edit_outlined,
                title: '备注与标签',
                subtitle: '填写只对自己可见的联系信息',
                onTap: () => _editContactNotes(context, id),
              ),
          ],
        ),
        const _SettingsHeading('会话'),
        _InfoCard(
          children: [
            _SettingsSwitch(
              id: 'contact-settings-pin',
              title: '置顶聊天',
              subtitle: '在会话列表顶部显示',
              value: preferences.pinned,
              onChanged: (value) => actions.setPinned(id, value),
            ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            _SettingsSwitch(
              id: 'contact-settings-mute',
              title: '消息免打扰',
              subtitle: '消息照常接收，未读标记使用灰色',
              value: preferences.muted,
              onChanged: (value) => actions.setMuted(id, value),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          '置顶与免打扰仅在本次运行中保留。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: muted, height: 1.5),
        ),
        if (!profile.contact.isGroup) ...[
          const SizedBox(height: 24),
          _DeleteContactButton(
            id: id,
            onDeleted: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              onDeleted?.call();
            },
          ),
        ],
        const _ContactNotesNotice(),
      ],
    );
  }
}

class _ContactNotesNotice extends ConsumerWidget {
  const _ContactNotesNotice();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(contactNotesSaveErrorProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 20),
      child: Column(
        children: [
          Text(
            error ?? '备注、标签及补充信息仅自己可见，保存后会在本机保留。',
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
                  ref.read(contactNotesStoreProvider.notifier).persist(),
              child: const Text('重试保存'),
            ),
        ],
      ),
    );
  }
}

class _ContactCopyInfo extends StatelessWidget {
  const _ContactCopyInfo({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
    title: Text(label, style: const TextStyle(fontSize: 14, color: muted)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(value, style: const TextStyle(fontSize: 16, color: ink)),
    ),
    trailing: IconButton(
      tooltip: '复制$label',
      icon: const Icon(Icons.copy_rounded, size: 19, color: green),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$label已复制')));
        }
      },
    ),
  );
}

class EditContactNotesPage extends ConsumerStatefulWidget {
  const EditContactNotesPage({super.key, required this.id});
  final int id;
  @override
  ConsumerState<EditContactNotesPage> createState() =>
      _EditContactNotesPageState();
}

class _EditContactNotesPageState extends ConsumerState<EditContactNotesPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _remark, _tags, _phone, _description;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    final notes = ref.read(contactNotesProvider(widget.id));
    _remark = TextEditingController(text: notes.remark);
    _tags = TextEditingController(text: notes.tags.join('，'));
    _phone = TextEditingController(text: notes.phone);
    _description = TextEditingController(text: notes.description);
  }

  @override
  void dispose() {
    _remark.dispose();
    _tags.dispose();
    _phone.dispose();
    _description.dispose();
    super.dispose();
  }

  List<String> _splitTags(String value) => value
      .split(RegExp('[,，、\\n]'))
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet()
      .toList();
  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    FocusManager.instance.primaryFocus?.unfocus();
    await ref
        .read(contactEditActionsProvider)
        .save(
          widget.id,
          remark: _remark.text,
          tags: _splitTags(_tags.text),
          phone: _phone.text,
          description: _description.text,
        );
    if (!mounted) return;
    if (ref.read(contactNotesSaveErrorProvider) != null) {
      setState(() => _saving = false);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(contactProfileProvider(widget.id));
    return _ProfileScaffold(
      title: '备注与标签',
      actions: [
        TextButton(
          key: const Key('save-contact-notes'),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? '保存中' : '保存',
            style: const TextStyle(fontSize: 16, color: green),
          ),
        ),
      ],
      children: [
        const SizedBox(height: 20),
        Text(
          '${profile.contact.isGroup ? '群名' : '昵称'}：${profile.contact.originalName}',
          style: const TextStyle(fontSize: 14, color: muted, height: 1.5),
        ),
        const SizedBox(height: 20),
        Form(
          key: _form,
          child: Column(
            children: [
              _field('备注名', 'contact-remark', _remark, 24, hint: '留空使用原昵称'),
              const SizedBox(height: 18),
              _field(
                '标签',
                'contact-tags',
                _tags,
                100,
                hint: '例如：同事，设计，朋友',
                validator: (value) {
                  final tags = _splitTags(value ?? '');
                  if (tags.length > 6) return '最多添加 6 个标签';
                  if (tags.any((tag) => tag.runes.length > 12)) {
                    return '每个标签最多 12 个字';
                  }
                  return null;
                },
              ),
              if (!profile.contact.isGroup) ...[
                const SizedBox(height: 18),
                _field(
                  '电话号码',
                  'contact-phone',
                  _phone,
                  32,
                  keyboard: TextInputType.phone,
                  hint: '选填，只对自己可见',
                ),
              ],
              const SizedBox(height: 18),
              _field(
                '补充说明',
                'contact-description',
                _description,
                200,
                lines: 4,
                hint: '记录你们如何认识，或下次想聊的事',
              ),
            ],
          ),
        ),
        const _ContactNotesNotice(),
      ],
    );
  }

  Widget _field(
    String label,
    String key,
    TextEditingController controller,
    int limit, {
    String? hint,
    int lines = 1,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) => TextFormField(
    key: Key(key),
    controller: controller,
    enabled: !_saving,
    maxLength: limit,
    minLines: lines,
    maxLines: lines,
    keyboardType: keyboard,
    validator: (value) => (value ?? '').trim().runes.length > limit
        ? '最多 $limit 个字'
        : validator?.call(value),
    style: const TextStyle(fontSize: 16, color: ink),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 14),
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

Future<void> _restoreContact(
  BuildContext context,
  WidgetRef ref,
  int id,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final actions = ref.read(contactEditActionsProvider);
  final saved = await actions.restoreContact(id);
  if (!saved && messenger.mounted) {
    messenger.showSnackBar(
      const SnackBar(content: Text('联系人已添加，但未能保存到本机，请在资料页重试保存。')),
    );
  }
}

class _DeletedContactComposer extends ConsumerWidget {
  const _DeletedContactComposer({required this.id});
  final int id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
    key: const Key('deleted-contact-composer'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    color: Colors.white,
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        const Text(
          '联系人已删除，聊天记录仍保留',
          style: TextStyle(fontSize: 14, color: muted),
        ),
        TextButton(
          key: const Key('chat-restore-contact'),
          onPressed: () => _restoreContact(context, ref, id),
          child: const Text('重新添加'),
        ),
      ],
    ),
  );
}

class _DeleteContactButton extends ConsumerStatefulWidget {
  const _DeleteContactButton({required this.id, required this.onDeleted});
  final int id;
  final VoidCallback onDeleted;
  @override
  ConsumerState<_DeleteContactButton> createState() =>
      _DeleteContactButtonState();
}

class _DeleteContactButtonState extends ConsumerState<_DeleteContactButton> {
  bool _busy = false;
  Future<void> _delete() async {
    if (_busy) return;
    if (!ref.read(contactDeletedProvider(widget.id))) {
      final name = ref.read(contactDisplayNameProvider(widget.id));
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text('删除“$name”？'),
          content: const Text(
            '将从联系人列表移除，并停止与其模拟收发消息。已有会话、聊天记录和备注会保留，可从原会话资料页重新添加。',
          ),
          actions: [
            TextButton(
              key: const Key('cancel-delete-contact'),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('confirm-delete-contact'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                '删除联系人',
                style: TextStyle(color: Color(0xFFB54040)),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busy = true);
    final saved = await ref
        .read(contactEditActionsProvider)
        .deleteContact(widget.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved && ModalRoute.of(context)?.isCurrent == true) {
      widget.onDeleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final deleted = ref.watch(contactDeletedProvider(widget.id));
    final error = ref.watch(contactNotesSaveErrorProvider);
    return _InfoCard(
      children: [
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            key: const Key('delete-contact'),
            onPressed: _busy || (deleted && error == null) ? null : _delete,
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              foregroundColor: const Color(0xFFB54040),
            ),
            icon: const Icon(Icons.person_remove_outlined, size: 21),
            label: Text(
              _busy
                  ? '正在删除…'
                  : deleted
                  ? (error == null ? '联系人已删除' : '重试保存删除')
                  : '删除联系人',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}
