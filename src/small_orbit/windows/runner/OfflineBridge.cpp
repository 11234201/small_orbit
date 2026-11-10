#include "OfflineBridge.h"
#include "resource.h"
#include <string>
#include <algorithm>

namespace {
constexpr UINT kTrayMessage = WM_APP + 31;
constexpr UINT kExitMessage = WM_APP + 32;
std::wstring WideText(const std::string& text) {
  if (text.empty()) return L"";
  int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), length);
  return result;
}
std::string ReadString(const flutter::EncodableMap& values, const char* key) {
  auto found = values.find(flutter::EncodableValue(key));
  if (found == values.end()) return "";
  const auto* value = std::get_if<std::string>(&found->second);
  return value ? *value : "";
}
}

OfflineBridge::OfflineBridge(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), taskbarMessage_(RegisterWindowMessageW(L"TaskbarCreated")) {
  MONITORINFO monitorInfo{};
  monitorInfo.cbSize = sizeof(monitorInfo);
  if (GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitorInfo)) {
    RECT bounds{}; GetWindowRect(window_, &bounds);
    int width = (std::min)(bounds.right-bounds.left, monitorInfo.rcWork.right-monitorInfo.rcWork.left);
    int height = (std::min)(bounds.bottom-bounds.top, monitorInfo.rcWork.bottom-monitorInfo.rcWork.top);
    int x = (std::max)(monitorInfo.rcWork.left, (std::min)(bounds.left, monitorInfo.rcWork.right-width));
    int y = (std::max)(monitorInfo.rcWork.top, (std::min)(bounds.top, monitorInfo.rcWork.bottom-height));
    SetWindowPos(window_, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
  }
  AddTray();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "small_orbit/platform", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getNotificationStatus") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("notifications"), flutter::EncodableValue(trayAdded_)},
          {flutter::EncodableValue("exact"), flutter::EncodableValue(false)}}));
    } else if (method == "requestNotifications" || method == "requestExactAlarms" || method == "syncReminders") {
      result->Success();
    } else if (method == "showNotification") {
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!arguments) { result->Error("ARGUMENT", "Missing notification text"); return; }
      if (ShowNotification(ReadString(*arguments, "title"), ReadString(*arguments, "body"))) result->Success();
      else result->Error("NOTIFICATION", "System tray is unavailable");
    } else if (method == "hide") {
      ::ShowWindow(window_, trayAdded_ ? SW_HIDE : SW_MINIMIZE);
      result->Success();
    } else if (method == "minimize") {
      ::ShowWindow(window_, SW_MINIMIZE); result->Success();
    } else if (method == "quit") {
      result->Success(); PostMessageW(window_, kExitMessage, 0, 0);
    } else { result->NotImplemented(); }
  });
}
OfflineBridge::~OfflineBridge() {
  if (trayAdded_) Shell_NotifyIconW(NIM_DELETE, &tray_);
}
void OfflineBridge::AddTray() {
  tray_ = {};
  tray_.cbSize = sizeof(tray_); tray_.hWnd = window_; tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"小事星球 · 双击打开，右键退出");
  trayAdded_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
}
void OfflineBridge::ShowWindow() {
  ::ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_);
}
bool OfflineBridge::ShowNotification(const std::string& title, const std::string& body) {
  if (!trayAdded_) AddTray();
  tray_.uFlags = NIF_INFO;
  wcsncpy_s(tray_.szInfoTitle, WideText(title).c_str(), _TRUNCATE);
  wcsncpy_s(tray_.szInfo, WideText(body).c_str(), _TRUNCATE);
  tray_.dwInfoFlags = NIIF_INFO;
  return Shell_NotifyIconW(NIM_MODIFY, &tray_) != FALSE;
}
std::optional<LRESULT> OfflineBridge::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
  (void)wParam;
  if (message == taskbarMessage_) { trayAdded_ = false; AddTray(); return 0; }
  if (message == WM_CLOSE) { ::ShowWindow(window_, trayAdded_ ? SW_HIDE : SW_MINIMIZE); return 0; }
  if (message == kExitMessage) { DestroyWindow(window_); return 0; }
  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
    const UINT dpi = GetDpiForWindow(window_);
    info->ptMinTrackSize.x = MulDiv(360, static_cast<int>(dpi), 96);
    info->ptMinTrackSize.y = MulDiv(560, static_cast<int>(dpi), 96);
    return 0;
  }
  if (message != kTrayMessage) return std::nullopt;
  if (lParam == WM_LBUTTONDBLCLK || lParam == NIN_BALLOONUSERCLICK) ShowWindow();
  if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, 1, L"打开小事星球");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 2, L"退出并停止提醒");
    POINT cursor; GetCursorPos(&cursor); SetForegroundWindow(window_);
    UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0, window_, nullptr);
    DestroyMenu(menu);
    if (selected == 1) ShowWindow();
    if (selected == 2) PostMessageW(window_, kExitMessage, 0, 0);
    PostMessageW(window_, WM_NULL, 0, 0);
  }
  return 0;
}
