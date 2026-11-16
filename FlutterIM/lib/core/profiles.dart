import 'package:lpinyin/lpinyin.dart';

import '../mock/group_members.dart';
import 'chat_engine.dart';
import 'contact_notes.dart';

class ContactSummary {
  ContactSummary({
    required this.id,
    required String name,
    required this.isGroup,
    this.accountId,
    String remark = '',
  }) : originalName = name,
       name = remark.isEmpty ? name : remark,
       sortKey = PinyinHelper.getPinyinE(
         (remark.isEmpty ? name : remark).trim(),
         separator: '',
         format: PinyinFormat.WITHOUT_TONE,
         defPinyin: '#',
       ).toUpperCase();
  final int id;
  final String? accountId;
  final String name, originalName;
  final bool isGroup;
  final String sortKey;
  String get initial =>
      sortKey.isNotEmpty &&
          sortKey.codeUnitAt(0) >= 65 &&
          sortKey.codeUnitAt(0) <= 90
      ? sortKey[0]
      : '#';
  static int compare(ContactSummary a, ContactSummary b) {
    if ((a.initial == '#') != (b.initial == '#')) {
      return a.initial == '#' ? 1 : -1;
    }
    final order = a.sortKey.compareTo(b.sortKey);
    return order != 0 ? order : a.id.compareTo(b.id);
  }

  String get handle =>
      accountId ??
      '${isGroup ? 'group' : 'ripple'}_${id.toString().padLeft(5, '0')}';
}

class ContactProfile {
  const ContactProfile({
    required this.contact,
    required this.region,
    required this.bio,
    this.memberCount,
    required this.source,
    required this.addedAt,
  });
  final ContactSummary contact;
  final String region, bio, source;
  final DateTime addedAt;
  final int? memberCount;
}

/// Stable directory metadata, independent of message order, previews and unread.
/// Detailed profiles are generated only when requested.
class ContactDirectory {
  factory ContactDirectory(ChatEngine engine) => ContactDirectory._(
    engine.initialConversationCount,
    List.generate(engine.directoryContactCount, (id) {
      final c = engine.conversation(id);
      return ContactSummary(id: id, name: c.name, isGroup: c.isGroup);
    }),
  );
  ContactDirectory.fromEntries(List<ContactSummary> entries)
    : this._(0, entries);
  final int _rosterSize;
  ContactDirectory._(
    this._rosterSize,
    List<ContactSummary> entries, {
    Set<int> deleted = const {},
  }) {
    _entries = List.unmodifiable(entries);
    friends = List.unmodifiable(
      _entries.where((c) => !c.isGroup && !deleted.contains(c.id)).toList()
        ..sort(ContactSummary.compare),
    );
    groups = List.unmodifiable(
      _entries.where((c) => c.isGroup && !deleted.contains(c.id)).toList()
        ..sort(ContactSummary.compare),
    );
  }
  late final List<ContactSummary> _entries;
  late final List<ContactSummary> friends, groups;

  ContactDirectory withNotes(Map<int, ContactNotes> notes) {
    final remarks = notes.entries.where(
      (e) => e.key >= 0 && e.key < _entries.length && e.value.remark.isNotEmpty,
    );
    final deleted = {
      for (final entry in notes.entries)
        if (entry.value.deleted) entry.key,
    };
    if (remarks.isEmpty && deleted.isEmpty) return this;
    final entries = [..._entries];
    for (final entry in remarks) {
      final original = _entries[entry.key];
      entries[entry.key] = ContactSummary(
        id: original.id,
        name: original.originalName,
        isGroup: original.isGroup,
        remark: entry.value.remark,
      );
    }
    return ContactDirectory._(_rosterSize, entries, deleted: deleted);
  }

  ContactProfile profile(int id) {
    RangeError.checkValidIndex(id, _entries, 'id');
    return describe(_entries[id], _rosterSize);
  }

  static ContactProfile describe(ContactSummary c, int rosterSize) {
    final id = c.id;
    const regions = ['杭州', '上海', '成都', '深圳', '北京', '苏州'];
    const bios = ['保持好奇，慢慢成长。', '认真生活，也享受日常。', '有空一起喝杯咖啡。', '分享想法，保持联系。'];
    return ContactProfile(
      contact: c,
      region: regions[id % regions.length],
      bio: c.isGroup ? '欢迎来到${c.name}，在这里分享日常、交流想法。' : bios[id % bios.length],
      memberCount: c.isGroup ? mockGroupMemberCount(id, rosterSize) : null,
      source: c.isGroup
          ? '通过邀请加入群聊'
          : const ['通过账号搜索添加', '通过联系人推荐添加', '通过群聊添加'][id % 3],
      addedAt: DateTime(2026, 10, 1 + id % 28),
    );
  }
}

class MyProfile {
  static const avatarId = 9;
  const MyProfile({this.name = '涟漪用户', this.region = '', this.bio = '很高兴认识你。'});
  final String name, region, bio;
  String get handle => 'ripple_me';
}

/// Group rows and exact scroll offsets are prepared once per filter change.
class ContactListEntry {
  const ContactListEntry.header(this.letter) : contact = null;
  const ContactListEntry.person(this.contact) : letter = null;
  final String? letter;
  final ContactSummary? contact;
  double get extent => contact == null ? 32 : 76;
}

class ContactListIndex {
  ContactListIndex(List<ContactSummary> contacts) {
    final entries = <ContactListEntry>[];
    final offsets = <String, double>{};
    var offset = 0.0;
    String? previous;
    for (final contact in contacts) {
      if (contact.initial != previous) {
        previous = contact.initial;
        offsets[previous] = offset;
        entries.add(ContactListEntry.header(previous));
        offset += entries.last.extent;
      }
      entries.add(ContactListEntry.person(contact));
      offset += entries.last.extent;
    }
    totalExtent = offset;
    rows = List.unmodifiable(entries);
    letterOffsets = Map.unmodifiable(offsets);
  }
  late final double totalExtent;
  late final List<ContactListEntry> rows;
  late final Map<String, double> letterOffsets;
}
