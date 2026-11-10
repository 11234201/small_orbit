# Release 维护说明

仓库：[11234201/small_orbit](https://github.com/11234201/small_orbit)。源码和文档进入 Git；安装包通过 GitHub Releases 发布，不提交 `dist/`。项目采用 [MIT](../LICENSE)，第三方依赖保留各自许可。

## 准备版本

1. 在 `src/small_orbit/pubspec.yaml` 修改版本名和构建号，保持 Android 构建号递增。候选版使用 `1.0.0-rc.N+构建号`；Git 标签不含构建号，例如 `v1.0.0-rc.6`。
2. 按 [构建说明](build.md) 执行相关静态分析、回归和两端构建；记录实际运行结果，设备依赖不能标为通过。
3. Windows 执行 `scripts/package_windows.ps1` 与 `python scripts/verify_windows.py`，确认 ZIP 含运行库、使用说明、`LICENSE.txt` 和第三方声明。Android 执行构建和验证脚本，保持原发布密钥及两种 APK 的同一版本码。
4. 更新 README 下载链接、变更记录、验证记录和 `docs/releases/<标签>.md`。包名、pubspec、EXE/APK 版本和标签必须一致。
5. 生成 `dist/SOURCE_SHA256-<版本>.txt`，对当前 `src/small_orbit/` 和 `scripts/` 下的 Git 源文件按相对路径排序逐项计算 SHA-256。复制根目录 `LICENSE` 为 `dist/LICENSE.txt`，再为 ZIP、两种 APK、源码指纹清单和许可证生成 `SHA256SUMS-<版本>.txt`。使用 UTF-8 和 LF 换行。
6. 检查待推送历史与附件没有任务数据、密钥、口令、环境配置或构建缓存。确认源码清单与当前发布提交一致，`git diff --check` 通过后提交。

## 创建并检查草稿

以下命令为 rc.6 示例，后续版本需替换版本名。`gh` 使用本机已登录账号；不把 token 写入命令或仓库。

```powershell
git tag -a v1.0.0-rc.6 -m "Small Orbit 1.0.0-rc.6"
git push origin master
git push origin v1.0.0-rc.6
gh release create v1.0.0-rc.6 --repo 11234201/small_orbit --verify-tag --draft --prerelease --title "小事星球 v1.0.0-rc.6 · 离线候选版" --notes-file docs/releases/v1.0.0-rc.6.md
gh release upload v1.0.0-rc.6 --repo 11234201/small_orbit dist/small_orbit-1.0.0-rc.6-windows-x64.zip dist/small_orbit-1.0.0-rc.6-android.apk dist/small_orbit-1.0.0-rc.6-android-arm64.apk dist/SHA256SUMS-1.0.0-rc.6.txt dist/SOURCE_SHA256-1.0.0-rc.6.txt dist/LICENSE.txt
```

检查远端标签指向发布提交、6个附件均为 `uploaded`，尺寸和 GitHub SHA-256 摘要与本地文件一致，发布说明及 README 图片链接可用。没有摘要的附件应重新下载核对。候选版保持 `prerelease=true`，不伪装成稳定版。

如果本地同版本程序正在运行，使用 `scripts/package_windows.ps1 -OutputDirectory .build_cache/public_release` 在独立目录打包；核对后只将ZIP复制到 `dist/`，不覆盖运行中的程序目录。

## 公开发布和核验

用户已授权公开发布、上面的检查通过后再发布：

```powershell
gh release edit v1.0.0-rc.6 --repo 11234201/small_orbit --draft=false --prerelease --latest=false
gh release view v1.0.0-rc.6 --repo 11234201/small_orbit --json url,isDraft,isPrerelease,assets
```

确认仓库公开、Release 非草稿，访客可以打开发布页和附件链接。公开后保持标签和附件稳定；应用修改应发布新版本，不覆盖已发布包。
