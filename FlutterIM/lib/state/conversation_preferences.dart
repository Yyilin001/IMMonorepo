import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'resources.dart';

/// Small profile controls, invalidated only by explicit pin/mute commands.
/// Reading them must not create a timeline or subscribe to incoming messages.
final conversationPreferencesProvider = Provider.autoDispose
    .family<({bool pinned, bool muted}), int>((ref, id) {
      final conversation = ref.watch(engineProvider).conversation(id);
      return (pinned: conversation.pinned, muted: conversation.muted);
    });
