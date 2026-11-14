# MacPowerTemp

一个占用**一格**菜单栏的功耗 + 温度监视器。两个数值上下叠在同一格里，不需要 Dock 图标，不需要 root 权限。

```
┌──────────┐
│  8.6W    │   ← 整机功耗
│  40°     │   ← SoC 最高温
└──────────┘
```

## 安装与编译

```bash
git clone https://github.com/Rengwang/MacPowerTemp.git
cd MacPowerTemp
./build.sh
cp -R MacPowerTemp.app ~/Applications/
open ~/Applications/MacPowerTemp.app
```

> **固定本地签名（推荐）**：`build.sh` 会优先查找钥匙串中的代码签名证书 `MacPowerTemp Local Signing`（也可通过环境变量 `MACPOWERTEMP_SIGN_IDENTITY` 指定）。在「钥匙串访问」创建自签名代码签名证书后，后续重新编译覆盖安装可保留「录屏」和「辅助功能」等 TCC 权限，无需每次重新授权；若本地无证书会自动回退到临时签名。

## 数据从哪来

| 显示项 | 数据源 | 说明 |
|---|---|---|
| 功耗 | AppleSMC `PSTR` | 系统总功耗（W），**与 Stats 的 “System Total” 同源同值**，每秒真实刷新 |
| 芯片当前 | AppleSMC `PZC0` | 菜单内与整机功耗并排显示；仅打开菜单时立即读取并随刷新频率更新，关闭即停止。不可用显示 `—`，不使用目标值或整机读数代替 |
| 温度 | IOHID `AppleVendor` 温度传感器 | 取所有 SoC 裸片传感器（`PMU tdie*` 等）中的**最高值** |

两条通路都不需要 sudo。

