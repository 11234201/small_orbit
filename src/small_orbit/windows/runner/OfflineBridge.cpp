#include "OfflineBridge.h"
#include "resource.h"
#include <string>
#include <algorithm>
#include <flutter/method_result_functions.h>

namespace {
constexpr UINT kTrayMessage = WM_APP + 31;
constexpr UINT kExitMessage = WM_APP + 32;
constexpr UINT kRestorePlacement = WM_APP + 33;
constexpr UINT kRememberPlacement = WM_APP + 34;
constexpr UINT kVisibilityMessage = WM_APP + 35;
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
    : window_(window), placement_(window), options_(window),
      taskbarMessage_(RegisterWindowMessageW(L"TaskbarCreated")),
      showMessage_(RegisterWindowMessageW(L"SmallOrbit.ShowExistingWindow.v1")) {
  // Restore after the bridge is assigned to FlutterWindow, so DPI messages
  // caused by moving to another monitor pass through this bridge as well.
  PostMessageW(window_, kRestorePlacement, 0, 0);
  AddTray();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "small_orbit/platform", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getNotificationStatus") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("version"), flutter::EncodableValue(FLUTTER_VERSION)},
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
      placement_.Remember();
      ::ShowWindow(window_, trayAdded_ ? SW_HIDE : SW_MINIMIZE);
      result->Success();
    } else if (method == "minimize") {
      placement_.Remember();
      ::ShowWindow(window_, SW_MINIMIZE); result->Success();
    } else if (method == "quit") {
      result->Success(); RequestQuit();
    } else { result->NotImplemented(); }
  });
  windowChannel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "small_orbit/window", &flutter::StandardMethodCodec::GetInstance());
  windowChannel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "requestQuit") {
      result->Success();
      RequestQuit();
    } else if (call.method_name() == "isVisible") {
      result->Success(flutter::EncodableValue(IsVisible()));
    } else if (call.method_name() == "getOptions") {
      RestoreWindowOptions();
      result->Success(WindowOptionsValue());
    } else if (call.method_name() == "setCompact" || call.method_name() == "setAlwaysOnTop") {
      const auto* value = call.arguments() == nullptr ? nullptr : std::get_if<bool>(call.arguments());
      if (!value) { result->Error("ARGUMENT", "Expected a boolean window option"); return; }
      RestoreWindowOptions();
      const bool compact = call.method_name() == "setCompact" ? *value : options_.IsCompact();
      const bool top = call.method_name() == "setAlwaysOnTop" ? *value : options_.IsAlwaysOnTop();
      if (ChangeWindowOptions(compact, top)) result->Success(WindowOptionsValue());
      else result->Error("WINDOW_OPTIONS", "Could not apply and save window settings");
    } else if (call.method_name() == "startDragging") {
      result->Success();
      if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
        ReleaseCapture();
        SendMessageW(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      }
    } else { result->NotImplemented(); }
  });
  QueueVisibilityUpdate();
}
OfflineBridge::~OfflineBridge() {
  alive_.reset();
  channel_->SetMethodCallHandler(nullptr);
  windowChannel_->SetMethodCallHandler(nullptr);
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
  placement_.KeepVisible();
}

bool OfflineBridge::IsVisible() const {
  return IsWindowVisible(window_) != FALSE && IsIconic(window_) == FALSE;
}

flutter::EncodableValue OfflineBridge::WindowOptionsValue() const {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("compact"), flutter::EncodableValue(options_.IsCompact())},
      {flutter::EncodableValue("alwaysOnTop"), flutter::EncodableValue(IsVisible()
          ? (GetWindowLongPtrW(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0 : options_.IsAlwaysOnTop())}});
}

void OfflineBridge::RestoreWindowOptions() {
  if (optionsRestored_) return;
  optionsRestored_ = true;
  options_.Restore();
  placement_.SetMinimumSize(options_.IsCompact() ? 260 : 360, options_.IsCompact() ? 300 : 560);
  placement_.Restore();
}

bool OfflineBridge::ChangeWindowOptions(bool compact, bool alwaysOnTop) {
  RestoreWindowOptions();
  if (!options_.SetOptions(compact, alwaysOnTop)) return false;
  placement_.SetMinimumSize(compact ? 260 : 360, compact ? 300 : 560);
  placement_.Remember();
  windowChannel_->InvokeMethod("optionsChanged", std::make_unique<flutter::EncodableValue>(WindowOptionsValue()));
  return true;
}

void OfflineBridge::QueueVisibilityUpdate() {
  if (visibilityUpdateQueued_) return;
  visibilityUpdateQueued_ = PostMessageW(window_, kVisibilityMessage, 0, 0) != FALSE;
}

void OfflineBridge::PublishVisibility() {
  visibilityUpdateQueued_ = false;
  const bool visible = IsVisible();
  if (lastVisibility_.has_value() && *lastVisibility_ == visible) return;
  lastVisibility_ = visible;
  if (visible && optionsRestored_) {
    // Reassert a saved pin after the initial show, minimizing, or tray restore.
    if (!options_.Reapply()) ShowNotification("小事星球", "窗口置顶未能应用，请在窗口菜单中重试。");
    windowChannel_->InvokeMethod("optionsChanged", std::make_unique<flutter::EncodableValue>(WindowOptionsValue()));
  }
  windowChannel_->InvokeMethod("visibilityChanged", std::make_unique<flutter::EncodableValue>(visible));
}

