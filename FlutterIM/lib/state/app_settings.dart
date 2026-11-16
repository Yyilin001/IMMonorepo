import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_preferences.dart';
export '../core/app_preferences.dart';

/// Only application preferences are persisted; no live message takes this path.
class SettingsPersistence {
  SettingsPersistence({
    this.initial = const AppPreferences(),
    this.initialError,
    required this.write,
  });
  static const storageKey = 'ripple.app-preferences.v1';
  final AppPreferences initial;
  final String? initialError;
  final Future<void> Function(AppPreferences) write;

  static Future<SettingsPersistence> load() async {
    final preferences = SharedPreferencesAsync();
    Future<void> write(AppPreferences settings) =>
        preferences.setString(storageKey, settings.encode());
    try {
      return SettingsPersistence(
        initial: AppPreferences.decode(await preferences.getString(storageKey)),
        write: write,
      );
    } catch (_) {
      return SettingsPersistence(
        initialError: '暂时无法读取设置，已使用默认值。',
        write: write,
      );
    }
  }
}

// Tests and embedded previews use an isolated in-memory scope by default.
final settingsPersistenceProvider = Provider<SettingsPersistence>(
  (ref) => SettingsPersistence(write: (_) async {}),
);
final settingsSaveErrorProvider = NotifierProvider<SettingsSaveError, String?>(
  SettingsSaveError.new,
);

class SettingsSaveError extends Notifier<String?> {
  @override
  String? build() => ref.watch(settingsPersistenceProvider).initialError;
  void set(String? error) => state = error;
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppPreferences>(
      AppSettingsNotifier.new,
    );

class AppSettingsNotifier extends Notifier<AppPreferences> {
  Future<void> _writes = Future.value();
  int _revision = 0;
  @override
  AppPreferences build() => ref.watch(settingsPersistenceProvider).initial;

  Future<void> update(AppPreferences next) {
    if (next.encode() == state.encode()) return _writes;
    state = next;
    return _persist(next);
  }

  Future<void> _persist(AppPreferences next) {
    final revision = ++_revision;
    final persistence = ref.read(settingsPersistenceProvider);
    // Serialize each preference write so rapid toggles cannot restore an older
    // value. UI state is immediate; this is not message batching or debouncing.
    return _writes = _writes.then((_) async {
      String? error;
      try {
        await persistence.write(next);
      } catch (_) {
        error = '设置已生效，但未能保存到本机，请重试。';
      }
      if (ref.mounted && revision == _revision) {
        ref.read(settingsSaveErrorProvider.notifier).set(error);
      }
    });
  }

  Future<void> retrySave() => _persist(state);
  Future<void> reset() => update(const AppPreferences());
}
