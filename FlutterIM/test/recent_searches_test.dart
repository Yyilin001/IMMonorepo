import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/state/recent_searches.dart';

void main() {
  test('recent queries restore, deduplicate, stay bounded and clear in write order', () async {
    final gate = Completer<void>();
    final saved = <SearchDirectory, List<String>>{
      SearchDirectory.friends: ['陈一舟'],
    };
    final storage = RecentSearchStorage(saved, (directory, queries) async {
      await gate.future;
      saved[directory] = queries;
    });
    ProviderContainer open() => ProviderContainer(
      overrides: [recentSearchStorageProvider.overrideWithValue(storage)],
    );
    final c = open();
    addTearDown(c.dispose);
    final chats = recentSearchesProvider(SearchDirectory.conversations);
    final recent = c.read(chats.notifier);
    for (var i = 0; i < 15; i++) {
      unawaited(recent.remember('Chat $i'));
    }
    unawaited(recent.remember(' CHAT 5 '));
    expect(c.read(chats), hasLength(12));
    expect(c.read(chats).first, 'CHAT 5');
    expect(c.read(chats), isNot(contains('Chat 5')));
    final cleared = recent.clear();
    expect(c.read(chats), isEmpty);
    gate.complete();
    await cleared;
    final reopened = open();
    addTearDown(reopened.dispose);
    expect(reopened.read(chats), isEmpty);
    expect(reopened.read(recentSearchesProvider(SearchDirectory.friends)), [
      '陈一舟',
    ]);
  });
}
