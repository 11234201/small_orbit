# 构建与验证

使用 Flutter stable 3.47.9 / Dart 3.13.7，Flutter 提交 `c197ca5199e9ee5661e865596c9c07294dfab51c`。依赖固定于 `src/small_orbit/pubspec.lock`。Android 使用 JDK 17、Gradle 9.3.1、AGP 9.1.0。

远端工程 `/home/wzh/my_code/todo_list`，Flutter 上游 `/home/wzh/open_source/flutter`。SDK、缓存、签名和输出保留在远端项目的忽略目录。

## Android

同步源码和 scripts 到远端，排除 `.toolchain`、`.dart_tool`、`build`、`ephemeral`、凭据和测试数据；保留已有 `android/key.properties`。

```bash
bash /home/wzh/my_code/todo_list/scripts/bootstrap_remote.sh
source /home/wzh/my_code/todo_list/.toolchain/env.sh
export PUB_HOSTED_URL=https://pub.dev
cd /home/wzh/my_code/todo_list/src/small_orbit
flutter pub get
flutter analyze --no-fatal-infos
flutter test --timeout 120s
bash /home/wzh/my_code/todo_list/scripts/build_android.sh
bash /home/wzh/my_code/todo_list/scripts/verify_android.sh
cd android
./gradlew :app:testDebugUnitTest
```

构建脚本首次生成专用 RSA 签名密钥，位于远端 `.private/`，不进 Git 或安装包。后续升级必须使用同一密钥，请妥善备份此目录。没有 `key.properties` 时手工 Flutter 构建会回退到调试签名，交付使用上述脚本。

## Windows

需要 Visual Studio C++ Build Tools、Windows SDK 和相同 Flutter 提交，后者放在 `.toolchain/flutter`。Linux 无法完成 Windows 原生编译，因此本机仅保留这一步必需的工具链和输出。

```powershell
./scripts/build_windows.ps1
./scripts/package_windows.ps1
```

此机器未开启开发者模式。构建脚本在遇到符号链接权限问题时，依据 `.flutter-plugins-dependencies` 自动创建指向项目缓存的 NTFS Junction 并重试，无需改全局系统设置。

打包附带 Visual Studio 可再分发目录中的 x64 CRT DLL。Flutter 依赖许可保留在 `data/flutter_assets/NOTICES.Z`。

## 候选版版本和统一回归

发布版本只在 `src/small_orbit/pubspec.yaml` 设置，当前为 `1.0.0-rc.6+8`。Android 与 Windows 包名由脚本读取；设置页显示原生包版本，Windows 打包先核对 EXE 产品版本，避免把旧构建打成新版本。

当前模型使用与输入框一致的 `characters` 字符计数。在项目根目录单独编译模型基准时，要提供应用包配置：`dart compile exe --packages=src/small_orbit/.dart_tool/package_config.json scripts/benchmark_model.dart -o .build_cache/benchmark_model`。此前已保存的基线/优化样本源文件不变，旧测量仍按当时源码复现。

Android 构建同时输出通用包与 `android-arm64.apk`。`android/gradle.properties` 使用固定 Flutter 插件支持的 `force-version-code-ignoring-abi=true`，两者都沿用 pubspec 的版本代码，避免 ARM64 默认附加2000后阻碍切回通用包。验证脚本检查每个包的签名、版本、ABI、权限、CRC和对齐，并对比0.1.0签名。

```bash
bash /home/wzh/my_code/todo_list/scripts/verify_shared.sh
```

此命令顺序执行静态分析、全部 Flutter 测试与 Android JVM 单测，任一步失败即停止；日志归档至远端 `logs/<版本>/`。发布构建仍使用前面的两端命令。Windows 包可做独立轻量校验（需要 Python 3）：

```powershell
python scripts/verify_windows.py
```

Windows 原生窗口测试使用已有 MSVC/SDK，在独立 `.qa_data/windows_native_test` 使用自己的窗口。位置测试使用隐藏窗口；置顶测试将窗口放在所有显示器之外，不激活、不显示任务栏入口，验证真实置顶样式及重新显示行为：

```powershell
./src/small_orbit/test/native/run_window_placement_test.ps1
```

发布版启动/资源探针需要 PowerShell 7；先关闭正在运行的小事星球，再执行：

```powershell
./scripts/benchmark_windows.ps1
```

探针生成0/100/1000任务的独立 `.qa_data` 目录，隐藏启动各3次，首帧后采样CPU/工作集，并通过应用自身退出握手结束。仅在 `SMALL_ORBIT_DIAGNOSTICS=1` 且指定独立数据目录时启用；普通启动不写诊断也不会自动退出。日志 `logs/windows_probe_<版本>.json`。这是本机Windows专有验证，不替代可见交互/手机耗电测试。

## 验证

Flutter 测试覆盖日历、文件校验、中断恢复、导入备份、跨模式完成与撤销、牌堆操作、泡泡边界和 320/390/480 宽度布局；窗口选项与简洁模式另有260×300大字号检查。Android原生回归覆盖日历、回执及提醒配置。`ORBIT_PREVIEW_DIR` 可让布局测试输出 PNG；`ORBIT_WINDOW_PREVIEW_DIR` 配合 `flutter test test_tools/render_window_modes.dart` 输出完整/简洁/菜单预览。截图使用远端预装中文字体，不把字体打进应用。实际结果和未覆盖范围见 `validation.md`。

`SMALL_ORBIT_DATA_DIR` 可为测试指定独立数据目录。没有真机时，不把自动测试等同于 Android 厂商后台提醒验证。

参考：[Android 系统提醒](https://developer.android.com/develop/background-work/services/alarms)、[Flutter Windows 打包](https://docs.flutter.dev/platform-integration/windows/building)。
