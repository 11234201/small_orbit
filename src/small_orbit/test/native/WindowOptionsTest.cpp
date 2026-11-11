#include <windows.h>
#include <cstdlib>
#include <iostream>
#include <string>
#include "WindowOptions.h"

namespace {
void Check(bool value, const char* description) {
  if (!value) { std::cerr << "FAIL: " << description << '\n'; std::exit(1); }
}
void WritePreference(const std::wstring& path, const std::string& text) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(file != INVALID_HANDLE_VALUE, "open isolated preference");
  DWORD written = 0;
  Check(WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) && written == text.size(), "write preference");
  CloseHandle(file);
}
bool HasCaption(HWND window) { return (GetWindowLongPtrW(window, GWL_STYLE) & WS_CAPTION) == WS_CAPTION; }
bool IsTopmost(HWND window) { return (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0; }
void PumpMessages() {
  for (int i = 0; i < 3; ++i) {
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 20, QS_ALLINPUT);
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
}
}

int wmain(int argumentCount, wchar_t** arguments) {
  Check(argumentCount == 2, "isolated test directory required");
  Check(SetEnvironmentVariableW(L"SMALL_ORBIT_DATA_DIR", arguments[1]) != FALSE, "set isolated path");
  WNDCLASSW windowClass{};
  windowClass.lpfnWndProc = DefWindowProcW;
  windowClass.hInstance = GetModuleHandleW(nullptr);
  windowClass.lpszClassName = L"SmallOrbitOptionsTest";
  Check(RegisterClassW(&windowClass) != 0, "register hidden window class");
  const int outsideX = GetSystemMetrics(SM_XVIRTUALSCREEN) - 1000;
  const int outsideY = GetSystemMetrics(SM_YVIRTUALSCREEN) - 1000;
  const HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, windowClass.lpszClassName,
      L"Offscreen options test", WS_OVERLAPPEDWINDOW, outsideX, outsideY, 440, 700,
      nullptr, nullptr, windowClass.hInstance, nullptr);
  Check(window != nullptr, "create hidden window");
  SetWindowPos(window, nullptr, outsideX, outsideY, 440, 700, SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
  PumpMessages();
  WindowOptions options(window);
  Check(options.SetOptions(true, true), "set compact and topmost");
  PumpMessages();
  Check(!HasCaption(window) && IsTopmost(window), "native styles reflect both choices");
  Check((GetWindowLongPtrW(window, GWL_STYLE) & WS_THICKFRAME) != 0, "compact frame remains resizable");
  RECT bounds{};
  Check(GetWindowRect(window, &bounds) && bounds.right < GetSystemMetrics(SM_XVIRTUALSCREEN) &&
        bounds.bottom < GetSystemMetrics(SM_YVIRTUALSCREEN) && GetForegroundWindow() != window,
        "test remains outside user screens and never activates");
  std::cout << "PASS: compact, topmost, resize and non-activation\n";

  WindowOptions reopened(window);
  reopened.Restore();
  Check(reopened.IsCompact() && reopened.IsAlwaysOnTop(), "choices survive reopen");
  std::cout << "PASS: window choices survive reopen\n";

  Check(reopened.SetOptions(false, true) && HasCaption(window) && IsTopmost(window), "restoring controls preserves pin");
  Check(reopened.SetOptions(true, false) && !HasCaption(window) && !IsTopmost(window), "unpin preserves compact mode");
  Check(reopened.SetOptions(false, false) && HasCaption(window) && !IsTopmost(window), "both switches reversible");
  std::cout << "PASS: independent reversible native options\n";
  ShowWindow(window, SW_HIDE);
  Check(reopened.SetOptions(true, true), "save topmost while hidden");
  ShowWindow(window, SW_SHOWNOACTIVATE);
  Check(reopened.Reapply() && IsTopmost(window), "pin reapplies after tray restore");
  Check(reopened.SetOptions(false, false), "restore test baseline");
  std::cout << "PASS: hidden pin reapplies on show\n";

  const std::wstring preference = std::wstring(arguments[1]) + L"\\window_options-v1.txt";
  for (const auto& invalid : {"bad data", "1 2 1", "2 1 1", "1 1 1 trailing"}) {
    WritePreference(preference, invalid);
    WindowOptions broken(window);
    broken.Restore();
    Check(!broken.IsCompact() && !broken.IsAlwaysOnTop() && HasCaption(window) && !IsTopmost(window), "bad preferences use recoverable defaults");
  }
  std::cout << "PASS: corrupt and future preferences ignored\n";

  const auto pending = preference + L".pending";
  Check(CreateDirectoryW(pending.c_str(), nullptr) != FALSE, "block only isolated pending output");
  Check(!reopened.SetOptions(true, true), "persist failure reported");
  Check(!reopened.IsCompact() && !reopened.IsAlwaysOnTop() && HasCaption(window) && !IsTopmost(window), "persist failure rolls back native choices");
  Check(RemoveDirectoryW(pending.c_str()) != FALSE, "remove isolated blocker");
  Check(reopened.SetOptions(true, true), "retry succeeds after storage recovers");
  std::cout << "PASS: save failure rollback and retry\n";

  WindowOptions missing(nullptr);
  Check(!missing.SetOptions(true, true), "native apply failure reported");
  Check(!missing.IsCompact() && !missing.IsAlwaysOnTop(), "failed native apply leaves logical state unchanged");
  Check(GetForegroundWindow() != window, "test never steals focus");
  std::cout << "PASS: native failure does not publish new state\n";
  WindowOptions translucent(window);
  translucent.Restore();
  Check(translucent.SetOpacity(30), "apply whole-window opacity");
  BYTE alpha = 0;
  DWORD flags = 0;
  Check(GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) && alpha == 77 && flags == LWA_ALPHA,
        "native alpha matches 30 percent");
  Check((GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TRANSPARENT) == 0, "opacity does not enable click-through");
  Check(translucent.SetOptions(false, true) && IsTopmost(window), "opacity coexists with normal pinned view");
  Check(GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) && alpha == 77, "mode switch preserves alpha");
  WindowOptions restoredOpacity(window);
  restoredOpacity.Restore();
  Check(restoredOpacity.OpacityPercent() == 30 && restoredOpacity.IsAlwaysOnTop(), "opacity survives reopen");
  ShowWindow(window, SW_HIDE);
  ShowWindow(window, SW_SHOWNOACTIVATE);
  Check(restoredOpacity.Reapply() && GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) && alpha == 77,
        "opacity reapplies on show");
  std::cout << "PASS: alpha, interaction, pin, mode and restart preservation\n";

  Check(CreateDirectoryW(pending.c_str(), nullptr) != FALSE, "block opacity persistence");
  Check(!restoredOpacity.SetOpacity(75) && restoredOpacity.OpacityPercent() == 30, "failed opacity write preserves preference");
  Check(GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) && alpha == 77, "failed opacity write rolls back alpha");
  Check(RemoveDirectoryW(pending.c_str()) != FALSE, "remove opacity blocker");
  Check(restoredOpacity.SetOpacity(75), "opacity retry succeeds");
  Check(!restoredOpacity.SetOpacity(0) && !restoredOpacity.SetOpacity(101) && restoredOpacity.OpacityPercent() == 75,
        "invalid opacity rejected without changing state");
  Check(restoredOpacity.SetOpacity(100) && (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_LAYERED) == 0,
        "full opacity restores ordinary compositing");
  std::cout << "PASS: opacity rollback, retry, validation and full reset\n";

  WritePreference(preference, "1 1 0\n");
  WindowOptions legacy(window);
  legacy.Restore();
  Check(legacy.IsCompact() && !legacy.IsAlwaysOnTop() && legacy.OpacityPercent() == 100, "legacy preferences preserved");
  for (const auto& invalid : {"2 1 1 0", "2 1 1 101", "2 1 1 50 trailing", "3 1 1 50"}) {
    WritePreference(preference, invalid);
    legacy.Restore();
    Check(!legacy.IsCompact() && !legacy.IsAlwaysOnTop() && legacy.OpacityPercent() == 100, "invalid opacity preferences use visible defaults");
  }
  Check(GetForegroundWindow() != window, "opacity never activates the test window");
  std::cout << "PASS: legacy preferences and corrupt opacity recovery\n";
  DestroyWindow(window);
  UnregisterClassW(windowClass.lpszClassName, windowClass.hInstance);
  return 0;
}
