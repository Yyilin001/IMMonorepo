import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'resources.dart';
import 'list_providers.dart';
import 'session_cache.dart';

final selectedConversationProvider =
    NotifierProvider<SelectedConversationNotifier, int?>(
      SelectedConversationNotifier.new,
    );

class SelectedConversationNotifier extends Notifier<int?> {
  @override
  int? build() => ref.watch(engineProvider).activeId;
  void select(int? id) {
    final engine = ref.read(engineProvider);
    if (id != null) {
      engine.conversation(id); // Validate before mutating selection.
    }
    engine.select(id);
    if (id != null) ref.read(chatSessionsProvider).open(id);
    state = id;
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
  }
}
