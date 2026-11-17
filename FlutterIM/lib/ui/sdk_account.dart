part of 'workspace.dart';

String _generateRecoveryCode() {
  final random = Random.secure();
  return List.generate(32, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

class _AccountSecurityPage extends StatefulWidget {
  const _AccountSecurityPage();

  @override
  State<_AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<_AccountSecurityPage> {
  final account = TextEditingController();
  final current = TextEditingController();
  final next = TextEditingController();
  final confirmation = TextEditingController();
  final code = TextEditingController();
  var action = 'change';
  var generatedCode = '';
  var savedCode = false;
  var busy = false;
  String? message, error;

  @override
  void dispose() {
    account.dispose();
    current.dispose();
    next.dispose();
    confirmation.dispose();
    code.dispose();
    super.dispose();
  }

  String? validate() {
    if (account.text.trim().isEmpty) return '请输入登录账号';
    if (action != 'recover' && current.text.isEmpty) return '请输入当前密码';
    if (action != 'recovery-code') {
      if (next.text.length < 12) return '新密码至少 12 个字符';
      if (next.text != confirmation.text) return '两次输入的新密码不一致';
    }
    if (action == 'recovery-code') {
      if (generatedCode.isEmpty) return '请先生成恢复码';
      if (!savedCode) return '请确认已安全保存恢复码';
    }
    if (action == 'recover') {
      final value = code.text.trim();
      if (value.length != 64 ||
          !RegExp(r'^[0-9a-z]{64}$').hasMatch(value)) {
        return '恢复码须为 64 位小写字母和数字';
      }
    }
    return null;
  }

  Future<void> submit() async {
    if (busy) return;
    final invalid = validate();
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    final sdk = _SdkScope.of(context)!;
    try {
      await sdk.client!.passwordLifecycle(
        account: account.text.trim(),
        action: action,
        currentPassword: action == 'recover' ? null : current.text,
        newPassword: action == 'recovery-code' ? null : next.text,
        recoveryCode: action == 'recovery-code'
            ? generatedCode
            : action == 'recover'
            ? code.text.trim()
            : null,
      );
      if (!mounted) return;
      if (action == 'recovery-code') {
        setState(() {
          busy = false;
          message = '恢复码已启用。请把副本放在安全位置，旧恢复码已失效。';
          generatedCode = '';
          savedCode = false;
        });
        return;
      }
      setState(() {
        busy = false;
        message = action == 'change'
            ? '密码已更新，全部设备已退出登录，请使用新密码登录。'
            : '密码已重置，全部设备已退出登录，请使用新密码登录。';
      });
      sdk.signOut();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = _accountSecurityError(failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final recoverySetup = action == 'recovery-code';
    final recover = action == 'recover';
    return _ProfileScaffold(
      title: '账号安全',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'change', label: Text('修改密码')),
              ButtonSegment(value: 'recovery-code', label: Text('恢复码')),
              ButtonSegment(value: 'recover', label: Text('找回账号')),
            ],
            selected: {action},
            onSelectionChanged: busy
                ? null
                : (value) => setState(() {
                    action = value.first;
                    error = null;
                    message = null;
                  }),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(
            '请只在仍记得密码时设置离线恢复码。密码和恢复码都丢失后，账号将无法找回。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
          ),
        ),
        _InfoCard(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline, color: green),
              title: TextField(
                key: const Key('security-account'),
                controller: account,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '登录账号'),
              ),
            ),
            if (!recover)
              ListTile(
                leading: const Icon(Icons.lock_outline, color: green),
                title: TextField(
                  key: const Key('security-current-password'),
                  controller: current,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
              ),
          ],
        ),
        if (!recoverySetup) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              ListTile(
                leading: const Icon(Icons.lock_reset, color: green),
                title: TextField(
                  key: const Key('security-new-password'),
                  controller: next,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.lock_reset, color: green),
                title: TextField(
                  key: const Key('security-confirm-password'),
                  controller: confirmation,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                ),
              ),
            ],
          ),
        ],
        if (recover) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              ListTile(
                leading: const Icon(Icons.key_outlined, color: green),
                title: TextField(
                  key: const Key('security-recovery-code'),
                  controller: code,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '已保存的恢复码'),
                ),
              ),
            ],
          ),
        ],
        if (recoverySetup) ...[
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              if (generatedCode.isEmpty)
                ListTile(
                  key: const Key('generate-recovery-code'),
                  leading: const Icon(Icons.vpn_key_outlined, color: green),
                  title: const Text('生成恢复码'),
                  trailing: const Icon(Icons.chevron_right_rounded, color: muted),
                  onTap: busy
                      ? null
                      : () => setState(() => generatedCode = _generateRecoveryCode()),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    generatedCode,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 14,
                      height: 1.5,
                      color: ink,
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const Key('saved-recovery-code'),
                  title: const Text('我已在应用外安全保存恢复码'),
                  value: savedCode,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => savedCode = value),
                ),
              ],
            ],
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFB3261E), height: 1.5),
            ),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              message!,
              style: const TextStyle(color: green, height: 1.5),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
          child: FilledButton(
            key: const Key('submit-account-security'),
            onPressed: busy ? null : submit,
            child: Text(
              recoverySetup
                  ? '启用恢复码'
                  : recover
                  ? '重置密码'
                  : '更新密码',
            ),
          ),
        ),
      ],
    );
  }
}

String _accountSecurityError(Object failure) {
  final code = failure is PlatformException ? failure.code : '';
  return switch (code) {
    'invalidRecoveryCode' => '恢复码须为保存时的 64 位小写字母和数字',
    'invalidPassword' => '密码须为 12–1024 个 UTF-8 字节',
    'rateLimited' => '尝试过于频繁，请稍后重试',
    'authenticationRequired' => '账号、当前密码或恢复码不正确，或已被更换',
    'invalidInput' => '请检查账号和输入的格式',
    _ => '结果尚未确认。若修改的是密码，请先用新密码尝试登录；不要重复提交恢复码。',
  };
}
