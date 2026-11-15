// Scans a selection into a plan, then overwrites and deletes it.
//
// Everything here is synchronous and blocking: run it in a background isolate
// through the helpers in shred_job.dart.
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'safety.dart';
import 'win32.dart';

/// Number of full random overwrites applied to every file.
const defaultPasses = 3;

const _chunkSize = 1024 * 1024;
const _progressIntervalMs = 50;

enum EntryKind { file, directory, fileLink, directoryLink }

class PlanEntry {
  const PlanEntry(this.path, this.kind, this.size);

  /// Extended (`\\?\`) path.
  final String path;
  final EntryKind kind;
  final int size;
}

class ShredIssue {
  const ShredIssue(this.path, this.message);

  /// Path in display form.
  final String path;
  final String message;
}

class ShredPlan {
  ShredPlan(this.roots, this.entries, this.issues);

  /// The selected items that will be processed, in display form.
  final List<String> roots;

  /// Children always precede their parent folder.
  final List<PlanEntry> entries;

  /// Items that will be skipped, with the reason.
  final List<ShredIssue> issues;

  int get fileCount => entries.where((e) => e.kind == EntryKind.file).length;
  int get folderCount =>
      entries.where((e) => e.kind == EntryKind.directory).length;
  int get linkCount => entries.length - fileCount - folderCount;
  int get totalBytes => entries.fold(0, (sum, e) => sum + e.size);
}

class ShredProgress {
  const ShredProgress(this.bytesDone, this.bytesTotal, this.currentPath);

  final int bytesDone;
  final int bytesTotal;
  final String currentPath;
}

class ShredReport {
  ShredReport({
    required this.filesShredded,
    required this.foldersRemoved,
    required this.linksRemoved,
    required this.issues,
    required this.stopped,
  });

  final int filesShredded;
  final int foldersRemoved;
  final int linksRemoved;
  final List<ShredIssue> issues;
  final bool stopped;
}

class _Failure implements Exception {
  const _Failure(this.message);
  final String message;
}

class _Stopped implements Exception {
  const _Stopped();
}

/// Error codes only choose the message. Dart can reset the code between the
/// failing call and GetLastError, so no decision may depend on it.
String _describeError(int code) => switch (code) {
  0 => 'The item does not exist or cannot be accessed.',
  errorFileNotFound || errorPathNotFound => 'The item no longer exists.',
  errorAccessDenied => 'Access denied.',
  errorSharingViolation ||
  errorLockViolation => 'The file is in use by another program.',
  errorDirNotEmpty => 'The folder still contains items that were not shredded.',
  _ => 'Windows error $code.',
};

class _FindInfo {
  _FindInfo(Pointer<Uint8> data)
    : attributes = (data + findDataAttributes).cast<Uint32>().value,
      size =
          ((data + findDataSizeHigh).cast<Uint32>().value << 32) |
          (data + findDataSizeLow).cast<Uint32>().value,
      reparseTag = (data + findDataReparseTag).cast<Uint32>().value,
      name = (data + findDataFileName).cast<Utf16>().toDartString();

  final int attributes;
  final int size;
  final int reparseTag;
  final String name;

  bool get isDirectory => attributes & fileAttributeDirectory != 0;
  bool get isReparsePoint => attributes & fileAttributeReparsePoint != 0;
}

/// Builds the list of everything a selection would touch. Touches nothing on
/// disk and never follows symbolic links or junctions.
ShredPlan scanSelection(List<String> inputs, {ProtectedPaths? protectedPaths}) {
  final protected = protectedPaths ?? ProtectedPaths.forCurrentSystem();
  final roots = <String>[];
  final entries = <PlanEntry>[];
  final issues = <ShredIssue>[];

  final unique = <String>[];
  for (final input in inputs.map(normalizeInput)) {
    if (unique.any((other) => isSameOrInside(input, other))) continue;
    unique
      ..removeWhere((other) => isSameOrInside(other, input))
      ..add(input);
  }

  final data = malloc<Uint8>(findDataSize);
  try {
    for (final path in unique) {
      final refusal = protected.refusalReason(path);
      if (refusal != null) {
        issues.add(ShredIssue(path, refusal));
        continue;
      }
      final extended = toExtended(path);
      final handle = withWide(extended, (w) => findFirstFile(w, data));
      if (handle == invalidHandle) {
        issues.add(ShredIssue(path, _describeError(lastWideCallError)));
        continue;
      }
      final info = _FindInfo(data);
      findClose(handle);
      roots.add(path);
      _walk(extended, info, entries, issues);
    }
  } finally {
    malloc.free(data);
  }
  return ShredPlan(roots, entries, issues);
}

