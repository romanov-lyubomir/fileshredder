import 'dart:io';

import 'package:fileshredder/src/context_menu.dart';
import 'package:fileshredder/src/safety.dart';
import 'package:fileshredder/src/shredder.dart';
import 'package:fileshredder/src/win32.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('shredder_test_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ShredReport shred(List<String> paths, {bool Function()? shouldStop}) =>
      executePlan(scanSelection(paths), passes: 2, shouldStop: shouldStop);

  void mklink(String flag, String link, String target) {
    final result = Process.runSync('cmd', ['/c', 'mklink', flag, link, target]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  test('overwrites contents in place with non-repeating data', () {
    final original = List.filled(3 * 1024 * 1024 + 17, 0x41);
    final file = File('${temp.path}\\data.bin')..writeAsBytesSync(original);

    overwriteFileForTest(file.path, 2);

    final after = file.readAsBytesSync();
    expect(after.length, original.length);
    final unchanged = [
      for (var i = 0; i < after.length; i++)
        if (after[i] == 0x41) i,
    ].length;
    // Random data matches a fixed byte about once in 256 positions.
    expect(unchanged, lessThan(original.length ~/ 100));
    expect(after.sublist(0, 1024), isNot(after.sublist(1024, 2048)));
  });

  test('removes a file, including an empty one', () {
    final full = File('${temp.path}\\a.txt')..writeAsStringSync('secret');
    final empty = File('${temp.path}\\b.txt')..createSync();

    final report = shred([full.path, empty.path]);

    expect(report.issues, isEmpty);
    expect(report.filesShredded, 2);
    expect(temp.listSync(), isEmpty);
  });

  test('removes nested folders with read-only and Cyrillic names', () {
    final root = Directory('${temp.path}\\Секретно')..createSync();
    final sub = Directory('${root.path}\\вътре\\deep')
      ..createSync(recursive: true);
    final readOnly = File('${sub.path}\\заключен.txt')
      ..writeAsStringSync('secret');
    Process.runSync('attrib', ['+R', readOnly.path]);

    final report = shred([root.path]);

    expect(report.issues, isEmpty);
    expect(report.filesShredded, 1);
    expect(report.foldersRemoved, 3);
    expect(root.existsSync(), isFalse);
  });

  test('handles paths longer than MAX_PATH', () {
    var path = temp.path;
    final segment = 'x' * 60;
    for (var i = 0; i < 6; i++) {
      path = '$path\\$segment';
    }
    final extended = toExtended(normalizeInput(path));
    Directory(extended).createSync(recursive: true);
    File('$extended\\deep.txt').writeAsStringSync('secret');
    expect(path.length, greaterThan(260));

    final report = shred(['${temp.path}\\$segment']);

    expect(report.issues, isEmpty);
    expect(temp.listSync(), isEmpty);
  });

  test('destroys alternate data streams with the file', () {
    final file = File('${temp.path}\\ads.txt')..writeAsStringSync('main');
    final streamPath = '${file.path}:hidden';
    File(streamPath).writeAsStringSync('hidden secret');

    final plan = scanSelection([file.path]);
    final report = executePlan(plan, passes: 1);

    expect(report.issues, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('removes a junction but leaves the target untouched', () {
    final outside = Directory('${temp.path}\\outside')..createSync();
    final precious = File('${outside.path}\\precious.txt')
      ..writeAsStringSync('keep me');
    final folder = Directory('${temp.path}\\folder')..createSync();
    mklink('/J', '${folder.path}\\link', outside.path);

    final report = shred([folder.path]);

    expect(report.issues, isEmpty);
    expect(report.linksRemoved, 1);
    expect(folder.existsSync(), isFalse);
    expect(precious.readAsStringSync(), 'keep me');
  });

  test('refuses files with hard links and leaves the data intact', () {
    final file = File('${temp.path}\\a.txt')..writeAsStringSync('shared');
    final other = '${temp.path}\\b.txt';
    mklink('/H', other, file.path);

    final report = shred([file.path]);

    expect(report.filesShredded, 0);
    expect(report.issues.single.message, contains('hard links'));
    expect(file.readAsStringSync(), 'shared');
    expect(File(other).readAsStringSync(), 'shared');
  });

  test('skips a locked file unchanged and keeps its folder and name', () {
    final folder = Directory('${temp.path}\\folder')..createSync();
    final locked = File('${folder.path}\\locked.txt')
      ..writeAsStringSync('in use');
    final free = File('${folder.path}\\free.txt')..writeAsStringSync('x');
    final handle = locked.openSync(mode: FileMode.append);

    try {
      final report = shred([folder.path]);
      expect(report.filesShredded, 1);
      expect(report.issues.length, 2);
      expect(report.issues.first.message, contains('in use'));
      expect(free.existsSync(), isFalse);
    } finally {
      handle.closeSync();
    }
    expect(locked.readAsStringSync(), 'in use');
    expect(folder.existsSync(), isTrue);
  });

  test('stops when asked and keeps later items', () {
    final first = File('${temp.path}\\1.bin')..writeAsBytesSync(List.filled(10, 1));
    final second = File('${temp.path}\\2.bin')..writeAsStringSync('later');

    final report = shred([first.path, second.path], shouldStop: () => true);

    expect(report.stopped, isTrue);
    expect(report.filesShredded, 0);
    expect(second.readAsStringSync(), 'later');
  });

  test('reports a missing item instead of failing', () {
    final plan = scanSelection(['${temp.path}\\missing.txt']);
    expect(plan.entries, isEmpty);
    expect(plan.roots, isEmpty);
    expect(plan.issues.single.path, '${temp.path}\\missing.txt');
  });

  test('ignores duplicates and items already inside a selected folder', () {
    final folder = Directory('${temp.path}\\folder')..createSync();
    final file = File('${folder.path}\\a.txt')..writeAsStringSync('x');

    final plan = scanSelection([file.path, folder.path, folder.path]);

    expect(plan.roots, [folder.path]);
    expect(plan.fileCount, 1);
  });

  group('protected locations', () {
    final protected = ProtectedPaths(
      keep: [
        r'C:\Windows',
        r'C:\Program Files',
        r'C:\Users\me',
        r'C:\Users\me\Desktop',
      ],
      noTouchInside: [r'C:\Windows', r'C:\Tools\Shredder'],
    );

    for (final path in [
      r'C:\',
      r'D:\',
      r'\\server\share',
      r'relative\file.txt',
      r'\rooted\file.txt',
      r'\\.\PhysicalDrive0',
      r'C:\Windows',
      r'c:\windows\System32\kernel32.dll',
      r'C:\Program Files',
      r'C:\Users',
      r'C:\Users\me',
      r'C:\Users\me\Desktop',
      r'C:\Tools\Shredder\fileshredder.exe',
      r'C:\Tools',
    ]) {
      test('refuses $path', () {
        expect(protected.refusalReason(normalizeInput(path)), isNotNull);
      });
    }

    for (final path in [
      r'C:\Users\me\Desktop\old.txt',
      r'C:\Users\me\Desktopper',
      r'C:\Program Files\App\data.txt',
      r'D:\archive\folder',
      r'\\server\share\folder',
    ]) {
      test('allows $path', () {
        expect(protected.refusalReason(normalizeInput(path)), isNull);
      });
    }

    test('normalization cannot walk back into a protected folder', () {
      final path = normalizeInput(r'C:\Temp\..\Windows\System32');
      expect(protected.refusalReason(path), isNotNull);
    });
  });

  group('context menu registration', () {
    const testKey = r'Software\FileShredderTest';
    const exe = r'C:\Програми\Shredder\fileshredder.exe';

    tearDown(() => regDeleteTree(testKey));

    test('enable writes both verbs and disable removes them', () {
      const menu = ContextMenu(exe, classesKey: testKey);
      expect(menu.isEnabled, isFalse);

      expect(menu.enable(), isTrue);
      expect(menu.isEnabled, isTrue);

      for (final type in ['*', 'Directory']) {
        final key = '$testKey\\$type\\shell\\FileShredder.Shred';
        expect(regGetString(key, 'MUIVerb'), 'Shred');
        expect(regGetString(key, 'Icon'), '"$exe",0');
        expect(regGetString('$key\\command', null), '"$exe" "%1"');
      }

      menu.disable();
      expect(menu.isEnabled, isFalse);
    });

    test('a copy at another path counts as not enabled', () {
      const ContextMenu(exe, classesKey: testKey).enable();
      const moved = ContextMenu(r'D:\other.exe', classesKey: testKey);
      expect(moved.isEnabled, isFalse);
    });
  });
}
