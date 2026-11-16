import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
export '../core/app_preferences.dart' show ChatBackground;

// Keep only explicit choices; reading defaults does not allocate 10k entries.
final _backgroundChoicesProvider = Provider<Map<int, ChatBackground>>(
  (ref) => {},
);
final chatBackgroundProvider = NotifierProvider.autoDispose
    .family<ChatBackgroundNotifier, ChatBackground, int>(
      ChatBackgroundNotifier.new,
    );

class ChatBackgroundNotifier extends Notifier<ChatBackground> {
  ChatBackgroundNotifier(this.id);
  final int id;
  @override
  ChatBackground build() =>
      ref.watch(_backgroundChoicesProvider)[id] ??
      ref.watch(appSettingsProvider.select((settings) => settings.background));
  void select(ChatBackground background) {
    final choices = ref.read(_backgroundChoicesProvider);
    choices[id] = background;
    state = background;
  }
}
