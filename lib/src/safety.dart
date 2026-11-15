// Guards that stop a misclick from destroying the system or a user profile.
import 'dart:io';

import 'package:path/path.dart' as p;

final _driveAbsolute = RegExp(r'^[A-Za-z]:\\');
final _uncAbsolute = RegExp(r'^\\\\[^\\.?][^\\]*\\[^\\]+');

/// Converts any incoming path to a plain, normalized absolute form, removing
/// the `\\?\` prefix if there is one.
String normalizeInput(String input) {
  var path = input.replaceAll('/', r'\');
  if (path.toUpperCase().startsWith(r'\\?\UNC\')) {
    path = r'\\' + path.substring(8);
  } else if (path.startsWith(r'\\?\')) {
    path = path.substring(4);
  }
  return p.windows.normalize(path);
}

/// Prefixes a normalized path so Win32 accepts long paths and treats trailing
/// dots and spaces literally.
String toExtended(String normalized) => normalized.startsWith(r'\\')
    ? r'\\?\UNC\' + normalized.substring(2)
    : r'\\?\' + normalized;

/// Reverses [toExtended] for display.
String toDisplay(String path) => normalizeInput(path);

bool isSameOrInside(String path, String parent) {
  final child = path.toLowerCase();
  final base = parent.toLowerCase();
  return child == base || child.startsWith('$base\\');
}

class ProtectedPaths {
  ProtectedPaths({required this.keep, required this.noTouchInside});

  /// Folders that may not be selected, directly or through a parent.
  final List<String> keep;

  /// Folders whose contents may not be touched at all.
  final List<String> noTouchInside;

  factory ProtectedPaths.forCurrentSystem() {
    final env = Platform.environment;
    final appDir = p.windows.dirname(Platform.resolvedExecutable);

    final profile = env['USERPROFILE'];
    final keep = <String?>[
      env['SystemRoot'],
      env['ProgramFiles'],
      env['ProgramFiles(x86)'],
      env['ProgramW6432'],
      env['ProgramData'],
      env['PUBLIC'],
      env['OneDrive'],
      profile,
      if (profile != null)
        for (final name in const [
          'AppData',
          'Desktop',
          'Documents',
          'Downloads',
          'Music',
          'Pictures',
          'Videos',
        ])
          p.windows.join(profile, name),
    ];

    return ProtectedPaths(
      keep: [
        for (final path in keep)
          if (path != null && path.isNotEmpty) normalizeInput(path),
      ],
      noTouchInside: [
        if (env['SystemRoot'] case final String root) normalizeInput(root),
        normalizeInput(appDir),
      ],
    );
  }

  /// Returns why [normalized] must not be shredded, or null if it is allowed.
  String? refusalReason(String normalized) {
    if (!_driveAbsolute.hasMatch(normalized) &&
        !_uncAbsolute.hasMatch(normalized)) {
      return 'Not a full local or network path.';
    }
    if (normalized.length <= p.windows.rootPrefix(normalized).length ||
        '$normalized\\' == p.windows.rootPrefix(normalized)) {
      return 'A whole drive or network share cannot be shredded.';
    }
    for (final dir in noTouchInside) {
      if (isSameOrInside(normalized, dir)) {
        return 'Protected location: $dir';
      }
    }
    for (final dir in [...keep, ...noTouchInside]) {
      if (isSameOrInside(dir, normalized)) {
        return 'This is, or contains, a protected folder: $dir';
      }
    }
    return null;
  }
}
