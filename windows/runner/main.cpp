#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutex[] = L"Global\\AmLDiagnosticSingleInstance";
constexpr wchar_t kWindowTitle[] = L"AOW Diagnostic tool for Android";

struct FindWindowData {
  HWND result = nullptr;
};

BOOL CALLBACK FindExistingWindowProc(HWND hwnd, LPARAM lparam) {
  auto* data = reinterpret_cast<FindWindowData*>(lparam);
  if (!::IsWindowVisible(hwnd)) {
    return TRUE;
  }
  wchar_t title[512];
  const int length = ::GetWindowTextW(hwnd, title, 512);
  if (length <= 0) {
    return TRUE;
  }
  if (wcsncmp(title, kWindowTitle, wcslen(kWindowTitle)) == 0) {
    data->result = hwnd;
    return FALSE;
  }
  return TRUE;
}

void FocusExistingInstance() {
  FindWindowData data;
  ::EnumWindows(FindExistingWindowProc, reinterpret_cast<LPARAM>(&data));
  if (data.result == nullptr) {
    return;
  }
  if (::IsIconic(data.result)) {
    ::ShowWindow(data.result, SW_RESTORE);
  }
  ::SetForegroundWindow(data.result);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance_mutex == nullptr) {
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    FocusExistingInstance();
    ::CloseHandle(single_instance_mutex);
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance_mutex);
  return EXIT_SUCCESS;
}
