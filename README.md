# PowerProfile — CPU 电源模式自动切换器

部署位置: `E:\PowerProfile\`

## 三个模式

| 模式 | PERFBOOSTMODE | 最低频 | 最高频 | 频率上限 | 用途 |
|------|---------------|--------|--------|----------|------|
| **Idle** (静音) | 0 (关 Turbo) | 70% | 70% | ~1.82 GHz 锁定 | 日常使用，防崩，安静，省电 |
| **Balanced** (均衡) | 1 (保守 Turbo) | 40% | 100% | 按需 Turbo | 工作/写代码 |
| **Game** (游戏) | 2 (积极 Turbo) | 60% | 100% | 满血 4.9 GHz | 游戏/烤机 |

## 文件清单

```
E:\PowerProfile\
├── PowerProfile.ps1       # 核心 Worker — 接受 -Mode 参数切换
├── PowerProfileTray.ps1   # 托盘 GUI + 60s 自动检测
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

按设置里的间隔检测系统状态:
- 锁屏/刚开机未进入桌面时强制保持 **Idle** 模式
- 检测到全屏 3D 且存在真实 CPU/GPU 负载, 或后台持续高负载 → 自动切 **Game** 模式
- 前台是浏览器、Codex/IDE、Office、Steam 大屏幕、桌面外壳等硬排除 GUI 时, 即使全屏也不会切 **Game** 模式
- Wallpaper Engine、Edge WebView 和 Windows 开机组件的 GPU 占用不会单独触发 **Game** 模式，且不会提前解除开机静音保护
- 当前处于 **Game** 模式时, 鼠标/键盘/常见 XInput 手柄超过设置阈值无输入 → 临时强制 **Idle**; 输入恢复后切回之前模式
- 游戏退出后连续多次检测不到游戏 → 自动切回 **Idle** 模式
- 每次真正切换都会在 `profile.log` 记录原因, 包括前台 exe、top CPU/GPU 进程和负载数据

### 手动切换

- **左键单击托盘图标** → 开启/关闭 Auto 检测
- **右键单击托盘图标** → 弹出菜单, 选具体模式
- **双击托盘图标** → 打开切换日志

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

## 自动检测识别什么游戏?

检测不再依赖游戏进程白名单, 而是组合这些信号:

- 前台窗口是否全屏
- 前台进程是否加载 D3D/DXGI/Vulkan/OpenGL 模块
- GPU 3D、总 CPU、单核峰值是否持续较高
- 前台进程或 GPU 最高进程是否属于浏览器、Office、IDE、Steam 大屏幕、Codex、Wallpaper Engine、Edge WebView 等非游戏 GUI 黑名单
- 开机/锁屏保护是否仍在生效
- Game 模式中是否超过设定时间没有鼠标/键盘/XInput 手柄输入

如果某个软件全屏但 CPU/GPU 都很低, 会保持当前模式, 不会只因为全屏 D3D 就切到 Game。
浏览器、Codex/IDE、Office、Steam 大屏幕、桌面壳、Wallpaper Engine、Edge WebView 等硬排除进程即使全屏高负载也不会切到 Game。

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

## 跟死机防护的关系

**Idle (静音) 模式的核心目的**: 让 CPU 频率锁在 1.82 GHz, VID 稳定在约 1.05V 区间, **避开你 ThrottleStop 日志显示的崩溃高发区 1.19-1.24V**。
配合 powercfg 全局禁用 idle (CPU 不进 C-state), 这是软件层最强的防崩配置。

游戏时切到 Game 模式恢复满血性能, 因为 ThrottleStop 数据显示**重负载下反而不崩** (持续高 VID 远离 Vmin 阈值)。
