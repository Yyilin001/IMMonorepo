import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/ui/workspace.dart';

void main() {
  testWidgets('avatars expose a descriptive image label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatAvatar(id: 1, name: '张三'),
              ChatAvatar(id: 2, name: '产品群', group: true),
            ],
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('头像：张三'), findsOneWidget);
    expect(find.bySemanticsLabel('群头像：产品群'), findsOneWidget);
    semantics.dispose();
  });
}
