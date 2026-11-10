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
  bool IsCompact() const;
  bool IsAlwaysOnTop() const;

 private:
  bool Apply(bool compact, bool alwaysOnTop);
  bool Save(bool compact, bool alwaysOnTop) const;
  std::wstring FilePath() const;
  HWND window_;
  bool compact_ = false;
  bool alwaysOnTop_ = false;
};

#endif