芯片当前功耗使用 SMC 芯片封装传感器口径，不等同于 `powermetrics` 的 CPU+GPU+ANE 能耗之和，也不代表芯片目标已生效（实测在 Apple Silicon 上可读取 `PZC0` 且随负载变化；不同机型的传感器定义可能不同）。实现前参考了 [macmon 的 IOReport 采样](https://github.com/vladkens/macmon/blob/main/src/sources.rs) 和 [SiliconScope 的 PZC0 方案](https://github.com/kennss/SiliconScope/blob/main/CHANGELOG.md)；若部分机型旧 Energy Model CPU 通道恒为零，不将其作为当前功耗显示。此功能复用现有 SMC 连接与刷新节拍，不增加后台进程或定时器。

验证菜单开关采样与读数文案：`./MacPowerTemp --test-chip-power`。命令行查看芯片读数：`./MacPowerTemp --dump-readings --include-chip`（该诊断选项显式模拟菜单打开）。

### 为什么不用系统自带的电池遥测

`AppleSmartBattery → PowerTelemetryData → SystemLoad` 也能读到整机功耗，数值接近，但实测**约 18 秒才跳一次**（阶梯值），做实时显示会看起来卡住。所以只用它做 `PSTR` 读取失败时的兜底。

### 为什么温度和 Stats 对不齐

Stats 会把传感器重映射成 “CPU super core 1 / performance core 2” 这类自定义名字，再分组算平均。本程序不猜映射关系，直接报 **最高的那一个裸片传感器**——即“芯片最热的地方现在多少度”，这也是判断散热与降频风险最直接的口径。

## 菜单里能做什么

- **功耗 / 电池 / 温度 / 传感器**：实时明细（含取样传感器名、供电方式）
- **芯片目标（滑块 + 快捷预设）**：设置 SoC 封装功率目标；数值只读，不再弹出手动输入框
- **超省电模式**：比系统「省电模式」（~4W）更省电（~2W SoC + 2W GPU 限制 + 系统省电模式）
- **一键恢复**：随时一键还原原厂未限功率状态、GPU 上限与省电模式
- **iPad 随航（原生横屏 + HiDPI 竖屏 + 触控手势）**：未连接时可一键直连系统**原生横屏随航**（零虚拟屏、无需录屏权限与额外开销），或启动 **HiDPI 2.0x 竖屏**（支持 4 档自适应分辨率、180° 方向翻转、左右位置切换、防光标误触、全局快捷键 `Ctrl+Opt+V` 以及单指点按/拖拽/滚动与双指捏合缩放/旋转/右键等原生触控手势）
- **盒盖不休眠**：合盖后屏幕变黑但系统继续运行，AI 任务不会被打断（详见下节）
- **状态符号**：第一行功率后显示限制状态（`↓` 已限功率 / `✧` 超省电），第二行温度后显示休眠状态（`⏾` / `⚠`）
- **免密码授权（含功率调节）**：一键安装 root 只读助手与精确 sudoers 规则，之后切换与调功率均不再弹密码框
- **字号**：小 9.5 / 中 10.5 / 大 12（默认大，粗体数字）
- **配色**：三档，见下表
- **刷新频率**：1 / 2 / 5 秒
- **登录时启动**：写入 `~/Library/LaunchAgents/com.workbuddy.macpowertemp.plist`
- **退出**

## 功率上限控制与超省电模式

基于 Apple Silicon CLPC（`AppleCLPC` / `~pkg-avg-therm-power-target` Q8.24 定点数）与 GPU `AGXAccelerator`（`SetMaxGPUAbsolutePower`）实现内核级动态功率上限控制（架构思路参考自开源项目 [maderix/apple-gpu-dvfs](https://github.com/maderix/apple-gpu-dvfs) 并在 M5 上完成校准）：

- **调节芯片目标**：支持 **8 / 10 / 12 / 15 / 20 W** 快捷档位、**1.0 ~ 25.0 W（步进 0.5 W）滑块**。右侧只显示选中的瓦数，拖动后可点击「应用」。芯片目标不等同于整机功耗上限。
- **超省电模式**：将 SoC 封装上限降至 **2.0 W**、GPU 功率上限降至 **2.0 W**，同时开启系统 `lowpowermode`。实测相比单纯开启系统「省电模式」（约 4 W）整机空载/轻载功耗可进一步降低约一半，日常文字/网页仍可保持 E 核流畅运行。
- **一键恢复**：点击「一键恢复」即可将 `` `pkg-avg-therm-power-target `` 还原为未限制（`-16777216`）、还原 GPU 功率上限（如 `24240 mW`）及原本的系统省电模式开关。
- **状态栏徽标**：第一行功耗右侧自动显示单色徽标——`↓`（`U+2193`）表示已设置功耗上限，`✧`（`U+2727`）表示超省电模式已激活。
- **退出兜底**：与 `disablesleep` 一样，CLPC/GPU 功率限制属于内核级状态；退出程序前若仍处于限功率或超省电状态，会弹窗提示是否一键恢复原厂设置后退出。

### 免密码授权说明

在菜单中点击「免密码授权（含功率调节）」（若此前装过旧版则会显示为「升级免密码授权（含功率调节）」），会弹出一次系统授权窗口：
1. 将编译好的原生 C 辅助工具安装到 `/Library/PrivilegedHelperTools/com.workbuddy.macpowertemp.ctl`（`root:wheel`，`0755`，普通用户不可篡改）。
2. 在 `/etc/sudoers.d/macpowertemp` 写入无通配符的精确规则（`<username>` 为当前 macOS 用户名）：
   ```
   <username> ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /Library/PrivilegedHelperTools/com.workbuddy.macpowertemp.ctl
   ```
未安装免密码规则时，每次调节功率/超省电/一键恢复会自动回退到 macOS 管理员授权弹窗，功能同样可用。

## 盒盖不休眠

勾选后合上盖子：屏幕黑，但系统不休眠，本地 AI 任务、下载、SSH 会话继续跑。取消勾选恢复「合盖即休眠」。

### 温度后面的状态符号

第二行温度数字后面跟一个符号，直接反映当前休眠状态，**颜色与温度数字完全相同**：

| 符号 | 字符 | 含义 |
|---|---|---|
| ⏾ | `U+23FE` POWER SLEEP（月牙） | 休眠正常 · 合盖即休眠 |
| ⚠ | `U+26A0` WARNING（三角感叹号） | 休眠已禁用 · 合盖继续运行 |

两个都刻意选**单色字形**而非彩色 emoji：彩色 emoji（如 💤）不响应 `foregroundColor`，会固定显示蓝紫色，在中灰菜单栏上几乎看不见；单色字形则跟随前景色，在单色模式下还能随菜单栏深浅自动反色。

状态每 5 秒优先通过内核 IORegistry（`IOPMrootDomain.SleepDisabled`，不可用时回落至 `pmset -g`）回读一次，所以被别的程序（AI 工具、终端手输命令）改掉时，符号也会跟着变。

### 为什么不能用 caffeinate

Apple 在 `IOPMLib.h` 里写明了 `kIOPMAssertPreventUserIdleSystemSleep`「may still sleep for lid close, Apple menu, low battery」——**用户态断言挡不住硬件盒盖事件**。所以 `caffeinate`、以及包装它的 KeepingYouAwake 都无法在合盖时保持唤醒（后者 README 也明确声明不支持闭合盖子）。

能挡住盒盖的是内核的 `SleepDisabled` 标志，即：

```bash
sudo pmset -a disablesleep 1   # 开启（合盖不休眠）
sudo pmset -a disablesleep 0   # 恢复
pmset -g | grep SleepDisabled  # 查看当前状态
```

本程序用的就是它，在 Apple Silicon 上原生生效，盒盖与电池供电都能挡住。菜单里的勾选状态是**每次打开菜单时从系统实读**的，不会显示与真实状态不符的假象。

### 需要管理员权限

`pmset` 改电源设置必须 root，所以有两条路径：

1. **系统授权弹窗**（默认）— 每次切换弹一次密码框。
2. **免密码切换**（可选）— 菜单里勾选后，会弹一次授权窗口，把下面这条规则写入 `/etc/sudoers.d/macpowertemp`：

   ```
   <username> ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
   ```

   sudoers 按字面匹配命令、**不支持通配符**，所以这条规则只能用于切换盒盖不休眠，无法被挪作他用。随时可在菜单里取消勾选移除。

   写入前会用 `visudo -cf` 校验语法，校验不过就不落盘。若 `/etc/sudoers.d` 未被主配置引入，程序会自动回落到授权弹窗，不会卡死。

### 注意

- 这是**系统级开关**，会禁用全部休眠，不只是盒盖。期间苹果菜单里的「睡眠」也不可用。
- 开关不随进程消失：退出程序不会自动关闭。因此**退出时会弹确认**，可选择「恢复正常休眠并退出」。
- 电池供电时持续耗电，合盖放在包里还会发热。建议插电使用，用完及时关掉。
- 手动兜底命令：`sudo pmset -a disablesleep 0`

数值做了指数平滑（功耗 α=0.3，温度 α=0.5），菜单里显示的是原始瞬时值。

## 配色为什么这么设

菜单栏底色（实测 `#95A5B3`，相对亮度 0.37）是**中灰**，这是最尴尬的一档：纯黑能到 8.35:1，纯白只有 2.52:1，而任何饱和色系都掉到 2:1 以下。

| 方案 | 对比度 | 结论 |
|---|---|---|
| 青色字 `#00C7BE`（旧默认） | **1.19 : 1** | 基本看不见，这是「彩色看不清」的真正原因 |
| 蓝色字 `#007AFF`（旧默认） | 1.60 : 1 | 同样偏弱 |
| 单色（模板图，系统反色） | 2.52 : 1（本机为白字） | 可读，跟随系统 |
| 色块（黑字 + 彩底） | **8 ~ 10 : 1** | 最清晰，且颜色面积大、情绪最强 |

所以：

- **单色（最清晰）** — 默认。交给系统渲染模板图，深浅菜单栏都会自动反色，永不出错。
- **彩色文字（对比弱）** — 保留旧观感，改为暖色（琥珀 + 绿/橙/红，避开与蓝灰底色同色系的冷色），但对比度仍在 1.5 : 1 左右，只适合当装饰。
- **色块（黑字彩底，最醒目）** — 推荐给想要颜色又要看清的场景：颜色放在底块上，文字压纯黑，对比 8:1 以上。

## 应用图标

Finder / 启动台 / 「显示简介」里显示的图标。构图是**温度计 + 闪电**：左边白色管身 + 琥珀液柱代表温度，右边金色闪电代表功耗，坐在深色 squircle 上（系统圆角 22.37%），底部一层暖光呼应「热」的主题。

尺寸覆盖 16–1024px 全套，已验证 32px 以下仍能分辨出两个主体。

重新生成（改 `make_icon.swift` 后）：

```bash
swift make_icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns
./build.sh && pkill -f MacPowerTemp.app; cp -R MacPowerTemp.app ~/Applications/ && open ~/Applications/MacPowerTemp.app
```

执行 `make_icon.swift` 会临时生成 `icon_1024.png`、`icon_preview.png` 与 `AppIcon.iconset/` 供多尺寸检查与打包 `AppIcon.icns`（已纳入 `.gitignore`）。

## 已知限制

- `PSTR` 与 IOHID 温度传感器都是 Apple 私有接口。系统大版本升级后若失效，重新运行 `./build.sh` 通常即可（失效时菜单里会显示 `--`）。
- 整机功耗包含屏幕、SSD 等全部子系统；若想对比「芯片功耗」这个口径，数值会明显更低。
- 目前只做了功耗与温度。开箱即用的 CPU/GPU 占用率不在范围内。
- **随航竖屏与触控权限**：基于 `CGVirtualDisplay`（参考开源项目 [drealdeal/ipad-vertical](https://github.com/drealdeal/ipad-vertical)、[TTSoong/StripRotate](https://github.com/TTSoong/StripRotate) 与 [DeskPad](https://github.com/Stengo/DeskPad)）与 `ScreenCaptureKit` 零拷贝 `IOSurface` + 硬件旋转 `CALayer` 实现；未开启竖屏时零额外后台采集开销。首次启用竖屏需在「系统设置 → 隐私与安全性 → 录屏与系统录音」允许 `MacPowerTemp`，启用触屏与手势重映射需授权「辅助功能」。

## 卸载

```bash
pkill -f MacPowerTemp.app
rm -rf ~/Applications/MacPowerTemp.app
rm -f ~/Library/LaunchAgents/com.workbuddy.macpowertemp.plist
```

## 源码结构

```
bridge.h                ObjC/C 总桥接头文件：引入 sensors.h 与 CGVirtualDisplay 私有声明
sensors.h / sensors.c   C 桥接层：IOHID 温度、SMC 功耗、CLPC/AGX 上限与 SleepDisabled 查询
powerctl.c              原生特权助手：IOKit CLPC / AGX 功率上限写入、超省电与恢复
SidecarBridge.swift     SidecarCore 私有框架封装、iPad 规格探测与 HiDPI 竖屏预设计算
SidecarController.swift 虚拟屏管理、ScreenCaptureKit 零拷贝采集、多指触控识别、防误触守护与热键
SidecarControlView.swift 菜单内嵌随航竖屏控制卡片（与功率控制面板同套深浅色视觉规范）
main.swift              NSStatusItem 界面、两行位图绘制、功率控制面板、菜单与登录项
make_icon.swift         应用图标生成器（CoreGraphics 矢量绘制）
AppIcon.icns            16–1024px 全套图标
Info.plist              LSUIElement = true（不占 Dock）
build.sh                一条命令产出并签名 MacPowerTemp.app（含 powerctl）
.gitignore              忽略编译产物、临时图标中间文件与系统元数据
```