void OfflineBridge::RequestQuit() {
  if (quitPending_) return;
  quitPending_ = true;
  EnableWindow(window_, FALSE);
  const std::weak_ptr<bool> lifetime = alive_;
  windowChannel_->InvokeMethod("prepareToQuit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this, lifetime](const flutter::EncodableValue* value) {
            if (lifetime.expired()) return;
            const auto* ready = value == nullptr ? nullptr : std::get_if<bool>(value);
            FinishQuit(ready != nullptr && *ready);
          },
          [this, lifetime](const std::string&, const std::string&, const flutter::EncodableValue*) {
            if (!lifetime.expired()) FinishQuit(false);
          },
          [this, lifetime]() {
            if (!lifetime.expired()) FinishQuit(false);
          }));
}

void OfflineBridge::FinishQuit(bool ready) {
  if (ready) {
    placement_.Remember();
    PostMessageW(window_, kExitMessage, 0, 0);
  } else {
    quitPending_ = false;
    EnableWindow(window_, TRUE);
    ShowWindow();
    ShowNotification("小事星球 · 尚未退出", "保存尚未就绪，请回到窗口检查后再退出。");
  }
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
  if (message == taskbarMessage_) { trayAdded_ = false; AddTray(); return 0; }
  if (message == showMessage_) { ShowWindow(); return 0; }
  if (message == WM_CLOSE) { placement_.Remember(); ::ShowWindow(window_, trayAdded_ ? SW_HIDE : SW_MINIMIZE); return 0; }
  if (message == kExitMessage) { DestroyWindow(window_); return 0; }
  if (message == kRestorePlacement) { RestoreWindowOptions(); return 0; }
  if (message == kRememberPlacement) { placement_.Remember(); return 0; }
  if (message == kVisibilityMessage) { PublishVisibility(); return 0; }
  // WM_SHOWWINDOW is sent before the state transition. Defer the query until
  // the normal window procedure has applied it. WINDOWPOSCHANGED also covers
  // ShowWindow(SW_SHOWNORMAL), which can omit WM_SHOWWINDOW entirely.
  if (message == WM_SHOWWINDOW || message == WM_SIZE || message == WM_WINDOWPOSCHANGED) {
    QueueVisibilityUpdate();
  }
  if (message == WM_EXITSIZEMOVE) { placement_.KeepVisible(); placement_.Remember(); }
  if (message == WM_DPICHANGED) {
    placement_.AdjustDpiChange(*reinterpret_cast<RECT*>(lParam));
    PostMessageW(window_, kRememberPlacement, 0, 0);
  }
  if (message == WM_DISPLAYCHANGE ||
      (message == WM_SETTINGCHANGE && wParam == SPI_SETWORKAREA)) placement_.KeepVisible();
  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
    const UINT dpi = GetDpiForWindow(window_);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    const bool known = GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor) != FALSE;
    info->ptMinTrackSize.x = (std::min<LONG>)(MulDiv(options_.IsCompact() ? 260 : 360, static_cast<int>(dpi), 96), known ? monitor.rcWork.right - monitor.rcWork.left : 32000L);
    info->ptMinTrackSize.y = (std::min<LONG>)(MulDiv(options_.IsCompact() ? 300 : 560, static_cast<int>(dpi), 96), known ? monitor.rcWork.bottom - monitor.rcWork.top : 32000L);
    return 0;
  }
  if (message != kTrayMessage) return std::nullopt;
  if (lParam == WM_LBUTTONDBLCLK || lParam == NIN_BALLOONUSERCLICK) ShowWindow();
  if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, 1, L"打开小事星球");
    AppendMenuW(menu, MF_STRING | (options_.IsCompact() ? MF_CHECKED : MF_UNCHECKED), 3, L"仅显示待办");
    AppendMenuW(menu, MF_STRING | (options_.IsAlwaysOnTop() ? MF_CHECKED : MF_UNCHECKED), 4, L"窗口置顶");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 2, L"退出并停止提醒");
    POINT cursor; GetCursorPos(&cursor); SetForegroundWindow(window_);
    UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0, window_, nullptr);
    DestroyMenu(menu);
    if (selected == 1) ShowWindow();
    if (selected == 2) RequestQuit();
    if (selected == 3 || selected == 4) {
      const bool compact = selected == 3 ? !options_.IsCompact() : options_.IsCompact();
      const bool top = selected == 4 ? !options_.IsAlwaysOnTop() : options_.IsAlwaysOnTop();
      if (!ChangeWindowOptions(compact, top)) {
        ShowNotification("小事星球", "窗口设置未保存，请重试。");
      }
    }
    PostMessageW(window_, WM_NULL, 0, 0);
  }
  return 0;
}
