#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>
#include <string>

// Device-local preferences, deliberately separate from the exported task file.
class WindowPlacement {
 public:
  explicit WindowPlacement(HWND window);
  void Restore();
  void Remember();
  void KeepVisible();
  void AdjustDpiChange(RECT& proposed);

 private:
  void ApplyBounds(RECT bounds);
  RECT ClampBounds(RECT bounds) const;
  std::wstring FilePath() const;
  HWND window_;
  bool applyingBounds_ = false;
  RECT requestedBounds_{};
};

#endif
