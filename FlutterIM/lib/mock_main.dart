import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/workspace.dart';
import 'state/app_settings.dart';
import 'state/recent_searches.dart';
import 'state/contact_notes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (settings, contactNotes, recentSearches) = await (
    SettingsPersistence.load(),
    ContactNotesPersistence.load(),
    RecentSearchStorage.load(),
  ).wait;
  runApp(
    ProviderScope(
      overrides: [
        settingsPersistenceProvider.overrideWithValue(settings),
        recentSearchStorageProvider.overrideWithValue(recentSearches),
        contactNotesPersistenceProvider.overrideWithValue(contactNotes),
      ],
      child: const LocalImApp(),
    ),
  );
}

class LocalImApp extends StatelessWidget {
  const LocalImApp({super.key, this.home = const Workspace()});
  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '涟漪 · Local IM',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      appBarTheme: const AppBarThemeData(
        backgroundColor: Colors.white,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF147D64),
        surface: const Color(0xFFF8FAF9),
      ),
      scaffoldBackgroundColor: const Color(0xFFF3F6F5),
      fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC'],
      dividerColor: const Color(0xFFE7ECE9),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 13, color: Color(0xFF253B34)),
        bodySmall: TextStyle(fontSize: 11, color: Color(0xFF7D8B85)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        isDense: true,
      ),
    ),
    builder: (_, child) => _DismissInputOnTap(child: child!),
    home: home,
  );
}

class _DismissInputOnTap extends StatefulWidget {
  const _DismissInputOnTap({required this.child});
  final Widget child;

  @override
  State<_DismissInputOnTap> createState() => _DismissInputOnTapState();
}

class _DismissInputOnTapState extends State<_DismissInputOnTap> {
  PointerDownEvent? _down;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      EditableTextTapOutsideIntent:
          CallbackAction<EditableTextTapOutsideIntent>(
            onInvoke: (intent) {
              _down = intent.pointerDownEvent;
              return null;
            },
          ),
      EditableTextTapUpOutsideIntent:
          CallbackAction<EditableTextTapUpOutsideIntent>(
            onInvoke: (intent) {
              final down = _down;
              final up = intent.pointerUpEvent;
              _down = null;
              if (down != null &&
                  down.pointer == up.pointer &&
                  (down.position - up.position).distance <= kTouchSlop &&
                  intent.focusNode.hasPrimaryFocus) {
                intent.focusNode.unfocus();
              }
              return null;
            },
          ),
    },
    child: widget.child,
  );
}
