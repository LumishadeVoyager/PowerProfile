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

每 60 秒检测一次系统状态:
- 检测到游戏进程或 GPU 占用 >30% → 自动切 **Game** 模式
- 游戏退出 → 自动切回 **Idle** 模式 (只在之前是 Game 时切回)

### 手动切换

- **左键单击托盘图标** → 立刻 Auto 检测
- **右键单击托盘图标** → 弹出菜单, 选具体模式
- **双击托盘图标** → 打开切换日志

### 命令行调用 (高级)

```powershell
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Idle
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Balanced
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Game
powershell -File E:\PowerProfile\PowerProfile.ps1 -Mode Auto
```

## 自动检测识别什么游戏?

`PowerProfile.ps1` 里的 `$gameKeywords` 数组定义:

- Steam, Epic, GOG, Battle.net 启动器
- 主流游戏: CS2, Valorant, LOL, Dota2, R6, 原神, PUBG, GTA, Cyberpunk, Witcher, Elden Ring, Sekiro, Minecraft 等
- Unreal/Unity 引擎进程
- 路径含 `steamapps\common\`, `Epic Games\`, `GOG Games\` 的进程
- GPU 3D 引擎占用 > 30%

**添加新游戏**: 编辑 `PowerProfile.ps1` 的 `$gameKeywords` 数组, 加入进程名关键词。

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
