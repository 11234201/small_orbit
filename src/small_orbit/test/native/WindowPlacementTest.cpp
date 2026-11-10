#include <windows.h>
#include <flutter_windows.h>
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <string>

#include "WindowPlacement.h"

namespace {
void Check(bool value, const char* description) {
  if (!value) {
    std::cerr << "FAIL: " << description << '\n';
    std::exit(1);
  }
}

void WritePreference(const std::wstring& path, const std::string& value) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(file != INVALID_HANDLE_VALUE, "open isolated preference");
  DWORD written = 0;
  Check(WriteFile(file, value.data(), static_cast<DWORD>(value.size()), &written, nullptr) &&
          written == value.size(), "write isolated preference");
  CloseHandle(file);
}

RECT Bounds(HWND window) {
  RECT bounds{};
  Check(GetWindowRect(window, &bounds) != FALSE, "read window bounds");
  return bounds;
}

bool Visible(const RECT& bounds) {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  Check(GetMonitorInfoW(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor) != FALSE,
        "read monitor work area");
  return bounds.left >= monitor.rcWork.left && bounds.top >= monitor.rcWork.top &&
         bounds.right <= monitor.rcWork.right && bounds.bottom <= monitor.rcWork.bottom;
}
}

int wmain(int argumentCount, wchar_t** arguments) {
  Check(argumentCount == 2, "explicit isolated test directory is required");
  Check(SetEnvironmentVariableW(L"SMALL_ORBIT_DATA_DIR", arguments[1]) != FALSE,
        "set process-only test data override");
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  WNDCLASSW windowClass{};
  windowClass.lpfnWndProc = DefWindowProcW;
  windowClass.hInstance = GetModuleHandleW(nullptr);
  windowClass.lpszClassName = L"SmallOrbitPlacementTest";
  Check(RegisterClassW(&windowClass) != 0, "register isolated window class");
  const HWND window = CreateWindowW(windowClass.lpszClassName, L"Hidden placement test",
      WS_OVERLAPPEDWINDOW, 100, 70, 440, 700, nullptr, nullptr, windowClass.hInstance, nullptr);
  Check(window != nullptr, "create hidden test window");
  Check(!IsWindowVisible(window), "test window never becomes visible");
  const int dpi = static_cast<int>(GetDpiForWindow(window));
  SetWindowPos(window, nullptr, 100, 70, MulDiv(440, dpi, 96), MulDiv(700, dpi, 96), SWP_NOZORDER);
  WindowPlacement placement(window);
  placement.KeepVisible();
  const RECT original = Bounds(window);
  placement.Remember();
  SetWindowPos(window, nullptr, original.left + 17, original.top + 13, 380, 580, SWP_NOZORDER);
  placement.Restore();
  const RECT restored = Bounds(window);
  Check(EqualRect(&original, &restored) != FALSE, "normal geometry survives reopen");
  std::cout << "PASS: remembered geometry round trip\n";

  const std::wstring preference = std::wstring(arguments[1]) + L"\\window_placement-v1.txt";
  WritePreference(preference, "corrupted preference\n");
  placement.Restore();
  const RECT afterCorruption = Bounds(window);
  Check(EqualRect(&restored, &afterCorruption) != FALSE, "corrupt preference leaves current window intact");
  std::cout << "PASS: corrupt preference safely ignored\n";

  WritePreference(preference, "1 900000 -900000 30000 30000 96\n");
  placement.Restore();
  Check(Visible(Bounds(window)), "off-screen oversized saved window restored within work area");
  std::cout << "PASS: removed-monitor and oversized geometry recovery\n";

  RECT dpiProposal{-900000, 900000, -890000, 910000};
  placement.AdjustDpiChange(dpiProposal);
  Check(Visible(dpiProposal), "DPI change proposal remains in work area");
  Check(!IsWindowVisible(window), "validation did not show a user-facing window");
  std::cout << "PASS: DPI proposal constrained to visible work area\n";
  placement.SetMinimumSize(260, 300);
  SetWindowPos(window, nullptr, 100, 70, MulDiv(260, dpi, 96), MulDiv(300, dpi, 96), SWP_NOZORDER);
  const RECT compact = Bounds(window);
  placement.Remember();
  SetWindowPos(window, nullptr, 100, 70, MulDiv(440, dpi, 96), MulDiv(700, dpi, 96), SWP_NOZORDER);
  placement.Restore();
  const RECT compactRestored = Bounds(window);
  Check(EqualRect(&compact, &compactRestored) != FALSE, "compact window size survives reopen");
  std::cout << "PASS: compact geometry round trip\n";
  placement.SetMinimumSize(360, 560);
  const RECT expanded = Bounds(window);
  Check(expanded.right - expanded.left >= MulDiv(360, dpi, 96) &&
        expanded.bottom - expanded.top >= MulDiv(560, dpi, 96), "full view expands to usable size");
  Check(!IsWindowVisible(window), "mode switch does not show hidden window");
  std::cout << "PASS: full view restores usable minimum bounds\n";
  DestroyWindow(window);
  UnregisterClassW(windowClass.lpszClassName, windowClass.hInstance);
  return 0;
}
