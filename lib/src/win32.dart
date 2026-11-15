// Minimal hand-written bindings for the Win32 calls the shredder needs.
//
// Calls that read GetLastError afterwards are leaf calls so the Dart runtime
// cannot clobber the error code in between. WriteFile and FlushFileBuffers can
// block for a long time, so they stay non-leaf to avoid stalling the GC.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const genericRead = 0x80000000;
const genericWrite = 0x40000000;
const openExisting = 3;
const fileFlagWriteThrough = 0x80000000;
const fileFlagSequentialScan = 0x08000000;
const fileFlagOpenReparsePoint = 0x00200000;
const invalidHandle = -1;

const fileAttributeDirectory = 0x10;
const fileAttributeNormal = 0x80;
const fileAttributeReparsePoint = 0x400;

const ioReparseTagMountPoint = 0xA0000003;
const ioReparseTagSymlink = 0xA000000C;

const errorFileNotFound = 2;
const errorPathNotFound = 3;
const errorAccessDenied = 5;
const errorSharingViolation = 32;
const errorLockViolation = 33;
const errorDirNotEmpty = 145;

const findDataSize = 592;
const findDataAttributes = 0;
const findDataSizeHigh = 28;
const findDataSizeLow = 32;
const findDataReparseTag = 36;
const findDataFileName = 44;

const findStreamDataSize = 600;
const findStreamDataName = 8;

const handleInfoSize = 52;
const handleInfoAttributes = 0;
const handleInfoSizeHigh = 32;
const handleInfoSizeLow = 36;
const handleInfoLinks = 40;

const _hkeyCurrentUser = -0x7FFFFFFF; // (HKEY)(LONG)0x80000001, sign-extended.
const _regSz = 1;
const _rrfRtRegSz = 2;

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _bcrypt = DynamicLibrary.open('bcrypt.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');

final getLastError = _kernel32.lookupFunction<Uint32 Function(), int Function()>(
  'GetLastError',
  isLeaf: true,
);

final createFile = _kernel32
    .lookupFunction<
      IntPtr Function(
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        IntPtr,
      ),
      int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW', isLeaf: true);

final closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'CloseHandle',
      isLeaf: true,
    );

final writeFile = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('WriteFile');

final flushFileBuffers = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'FlushFileBuffers',
    );

final setFilePointerEx = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Int64, Pointer<Int64>, Uint32),
      int Function(int, int, Pointer<Int64>, int)
    >('SetFilePointerEx', isLeaf: true);

final setEndOfFile = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetEndOfFile',
      isLeaf: true,
    );

final getFileInformationByHandle = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('GetFileInformationByHandle', isLeaf: true);

final findFirstFile = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Uint8>),
      int Function(Pointer<Utf16>, Pointer<Uint8>)
    >('FindFirstFileW', isLeaf: true);

final findNextFile = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('FindNextFileW', isLeaf: true);

final findClose = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'FindClose',
      isLeaf: true,
    );

final findFirstStream = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Int32, Pointer<Uint8>, Uint32),
      int Function(Pointer<Utf16>, int, Pointer<Uint8>, int)
    >('FindFirstStreamW', isLeaf: true);

final findNextStream = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('FindNextStreamW', isLeaf: true);

final setFileAttributes = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, int)
    >('SetFileAttributesW', isLeaf: true);

final moveFile = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('MoveFileW', isLeaf: true);

final deleteFile = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('DeleteFileW', isLeaf: true);

final removeDirectory = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('RemoveDirectoryW', isLeaf: true);

const _bcryptUseSystemPreferredRng = 2;

final _bcryptGenRandom = _bcrypt
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Uint32),
      int Function(int, Pointer<Uint8>, int, int)
    >('BCryptGenRandom', isLeaf: true);

/// Fills [buffer] with cryptographically random bytes; returns false on error.
bool fillRandom(Pointer<Uint8> buffer, int length) =>
    _bcryptGenRandom(0, buffer, length, _bcryptUseSystemPreferredRng) == 0;

final _regSetKeyValue = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Pointer<Void>,
        Uint32,
      ),
      int Function(
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        Pointer<Void>,
        int,
      )
    >('RegSetKeyValueW', isLeaf: true);

final _regGetValue = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
        Pointer<Uint32>,
      ),
      int Function(
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        Pointer<Uint32>,
        Pointer<Void>,
        Pointer<Uint32>,
      )
    >('RegGetValueW', isLeaf: true);

final _regDeleteTree = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)
    >('RegDeleteTreeW', isLeaf: true);

/// The Win32 error from the latest [withWide] call. Freeing the string resets
/// GetLastError, so it has to be captured before that happens.
int lastWideCallError = 0;

T withWide<T>(String text, T Function(Pointer<Utf16>) action) {
  final pointer = text.toNativeUtf16();
  try {
    final result = action(pointer);
    lastWideCallError = getLastError();
    return result;
  } finally {
    malloc.free(pointer);
  }
}

/// Writes a REG_SZ under HKCU, creating the key if needed. A null [name] sets
/// the key's default value. Returns the Win32 status code.
int regSetString(String subKey, String? name, String value) {
  return using((arena) {
    final data = value.toNativeUtf16(allocator: arena);
    return _regSetKeyValue(
      _hkeyCurrentUser,
      subKey.toNativeUtf16(allocator: arena),
      name == null ? nullptr : name.toNativeUtf16(allocator: arena),
      _regSz,
      data.cast(),
      (value.length + 1) * 2,
    );
  });
}

/// Reads a REG_SZ from HKCU, or returns null when it does not exist.
String? regGetString(String subKey, String? name) {
  return using((arena) {
    const capacity = 8192;
    final size = arena<Uint32>()..value = capacity;
    final buffer = arena<Uint8>(capacity);
    final status = _regGetValue(
      _hkeyCurrentUser,
      subKey.toNativeUtf16(allocator: arena),
      name == null ? nullptr : name.toNativeUtf16(allocator: arena),
      _rrfRtRegSz,
      nullptr,
      buffer.cast(),
      size,
    );
    return status == 0 ? buffer.cast<Utf16>().toDartString() : null;
  });
}

/// Deletes an HKCU key and everything below it. Returns the Win32 status code.
int regDeleteTree(String subKey) =>
    withWide(subKey, (key) => _regDeleteTree(_hkeyCurrentUser, key));
