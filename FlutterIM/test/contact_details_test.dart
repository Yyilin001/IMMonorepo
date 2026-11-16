import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

Future<void> save(
  ProviderContainer c,
  int id,
  String remark, {
  List<String> tags = const [],
  String phone = '',
  String description = '',
}) => c
    .read(contactEditActionsProvider)
    .save(
      id,
      remark: remark,
      tags: tags,
      phone: phone,
      description: description,
    );
ChatMessage incoming(int i, int id) => ChatMessage(
  id: 'contact-$i',
  conversationId: id,
  text: 'hello $i',
  timestamp: DateTime(2026, 11, 14),
);

void main() {
  test('notes normalize, validate and recover other contacts from malformed records', () {
    final notes = ContactNotes.normalized(
      remark: ' 小林 ',
      tags: [' 设计 ', '朋友', '设计', ''],
      phone: ' 123 ',
      description: ' 认识于线下活动 ',
    );
    expect(notes.tags, ['设计', '朋友']);
    expect(notes.remark, '小林');
    expect(
      ContactNotes.decodeAll(encodeContactNotes({1: notes}))[1]!.encode(),
      notes.encode(),
    );
    expect(
      ContactNotes.decodeAll(
        '{"-1":{},"x":{},"1":{"remark":"小林"},"2":{"remark":3}}',
      ).keys,
      [1],
    );
    expect(ContactNotes.decodeAll('broken'), isEmpty);
    expect(
      () => ContactNotes.normalized(
        remark: '长' * 25,
        tags: [],
        phone: '',
        description: '',
      ),
      throwsArgumentError,
    );
    expect(
      () => ContactNotes.normalized(
        remark: '',
        tags: List.generate(7, (i) => '$i'),
        phone: '',
        description: '',
      ),
      throwsArgumentError,
    );
  });

  test('remark synchronizes directory, searches and conversation rows without reordering or unrelated notifications', () async {
    final c = createContainer();
    addTearDown(c.dispose);
    final engine = c.read(engineProvider);
    final order = engine.orderedConversations.map((x) => x.id).toList();
    final unread = engine.totalUnread;
    var unrelated = 0, timeline = 0, ownProfile = 0;
    c.listen(contactProfileProvider(3), (_, _) => unrelated++);
    c.listen(contactProfileProvider(1), (_, _) => ownProfile++);
    c.listen(timelineStructureProvider(0), (_, _) => timeline++);
    await save(c, 1, '阿林', tags: ['设计伙伴'], phone: '123', description: '同项目');
    expect(c.read(contactProfileProvider(1)).contact.originalName, '林知夏');
    expect(c.read(contactDisplayNameProvider(1)), '阿林');
    expect(engine.conversation(1).displayName, '阿林');
    expect(engine.orderedConversations.map((x) => x.id), order);
    expect(engine.totalUnread, unread);
    expect((unrelated, ownProfile, timeline), (0, 1, 0));
    for (final query in ['阿林', 'alin', '林知夏', '设计伙伴', 'ripple_00001']) {
      c.read(contactFilterProvider.notifier).filter(query: query);
      expect(c.read(contactResultsProvider).map((x) => x.id), contains(1));
    }
    c.read(contactFilterProvider.notifier).filter(query: '阿林');
    expect(c.read(contactResultsProvider).single.initial, 'A');
    for (final query in ['阿林', '林知夏']) {
      c.read(conversationListProvider.notifier).filter(query: query);
      expect(c.read(conversationStoreProvider).value.single.id, 1);
    }
    await save(c, 1, '');
    expect(engine.conversation(1).displayName, '林知夏');
    expect(c.read(contactNotesStoreProvider), isEmpty);
    expect(c.read(chatSessionProvider(1).exists), isFalse);
  });

  test('notes persist in order, restore display names at startup and retry failed saves', () async {
    var disk = '';
    var fail = false;
    final gate = Completer<void>();
    var writes = 0;
    final c = ProviderContainer(
      overrides: [
        imConfigProvider.overrideWithValue(const ImConfig(autoStart: false)),
        contactNotesPersistenceProvider.overrideWithValue(
          ContactNotesPersistence(
            write: (value) async {
              if (++writes == 1) await gate.future;
              if (fail) throw StateError('write failed');
              disk = value;
            },
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final a = save(c, 1, '林同学');
    final b = save(c, 1, '林设计师');
    expect(c.read(engineProvider).conversation(1).displayName, '林设计师');
    gate.complete();
    await Future.wait([a, b]);
    expect(writes, 2);
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
    expect(restored.read(engineProvider).conversation(1).displayName, '林设计师');
    expect(
      restored.read(contactProfileProvider(1)).contact.originalName,
      '林知夏',
    );
    expect(restored.read(contactProfileProvider(1)).contact.name, '林设计师');
    fail = true;
    await save(c, 1, '林伙伴');
    expect(c.read(contactNotesSaveErrorProvider), isNotNull);
    fail = false;
    await save(c, 1, '林伙伴');
    expect(c.read(contactNotesSaveErrorProvider), isNull);
    expect(ContactNotes.decodeAll(disk)[1]!.remark, '林伙伴');
  });

  test('profile pin and mute controls stay synchronized without creating chat sessions or reacting to messages', () async {
    final c = createContainer();
    addTearDown(c.dispose);
    final sessions = c.read(chatSessionsProvider).retainedIds.toList();
    var updates = 0;
    c.listen(conversationPreferencesProvider(3333), (_, _) => updates++);
    c.read(conversationActionsProvider).setPinned(3333, true);
    expect(c.read(conversationPreferencesProvider(3333)).pinned, isTrue);
    c.read(conversationActionsProvider).setMuted(3333, true);
    expect(c.read(conversationPreferencesProvider(3333)).muted, isTrue);
    expect(c.read(chatSessionsProvider).retainedIds, sessions);
    final previous = updates;
    for (var i = 0; i < 1000; i++) {
      c.read(messageActionsProvider).receive(incoming(i, 3333));
    }
    expect(updates, previous);
    c.read(selectedConversationProvider.notifier).select(3333);
    c.read(chatSessionProvider(3333).notifier).setMuted(false);
    expect(c.read(conversationPreferencesProvider(3333)).muted, isFalse);
  });

  Future<ProviderContainer> mount(WidgetTester tester, bool desktop) async {
    tester.view.physicalSize = desktop
        ? const Size(1380, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final c = createContainer();
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pumpAndSettle();
    return c;
  }

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? "desktop" : "phone"} edit contact, copy number, open chat and update its existing title',
      (tester) async {
        final c = await mount(tester, desktop);
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
        await tester.tap(find.byKey(const Key('contact-settings-mute')));
        await tester.pump();
        expect(c.read(engineProvider).conversation(1).muted, isTrue);
        expect(c.read(chatSessionProvider(1).exists), isFalse);
        await tester.tap(find.byKey(const Key('contact-settings-edit')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('contact-remark')), '林设计师');
        await tester.enterText(
          find.byKey(const Key('contact-tags')),
          '同事，设计，同事',
        );
        await tester.ensureVisible(find.byKey(const Key('contact-phone')));
        await tester.enterText(find.byKey(const Key('contact-phone')), '123');
        await tester.tap(find.byKey(const Key('save-contact-notes')));
        await tester.pumpAndSettle();
        expect(c.read(contactNotesProvider(1)).tags, ['同事', '设计']);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('林设计师'), findsWidgets);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.ensureVisible(find.byTooltip('复制电话号码'));
        await tester.tap(find.byTooltip('复制电话号码'));
        await tester.pump();
        expect(copied, '123');
        await tester.ensureVisible(
          find.byKey(const Key('profile-send-message')),
        );
        await tester.tap(find.byKey(const Key('profile-send-message')));
        await tester.pumpAndSettle();
        expect(c.read(selectedConversationProvider), 1);
        expect(find.text('林设计师'), findsWidgets);
        final window = c.read(timelineStoreProvider(1)).value;
        await save(c, 1, '阿林');
        await tester.pump();
        expect(find.text('阿林'), findsWidgets);
        expect(
          identical(c.read(timelineStoreProvider(1)).value, window),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'contact profile remains still during incoming traffic and cancelling edits keeps the saved data',
    (tester) async {
      final c = await mount(tester, false);
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-contact-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-search')), '林知夏');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('contact-1')));
      await tester.pumpAndSettle();
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is ContactProfilePage) builds++;
      };
      for (var i = 0; i < 1000; i++) {
        c.read(messageActionsProvider).receive(incoming(i, 1));
      }
      await tester.pump();
      expect(builds, 0);
      debugOnRebuildDirtyWidget = null;
      await tester.tap(find.byKey(const Key('contact-edit-notes')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-remark')), '不保存');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(c.read(contactNotesProvider(1)).remark, isEmpty);
    },
  );

  for (final id in [1, 0]) {
    testWidgets('contact $id details and editor fit 320px and large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      final c = createContainer();
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
            home: ContactProfilePage(id: id, onMessage: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('contact-edit-notes')).hitTestable(),
        160,
      );
      await tester.tap(find.byKey(const Key('contact-edit-notes')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-remark')), '窄屏备注');
      await tester.ensureVisible(find.byKey(const Key('contact-tags')));
      await tester.enterText(
        find.byKey(const Key('contact-tags')),
        '一，二，三，四，五，六，七',
      );
      await tester.tap(find.byKey(const Key('save-contact-notes')));
      await tester.pump();
      expect(find.text('最多添加 6 个标签'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('contact-tags')), '朋友');
      await tester.tap(find.byKey(const Key('save-contact-notes')));
      await tester.pumpAndSettle();
      expect(c.read(contactNotesProvider(id)).remark, '窄屏备注');
      expect(tester.takeException(), isNull);
    });
  }
}