void _walk(
  String path,
  _FindInfo info,
  List<PlanEntry> entries,
  List<ShredIssue> issues,
) {
  if (info.isReparsePoint) {
    if (info.reparseTag == ioReparseTagSymlink ||
        info.reparseTag == ioReparseTagMountPoint) {
      // Only the link itself is removed; its target is left alone.
      entries.add(
        PlanEntry(
          path,
          info.isDirectory ? EntryKind.directoryLink : EntryKind.fileLink,
          0,
        ),
      );
    } else {
      issues.add(
        ShredIssue(
          toDisplay(path),
          'Cloud-synced or special file. It cannot be shredded safely.',
        ),
      );
    }
    return;
  }

  if (!info.isDirectory) {
    entries.add(PlanEntry(path, EntryKind.file, info.size));
    return;
  }

  final children = <_FindInfo>[];
  final data = malloc<Uint8>(findDataSize);
  try {
    final handle = withWide('$path\\*', (w) => findFirstFile(w, data));
    if (handle == invalidHandle) {
      issues.add(ShredIssue(toDisplay(path), _describeError(lastWideCallError)));
    } else {
      try {
        do {
          final child = _FindInfo(data);
          if (child.name != '.' && child.name != '..') children.add(child);
        } while (findNextFile(handle, data) != 0);
      } finally {
        findClose(handle);
      }
    }
  } finally {
    malloc.free(data);
  }

  for (final child in children) {
    _walk('$path\\${child.name}', child, entries, issues);
  }
  entries.add(PlanEntry(path, EntryKind.directory, 0));
}

/// Executes [plan]. A failure on one item never stops the others.
ShredReport executePlan(
  ShredPlan plan, {
  int passes = defaultPasses,
  void Function(ShredProgress)? onProgress,
  bool Function()? shouldStop,
}) {
  final runner = _Runner(passes, plan.totalBytes * passes, onProgress, shouldStop);
  try {
    return runner.run(plan);
  } finally {
    runner.dispose();
  }
}

/// Runs only the in-place overwrite, leaving the file on disk for inspection.
@visibleForTesting
void overwriteFileForTest(String path, int passes) {
  final runner = _Runner(passes, 0, null, null);
  final extended = toExtended(normalizeInput(path));
  final handle = runner.open(extended);
  try {
    runner.overwrite(handle, runner.fileInfo(handle).size);
  } finally {
    closeHandle(handle);
    runner.dispose();
  }
}

class _HandleInfo {
  const _HandleInfo(this.attributes, this.size, this.links);
  final int attributes;
  final int size;
  final int links;
}

class _Runner {
  _Runner(this.passes, this.bytesTotal, this.onProgress, this.shouldStop);

  final int passes;
  final int bytesTotal;
  final void Function(ShredProgress)? onProgress;
  final bool Function()? shouldStop;

  final Pointer<Uint8> _buffer = malloc<Uint8>(_chunkSize);
  final Pointer<Uint32> _written = malloc<Uint32>();
  final Stopwatch _sinceReport = Stopwatch()..start();
  int _bytesDone = 0;
  String _current = '';

  void dispose() {
    malloc.free(_buffer);
    malloc.free(_written);
  }

  ShredReport run(ShredPlan plan) {
    final issues = List<ShredIssue>.of(plan.issues);
    var files = 0, folders = 0, links = 0, finishedBytes = 0;
    var stopped = false;

    for (final entry in plan.entries) {
      _current = toDisplay(entry.path);
      _report(force: true);
      try {
        switch (entry.kind) {
          case EntryKind.file:
            _shredFile(entry);
            files++;
          case EntryKind.directory:
            _removeFolder(entry);
            folders++;
          case EntryKind.fileLink:
            _check(
              withWide(entry.path, deleteFile),
              entry.path,
            );
            links++;
          case EntryKind.directoryLink:
            _check(
              withWide(entry.path, removeDirectory),
              entry.path,
            );
            links++;
        }
      } on _Failure catch (failure) {
        issues.add(ShredIssue(_current, failure.message));
      } on _Stopped {
        stopped = true;
        break;
      }
      finishedBytes += entry.size * passes;
      _bytesDone = finishedBytes;
    }
    _report(force: true);

    return ShredReport(
      filesShredded: files,
      foldersRemoved: folders,
      linksRemoved: links,
      issues: issues,
      stopped: stopped,
    );
  }

  void _check(int result, String path) {
    if (result == 0) throw _Failure(_describeError(lastWideCallError));
  }

  void _report({bool force = false}) {
    if (onProgress == null) return;
    if (force || _sinceReport.elapsedMilliseconds >= _progressIntervalMs) {
      _sinceReport.reset();
      onProgress!(
        ShredProgress(math.min(_bytesDone, bytesTotal), bytesTotal, _current),
      );
    }
  }

  /// Opens a file or stream exclusively, so a file in use fails here, before
  /// anything has been changed. Never follows a reparse point.
  int open(String path) {
    final handle = withWide(
      path,
      (w) => createFile(
        w,
        genericRead | genericWrite,
        0,
        nullptr,
        openExisting,
        fileFlagWriteThrough |
            fileFlagSequentialScan |
            fileFlagOpenReparsePoint,
        0,
      ),
    );
    if (handle == invalidHandle) {
      throw _Failure(_describeError(lastWideCallError));
    }
    return handle;
  }

