# 轻量托盘新版与旧版回退

## 本次上线范围

- 新版继续作为 Windows 托盘工具运行：原生紧凑菜单，统一颜色的电源符号图标，保留静音/均衡/游戏三档。
- 左键打开运行状态；右键打开菜单；双击仍打开日志。状态窗口展示 CPU、内存、GPU 3D/视频编码/计算活动、配置频率上限、无输入时间和游戏判断原因。
- 系统信息仅在状态窗口打开时每 5 秒采样，关闭后停止定时器；正在执行的只读采样可完成最后一次。数据缺失/过期显示“暂不可用”，不会显示为零。频率上限是请求值，不等于实测频率；无输入时长包含远程输入，不冒充已校准的本机离开时间。
- 新设置入口提供常规/省电计划/应用保护分类。原有档位和自动检测设置仍从“档位与自动检测设置...”打开。新增通知开关，游戏切换不弹浮窗；提示窗不会抢焦点。
- 工作时段附加省电暂未启用，页面清楚标注待确认。20 分钟、法定工作日、10:00–18:00 作为已确认需求展示，没有暗中降低 CPU 参数，也尚未实现日历、严格生产力保护与远程输入校准。
- 之前准备但尚未提交的游戏识别改进、隐藏 Worker 启动修复与对应测试一并提交。

## 随时切回旧版

新版右键菜单 → **切换为旧版**；旧版右键菜单 → **切换为新版**。也可从新版常规设置切换。

`legacy/` 保存本轮 UI 改动前的托盘、Worker、游戏检测和纯判断代码。只对旧托盘增加版本切换入口与启动成功标记；不替换旧版电源和识别核心。两版使用相同的单实例锁，因此不会同时运行两套自动调节器。

本机旧版 `legacy/settings.json` 是上线前配置快照，与新版根目录配置独立。旧版改设置不影响新版；新版改设置不影响旧版。它们及个人游戏路径、状态和日志均不上传 Git。新安装首次选择旧版时补齐本机快照，后续不覆盖已有快照。

`tray_version.txt` 保存成功启动的选择，登录启动器沿用此选择。切换先等待正在执行的电源 Worker 完成，不强杀正在运行的 powercfg，再重启 UI。新版本要写入带 PID 和版本的 `tray_ready.json` 才算启动成功；新版初始化失败或未就绪会尝试启动旧版。不能保证任何程序永不崩溃，运行期间若界面异常退出仍可通过命令行选择旧版。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\PowerProfile\_restart_tray.ps1 -Version Legacy
powershell -NoProfile -ExecutionPolicy Bypass -File E:\PowerProfile\_restart_tray.ps1 -Version Modern
```

已提权托盘里的版本切换不重新提权。普通终端直接运行重启脚本仍可能产生一次 UAC。登录启动沿用已注册的“PowerProfile Tray”高权限交互任务，不关闭系统 UAC。

本机如已安装同目录的该任务，也可通过其启动器处理一次性固定版本请求，避免重复提权：

```powershell
'Legacy' | Set-Content E:\PowerProfile\tray_switch_request.txt -Encoding ASCII
Start-ScheduledTask -TaskName 'PowerProfile Tray'
```

此文件只接受 Modern 或 Legacy，不接受命令或其他路径；任务本身必须指向本安装目录的 Start-Tray.vbs。没有任务时使用 Install.ps1 安装，需要一次管理员授权。

## 稳定性边界

这次 UI 上线未修改 `PowerProfile.ps1`、`PowerProfileLogic.ps1`、`PowerProfileDetection.ps1` 相对上线前的内容；测试核对其与旧版快照一致。当前本机原有三档频率、最低处理器百分比、Boost、EPP、自主调度和 C-state 设置保持。两版仍执行原有 Auto，游戏或锁屏状态变化可能按原规则切档。

新设置保存只写 UI 的通知开关；原设置保存保持已有高级字段。尚未确定的附加频率、保护应用名单和负载阈值不启用。默认不改睡眠、锁屏、网络、显卡或 UU 的输出策略，也不结束其他应用。

GPU 计数器按最繁忙物理引擎汇总，不将所有引擎简单相加。驱动/本地化系统不提供计数器时显示不可用。CPU 值采用 Windows 系统时间统计；禁用处理器闲置可能影响指标解释，不能用该数字估算瓦数或电费。

## 验证

```powershell
powershell -NoProfile -File .\tests\PowerProfileDetection.Tests.ps1
powershell -NoProfile -File .\tests\PowerProfileUI.Tests.ps1
```

包括原有游戏回归、版本选择持久化、原生图标、实际窗体创建与关闭、关闭后停止采样定时器、新设置不改变 CPU 配置，以及旧版核心快照保持一致。发布时还应执行新版→旧版→新版的本机就绪检查，并核对 C-state 和本机频率配置。
