#include "WindowOptions.h"

#include <shlobj.h>
#include <cstring>
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

WindowOptions::WindowOptions(HWND window) : window_(window) {}
bool WindowOptions::IsCompact() const { return compact_; }
bool WindowOptions::IsAlwaysOnTop() const { return alwaysOnTop_; }
int WindowOptions::OpacityPercent() const { return opacity_; }
bool WindowOptions::Reapply() { return Apply(compact_, alwaysOnTop_, opacity_); }

bool WindowOptions::ApplyOpacity(int percent) {
  // Flutter paints the background alpha; task surfaces stay fully opaque.
  // Global LWA_ALPHA would multiply every pixel, including text and papers.
  struct AccentPolicy {
    int m_state;
    int m_flags;
    int m_color;
    int m_animation;
  };
  struct CompositionData {
    int m_attribute;
    void* m_data;
    SIZE_T m_size;
  };
  using SetComposition = BOOL(WINAPI*)(HWND, CompositionData*);
  const auto module = GetModuleHandleW(L"user32.dll");
  const auto address = module ? GetProcAddress(module, "SetWindowCompositionAttribute") : nullptr;
  SetComposition setComposition = nullptr;
  static_assert(sizeof(setComposition) == sizeof(address));
  std::memcpy(&setComposition, &address, sizeof(address));
  // Windows 10/11 support transparent client compositing. If unavailable,
  // report failure instead of silently fading the foreground again.
  if (!setComposition) return percent == 100;
  const LONG_PTR previous = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  const LONG_PTR next = previous & ~static_cast<LONG_PTR>(WS_EX_LAYERED);
  SetLastError(ERROR_SUCCESS);
  if (SetWindowLongPtrW(window_, GWL_EXSTYLE, next) == 0 && GetLastError() != ERROR_SUCCESS) return false;
  // WCA_ACCENT_POLICY / ACCENT_ENABLE_TRANSPARENTGRADIENT. This exposes
  // Flutter's per-pixel alpha without enabling pointer click-through.
  AccentPolicy policy{percent < 100 ? 2 : 0, 2, 0, 0};
  CompositionData data{19, &policy, sizeof(policy)};
  if (!setComposition(window_, &data)) {
    SetWindowLongPtrW(window_, GWL_EXSTYLE, previous);
    return false;
  }
  if (previous != next) RedrawWindow(window_, nullptr, nullptr, RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN);
  return true;
}

std::wstring WindowOptions::FilePath() const {
  std::wstring directory = EnvironmentValue(L"SMALL_ORBIT_DATA_DIR");
  if (directory.empty()) {
    directory = EnvironmentValue(L"LOCALAPPDATA");
    if (directory.empty()) return L"";
    directory += L"\\SmallOrbit";
  }
  const int created = SHCreateDirectoryExW(nullptr, directory.c_str(), nullptr);
  if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
      created != ERROR_FILE_EXISTS) return L"";
  return directory + L"\\window_options-v1.txt";
}

bool WindowOptions::Apply(bool compact, bool alwaysOnTop, int opacity) {
  if (!IsWindow(window_)) return false;
  const LONG_PTR oldStyle = GetWindowLongPtrW(window_, GWL_STYLE);
  const bool wasTopmost = (GetWindowLongPtrW(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
  const LONG_PTR caption = static_cast<LONG_PTR>(WS_CAPTION);
  const LONG_PTR style = compact ? oldStyle & ~caption : oldStyle | caption;
  SetLastError(ERROR_SUCCESS);
  if (SetWindowLongPtrW(window_, GWL_STYLE, style) == 0 && GetLastError() != ERROR_SUCCESS) return false;
  // Keep the thick resize frame and never activate another app's background
  // window just because the user changes its stacking preference.
  // Change only this window's Z order. Letting SetWindowPos reposition an
  // owner can acknowledge HWND_TOPMOST without changing this window's band.
  // Repeating that request does not repair it (observed on Windows 10).
  const UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED;
  const HWND order = alwaysOnTop ? HWND_TOPMOST : HWND_NOTOPMOST;
  const bool positioned = SetWindowPos(window_, order, 0, 0, 0, 0, flags) != FALSE;
  // A successful API return alone is insufficient, including while hidden.
  if (positioned &&
      (((GetWindowLongPtrW(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) == alwaysOnTop) &&
      ApplyOpacity(opacity)) return true;
  SetWindowLongPtrW(window_, GWL_STYLE, oldStyle);
  SetWindowPos(window_, wasTopmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, flags);
  ApplyOpacity(opacity_);
  return false;
}

void WindowOptions::Restore() {
  bool compact = false, alwaysOnTop = false;
  int opacity = 100;
  const auto path = FilePath();
  if (!path.empty()) {
    const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      char bytes[64]{};
      DWORD count = 0;
      const bool read = ReadFile(file, bytes, sizeof(bytes), &count, nullptr) != FALSE;
      CloseHandle(file);
      if (read && count > 0 && count < sizeof(bytes)) {
        std::istringstream input(std::string(bytes, count));
        int version = 0, compactValue = 0, topValue = 0, opacityValue = 100;
        std::string trailing;
        const bool fields = static_cast<bool>(input >> version >> compactValue >> topValue);
        const bool opacityRead = version == 1 || (version == 2 && static_cast<bool>(input >> opacityValue));
        if (fields && opacityRead && !(input >> trailing) &&
            opacityValue >= 30 && opacityValue <= 100 && (compactValue == 0 || compactValue == 1) &&
            (topValue == 0 || topValue == 1)) {
          compact = compactValue != 0;
          alwaysOnTop = topValue != 0;
          opacity = opacityValue;
        }
      }
    }
  }
  if (Apply(compact, alwaysOnTop, opacity)) {
    compact_ = compact;
    alwaysOnTop_ = alwaysOnTop;
    opacity_ = opacity;
  }
}

bool WindowOptions::Save(bool compact, bool alwaysOnTop, int opacity) const {
  const auto path = FilePath();
  if (path.empty()) return false;
  const auto pending = path + L".pending";
  const std::string text = std::string("2 ") + (compact ? "1 " : "0 ") + (alwaysOnTop ? "1 " : "0 ") + std::to_string(opacity) + "\n";
  const HANDLE file = CreateFileW(pending.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool saved = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) &&
                     written == text.size() && FlushFileBuffers(file);
  CloseHandle(file);
  return saved && MoveFileExW(pending.c_str(), path.c_str(),
                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

bool WindowOptions::SetOptions(bool compact, bool alwaysOnTop) {
  return SetValues(compact, alwaysOnTop, opacity_);
}

bool WindowOptions::SetOpacity(int percent) {
  return SetValues(compact_, alwaysOnTop_, percent);
}

bool WindowOptions::SetValues(bool compact, bool alwaysOnTop, int opacity) {
  if (opacity < 30 || opacity > 100) return false;
  if (compact == compact_ && alwaysOnTop == alwaysOnTop_ && opacity == opacity_) return Reapply();
  if (!Apply(compact, alwaysOnTop, opacity)) return false;
  if (!Save(compact, alwaysOnTop, opacity)) {
    Apply(compact_, alwaysOnTop_, opacity_);
    return false;
  }
  compact_ = compact;
  alwaysOnTop_ = alwaysOnTop;
  opacity_ = opacity;
  return true;
}
