#ifndef RUNNER_OFFLINE_BRIDGE_H_
#define RUNNER_OFFLINE_BRIDGE_H_
#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <optional>
#include "WindowPlacement.h"
#include "WindowOptions.h"

class OfflineBridge {
 public:
  OfflineBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~OfflineBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wParam, LPARAM lParam);
 private:
  void AddTray();
  void ShowWindow();
  bool ShowNotification(const std::string& title, const std::string& body);
  void RequestQuit();
  void FinishQuit(bool ready);
  bool IsVisible() const;
  void QueueVisibilityUpdate();
  void PublishVisibility();
  void RestoreWindowOptions();
  bool ChangeWindowOptions(bool compact, bool alwaysOnTop);
  flutter::EncodableValue WindowOptionsValue() const;
  HWND window_;
  WindowPlacement placement_;
  WindowOptions options_;
  bool optionsRestored_ = false;
  NOTIFYICONDATAW tray_{};
  bool trayAdded_ = false;
  UINT taskbarMessage_;
  UINT showMessage_;
  bool quitPending_ = false;
  bool visibilityUpdateQueued_ = false;
  std::optional<bool> lastVisibility_;
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> windowChannel_;
};
#endif
