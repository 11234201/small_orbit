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

## 验证

Flutter 测试覆盖日历、文件校验、中断恢复、导入备份、跨模式完成与撤销、牌堆操作、泡泡边界和 320/390/480 宽度布局。Android 另有 5 项原生日历调度测试。`ORBIT_PREVIEW_DIR` 可让布局测试输出 PNG；截图模式使用远端预装中文字体，不把字体打进应用。实际结果和未覆盖范围见 `validation.md`。

`SMALL_ORBIT_DATA_DIR` 可为测试指定独立数据目录。没有真机时，不把自动测试等同于 Android 厂商后台提醒验证。

参考：[Android 系统提醒](https://developer.android.com/develop/background-work/services/alarms)、[Flutter Windows 打包](https://docs.flutter.dev/platform-integration/windows/building)。
