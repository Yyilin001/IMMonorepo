import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SearchDirectory { conversations, friends, groups }

extension on SearchDirectory {
  String get key => 'ripple.recent-searches.v1.$name';
}

class RecentSearchStorage {
  const RecentSearchStorage(this.initial, this.write);
  final Map<SearchDirectory, List<String>> initial;
  final Future<void> Function(SearchDirectory, List<String>) write;

  static Future<RecentSearchStorage> load() async {
    final prefs = SharedPreferencesAsync();
    final initial = <SearchDirectory, List<String>>{};
    try {
      final saved = await prefs.getAll(
        allowList: {
          for (final directory in SearchDirectory.values) directory.key,
        },
      );
      for (final directory in SearchDirectory.values) {
        final values = saved[directory.key];
        if (values is List) {
          initial[directory] = values.whereType<String>().toList();
        }
      }
    } catch (_) {
      // A temporarily unavailable preferences service must not block startup.
    }
    return RecentSearchStorage(
      initial,
      (directory, queries) => prefs.setStringList(directory.key, queries),
    );
  }
}

final recentSearchStorageProvider = Provider<RecentSearchStorage>(
  (ref) => RecentSearchStorage(const {}, (_, _) async {}),
);

final recentSearchesProvider =
    NotifierProvider.family<RecentSearches, List<String>, SearchDirectory>(
      RecentSearches.new,
    );

class RecentSearches extends Notifier<List<String>> {
  RecentSearches(this.directory);
  final SearchDirectory directory;
  static const limit = 12;
  Future<void> _writes = Future.value();
  late List<String> _saved;

  @override
  List<String> build() => _saved = List.unmodifiable(
    (ref.watch(recentSearchStorageProvider).initial[directory] ??
            const <String>[])
        .take(limit),
  );

  Future<void> remember(String input) {
    final query = input.trim();
    if (query.isEmpty || state.firstOrNull == query) return _writes;
    return _replace([
      query,
      ...state
          .where((old) => old.toLowerCase() != query.toLowerCase())
          .take(limit - 1),
    ]);
  }

  Future<void> clear() => _replace(const []);

  Future<void> _replace(List<String> queries) {
    final next = List<String>.unmodifiable(queries);
    state = next;
    final storage = ref.read(recentSearchStorageProvider);
    final write = _writes.then((_) async {
      await storage.write(directory, next);
      _saved = next;
    });
    _writes = write.catchError((Object _) {
      if (ref.mounted && identical(state, next)) state = _saved;
    });
    return write;
  }
}
