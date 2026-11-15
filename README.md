# PowerProfile — CPU 电源模式自动切换器

Windows PowerShell 5.1 托盘工具。可放在任意本地目录；本机部署在 `E:\PowerProfile\`。

v1.6.0 新增全局液态玻璃皮肤，统一七页、卡片、图表、表格、菜单和应用弹窗；设置中可即时切回标准皮肤或经典毛玻璃。保留独立明暗 / 字号设置和 3:4 纵向窗口，以及 AI 历史与费用看板、游戏分析、米家设备和定时任务。详见 [工作台手册](WORKSPACE.md)、[AI 使用手册](AI_USAGE.md)。

## 下载与首次使用

从 [GitHub Release](https://github.com/LumishadeVoyager/PowerProfile/releases/latest) 下载正式 Windows ZIP，完整解压后用管理员 Windows PowerShell 运行 `Install.ps1`。新用户请先阅读 [使用手册](USER_GUIDE.md)；[v1.6.0 发布说明](RELEASE_NOTES_1.6.0.md) 包含本次功能与限制。首次运行有指南，无需米家插座也可使用电源档位。

正式分发版默认每 24 小时自动检查并下载稳定版，校验后下次启动托盘安装；源码 / Git 目录不被 OTA 覆盖。更新保留个人配置、授权、设备任务和历史。设置中的“使用指南与自动更新”可查看状态或关闭自动检查。私有仓库需授权访问，私有 OTA 另需 GitHub CLI 登录。

其他电脑默认关闭 **C-state 稳定性保护**，保留 Windows 原有 CPU 空闲设置；开启保护实际会禁用 CPU 空闲，需在独立窗口勾选理解确认，可能增加功耗和温度。已有本机设置不会被重置。详见 [C-state 说明](USER_GUIDE.md#3-c-state-稳定性保护默认关闭)。

新版提供轻量菜单、统一电源符号图标、按需实时状态窗口和分类设置，以及静音档上的工作时段附加省电。右键 **切换为旧版** 可使用独立保存的旧版代码与配置，切换前撤销附加限制。规则、稳定性边界和日志格式见 [RELEASE.md](RELEASE.md)。

设置页分为“常用设置 / 省电计划 / 高级与规则”。电费看板突出今日、本周、本月费用，同图显示费用（蓝）、唤醒且监测正常的时长（绿）、高功耗（橙）和游戏时长（紫）。历史游戏档会话可按日志补算，并标明游戏名称；据此推算的高功耗显示“估”，与 ≥150 W 实测区分。已知休眠区间被扣除，证据不足仍保留未知；不会据此增加电量或电费。日期附星期，周末突出。详细口径见 [ENERGY.md](ENERGY.md)。

用电卡片的“设备中枢”可集中查看其他米家设备、执行开关操作，并设置每日定时或时段内保持状态任务。FAKT Mesh 灯等设备通过已有米家云会话及网关接入；插座支持指定星期、单次日期、倒计时和时段内保持；电脑供电插座按实际设备标记，断电需明确确认，通断电不等于 Windows 开关机。用电看板顶部“插座开关与定时…”可直达中枢。中枢需要电脑唤醒、联网，关闭窗口不停止已启用任务；使用“暂停中枢”停止全部控制。范围及运行条件见 [DEVICES.md](DEVICES.md)。

## 三个模式

新版“设置 → 省电计划”提供日期、等待时长、CPU 上限和低负载确认的下拉选项。时间采用可直接输入小时、分钟的时钟控件，支持分钟精度；勾选“全天生效”可覆盖 00:00–24:00，并禁用自定义起止时间。“每天＋全天生效”允许每天任意时段进入省电，但仍须满足离开和低负载保护。旧配置沿用法定工作日、10:00–18:00、等待 20 分钟、至少 10 秒确认。自定义时段暂不跨午夜；结束时间 00:00 表示当天 24:00。每天/普通星期规则不依赖法定工作日日历。保存窗口明确持有配置文件路径，错误在窗口内显示并记录日志；校验失败不会部分写入配置。

用电监测已加入运行状态的合并概览；详情并列显示今日、本周和本月用电量及电费，保留功率曲线，并支持按日、周、月查看历史明细和已采集时长。本周从北京时间周一开始，本月按自然月统计；电费使用设置的固定电价，未采集周期不会显示为零。未授权时显示未连接，不使用示例读数。连接、估算口径及已知限制见 [ENERGY.md](ENERGY.md)。此模块不改动电源控制或 C-state，也不执行断电后自动休眠。

| 模式 | 默认 Boost | 默认 MHz 上限 | 用途 |
|------|------------|---------------|------|
| **Idle**（静音） | 0 | 1800 | 日常低功耗 |
| **Balanced**（均衡） | 1 | 3500 | 手动工作模式 |
| **Game**（游戏） | 2 | 4500 | 游戏性能 |

已有的 `settings.json` 优先于默认值，升级会保留本机频率配置。MHz 设置是上限请求，实际频率由处理器、Windows 和电源计划共同决定。

## 文件清单

```
E:\PowerProfile\
├── PowerProfile.ps1       # 核心 Worker — 接受 -Mode 参数切换
├── PowerProfileTray.ps1   # 托盘 GUI + 定时自动检测
├── PowerProfileLogic.ps1  # 游戏信号、会话与退出防抖的纯逻辑
├── PowerProfileDetection.ps1 # 游戏库发现、进程身份和本机会话
├── Analyze-Usage.ps1      # 只读分析历史切换日志
├── tests\                  # PowerShell 回归测试
├── Start-Tray.vbs         # 无窗口启动器
├── Install.ps1            # 一键安装 (创建开机自启)
├── Uninstall.ps1          # 一键卸载
├── current_mode.txt       # 当前模式状态 (运行时生成)
├── profile.log            # 切换日志 (运行时生成)
└── README.md              # 本文档
```

## 安装方法

1. **打开管理员 PowerShell** (Win+X → "终端 (管理员)")
2. 跑这条:
   ```powershell
   powershell -ExecutionPolicy Bypass -File E:\PowerProfile\Install.ps1
   ```
3. 输出 "安装完成" 后，右下角任务栏会出现电源符号图标，绿色为静音、蓝色为均衡、红色为游戏。

## 使用

### 自动模式 (默认)

按设置里的间隔检测系统状态：

- 锁屏时强制 **Idle**；解锁后仍执行开机静音保护，识别到实际游戏可解除保护。
- 自动读取 Steam 多磁盘游戏库和 Epic 本地安装清单。安装路径结合游戏自身 CPU/GPU 或 D3D 信号，可识别窗口化、2D 和无法枚举 D3D 模块的游戏。
- 库外全屏 D3D 应用需要自身 CPU/GPU 活动才能触发 **Game**，系统总负载不再直接充当游戏证据。
- 记住已确认游戏的 PID、创建时间和路径；同一游戏在前台时，暂停菜单、限帧和键鼠无输入都不触发降档。适用于 Xbox/XInput 和原生 HID 手柄场景。
- Alt-Tab 后默认保留 120 秒；之后游戏自身仍有 CPU 或 GPU 负载则继续 **Game**。浏览器或 ChatGPT 在前台不会否定后台游戏。
- 后台游戏长期低负载或已退出时，累计 `gameExitMissCount` 次后返回 **Idle**；重新切回仍存活的已确认游戏会立即恢复。
- 壁纸、Lossless Scaling、浏览器、启动器、反作弊辅助进程和崩溃报告器不能独自触发或维持游戏模式。排除规则针对候选进程，不否定其他游戏。
- 检测任务串行运行；检测状态采用原子写入。电源设置失败会记录 `worker_error.log`，不会写入成功状态。

CPU 的 `ownCPU` 使用单核等效百分比（100% = 一个逻辑核满载），避免多核电脑上总 CPU 占用偏低而漏判游戏。GPU 的 `ownGPU` 使用该进程最繁忙 3D 引擎的采样均值。它们用于判断活动，不用于 FPS 或游戏时长统计。

### 本机个性化与扩展

在 `settings.json` 中添加以下可选配置；设置窗口保存时会保留这些字段：

```json
{
  "processorBaseMHz": 0,
  "detection": {
    "discoverSteam": true,
    "discoverEpic": true,
    "backgroundGraceSec": 120,
    "gameProcesses": ["YourGame.exe"],
    "excludeProcesses": ["YourHelper.exe"],
    "gameRoots": ["D:\\Games\\YourGame"]
  }
}
```

- `gameProcesses`：精确进程名，忽略大小写及 `.exe` 后缀；用于没有标准启动器、路径不可读或模块受保护的游戏。内置辅助程序排除及 `excludeProcesses` 优先。
- `gameRoots`：具体游戏安装目录，包含其子目录；不要填写整个磁盘或通用软件下载目录。新安装的 Steam/Epic 游戏会在后续检测中自动发现，无需维护名称列表。
- `backgroundGraceSec`：0–900 秒，默认 120。修改后下一轮检测生效。
- `processorBaseMHz`：默认为 0，仅使用 MHz 上限和配置的最大处理器百分比；经本机校准后可填写基频，用于低于基频的百分比限频。不会将某一款 CPU 的 2600 MHz 基频强加给其他电脑。

进程规则、安装路径、日志和会话文件仅保存在本机，并由 `.gitignore` 排除。程序不会自动把历史误判学习为永久游戏规则，也不会按某个时段猜测你正在玩游戏。

### 手动切换

- **左键单击托盘图标** → 打开运行状态（旧版仍切换 Auto）
- **右键单击托盘图标** → 弹出菜单, 选具体模式
- **双击托盘图标** → 打开切换日志
- 新版右键菜单的“自动切换”管理 Auto；“切换为旧版”独立回退，并记住下次登录的版本。

### 设置

右键托盘图标 → **设置...**:
- 三个模式的频率上限使用预设挡位, 不需要手填 MHz
- 自动检测、人离开判定、提示时长、手动锁定恢复、游戏空闲静音、游戏退出防抖都使用易懂挡位
- 如果 `settings.json` 里已有自定义数值, 设置窗口会显示为"当前自定义", 保存时会保留该值
- `settings.json` 是本机运行配置, 不再提交到仓库; 仓库里保留 `settings.example.json` 作为参考

### 命令行调用 (高级)

```powershell
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Idle
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Balanced
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Game
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Auto
```

## 诊断与验证

```powershell
# 只读查看当前判断、识别规则及安装库；不切换模式、不更新会话或开机保护
powershell -NoProfile -File .\PowerProfile.ps1 -Diagnose

