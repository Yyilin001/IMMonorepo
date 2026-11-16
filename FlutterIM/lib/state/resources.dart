import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat_engine.dart';
import 'contact_notes.dart';
import '../core/conversation_store.dart';
import '../core/timeline_store.dart';
import '../core/history.dart';
import '../mock/mock_history_repository.dart';

class ImConfig {
  const ImConfig({
    this.conversationCount = 10000,
    this.autoStart = true,
    this.maxRetainedSessions = 20,
  });
  final int conversationCount;
  final bool autoStart;
  final int maxRetainedSessions;
}

final imConfigProvider = Provider<ImConfig>((ref) => const ImConfig());
final engineProvider = Provider<ChatEngine>((ref) {
  final engine = ChatEngine(
    conversationCount: ref.watch(imConfigProvider).conversationCount,
  )..select(0);
  for (final entry
      in ref.watch(contactNotesPersistenceProvider).initial.entries) {
    if (engine.hasContact(entry.key)) {
      engine.setRemark(entry.key, entry.value.remark);
    }
  }
  engine.takeChangedConversationIds();
  return engine;
});
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  final repository = MockHistoryRepository(
    conversationCount: ref.watch(imConfigProvider).conversationCount,
  );
  ref.onDispose(repository.dispose);
  return repository;
});
final conversationStoreProvider = Provider<ConversationStore>((ref) {
  final store = ConversationStore(ref.watch(engineProvider));
  return store;
});
final timelineStoreProvider = Provider.autoDispose.family<TimelineStore, int>((
  ref,
  id,
) {
  final store = TimelineStore()
    ..replace(ref.watch(engineProvider).messages(id));
  return store;
});