  _HandleInfo fileInfo(int handle) {
    final data = malloc<Uint8>(handleInfoSize);
    try {
      if (getFileInformationByHandle(handle, data) == 0) {
        throw _Failure(_describeError(getLastError()));
      }
      return _HandleInfo(
        (data + handleInfoAttributes).cast<Uint32>().value,
        ((data + handleInfoSizeHigh).cast<Uint32>().value << 32) |
            (data + handleInfoSizeLow).cast<Uint32>().value,
        (data + handleInfoLinks).cast<Uint32>().value,
      );
    } finally {
      malloc.free(data);
    }
  }

  void _shredFile(PlanEntry entry) {
    withWide(entry.path, (w) => setFileAttributes(w, fileAttributeNormal));

    final handle = open(entry.path);
    try {
      final info = fileInfo(handle);
      if (info.attributes & fileAttributeReparsePoint != 0) {
        throw const _Failure('The file changed into a link. It was skipped.');
      }
      if (info.links > 1) {
        // Overwriting would destroy the data under the other names too.
        throw _Failure(
          'The file has ${info.links} hard links. It was left unchanged.',
        );
      }

      for (final stream in _namedStreams(entry.path)) {
        final streamHandle = open('${entry.path}$stream');
        try {
          overwrite(streamHandle, fileInfo(streamHandle).size, countBytes: false);
        } finally {
          closeHandle(streamHandle);
        }
      }

      overwrite(handle, info.size);
      _seekToStart(handle);
      if (setEndOfFile(handle) == 0 || flushFileBuffers(handle) == 0) {
        throw _Failure(_describeError(getLastError()));
      }
    } finally {
      closeHandle(handle);
    }

    final scrambled = _renameToRandom(entry.path) ?? entry.path;
    _check(withWide(scrambled, deleteFile), scrambled);
  }

  void _removeFolder(PlanEntry entry) {
    withWide(entry.path, (w) => setFileAttributes(w, fileAttributeNormal));
    final scrambled = _renameToRandom(entry.path);
    final target = scrambled ?? entry.path;
    if (withWide(target, removeDirectory) != 0) return;

    final error = lastWideCallError;
    // Keep the original name on a folder that has to stay.
    if (scrambled != null) _rename(scrambled, entry.path);
    throw _Failure(_describeError(error));
  }

  List<String> _namedStreams(String path) {
    final streams = <String>[];
    final data = malloc<Uint8>(findStreamDataSize);
    try {
      final handle = withWide(path, (w) => findFirstStream(w, 0, data, 0));
      // Volumes without stream support fail here and simply have no streams.
      if (handle == invalidHandle) return streams;
      try {
        do {
          final name = (data + findStreamDataName).cast<Utf16>().toDartString();
          if (name != '::\$DATA') streams.add(name);
        } while (findNextStream(handle, data) != 0);
      } finally {
        findClose(handle);
      }
    } finally {
      malloc.free(data);
    }
    return streams;
  }

  void _seekToStart(int handle) {
    if (setFilePointerEx(handle, 0, nullptr, 0) == 0) {
      throw _Failure(_describeError(getLastError()));
    }
  }

  /// Rewrites [size] bytes in place, keeping the file's existing clusters.
  void overwrite(int handle, int size, {bool countBytes = true}) {
    for (var pass = 0; pass < passes; pass++) {
      _seekToStart(handle);
      var remaining = size;
      while (remaining > 0) {
        if (shouldStop?.call() ?? false) throw const _Stopped();
        final count = math.min(remaining, _chunkSize);
        if (!fillRandom(_buffer, count)) {
          throw const _Failure('The system random generator failed.');
        }
        if (writeFile(handle, _buffer, count, _written, nullptr) == 0 ||
            _written.value != count) {
          throw _Failure(_describeError(getLastError()));
        }
        remaining -= count;
        if (countBytes) {
          _bytesDone += count;
          _report();
        }
      }
      if (flushFileBuffers(handle) == 0) {
        throw _Failure(_describeError(getLastError()));
      }
    }
  }

  bool _rename(String from, String to) =>
      withWide(from, (a) => withWide(to, (b) => moveFile(a, b))) != 0;

  /// Hides the original name. Returns the new path, or null if renaming failed.
  String? _renameToRandom(String path) {
    final parent = path.substring(0, path.lastIndexOf(r'\'));
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!fillRandom(_buffer, 8)) return null;
      final name = [
        for (var i = 0; i < 8; i++)
          _buffer[i].toRadixString(16).padLeft(2, '0'),
      ].join();
      final candidate = '$parent\\$name';
      if (_rename(path, candidate)) return candidate;
    }
    return null;
  }
}
