# 0.1.0 验证记录

日期：2026-11-10。验证环境与重现命令见 `build.md`。

## 已验证

- Flutter 静态分析：无问题。
- 14 项核心测试：每日/每周周期、闰日和跨年、未完成归档、今日/未来过滤、导入校验、重复 ID、损坏日期、保存后重开、保存中断恢复、损坏主文件保留、恢复前备份、备份失败不中断原数据、排队修改、跨模式和跨日撤销、泡泡大小及边界、暂停和开场停止。
- 2 项界面交互测试：快速添加、完成、切换展示、撤销与保存；牌堆换一件、概览选择、右划完成和撤销。
- 1 项布局测试：泡泡/纸片/卡牌在 320、390、480 宽度，键盘弹出、编辑弹窗，无布局溢出。PNG 预览为实际 Flutter 渲染，使用示例数据，不包含用户任务。
- 5 项 Android 原生日历调度测试：闰日与已完成跳过、每周旧提醒不过期补发、触发后继续安排下一期、过去/未来一次性任务、改期后的旧闹钟过滤。JUnit 报告 5 tests / 0 failures / 0 errors。
- Windows Release 编译成功。便携包包含应用、Flutter 引擎、AOT 数据及 Visual C++ x64 CRT；ZIP CRC 与必需文件检查通过。
- Android Release APK 构建成功，版本 0.1.0+1，54,803,993 字节；最低 SDK 26，目标 SDK 36，包含 arm64-v8a、armeabi-v7a、x86_64。签名、ZIP CRC 和 16 KB ZIP 对齐验证通过，不可调试，最终权限清单没有 INTERNET。

最终安装包与 SHA-256 校验清单位于 `dist/`。Android 包 SHA-256：`e6c9571ce971c1ddee693a42369a3578bb5838fc252d6159252b6b4a1e234bdb`。

## 实测边界

- Android 服务器没有可用 KVM，未启动重型软件模拟器；未连接用户的 Android 15 手机。权限弹窗、后台、省电、重启后实际通知送达仍需真机验证。
- Windows 桌面检查工具等待应用授权超时。已编译并启动过隔离测试进程，但没有完成原生窗口交互、托盘及系统通知的端到端人工/自动验收，也没有分别在 Windows 10 和 11 上做真机回归。
- 通过的 Flutter 测试验证共享界面和逻辑，不替代两端原生系统行为检查。未测量冷启动耗时、后台内存或耗电，未承诺数值。
- Android 构建的第三方插件仍产生旧 Kotlin Gradle 接口弃用提示。本版固定工具链可以构建；升级 AGP/Flutter 时需要复核插件兼容性。

## 日志位置

远端 `/home/wzh/my_code/todo_list/logs/`：`analyze.log`、`tests.log`、`card_tests.log`、`layout.log`、`android_tests.log`、`android_build.log`。本机 `logs/`：`windows_build.log`、Windows 依赖检查日志。签名材料位于远端 `.private/`，不在日志或安装包内。

首轮 Android 构建的工具下载与旧源码构建日志保留在 `android_bootstrap_build.log`；旧构建为切换最终源码主动中止，不作为成功构建记录。
