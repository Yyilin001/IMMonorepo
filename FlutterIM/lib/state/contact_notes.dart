import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contact_notes.dart';
export '../core/contact_notes.dart';

class ContactNotesPersistence {
  ContactNotesPersistence({
    this.initial = const {},
    this.initialError,
    required this.write,
  });
  static const storageKey = 'ripple.contact-notes.v1';
  final Map<int, ContactNotes> initial;
  final String? initialError;
  final Future<void> Function(String) write;
  static Future<ContactNotesPersistence> load() async {
    final preferences = SharedPreferencesAsync();
    Future<void> write(String value) =>
        preferences.setString(storageKey, value);
    try {
      return ContactNotesPersistence(
        initial: ContactNotes.decodeAll(
          await preferences.getString(storageKey),
        ),
        write: write,
      );
    } catch (_) {
      return ContactNotesPersistence(
        initialError: '无法读取已保存的联系人备注，请重启后重试。',
        write: write,
      );
    }
  }
}

final contactNotesPersistenceProvider = Provider<ContactNotesPersistence>(
  (ref) => ContactNotesPersistence(write: (_) async {}),
);
final contactNotesSaveErrorProvider =
    NotifierProvider<ContactNotesSaveError, String?>(ContactNotesSaveError.new);

class ContactNotesSaveError extends Notifier<String?> {
  @override
  String? build() => ref.watch(contactNotesPersistenceProvider).initialError;
  void set(String? value) => state = value;
}

final contactNotesStoreProvider =
    NotifierProvider<ContactNotesStore, Map<int, ContactNotes>>(
      ContactNotesStore.new,
    );

class ContactNotesStore extends Notifier<Map<int, ContactNotes>> {
  Future<void> _writes = Future.value();
  int _revision = 0;
  @override
  Map<int, ContactNotes> build() =>
      Map.unmodifiable(ref.watch(contactNotesPersistenceProvider).initial);

  Future<void> save(int id, ContactNotes notes) {
    final previous = state[id] ?? const ContactNotes();
    if (previous.encode() == notes.encode()) {
      return ref.read(contactNotesSaveErrorProvider) == null
          ? _writes
          : persist();
    }
    final next = {...state};
    if (notes.isEmpty) {
      next.remove(id);
    } else {
      next[id] = notes;
    }
    state = Map.unmodifiable(next);
    return persist();
  }

  Future<void> persist() {
    final revision = ++_revision;
    final value = encodeContactNotes(state);
    final storage = ref.read(contactNotesPersistenceProvider);
    return _writes = _writes.then((_) async {
      String? error;
      try {
        await storage.write(value);
      } catch (_) {
        error = '资料已更新，但未能保存到本机，请重试。';
      }
      if (ref.mounted && revision == _revision) {
        ref.read(contactNotesSaveErrorProvider.notifier).set(error);
      }
    });
  }
}

final contactNotesProvider = Provider.autoDispose.family<ContactNotes, int>(
  (ref, id) => ref.watch(
    contactNotesStoreProvider.select(
      (notes) => notes[id] ?? const ContactNotes(),
    ),
  ),
);

final contactDeletedProvider = Provider.autoDispose.family<bool, int>(
  (ref, id) =>
      ref.watch(contactNotesProvider(id).select((notes) => notes.deleted)),
);
