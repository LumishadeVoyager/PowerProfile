# PowerProfile 交付约定

- 项目代码、测试、文档及发布流程必须同步到 GitHub；完成本地修改不代表交付完成。
- 每次功能或修复交付，应运行相关回归检查、提交并推送至项目仓库；涉及可安装程序变化时，更新版本及发布说明，构建并发布 GitHub Release（Windows ZIP 与 SHA256 文件），核验远端提交、Release 附件及 GitHub Actions。
- 推送后重启本机托盘，核验 `tray_ready.json`、`tray_lifecycle.log` 中的新进程及功能初始化状态；最终回复提供提交和 Release 链接，并明确尚未实测的项目。
- 配置、凭据、设备身份、个人数据、运行日志和历史数据库继续保留在本机，遵守 `.gitignore` 和发布包白名单，不上传到 GitHub。
- 保留 C-state 稳定性设置；不增加转电池自动休眠。原有用户改动应先审查，避免覆盖。
