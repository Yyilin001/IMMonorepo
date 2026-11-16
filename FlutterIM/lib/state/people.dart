import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/profiles.dart';
import 'resources.dart';
import 'contact_notes.dart';

final _baseContactDirectoryProvider = Provider<ContactDirectory>(
  (ref) => ContactDirectory(ref.watch(engineProvider)),
);
final contactDirectoryProvider = Provider<ContactDirectory>(
  (ref) => ref
      .watch(_baseContactDirectoryProvider)
      .withNotes(ref.watch(contactNotesStoreProvider)),
);

final contactDisplayNameProvider = Provider.autoDispose.family<String, int>((
  ref,
  id,
) {
  final remark = ref.watch(
    contactNotesProvider(id).select((notes) => notes.remark),
  );
  return remark.isEmpty
      ? ref.watch(engineProvider).conversation(id).name
      : remark;
});

final contactProfileProvider = Provider.autoDispose.family<ContactProfile, int>(
  (ref, id) {
    final engine = ref.watch(engineProvider);
    final item = engine.conversation(id);
    final remark = ref.watch(
      contactNotesProvider(id).select((notes) => notes.remark),
    );
    return ContactDirectory.describe(
      ContactSummary(
        id: id,
        name: item.name,
        isGroup: item.isGroup,
        remark: remark,
      ),
      engine.initialConversationCount,
    );
  },
);

class ContactFilter {
  const ContactFilter({this.query = '', this.groups = false});
  final String query;
  final bool groups;
}

final contactFilterProvider =
    NotifierProvider<ContactFilterNotifier, ContactFilter>(
      ContactFilterNotifier.new,
    );

class ContactFilterNotifier extends Notifier<ContactFilter> {
  @override
  ContactFilter build() => const ContactFilter();

  void filter({String? query, bool? groups}) {
    final next = ContactFilter(
      query: (query ?? state.query).trim().toLowerCase(),
      groups: groups ?? state.groups,
    );
    if (next.query != state.query || next.groups != state.groups) state = next;
  }
}

final contactResultsProvider = Provider<List<ContactSummary>>((ref) {
  final directory = ref.watch(contactDirectoryProvider);
  final filter = ref.watch(contactFilterProvider);
  final source = filter.groups ? directory.groups : directory.friends;
  if (filter.query.isEmpty) return source;
  final notes = ref.watch(contactNotesStoreProvider);
  return List.unmodifiable(
    source.where(
      (c) =>
          c.name.toLowerCase().contains(filter.query) ||
          c.originalName.toLowerCase().contains(filter.query) ||
          (notes[c.id]?.tags.any(
                (tag) => tag.toLowerCase().contains(filter.query),
              ) ??
              false) ||
          c.handle.contains(filter.query) ||
          c.sortKey.contains(filter.query.toUpperCase()),
    ),
  );
});

final myProfileProvider = NotifierProvider<MyProfileNotifier, MyProfile>(
  MyProfileNotifier.new,
);

class MyProfileNotifier extends Notifier<MyProfile> {
  @override
  MyProfile build() => const MyProfile();

  void save({
    required String name,
    required String region,
    required String bio,
  }) {
    final next = MyProfile(
      name: name.trim(),
      region: region.trim(),
      bio: bio.trim(),
    );
    if (next.name.isEmpty) throw ArgumentError.value(name, 'name', '昵称不能为空');
    if (next.name != state.name ||
        next.region != state.region ||
        next.bio != state.bio) {
      state = next;
    }
  }
}

final contactIndexProvider = Provider<ContactListIndex>(
  (ref) => ContactListIndex(ref.watch(contactResultsProvider)),
);
