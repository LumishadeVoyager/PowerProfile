# PowerProfile — CPU 电源模式自动切换器

Windows PowerShell 5.1 托盘工具。可放在任意本地目录；本机部署在 `E:\PowerProfile\`。

新版已提供轻量菜单、统一电源符号图标、按需实时状态窗口和分类设置；右键 **切换为旧版** 可使用独立保存的旧版代码与配置，旧版也有返回新版入口。工作时段额外省电仍未启用，保持已验证的电源行为。上线范围与回退细节见 [RELEASE.md](RELEASE.md)。

## 三个模式

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
3. 输出 "安装完成" 后, 右下角任务栏会出现一个**圆形彩色字母图标**:
   - 🟢 **I** = Idle 模式
   - 🔵 **B** = Balanced 模式
   - 🔴 **G** = Game 模式

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
