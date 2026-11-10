# 小事星球 · 轻量离线待办

面向个人工作和生活的 Windows / Android 小工具。用泡泡、纸片和卡牌整理小事，默认泡泡；越重要、越紧急，泡泡越大。提供可选运动节奏、完成与撤销、日期提醒和每日/每周重复。

2026-11-10：当前候选版 **1.0.0-rc.6+8**。Windows 新增“仅显示待办”和“窗口置顶”，两者独立选择并记住；简洁模式隐藏标题和控制栏，保留拖动、小菜单及快捷键。个人离线功能包括三种展示、搜索概览、提醒与重复、历史和撤销、安全恢复、窗口记忆和安全退出、可见失焦继续运动、长标题全文查看。共用 Flutter 界面与本地数据模型，Windows 托盘 / Android 系统闹钟；手动导出和整份恢复，恢复前备份。Android 15 / Windows 10/11 原生送达、真机覆盖升级及连续使用尚未完整验收，因此保留候选版标记，详情见验证记录。旧版本包保留。

- `dist/`：本地交付安装包及 Windows 便携目录，不提交 Git。
- [使用说明](docs/user_guide.md)：安装、交互、提醒和备份。
- [构建说明](docs/build.md)：固定环境、构建和测试命令。
- [验证记录](docs/validation.md)：测试证据与仍需真机验证的范围。
- [版本记录](docs/changelog.md)：每轮变更和升级说明。
- [性能记录](docs/performance.md)：固定样本优化对照与 Windows 本机测量边界。
- [后续路线](docs/roadmap.md)：真机可靠性、交互打磨、性能与升级、稳定版的推进顺序。
- [详细开发计划](docs/development_plan.md)：逐批任务、依赖与验收条件；[工作记录](docs/progress/work_log.md) 跟踪实际进度。
- `src/small_orbit/`：Flutter 应用与 Android/Windows 原生集成。
- `scripts/`：工具链准备、构建、打包和几何图标生成。
- `docs/`：需求、调研、实施记录和 Flutter 渲染预览。

主要使用环境：Android 15、Windows 10/11 x64；最低 Android 8.0。首版不含账号、在线同步或订阅服务。

决策见 [调研](docs/research.md)、[需求](docs/requirements.md)、[展示设计](docs/interface_directions.md) 和 [实施计划](docs/implementation_plan.md)。
