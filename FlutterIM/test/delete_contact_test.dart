import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

ChatMessage incoming(int i, int id) => ChatMessage(
  id: 'delete-test-$i',
  conversationId: id,
  text: 'message $i',
  timestamp: DateTime(2026, 11, 14),
);

void main() {
  test('delete removes directory/search entry, preserves conversation and rejects each subsequent message', () async {
    final c = createContainer();
    addTearDown(c.dispose);
    final actions = c.read(contactEditActionsProvider);
    await actions.save(
      1,
      remark: '设计伙伴',
      tags: ['同事'],
      phone: '123',
      description: '备注保留',
    );
    final engine = c.read(engineProvider);
    final count = c.read(contactDirectoryProvider).friends.length;
    final conversation = engine.conversation(1);
    final unread = engine.totalUnread;
    expect(await actions.deleteContact(1), isTrue);
    expect(c.read(contactDeletedProvider(1)), isTrue);
    expect(c.read(contactDirectoryProvider).friends.length, count - 1);
    expect(engine.conversation(1), same(conversation));
    expect(engine.totalUnread, unread);
    for (final query in ['林知夏', '设计伙伴', '同事', 'ripple_00001']) {
      c.read(contactFilterProvider.notifier).filter(query: query);
      expect(c.read(contactResultsProvider).where((c) => c.id == 1), isEmpty);
    }
    for (var i = 0; i < 1000; i++) {
      c.read(messageActionsProvider).receive(incoming(i, 1));
    }
    expect(engine.received, 0);
    expect(engine.messages(1), isEmpty);
    expect(c.read(chatSessionProvider(1).exists), isFalse);
    c.read(messageActionsProvider).receive(incoming(1001, 3));
    expect(engine.received, 1);
    expect(await actions.restoreContact(1), isTrue);
    expect(c.read(contactNotesProvider(1)).remark, '设计伙伴');
    expect(c.read(contactDirectoryProvider).friends.length, count);
    c.read(messageActionsProvider).receive(incoming(1002, 1));
    expect(engine.messages(1).single.historySequence, 9);
    expect(engine.received, 2);
    await expectLater(actions.deleteContact(0), throwsArgumentError);
    expect(c.read(contactDeletedProvider(0)), isFalse);
  });

  test('deletion persists without notes, restores on startup, and retries failed writes', () async {
    var disk = '';
    var fail = true;
    final c = ProviderContainer(
      overrides: [
        contactNotesPersistenceProvider.overrideWithValue(
          ContactNotesPersistence(
            write: (value) async {
              if (fail) throw StateError('disk unavailable');
              disk = value;
            },
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final actions = c.read(contactEditActionsProvider);
    expect(await actions.deleteContact(1), isFalse);
    expect(c.read(contactDeletedProvider(1)), isTrue);
    expect(c.read(contactNotesSaveErrorProvider), isNotNull);
    fail = false;
    expect(await actions.deleteContact(1), isTrue);
    final restored = ProviderContainer(
      overrides: [
        contactNotesPersistenceProvider.overrideWithValue(
          ContactNotesPersistence(
            initial: ContactNotes.decodeAll(disk),
            write: (_) async {},
          ),
        ),
      ],
    );
    addTearDown(restored.dispose);
    expect(restored.read(contactDeletedProvider(1)), isTrue);
    expect(
      restored
          .read(contactDirectoryProvider)
          .friends
          .any((contact) => contact.id == 1),
      isFalse,
    );
    expect(
      await restored.read(contactEditActionsProvider).restoreContact(1),
      isTrue,
    );
    expect(restored.read(contactNotesStoreProvider), isEmpty);
    expect(c.read(contactDeletedProvider(1)), isTrue);
  });

  testWidgets(
    'delete cancels only its pending reply, blocks sends, and keeps drafts and loaded history',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      c.read(selectedConversationProvider.notifier).select(1);
      await tester.pump(const Duration(milliseconds: 110));
      final messages = c.read(messageActionsProvider);
      messages.send('one');
      final original = c.read(timelineStoreProvider(1)).value;
      c.read(draftProvider(1).notifier).save('保留草稿');
      c.read(selectedConversationProvider.notifier).select(3);
      messages.send('three');
      await c.read(contactEditActionsProvider).deleteContact(1);
      c.read(selectedConversationProvider.notifier).select(1);
      messages.send('blocked');
      messages.sendImage(1, mockImages.first);
      expect(c.read(engineProvider).sent, 2);
      expect(c.read(draftProvider(1)), '保留草稿');
      expect(c.read(timelineStoreProvider(1)).value, same(original));
      await c.read(contactEditActionsProvider).restoreContact(1);
      await tester.pump(const Duration(milliseconds: 700));
      expect(c.read(engineProvider).received, 1);
      expect(
        c.read(engineProvider).messages(3).any((m) => m.id == 'reply-1'),
        isTrue,
      );
      expect(
        c.read(engineProvider).messages(1).any((m) => m.id == 'reply-0'),
        isFalse,
      );
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? "desktop" : "phone"} confirm/cancel deletion returns to contacts, then history permits re-adding',
      (tester) async {
        tester.view.physicalSize = desktop
            ? const Size(1380, 900)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        final c = createContainer();
        addTearDown(() {
          c.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(container: c, child: const LocalImApp()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-contacts')));
        await tester.pumpAndSettle();
        if (!desktop) {
          await tester.tap(find.byKey(const Key('open-contact-search')));
          await tester.pumpAndSettle();
        }
        await tester.enterText(find.byKey(const Key('contact-search')), '林知夏');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('contact-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('contact-profile-settings')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('delete-contact')));
        await tester.tap(find.byKey(const Key('delete-contact')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('cancel-delete-contact')));
        await tester.pumpAndSettle();
        expect(c.read(contactDeletedProvider(1)), isFalse);
        await tester.tap(find.byKey(const Key('delete-contact')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-contact')));
        await tester.pumpAndSettle();
        expect(find.byType(ContactOptionsPage), findsNothing);
        expect(find.byType(ContactProfilePage), findsNothing);
        expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
        if (!desktop) {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('nav-messages')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('林知夏').first);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('deleted-contact-composer')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('composer')), findsNothing);
        await tester.tap(find.byKey(const Key('chat-profile')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('profile-restore-contact')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('profile-restore-contact')));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('composer')), findsOneWidget);
        expect(c.read(contactResultsProvider).any((c) => c.id == 1), isTrue);
        // Deleting from the chat's profile must return to that same chat, not pop it.
        await tester.tap(find.byKey(const Key('chat-profile')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('contact-profile-settings')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('delete-contact')));
        await tester.tap(find.byKey(const Key('delete-contact')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-contact')));
        await tester.pumpAndSettle();
        expect(c.read(selectedConversationProvider), 1);
        expect(
          find.byKey(const Key('deleted-contact-composer')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed deletion stays on the settings page with retry; narrow confirmation is usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      var fail = true;
      final c = ProviderContainer(
        overrides: [
          contactNotesPersistenceProvider.overrideWithValue(
            ContactNotesPersistence(
              write: (_) async {
                if (fail) throw StateError('disk unavailable');
              },
            ),
          ),
        ],
      );
      addTearDown(() {
        c.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const ContactOptionsPage(id: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('delete-contact')),
        150,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('delete-contact')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-contact')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-contact')));
      await tester.pumpAndSettle();
      expect(find.byType(ContactOptionsPage), findsOneWidget);
      expect(c.read(contactNotesSaveErrorProvider), isNotNull);
      fail = false;
      await tester.ensureVisible(find.byKey(const Key('delete-contact')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-contact')));
      await tester.pumpAndSettle();
      expect(c.read(contactNotesSaveErrorProvider), isNull);
      expect(c.read(contactDeletedProvider(1)), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during deletion does not pop another page when saving completes',
    (tester) async {
      final gate = Completer<void>();
      var callbacks = 0;
      final c = ProviderContainer(
        overrides: [
          contactNotesPersistenceProvider.overrideWithValue(
            ContactNotesPersistence(write: (_) => gate.future),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ContactOptionsPage(
                        id: 1,
                        onDeleted: () => callbacks++,
                      ),
                    ),
                  ),
                  child: const Text('返回目标'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('返回目标'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('delete-contact')));
      await tester.tap(find.byKey(const Key('delete-contact')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-contact')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 50));
      gate.complete();
      await tester.pumpAndSettle();
      expect(callbacks, 0);
      expect(find.text('返回目标'), findsOneWidget);
      expect(c.read(contactDeletedProvider(1)), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group settings do not expose friend deletion', (tester) async {
    final c = createContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ContactOptionsPage(id: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-contact')), findsNothing);
  });
}
