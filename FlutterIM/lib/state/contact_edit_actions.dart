import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'contact_notes.dart';
import 'resources.dart';
import 'list_providers.dart';
import 'message_actions.dart';

final contactEditActionsProvider = Provider<ContactEditActions>(
  ContactEditActions.new,
);

class ContactEditActions {
  ContactEditActions(this.ref);
  final Ref ref;
  Future<void> save(
    int id, {
    required String remark,
    required Iterable<String> tags,
    required String phone,
    required String description,
  }) {
    final engine = ref.read(engineProvider);
    RangeError.checkValueInInterval(id, 0, engine.contactCount - 1, 'id');
    final notes = ContactNotes.normalized(
      remark: remark,
      tags: tags,
      phone: phone,
      description: description,
      deleted: ref.read(contactNotesStoreProvider)[id]?.deleted ?? false,
    );
    // Publish each user edit immediately. Persisting notes never enters the
    // per-message path or creates the contact's chat session.
    engine.setRemark(id, notes.remark);
    ref
        .read(conversationListProvider.notifier)
        .refresh(engine.takeChangedConversationIds());
    return ref.read(contactNotesStoreProvider.notifier).save(id, notes);
  }

  Future<bool> deleteContact(int id) async {
    _validateFriend(id);
    final notes =
        ref.read(contactNotesStoreProvider)[id] ?? const ContactNotes();
    // Cancel only this contact's scheduled local replies. Each subsequent live
    // event is still handled individually and rejected before it can mutate data.
    ref.read(messageActionsProvider).cancelRepliesFor(id);
    await ref
        .read(contactNotesStoreProvider.notifier)
        .save(id, notes.withDeleted(true));
    return ref.mounted && ref.read(contactNotesSaveErrorProvider) == null;
  }

  Future<bool> restoreContact(int id) async {
    _validateFriend(id);
    final notes =
        ref.read(contactNotesStoreProvider)[id] ?? const ContactNotes();
    await ref
        .read(contactNotesStoreProvider.notifier)
        .save(id, notes.withDeleted(false));
    return ref.mounted && ref.read(contactNotesSaveErrorProvider) == null;
  }

  void _validateFriend(int id) {
    final engine = ref.read(engineProvider);
    RangeError.checkValueInInterval(id, 0, engine.contactCount - 1, 'id');
    if (engine.conversation(id).isGroup) {
      throw ArgumentError('群聊不是联系人，不能执行好友删除操作');
    }
  }
}
