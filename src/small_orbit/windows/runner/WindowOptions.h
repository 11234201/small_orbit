#ifndef RUNNER_WINDOW_OPTIONS_H_
#define RUNNER_WINDOW_OPTIONS_H_

#include <windows.h>
#include <string>

// Device-local window choices. Never included in task exports.
class WindowOptions {
 public:
  explicit WindowOptions(HWND window);
  void Restore();
  bool Reapply();
  bool SetOptions(bool compact, bool alwaysOnTop);
  bool SetOpacity(int percent);
  int OpacityPercent() const;
  bool IsCompact() const;
  bool IsAlwaysOnTop() const;

 private:
  bool SetValues(bool compact, bool alwaysOnTop, int opacity);
  bool Apply(bool compact, bool alwaysOnTop, int opacity);
  bool ApplyOpacity(int percent);
  bool Save(bool compact, bool alwaysOnTop, int opacity) const;
  std::wstring FilePath() const;
  HWND window_;
  bool compact_ = false;
  bool alwaysOnTop_ = false;
  int opacity_ = 100;
};

#endif
