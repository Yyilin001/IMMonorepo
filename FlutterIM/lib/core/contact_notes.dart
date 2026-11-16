import 'dart:convert';

/// Information entered by this user, separate from a contact's mock identity.
class ContactNotes {
  const ContactNotes({
    this.remark = '',
    this.tags = const [],
    this.phone = '',
    this.description = '',
    this.deleted = false,
  });
  final String remark, phone, description;
  final List<String> tags;
  final bool deleted;
  ContactNotes withDeleted(bool value) => ContactNotes(
    remark: remark,
    tags: tags,
    phone: phone,
    description: description,
    deleted: value,
  );
  bool get isEmpty =>
      !deleted &&
      remark.isEmpty &&
      tags.isEmpty &&
      phone.isEmpty &&
      description.isEmpty;

  static ContactNotes normalized({
    required String remark,
    required Iterable<String> tags,
    required String phone,
    required String description,
    bool deleted = false,
  }) {
    final cleanTags = tags
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (remark.trim().runes.length > 24 ||
        phone.trim().runes.length > 32 ||
        description.trim().runes.length > 200 ||
        cleanTags.length > 6 ||
        cleanTags.any((s) => s.runes.length > 12)) {
      throw ArgumentError('备注最多 24 字，电话最多 32 字，说明最多 200 字；最多 6 个标签，每个 12 字。');
    }
    return ContactNotes(
      remark: remark.trim(),
      tags: List.unmodifiable(cleanTags),
      phone: phone.trim(),
      description: description.trim(),
      deleted: deleted,
    );
  }

  Map<String, Object> toJson() => {
    'remark': remark,
    'tags': tags,
    'phone': phone,
    'description': description,
    'deleted': deleted,
  };
  String encode() => jsonEncode(toJson());

  static Map<int, ContactNotes> decodeAll(String? text) {
    if (text == null) return const {};
    try {
      final data = jsonDecode(text);
      if (data is! Map<String, dynamic>) return const {};
      final result = <int, ContactNotes>{};
      for (final entry in data.entries) {
        final id = int.tryParse(entry.key);
        final value = entry.value;
        if (id == null || id < 0 || value is! Map<String, dynamic>) continue;
        try {
          final notes = normalized(
            deleted: value['deleted'] == true,
            remark: value['remark'] is String ? value['remark'] as String : '',
            tags: value['tags'] is List
                ? (value['tags'] as List).whereType<String>()
                : const [],
            phone: value['phone'] is String ? value['phone'] as String : '',
            description: value['description'] is String
                ? value['description'] as String
                : '',
          );
          if (!notes.isEmpty) result[id] = notes;
        } on ArgumentError {
          // A malformed record does not discard the other contacts' notes.
        }
      }
      return Map.unmodifiable(result);
    } on FormatException {
      return const {};
    }
  }
}

String encodeContactNotes(Map<int, ContactNotes> notes) => jsonEncode({
  for (final entry in notes.entries) '${entry.key}': entry.value.toJson(),
});
