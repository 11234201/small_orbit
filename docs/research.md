# 产品与技术调研

调研日期：2026-11-10（Asia/Shanghai）

范围：个人轻量待办、Android 与 Windows、离线使用、手动导入导出、轻巧完成反馈。

方法：查阅产品和技术官方资料，未安装竞品、未执行性能测试、未审计第三方源码。下文明确区分公开事实、设计判断和待验证事项。网页会更新，实施时应固定实际依赖版本。

## 1. 竞品：从成熟产品中选择适合本项目的部分

| 参考 | 官方资料中的事实 | 对本项目的设计判断 |
| --- | --- | --- |
| Microsoft To Do | 官方提供 Android、Windows 等客户端和自动同步；Android 小组件可添加和查看 My Day 任务。[来源 1](https://support.microsoft.com/en-us/todo/set-up-microsoft-to-do)、[来源 2](https://support.microsoft.com/en-us/todo/using-the-android-widget-with-microsoft-to-do) | 借鉴快速入口和当天任务的聚焦方式；是否增加“今天”视图取决于用户的日期需求。 |
| TickTick | 入门指南列出任务、日历、四象限、番茄钟和习惯模块。[来源](https://help.ticktick.com/articles/7054286604315131904) | 产品覆盖很广。本项目应先验证快速记录与完成这一条核心路径，其他模块按真实需求逐项考虑。 |
| Habitica | 完成任务可获得金币、经验和物品，还提供装备和组队任务。[来源](https://habitica.com/static/features) | 证明“任务完成后给予奖励”是一种现有产品模式；用户已明确偏好轻巧反馈，当前采用即时动效方向。不能据此推断动效必然提升坚持率。 |

结论属于产品判断：本项目的候选定位是“个人随手清单 + 及时的完成反馈”。核心价值需要在真实使用中验证，竞品功能介绍不是本项目需求证据。

## 2. 开源产品参考

Super Productivity 的官方介绍列出 Windows、Android、Web 等平台，默认本地数据和离线使用，可选 WebDAV / Dropbox 同步，并标明 MIT 许可。[官方资料](https://super-productivity.com/press-kit/)

- 借鉴点：将离线核心与可选数据传输分开设计；任务数据可以不依赖在线账户。
- 适用边界：它还覆盖时间追踪、日历和外部工作平台集成，产品范围比当前需求大。
- 当前决定：作为产品与架构参考，暂不直接派生其代码。
- 采用代码前：核查仓库对应提交的 LICENSE、依赖许可和维护情况，固定提交版本。目前未下载代码，因此未建立版本或完整性记录。
- 本项目暂不需要训练数据、竞赛测试集或论文复现；后续验证使用自建的小型任务样例。

## 3. 跨平台方案

| 方案 | 可核实的事实 | 针对当前需求的判断 | 待验证 |
| --- | --- | --- | --- |
| Flutter | 官方支持 Android 和 Windows；可以共用主要界面与逻辑。[平台支持](https://docs.flutter.dev/reference/supported-platforms)、[FAQ](https://docs.flutter.dev/resources/faq) | 如果重点是两端一致的应用体验与轻巧动效，可作为优先候选。 | 发布体积、启动与内存；Windows 窗口集成；文件导入导出及提醒插件的两端能力。 |
| Tauri 2 | 官方支持 Android 和 Windows；Windows 使用 WebView2，Android 使用系统 WebView。[官网](https://v2.tauri.app/)、[渲染器说明](https://v2.tauri.app/reference/webview-versions/) | 如果包体优先且接受 Web 技术，可作为重点备选；需评估各端系统能力的接入工作。 | WebView 运行开销、不同 Android WebView 的表现；原生提醒和窗口能力是否满足需求。 |
| PWA | 支持的浏览器可以安装网页应用；Service Worker 可实现离线体验。[安装说明](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable)、[离线与后台](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Offline_and_background_operation) | 适合快速验证清单交互。如果用户需要桌面常驻、托盘或严格的本地后台提醒，需要先验证浏览器能力，不能默认满足。 | 目标 Android 浏览器的安装形态、文件操作、存储持久性、后台行为。 |

目前倾向：用户已选择操作简单、打开快优先，并需要小窗口、提醒和重复任务，因此继续将 Flutter 列为优先评估对象。先验证两端系统提醒，再决定最终选型。Tauri 2 保留为候选。

这不是性能排名。Flutter 不等于已经满足“小包体”，Tauri 使用系统 WebView 也不意味着总内存一定更低；PWA 的离线和跨设备数据传输同样需要具体实现。

Flutter 官方提醒 debug 构建的大小不能代表发布版本，商店分发还会处理上传包。[体积测量说明](https://docs.flutter.dev/perf/app-size)

验证时应明确记录：分发包格式和架构、下载大小、安装占用、运行时依赖是否已存在、进程总内存、空闲 CPU、冷启动耗时和测试设备。不能拿不同测量口径直接比较。

## 4. 影响首版复杂度的边界

### 提醒

日期字段、应用内提示、应用关闭后的系统通知是三个不同层次的需求。

Android 的 AlarmManager 可在应用不运行时触发定时操作，但精确与非精确调度具有不同的限制；应按实际需求选择并在目标手机验证。[Android 官方说明](https://developer.android.com/develop/background-work/services/alarms)

用户已确认首版需要提醒和每天/每周重复。系统能力验证必须覆盖完成后取消、修改时间、重启、拒绝权限等实际行为。

2026-11-10 补充查阅：

- Flutter 的 `flutter_local_notifications` Windows 实现文档明确指出，`periodicallyShow` 和 `periodicallyShowWithDuration` 不受支持；已显示通知的取消/查询能力还与包身份、MSIX 分发有关。[插件维护方文档](https://pub.dev/packages/flutter_local_notifications_windows)
- Microsoft 官方说明，预先安排的通知可在应用未运行时显示，但通知有送达时间窗口，电脑在该时段关机可能导致通知丢弃。[Windows 定时通知文档](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-scheduled)
- 工程判断：这不等于 Windows 无法做每日/每周任务。应用可以管理重复规则，再安排各次通知；但具体排程、取消、补排和打包方式需要验证。
- 若采用提前安排有限数量通知的办法，必须明确应用长期不打开时如何补充后续通知，不能把有限队列视作无限期重复提醒。
- 不依赖网页定时器实现关闭应用后的提醒。当前提醒需求下，PWA 不作为优先候选。

### Windows 使用形态

用户已选择可收起的小窗口；建议优先验证尺寸和位置恢复、最小化及关窗行为。托盘和全局快捷键暂未纳入已确认范围。Tauri 官方全局快捷键文档使用桌面专用初始化，说明后续若增加此类入口，仍需分别处理平台能力。[文档](https://v2.tauri.app/plugin/global-shortcut/)

Flutter 官方提供 Windows 原生接口接入和分发指导；仍需按选定的功能验证实际实现。[文档](https://docs.flutter.dev/platform-integration/windows/building)

### 数据搬运

手动导出/恢复的基本路径较短；双端独立修改后的合并需要额外的冲突处理。这是需求和数据模型上的工程判断，不是框架自动提供的能力。

用户已选择整份恢复、替换前自动备份。因此当前重点转为文件校验、备份失败时中止、恢复回退，以及重复规则和历史记录的完整往返。

建议先定义数据格式与导入行为，再选择本地持久化库；不把整个数据库文件直接视作通用的跨版本备份协议。

## 5. 需要验证的假设

| 假设 | 如何验证 | 未满足时的调整 |
| --- | --- | --- |
| 单清单或“今天/全部”足以承载日常任务 | 用用户的三条真实待办走一遍低保真界面 | 只增加被真实任务证明必要的组织方式 |
| 勾选动效能让完成体验更愉快且不碍事 | 连续勾选、撤销、键盘操作和减少动态效果模式下试用 | 缩短或关闭动效，保留清晰状态变化 |
| 共用主要代码能覆盖两端核心流程 | 最小工程验证本地保存、文件往返和选定的平台入口 | 为必要的系统行为增加平台适配或调整方案 |
| 整份恢复可以安全完成数据迁移 | 用包含独有任务、重复规则和历史的样例检查替换前备份与回退 | 改善预览与恢复入口；需要合并或自动同步时重新规划 |

## 6. 调研限制

未测量任何方案的包体、内存或速度；提醒功能、Windows 小窗口、导入整份恢复及漏做不堆积均已确认。目标设备、提醒边界和交互细节仍待明确。当前资料足以讨论产品方向，不足以作出量化性能承诺或最终技术选型。