# 只读统计本机历史日志；进程出现次数不是游玩时长
powershell -NoProfile -File .\Analyze-Usage.ps1

# 不启动游戏、不调用 powercfg 的回归测试
powershell -NoProfile -File .\tests\PowerProfileDetection.Tests.ps1
```

测试覆盖缺失 D3D、窗口化游戏、手柄/低负载菜单、Alt-Tab、后台游戏负载、退出防抖、PID 复用、目录边界、损坏状态和设置保存。GitHub Actions 在 Windows PowerShell 5.1 上执行同一组测试。

双击托盘图标打开 `profile.log`。当前检测原因另存于 `game_detection_state.json`，会话身份保存在 `game_session_state.json`。高频 `unlock_debug.log` 超过 2 MB 后保留一份轮转文件，避免无限增长。

多显示器检测使用窗口所在屏幕的边界，参见 [Screen.FromHandle](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.screen.fromhandle)。进程 GPU 活动采用最繁忙引擎思路，参见 [Microsoft GPU performance counters](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/)。

## 故障排查

### 托盘图标没出现

```powershell
# 手动启动一次
wscript.exe E:\PowerProfile\Start-Tray.vbs

# 看进程在不
Get-Process powershell, wscript | Where-Object { $_.CommandLine -like '*PowerProfile*' }
```

### 模式切换不生效

```powershell
# 看当前 powercfg 配置
powercfg /Q SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 | findstr "当前"
powercfg /Q SCHEME_CURRENT SUB_PROCESSOR | findstr "PROCTHROTTLE" -A 2
```

### 看切换日志

打开 `E:\PowerProfile\profile.log`, 或托盘图标双击

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File E:\PowerProfile\Uninstall.ps1
```

