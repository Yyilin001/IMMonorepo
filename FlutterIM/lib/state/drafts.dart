import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-lifetime storage contains only nonempty drafts, not a provider per contact.
class DraftStore {
  final Map<int, String> _drafts = {};
  String read(int id) => _drafts[id] ?? '';
  void write(int id, String text) {
    if (text.isEmpty) {
      _drafts.remove(id);
    } else {
      _drafts[id] = text;
    }
  }

  int get length => _drafts.length;
}

final draftStoreProvider = Provider<DraftStore>((ref) => DraftStore());
final draftProvider = NotifierProvider.autoDispose
    .family<DraftNotifier, String, int>(DraftNotifier.new);

class DraftNotifier extends Notifier<String> {
  DraftNotifier(this.id);
  final int id;
  @override
  String build() => ref.watch(draftStoreProvider).read(id);
  void save(String text) {
    if (state == text) return;
    ref.read(draftStoreProvider).write(id, text);
    state = text;
  }
}
