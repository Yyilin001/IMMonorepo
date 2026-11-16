part of 'workspace.dart';

String _rateLabel(num rate) => rate < 1
    ? '3 秒/条'
    : rate < 1000
    ? '$rate / s'
    : '${rate ~/ 1000}k / s';

class _MobileMetricsPanel extends StatelessWidget {
  const _MobileMetricsPanel();
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '运行监控',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
            IconButton(
              key: const Key('close-metrics'),
              tooltip: '关闭运行监控',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          key: const Key('mobile-metrics-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          children: const [
            _MobileRateSettings(),
            SizedBox(height: 16),
            _MobilePatternSettings(),
            SizedBox(height: 16),
            _MetricsCard(title: '新会话压测', child: _NewChatBurstControl()),
            SizedBox(height: 16),
            _MobileHistorySettings(),
            SizedBox(height: 16),
            _MobileMetricsStats(),
          ],
        ),
      ),
      const _MobileSimulationControl(),
    ],
  );
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );
}

class _MobileRateSettings extends ConsumerWidget {
  const _MobileRateSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rate = ref.watch(mockRuntimeProvider.select((s) => s.rate));
    return _MetricsCard(
      title: '目标吞吐量',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (_, constraints) => Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final choice in messageRates)
                  SizedBox(
                    width: (constraints.maxWidth - 10) / 2,
                    child: Semantics(
                      selected: choice == rate,
                      child: Material(
                        color: choice == rate ? mint : const Color(0xFFF7F9F8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                          side: BorderSide(
                            color: choice == rate ? green : line,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('rate-$choice'),
                          onTap: () => ref
                              .read(mockRuntimeProvider.notifier)
                              .setRate(choice),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 52),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                              child: Text(
                                _rateLabel(choice),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: choice == rate
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: choice == rate ? green : ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            rate < 1 ? '每 3 秒生成 1 条消息，适合观察交互。' : '每秒生成 ${number(rate)} 条模拟消息。',
            style: const TextStyle(fontSize: 14, color: muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _MobilePatternSettings extends ConsumerWidget {
  const _MobilePatternSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(mockRuntimeProvider.select((s) => s.pattern));
    return _MetricsCard(
      title: '消息分布',
      child: Column(
        children: [
          for (final pattern in TrafficPattern.values) ...[
            if (pattern != TrafficPattern.values.first)
              const SizedBox(height: 10),
            Semantics(
              selected: selected == pattern,
              child: Material(
                color: selected == pattern ? mint : const Color(0xFFF7F9F8),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => ref
                      .read(mockRuntimeProvider.notifier)
                      .setPattern(pattern),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          selected == pattern
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: selected == pattern ? green : muted,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                pattern == TrafficPattern.hotspot
                                    ? '热点模式'
                                    : '全量均匀随机',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: ink,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                pattern == TrafficPattern.hotspot
                                    ? '优先模拟当前会话及前 100 个热点会话。'
                                    : '每个会话等概率接收，置顶会话仍排在前面。',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: muted,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MobileHistorySettings extends ConsumerWidget {
  const _MobileHistorySettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(historyScenarioProvider);
    return _MetricsCard(
      title: '历史记录场景',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9F8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<HistoryNetwork>(
                key: const Key('history-network'),
                value: state.network,
                isExpanded: true,
                itemHeight: null,
                style: const TextStyle(fontSize: 16, color: ink),
                items: [
                  for (final entry in const {
                    HistoryNetwork.normal: '正常 · 100ms 响应',
                    HistoryNetwork.slow: '慢速 · 1.5s 响应',
                    HistoryNetwork.offline: '历史服务离线',
                    HistoryNetwork.overlapping: '重复与乱序回包',
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(entry.value),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    ref
                        .read(historyScenarioProvider.notifier)
                        .setNetwork(value);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('fail-next-history'),
            onPressed: state.failNext
                ? null
                : ref.read(historyScenarioProvider.notifier).failNextRequest,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 50),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            icon: const Icon(Icons.error_outline_rounded, size: 20),
            label: Text(
              state.failNext ? '下次请求将失败' : '模拟下次请求失败',
              style: const TextStyle(fontSize: 15),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '仅影响历史记录加载，实时消息照常接收。',
            style: TextStyle(fontSize: 14, color: muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _MobileSimulationControl extends ConsumerWidget {
  const _MobileSimulationControl();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(mockRuntimeProvider.select((s) => s.running));
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              running ? '模拟消息接收中' : '模拟已暂停',
              style: const TextStyle(fontSize: 14, color: muted),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const Key('toggle-load'),
            onPressed: ref.read(mockRuntimeProvider.notifier).toggleRunning,
            style: FilledButton.styleFrom(
              backgroundColor: ink,
              minimumSize: const Size(0, 50),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
            icon: Icon(
              running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 21,
            ),
            label: Text(
              running ? '暂停模拟' : '开始模拟',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileMetricsStats extends ConsumerWidget {
  const _MobileMetricsStats();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(metricsProvider);
    return _MetricsCard(
      title: '实时统计',
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '接收速率',
                  style: TextStyle(fontSize: 15, color: muted),
                ),
              ),
              Text(
                '${number(stats.rate)} / s',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 90,
            width: double.infinity,
            child: CustomPaint(painter: _Sparkline(stats.history)),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '最近 30 秒',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
          const SizedBox(height: 18),
          for (final entry in {
            '累计接收': number(stats.received),
            '手动发送': number(stats.sent),
            '未读消息': number(stats.unread),
            '缓存消息': '${number(stats.cached)} / 40k',
            '已淘汰消息': number(stats.evicted),
            '单条处理峰值': '${stats.messageMs.toStringAsFixed(2)} ms',
            '状态通知峰值': '${stats.notificationMs.toStringAsFixed(2)} ms',
            '帧耗时 P95': '${stats.frameP95.toStringAsFixed(2)} ms',
            '慢帧 / 采样帧': '${stats.slowFrames} / ${stats.frameSamples}',
          }.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      style: const TextStyle(fontSize: 15, color: muted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      entry.value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 15,
                        color: ink,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NewChatBurstControl extends ConsumerWidget {
  const _NewChatBurstControl();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(newChatBurstProvider);
    final rate = ref.watch(mockRuntimeProvider.select((s) => s.rate));
    final elapsed = run.elapsed;
    final targetRate = rate < 1 ? 1000 : rate;
    final text = run.running
        ? '正在逐条创建，目标 ${number(run.rate)} 个/秒。可关闭面板并滚动列表。'
        : elapsed != null
        ? '上次新增 ${number(run.added)} 个，耗时 ${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)} 秒，实际 ${number(run.added * 1000000 / max(1, elapsed.inMicroseconds))} 个/秒。'
        : '每条消息来自一个新会话。可在上方调整目标吞吐量。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text, style: const TextStyle(color: muted)),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () {
            final runtime = ref.read(mockRuntimeProvider.notifier);
            if (run.running) {
              runtime.stopBurst();
            } else {
              runtime.startBurst();
            }
          },
          child: Text(
            run.running ? '停止压测' : '新增 1 万会话 · ${number(targetRate)}/秒',
          ),
        ),
      ],
    );
  }
}
