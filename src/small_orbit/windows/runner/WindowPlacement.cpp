#include "WindowPlacement.h"

#include <flutter_windows.h>
#include <shlobj.h>
#include <algorithm>
#include <sstream>
#include <vector>

namespace {
std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0 || length > 32768) return L"";
  std::vector<wchar_t> buffer(length);
  const DWORD copied = GetEnvironmentVariableW(name, buffer.data(), length);
  return copied > 0 && copied < length ? std::wstring(buffer.data(), copied) : L"";
}
}

WindowPlacement::WindowPlacement(HWND window) : window_(window) {}

std::wstring WindowPlacement::FilePath() const {
  std::wstring directory = EnvironmentValue(L"SMALL_ORBIT_DATA_DIR");
  if (directory.empty()) {
    directory = EnvironmentValue(L"LOCALAPPDATA");
    if (directory.empty()) return L"";
    directory += L"\\SmallOrbit";
  }
  const int created = SHCreateDirectoryExW(nullptr, directory.c_str(), nullptr);
  if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
      created != ERROR_FILE_EXISTS) return L"";
  return directory + L"\\window_placement-v1.txt";
}

RECT WindowPlacement::ClampBounds(RECT bounds) const {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor)) {
    return bounds;
  }
  const LONG width = (std::min)((std::max)(bounds.right - bounds.left, 1L),
                                monitor.rcWork.right - monitor.rcWork.left);
  const LONG height = (std::min)((std::max)(bounds.bottom - bounds.top, 1L),
                                 monitor.rcWork.bottom - monitor.rcWork.top);
  bounds.left = (std::clamp)(bounds.left, monitor.rcWork.left, monitor.rcWork.right - width);
  bounds.top = (std::clamp)(bounds.top, monitor.rcWork.top, monitor.rcWork.bottom - height);
  bounds.right = bounds.left + width;
  bounds.bottom = bounds.top + height;
  return bounds;
}

void WindowPlacement::ApplyBounds(RECT bounds) {
  bounds = ClampBounds(bounds);
  RECT current{};
  if (GetWindowRect(window_, &current) && EqualRect(&current, &bounds)) return;
  requestedBounds_ = bounds;
  applyingBounds_ = true;
  SetWindowPos(window_, nullptr, bounds.left, bounds.top,
               bounds.right - bounds.left, bounds.bottom - bounds.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
  applyingBounds_ = false;
}

void WindowPlacement::Restore() {
  const auto path = FilePath();
  if (!path.empty()) {
    const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      char bytes[256]{};
      DWORD count = 0;
      const bool read = ReadFile(file, bytes, sizeof(bytes), &count, nullptr) != FALSE;
      CloseHandle(file);
      if (read && count > 0 && count < sizeof(bytes)) {
        std::istringstream input(std::string(bytes, count));
        int version = 0, x = 0, y = 0, width = 0, height = 0, savedDpi = 0;
        std::string trailing;
        if ((input >> version >> x >> y >> width >> height >> savedDpi) &&
            !(input >> trailing) && version == 1 && x >= -1000000 && x <= 1000000 &&
            y >= -1000000 && y <= 1000000 && width >= 100 && width <= 32000 &&
            height >= 100 && height <= 32000 && savedDpi >= 48 && savedDpi <= 768) {
          RECT bounds{x, y, x + width, y + height};
          const UINT dpi = FlutterDesktopGetDpiForMonitor(
              MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST));
          const int scale = static_cast<int>(dpi == 0 ? 96 : dpi);
          bounds.right = bounds.left + (std::max)(MulDiv(width, scale, savedDpi), MulDiv(360, scale, 96));
          bounds.bottom = bounds.top + (std::max)(MulDiv(height, scale, savedDpi), MulDiv(560, scale, 96));
          ApplyBounds(bounds);
        }
      }
    }
  }
  KeepVisible();
}

void WindowPlacement::Remember() {
  // GetWindowRect uses screen coordinates. Never persist the iconic position or
  // maximize dimensions as the user's normal small window geometry.
  if (IsIconic(window_) || IsZoomed(window_)) return;
  RECT bounds{};
  if (!GetWindowRect(window_, &bounds)) return;
  const auto path = FilePath();
  if (path.empty()) return;
  const auto pending = path + L".pending";
  const UINT dpi = GetDpiForWindow(window_);
  std::ostringstream output;
  output << "1 " << bounds.left << ' ' << bounds.top << ' '
         << bounds.right - bounds.left << ' ' << bounds.bottom - bounds.top << ' '
         << (dpi == 0 ? 96 : dpi) << '\n';
  const std::string text = output.str();
  const HANDLE file = CreateFileW(pending.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  const bool saved = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) &&
                     written == text.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (saved) MoveFileExW(pending.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

void WindowPlacement::KeepVisible() {
  if (IsIconic(window_) || IsZoomed(window_)) return;
  RECT bounds{};
  if (GetWindowRect(window_, &bounds)) ApplyBounds(bounds);
}

void WindowPlacement::AdjustDpiChange(RECT& proposed) {
  // A restore has already converted the saved logical size to the destination
  // monitor's DPI. Avoid applying the OS scale suggestion a second time. Keep
  // the message flowing through Flutter and its normal Win32 DPI handler.
  proposed = ClampBounds(applyingBounds_ ? requestedBounds_ : proposed);
}
