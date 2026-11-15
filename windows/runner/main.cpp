#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

namespace {

// Sends |args| to the instance that owns the window. The owner may still be
// starting, so this waits up to five seconds for its window to appear.
bool ForwardToRunningInstance(const std::vector<std::string>& args) {
  std::string payload;
  for (const std::string& arg : args) {
    payload += arg;
    payload += '\n';
  }

  COPYDATASTRUCT data{};
  data.dwData = kInstanceCopyDataId;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = payload.data();

  for (int attempt = 0; attempt < 100; ++attempt) {
    HWND window = ::FindWindowW(kInstanceWindowClass, kInstanceWindowTitle);
    if (window != nullptr) {
      DWORD process_id = 0;
      ::GetWindowThreadProcessId(window, &process_id);
      ::AllowSetForegroundWindow(process_id);
      DWORD_PTR handled = 0;
      if (::SendMessageTimeoutW(window, WM_COPYDATA, 0,
                                reinterpret_cast<LPARAM>(&data),
                                SMTO_ABORTIFHUNG, 5000, &handled) != 0 &&
          handled != 0) {
        return true;
      }
    }
    ::Sleep(50);
  }
  return false;
}

bool IsCommandLineSwitch(const std::vector<std::string>& args) {
  return args.size() == 1 && args[0].rfind("--", 0) == 0;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Held until the process exits.
  ::CreateMutexW(nullptr, FALSE, kInstanceMutexName);
  if (::GetLastError() == ERROR_ALREADY_EXISTS &&
      !IsCommandLineSwitch(command_line_arguments) &&
      ForwardToRunningInstance(command_line_arguments)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size(640, 540);
  UINT dpi = ::GetDpiForSystem();
  Win32Window::Point origin(
      (::GetSystemMetrics(SM_CXSCREEN) * 96 / dpi - size.width) / 2,
      (::GetSystemMetrics(SM_CYSCREEN) * 96 / dpi - size.height) / 2);
  if (!window.Create(kInstanceWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
