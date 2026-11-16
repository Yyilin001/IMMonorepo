import 'dart:convert';

enum ChatBackground { light, mint, warm }

enum ChatTextSize { small, standard, large, extraLarge }

class AppPreferences {
  const AppPreferences({
    this.textSize = ChatTextSize.standard,
    this.background = ChatBackground.light,
    this.messageAnimations = true,
    this.haptics = true,
    this.unreadBadge = true,
    this.messagePreview = true,
  });

  final ChatTextSize textSize;
  final ChatBackground background;
  final bool messageAnimations, haptics, unreadBadge, messagePreview;
  double get fontDelta => switch (textSize) {
    ChatTextSize.small => -2,
    ChatTextSize.standard => 0,
    ChatTextSize.large => 2,
    ChatTextSize.extraLarge => 4,
  };

  AppPreferences copyWith({
    ChatTextSize? textSize,
    ChatBackground? background,
    bool? messageAnimations,
    bool? haptics,
    bool? unreadBadge,
    bool? messagePreview,
  }) => AppPreferences(
    textSize: textSize ?? this.textSize,
    background: background ?? this.background,
    messageAnimations: messageAnimations ?? this.messageAnimations,
    haptics: haptics ?? this.haptics,
    unreadBadge: unreadBadge ?? this.unreadBadge,
    messagePreview: messagePreview ?? this.messagePreview,
  );

  String encode() => jsonEncode({
    'textSize': textSize.name,
    'background': background.name,
    'messageAnimations': messageAnimations,
    'haptics': haptics,
    'unreadBadge': unreadBadge,
    'messagePreview': messagePreview,
  });

  static AppPreferences decode(String? value) {
    if (value == null) return const AppPreferences();
    try {
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic>) return const AppPreferences();
      bool flag(String key) => data[key] is bool ? data[key] as bool : true;
      return AppPreferences(
        textSize: ChatTextSize.values.firstWhere(
          (size) => size.name == data['textSize'],
          orElse: () => ChatTextSize.standard,
        ),
        background: ChatBackground.values.firstWhere(
          (background) => background.name == data['background'],
          orElse: () => ChatBackground.light,
        ),
        messageAnimations: flag('messageAnimations'),
        haptics: flag('haptics'),
        unreadBadge: flag('unreadBadge'),
        messagePreview: flag('messagePreview'),
      );
    } on FormatException {
      return const AppPreferences();
    }
  }
}
