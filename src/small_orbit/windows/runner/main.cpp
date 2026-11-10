#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
void BringExistingToFront() {
  // A second launch can arrive before the first process creates its window.
  // Wait briefly for that window without ever opening another data writer.
  const UINT showMessage = RegisterWindowMessageW(L"SmallOrbit.ShowExistingWindow.v1");
  for (int attempt = 0; attempt < 40; ++attempt) {
    const HWND window = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"小事星球");
    if (window != nullptr) {
      ShowWindowAsync(window, SW_RESTORE);
      SetForegroundWindow(window);
      PostMessageW(window, showMessage, 0, 0);
      return;
    }
    Sleep(50);
  }
}
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, L"Local\\SmallOrbitOffline_v1");
  const DWORD mutexStatus = GetLastError();
  if (instanceMutex == nullptr) {
    MessageBoxW(nullptr, L"无法安全打开数据，请关闭已有的小事星球窗口后重试。",
                L"小事星球", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (mutexStatus == ERROR_ALREADY_EXISTS) {
    BringExistingToFront();
    CloseHandle(instanceMutex);
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
  Win32Window::Point origin(100, 70);
  Win32Window::Size size(440, 700);
  if (!window.Create(L"小事星球", origin, size)) {
    ::CoUninitialize();
    CloseHandle(instanceMutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instanceMutex) CloseHandle(instanceMutex);
  return EXIT_SUCCESS;
}
