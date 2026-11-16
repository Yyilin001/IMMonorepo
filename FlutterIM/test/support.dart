import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_im/core/history.dart';
import 'package:local_im/state/im_providers.dart';

/// Tests exercise the actual provider graph in an isolated container.
ProviderContainer createContainer({
  bool autoStart = false,
  HistoryRepository? historyRepository,
  int conversationCount = 10000,
  int maxRetainedSessions = 20,
}) {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      imConfigProvider.overrideWithValue(
        ImConfig(
          autoStart: autoStart,
          conversationCount: conversationCount,
          maxRetainedSessions: maxRetainedSessions,
        ),
      ),
      if (historyRepository != null)
        historyRepositoryProvider.overrideWith((ref) {
          ref.onDispose(historyRepository.dispose);
          return historyRepository;
        }),
    ],
  );
  container.read(mockRuntimeProvider.notifier).start();
  return container;
}
