import 'dart:io';

import 'package:fileshredder/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the context menu switch when opened without files', (
    tester,
  ) async {
    await tester.pumpWidget(const ShredderApp());
    expect(find.textContaining('context menu'), findsOneWidget);
  });

  testWidgets('shreds only after the Shred button is pressed', (tester) async {
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('shredder_ui_'),
    );
    final file = File('${temp!.path}\\secret.txt')
      ..writeAsStringSync('classified');
    addTearDown(() => temp.deleteSync(recursive: true));

    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
    }

    await tester.pumpWidget(ShredderApp(initialPaths: [file.path]));
    await settle();

    expect(find.text('Permanently shred?'), findsOneWidget);
    expect(file.existsSync(), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'Shred'));
    await settle();
    await settle();

    expect(find.text('Shredded'), findsOneWidget);
    expect(file.existsSync(), isFalse);
  });
}
