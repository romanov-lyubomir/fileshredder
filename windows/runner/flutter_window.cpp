#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <sstream>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "fileshredder/instance",
          &flutter::StandardMethodCodec::GetInstance());
  instance_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "takePaths") {
          result->NotImplemented();
          return;
        }
        flutter::EncodableList paths;
        for (const std::string& path : pending_paths_) {
          paths.emplace_back(path);
        }
        pending_paths_.clear();
        result->Success(flutter::EncodableValue(std::move(paths)));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ReceiveForwardedPaths(const COPYDATASTRUCT& data) {
  if (data.cbData > 0 && data.lpData != nullptr) {
    std::istringstream lines(
        std::string(static_cast<const char*>(data.lpData), data.cbData));
    std::string path;
    while (std::getline(lines, path)) {
      if (!path.empty()) {
        pending_paths_.push_back(path);
      }
    }
    if (instance_channel_) {
      instance_channel_->InvokeMethod("pathsAvailable", nullptr);
    }
  }
  ::SetForegroundWindow(GetHandle());
}

void FlutterWindow::OnDestroy() {
  instance_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data != nullptr && data->dwData == kInstanceCopyDataId) {
      ReceiveForwardedPaths(*data);
      return TRUE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
