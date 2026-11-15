#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Explorer starts one process per selected item. The first one owns the window
// and the rest send it their paths as a WM_COPYDATA message: UTF-8 text with
// one path per line.
constexpr wchar_t kInstanceMutexName[] = L"Local\\FileShredder.SingleInstance";
constexpr wchar_t kInstanceWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kInstanceWindowTitle[] = L"File Shredder";
constexpr ULONG_PTR kInstanceCopyDataId = 0x53485244;  // "SHRD"

#endif  // RUNNER_SINGLE_INSTANCE_H_