会:
- 删除开机自启任务
- 停止托盘
- 恢复 Windows 默认电源设置 (Boost=2, Min=5%, Max=100%)
- 文件夹本身保留, 可手动删

## 本机频率调校

原有频率档位用于本机的静音和稳定性调校，本次识别升级不主动提高这些档位。电源策略只能调节性能与功耗，不能据此确认硬件崩溃的原因，也不能保证解决硬件稳定性问题。

升级推送后运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\_restart_tray.ps1`，让托盘加载新逻辑。重启脚本只停止本安装目录启动的托盘/Worker/VBS，不处理无法识别来源的 PowerShell 进程；需要时由 Windows 请求管理员权限。
# 概览主界面

自动切换恢复原来的游戏检测方案：日常使用静音，确认游戏后进入游戏档，退出游戏沿用原确认次数并回到静音。普通 CPU 占用、单核压力、视频编码或工作 GPU 占用不再自动触发均衡或高性能。均衡保留为手动档位，手动锁定仍优先。

设置 → 自动切换说明当前规则，不再显示已撤回的通用负载升档阈值。原游戏识别、安全启动、检测失败保持档位及自动检测间隔保持不变。深度省电继续采用原附加省电计划及严格游戏/负载保护。现有配置中的旧 `autoLoad` 字段不再参与决策；CPU 频率、C-state 稳定参数和其他功能不受这次回退影响。

自动检测采样已恢复到新增均衡策略前的 `64c0231` 版本，取消扩展工作 GPU 和单核升档采样。档位设置窗口的保存回调使用窗口上下文，修复从概览打开时找不到 `Get-PresetValue`、所选频率未落盘的问题；保存失败会明确提示。`tests/PowerProfileSettings.Tests.ps1` 通过实际窗口事件验证 2000/1600/2200 MHz 的保存及 Worker 派发。静音频率保持本机配置，回退不会重置 C-state、游戏无上限或用电监测数据。

托盘左键打开概览：顶部直接控制自动切换和静音、均衡、游戏档位，当前档位高亮；底部可打开设置和日志。更多操作包含附加省电开关、当天暂停、切换旧版和退出。收起只关闭概览窗口，托盘继续运行。所有操作与托盘右键菜单共用处理逻辑。
