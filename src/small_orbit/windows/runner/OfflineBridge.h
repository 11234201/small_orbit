#ifndef RUNNER_OFFLINE_BRIDGE_H_
#define RUNNER_OFFLINE_BRIDGE_H_
#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <optional>

class OfflineBridge {
 public:
  OfflineBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~OfflineBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wParam, LPARAM lParam);
 private:
  void AddTray();
  void ShowWindow();
  bool ShowNotification(const std::string& title, const std::string& body);
  HWND window_;
  NOTIFYICONDATAW tray_{};
  bool trayAdded_ = false;
  UINT taskbarMessage_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
