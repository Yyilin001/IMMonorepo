part of 'workspace.dart';

class _TransfersLink extends StatelessWidget {
  const _TransfersLink();
  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.swap_vert),
    title: const Text('文件传输'),
    onTap: () => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const _TransfersPage())),
  );
}

class _TransfersPage extends StatefulWidget {
  const _TransfersPage();
  @override
  State<_TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<_TransfersPage>
    with WidgetsBindingObserver {
  static const phases = {
    'queued': '排队中',
    'resolvingMetadata': '读取文件信息',
    'preparing': '准备中',
    'transferring': '传输中',
    'confirming': '确认中',
    'verifying': '校验中',
    'processing': '处理中',
    'pausing': '正在暂停',
    'paused': '已暂停',
    'cancelling': '正在取消',
    'waitingRetry': '等待重试',
    'requiresAttention': '需要处理',
    'completed': '已完成',
    'cancelled': '已取消',
    'failed': '失败',
  };
  static const labels = {
    'retry': '重试',
    'retryCancellation': '重新确认取消',
    'pause': '暂停',
    'resume': '继续',
    'cancel': '取消传输',
  };
  List<ImTransfer>? rows;
  String? error;
  Timer? timer;
  bool busy = false, initialized = false;
  late ImClient client;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    client = _SdkScope.of(context)!.client!;
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh({ImTransfer? transfer, String? action}) async {
    if (busy) return;
    timer?.cancel();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (transfer != null && action != null) {
        if (action == 'cancel') {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('取消传输？'),
              content: Text(transfer.name),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('返回'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('取消传输'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
        }
        await client.transferAction(transfer.id, action);
      }
      final latest = await client.transfers();
      if (mounted) rows = latest;
    } catch (failure) {
      if (mounted) error = _errorText(failure);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (error == null &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed &&
            rows?.any(
                  (row) => !const {
                    'completed',
                    'cancelled',
                    'failed',
                    'requiresAttention',
                    'paused',
                  }.contains(row.phase),
                ) ==
                true) {
          timer = Timer(const Duration(seconds: 2), refresh);
        }
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ProfileScaffold(
    title: '文件传输',
    actions: [
      IconButton(
        tooltip: '刷新传输记录',
        onPressed: busy ? null : refresh,
        icon: const Icon(Icons.refresh),
      ),
    ],
    children: [
      if (error != null)
        TextButton(
          onPressed: busy ? null : refresh,
          child: Text('$error · 重新加载'),
        )
      else if (rows == null)
        const Center(child: CircularProgressIndicator())
      else if (rows!.isEmpty)
        const Center(child: Text('暂无传输记录')),
      for (final row in rows ?? const <ImTransfer>[])
        ListTile(
          key: ValueKey((row.kind, row.id)),
          title: Text(row.name),
          leading: Icon(switch (row.kind) {
            'upload' => Icons.upload_outlined,
            'download' => Icons.download_outlined,
            _ => Icons.file_copy_outlined,
          }),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(phases[row.phase] ?? row.phase),
              if (row.confirmed case final confirmed?)
                Text(
                  row.total == null
                      ? '已确认 ${number(confirmed)} 字节'
                      : '${number(confirmed)} / ${number(row.total!)} 字节',
                ),
              if (row.confirmed != null && (row.total ?? 0) > 0)
                LinearProgressIndicator(
                  value: (row.confirmed! / row.total!).clamp(0, 1),
                ),
            ],
          ),
          trailing: row.actions.any(labels.containsKey)
              ? PopupMenuButton<String>(
                  tooltip: '传输操作',
                  enabled: !busy,
                  onSelected: (action) =>
                      refresh(transfer: row, action: action),
                  itemBuilder: (_) => [
                    for (final action in row.actions)
                      if (labels[action] case final label?)
                        PopupMenuItem(value: action, child: Text(label)),
                  ],
                )
              : null,
        ),
    ],
  );
}
