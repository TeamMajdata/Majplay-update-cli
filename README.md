# MajdataPlay Updater（Windows）

一个单文件 PowerShell 更新器：自动检查 [TeamMajdata/MajdataPlay](https://github.com/TeamMajdata/MajdataPlay/releases) 的 **稳定版 / nightly**，有新版本时下载、校验、覆盖安装，然后启动游戏。

- 优先使用系统代理；没有可用系统代理时自动走 `gh-proxy.org` 等 GitHub 镜像；最后才尝试直连。
- 默认只覆盖游戏程序文件，**保留 `MajdataPlay_Data\StreamingAssets` 中已存在的文件**；新文件仍会补齐。加 `-OverwriteStreamingAssets` 才会覆盖。
- 默认在竖屏 16:9 显示器上绘制全屏 GUI（白色背景、天蓝色文字）：圆直径等于屏幕宽度（1080×1920 上为 1080 px，4K 及其他 9:16 分辨率按比例缩放），所有输出都放在圆内；不满足条件时自动回退到命令行。
- 更新完成后自动启动 `MajdataPlay.exe`，核验游戏窗口已出现并置于前台后再退出。
- **首次运行**（安装目录中没有游戏文件）会弹出小窗口，让用户选择 `Stable` 或 `Nightly`，并把 `channel` 字段写入 `.majdataplay-updater.json`；后续直接使用保存的通道。
- 游戏默认安装到 `<脚本目录>\MajdataPlay\`；下载的 ZIP 也放在该目录，**解压完成后立即删除 ZIP**，避免占用空间；不使用 `%LOCALAPPDATA%` 或其它外部缓存目录。
- **更新器自更新**：从 `TeamMajdata/Majplay-update-cli` 的 `main` 分支检查脚本新版本，校验后替换自身并用原参数重启。

---

## 环境要求

- Windows 10 / 11 x64
- Windows PowerShell 5.1（系统自带）或 PowerShell 7+
- 安装目录有写权限。安装在 `Program Files` 等受保护目录时，请以管理员身份运行。

## 快速开始

把 `Update-MajdataPlay.ps1` 放在任意可写目录（默认游戏会安装到同级的 `MajdataPlay` 文件夹），然后双击 `Start-MajdataPlay-Updater.cmd`，或在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-MajdataPlay.ps1
```

默认目录结构：

```text
<脚本目录>\
├─ Update-MajdataPlay.ps1
└─ MajdataPlay\              # 游戏安装目录
   ├─ MajdataPlay.exe
   ├─ MajdataPlay_Data\
   ├─ staging\               # 仅解压期间存在
   └─ .majdataplay-updater.json
```

如果脚本本身已经位于名为 `MajdataPlay` 的文件夹中，则直接使用该文件夹，不会再多套一层。若已有游戏在脚本同级目录、想继续使用它，请显式传：

```powershell
.\Update-MajdataPlay.ps1 -InstallPath '<旧游戏目录>'
```

### 常用示例

```powershell
# 更新到最新稳定版（默认）
.\Update-MajdataPlay.ps1

# 更新到 nightly
.\Update-MajdataPlay.ps1 -Channel Nightly

# 只检查、不下载、不安装、不启动
.\Update-MajdataPlay.ps1 -CheckOnly

# 强制重新安装当前通道的最新包
.\Update-MajdataPlay.ps1 -Force

# 覆盖已有的 StreamingAssets 文件
.\Update-MajdataPlay.ps1 -OverwriteStreamingAssets

# 指定安装目录，强制使用命令行
.\Update-MajdataPlay.ps1 -InstallPath 'D:\Games\MajdataPlay' -NoGui

# 使用本地 HTTP 代理
.\Update-MajdataPlay.ps1 -Proxy 'http://127.0.0.1:7890'

# 不使用系统代理，只走镜像
.\Update-MajdataPlay.ps1 -NoProxy

# 自定义镜像顺序（会替换默认镜像列表）
.\Update-MajdataPlay.ps1 -Mirror 'https://gh-proxy.org','https://ghproxy.net'
```

## 启动菜单

每次正常启动更新器（未指定 `-CheckOnly` / `-SkipBootMenu`）时，会先显示 BIOS 风格的启动菜单，倒计时 **5 秒**：

- 无键盘操作 → 使用上次保存的引擎继续更新和启动，默认 `D3D12`。
- 键盘操作后倒计时停止，等待确认。

可用按键：

| 按键 | 作用 |
| --- | --- |
| `↑` / `W` / `Q` | 向上选择 |
| `↓` / `S` / `Z` / `X` | 向下选择 |
| `Enter` / `C` | 确认 |
| `Esc` | 跳过菜单，使用默认项 |

菜单项：

| 启动项 | 启动参数 |
| --- | --- |
| D3D12（默认） | `-force-d3d12` |
| D3D11 | `-force-d3d11` |
| Vulkan | `-force-vulkan` |
| OpenGL | `-force-glcore` |
| 测试模式 | `--test-mode` |
| 稳定版 Stable | 写入 `channel=stable` |
| Nightly | 写入 `channel=nightly` |

选择启动项后会把引擎写入 `.majdataplay-updater.json` 的 `engine` 字段，下次菜单会自动选中；默认使用 `d3d12`。选择通道项会更新 `channel` 字段并继续流程。

竖屏 16:9 显示器上，启动菜单绘制在与主 GUI 相同的底部内接圆内；`-NoGui` 或没有合适显示器时使用控制台菜单。

## 首次运行与通道设置

当安装目录中还没有 `MajdataPlay.exe` / `MajdataPlay_Data` 时，脚本会弹出一个小窗口。如果检测到竖屏 16:9 显示器，窗口会按分辨率缩放，并放在屏幕下半部分、与主 GUI 圆相同的圆心位置；否则居中显示在主显示器上。

- **稳定版 Stable**：正式发布版，经过测试，更新节奏较慢，更适合日常游玩。
- **Nightly 预览版**：滚动构建，更新更快，包含最新功能和修复，但可能不稳定，适合尝鲜。

选择结果只写入同一个状态文件：

```text
<安装目录>\.majdataplay-updater.json
```

通道由 `channel` 字段记录，启动引擎由 `engine` 字段记录：

```json
{
  "channel": "nightly",
  "engine": "vulkan"
}
```

后续启动会读取这些字段，不会再次询问通道；安装完成后该文件还会记录版本、commit、SHA256 等安装信息，但通道始终只由 `channel` 字段表示。也可以在命令行显式覆盖并更新该字段：

```powershell
.\Update-MajdataPlay.ps1 -Channel Nightly
.\Update-MajdataPlay.ps1 -Channel Stable
```

使用 `-NoGui` 时不会显示小窗口，而是在控制台询问；非交互环境请直接传 `-Channel`，避免等待输入。

## 更新判定

版本信息优先从 GitHub 的 Atom feed 获取，失败时再请求 API；资源列表从 releases 的 assets 页面获取，页面不可用时会尝试 API 资源信息，最后才使用约定的 Windows 包文件名。

本地版本从以下位置读取：

1. `MajdataPlay_Data\globalgamemanagers` 中的 `x.y.z-YYYYMMDD-commit` 构建版本号；
2. 如果读不到，则读取安装目录下的 `.majdataplay-updater.json`。

判断规则：

- **Stable**：比较版本号；同版本号但 commit 不同也视为新的重新构建。
- **Nightly**：比较 commit（短哈希）；nightly 每次发布都会替换 release，commit 不同即更新。
- 本地版本高于稳定版（例如正在用 nightly）时默认不降级；如需切回稳定版，使用 `-Channel Stable -Force`。
- `-Force` 强制重新安装（若上次在安装阶段失败、留下了通过校验的下载包，会直接复用）。
- 安装完成后会写入 `.majdataplay-updater.json`，记录通道、tag、版本、commit、资源 SHA256 和安装时间。

## 代理与镜像

请求按以下顺序尝试：

1. **系统代理**：读取 WinINET（Internet 选项）的 `ProxyEnable` / `ProxyServer`，支持 PAC、`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 环境变量。
2. **镜像**：默认依次为
   - `https://gh-proxy.org`
   - `https://ghproxy.net`
   - `https://gh-proxy.com`
   - `https://github.moeyy.xyz`
3. **直连**：以上都失败时尝试。

`-Proxy` 可以指定代理并跳过自动检测；`-NoProxy` 完全禁用代理；`-NoMirror` 禁用镜像。镜像只影响下载线路，安装内容仍然来自 Release 中的 Windows 包。

## StreamingAssets 的处理

Unity 的 StreamingAssets 位于：

```text
MajdataPlay_Data\StreamingAssets\
```

默认安装规则：

- 目标文件**已存在** → 跳过，不覆盖。
- 目标文件不存在 → 复制新文件。
- 其他目录（`MajdataPlay.exe`、`MajdataPlay_Data` 下的程序资源等）正常覆盖。

加 `-OverwriteStreamingAssets` 后，StreamingAssets 也全部覆盖。安装结束时会显示保留了多少个文件。

> 自定义皮肤、音效、语音、背景和 `MaiCharts` 都在 StreamingAssets 下，因此默认升级不会破坏这些内容。

## GUI 说明

启动时检查显示器：

- 首选主显示器；主显示器不是竖屏 16:9 时，会继续寻找其他竖屏 16:9 显示器。
- 判定条件：`宽 < 高` 且 `宽/高 ≈ 9/16`（容差 2%）。
- 满足条件时，在选中的显示器上显示无边框全屏 GUI：
  - 白色背景，标题、正文、进度和提示均为天蓝色系；
  - 绘制一个**直径等于屏幕宽度**的圆（1080×1920 上为 1080 px，4K 及其他 9:16 分辨率等比放大），底部对齐屏幕下边缘；
  - 标题、进度、百分比、速度、当前线路和提示都放在圆内；
  - `Esc`：下载/安装过程中取消，完成后退出。
- 不满足条件（例如常见的 1920×1080、2560×1440 横屏），自动使用命令行输出。

可用参数：

- `-NoGui`：强制命令行。
- `-MonitorIndex N`：指定第 N 个显示器（从 0 开始）；该显示器仍必须是竖屏 16:9，否则回退命令行。

## 更新器自更新

每次启动会顺带检查更新器自身：

- 默认源：`https://github.com/TeamMajdata/Majplay-update-cli/raw/refs/heads/main/Update-MajdataPlay.ps1`
- 版本号来自脚本顶部的标记：

  ```powershell
  # MAJDATA_UPDATER_VERSION: 1.2.0
  ```

- 只有远程版本**高于**当前版本时才会替换。
- 替换前会做 PowerShell 语法校验，并备份为 `Update-MajdataPlay.ps1.bak`。
- 替换成功后使用原始参数自动重启，本次更新继续由新版本执行；重启时自动带 `-SkipSelfUpdate`，不会循环。
- 自更新检查使用与游戏更新相同的代理/镜像线路，只尝试当前最优的一条线路，失败时**不会阻塞**游戏更新。
- 自更新失败（例如尚未推送到远端、断网）只写日志，继续使用当前脚本。

发布更新器新版本时，请同时修改 `# MAJDATA_UPDATER_VERSION:` 和 `$script:UpdaterVersion`，然后推送到 `main`，自更新才会生效。

可用参数：

- `-SelfUpdateUrl <url>`：自定义脚本源，便于 fork 或本地测试。
- `-SkipSelfUpdate`：本次跳过自更新检查。

## 安装与启动

1. 下载完整 ZIP 到游戏安装目录（默认 `<脚本目录>\MajdataPlay\`）；
2. 若资源页面提供 SHA256，则校验下载文件；否则至少验证 ZIP 结构；
3. 解压到 `<安装目录>\staging\<guid>`；
4. **解压完成后立即删除下载的 ZIP**（即使后续安装失败也不保留成功解压的包）；
5. 从解压目录中找到 `MajdataPlay.exe`（兼容 ZIP 内多一层 `StandaloneWindows64` 目录），按上面的 StreamingAssets 规则复制到安装目录；
6. 写入更新状态；
7. 关闭 GUI，启动 `MajdataPlay.exe`；等待游戏窗口出现，将其置于前台，然后脚本才退出。

下载支持断点续传（`.part`）。解压成功后 ZIP 会被删除；只有下载中断、解压失败或 ZIP 删除失败时才可能留下包，下次 `-Force` 会校验后复用。

如果游戏正在运行，默认会报错并停止，避免文件被占用；加 `-StopRunningGame` 会先尝试正常关闭，再强制结束。

## 日志

默认日志：

```text
<安装目录>\majdataplay-updater.log
```

可用 `-LogPath` 指定其他位置。失败时命令行会提示日志路径；GUI 模式下日志同样会写入。

## 参数一览

| 参数 | 说明 |
| --- | --- |
| `-Channel Stable\|Nightly` | 更新通道；省略时使用已保存的设置，首次运行弹窗选择 |
| `-InstallPath <path>` | 游戏目录；默认 `<脚本目录>\MajdataPlay` |
| `-Proxy <url>` | 指定代理，如 `http://127.0.0.1:7890` |
| `-NoProxy` | 禁用所有代理 |
| `-Mirror <string[]>` | 自定义镜像前缀列表 |
| `-NoMirror` | 禁用镜像 |
| `-TimeoutSec <5-300>` | 元数据请求超时，默认 20 秒 |
| `-OverwriteStreamingAssets` | 覆盖已有 StreamingAssets 文件 |
| `-Force` | 强制下载并重新安装 |
| `-CheckOnly` | 只检查并报告 |
| `-NoLaunch` | 更新后不启动游戏 |
| `-SkipBootMenu` | 跳过 5 秒启动菜单（自更新重启时会自动使用） |
| `-NoGui` | 强制命令行 |
| `-MonitorIndex <int>` | 指定 GUI 显示器索引，`-1` 为自动 |
| `-StopRunningGame` | 安装前关闭正在运行的游戏 |
| `-SelfUpdateUrl <url>` | 自定义更新器脚本源 |
| `-SkipSelfUpdate` | 本次跳过更新器自更新 |
| `-LogPath <path>` | 自定义日志路径 |

## 退出码

- `0`：已是最新版本，或更新成功（未指定 `-NoLaunch` 时游戏已启动）。
- `1`：检查/下载/校验/安装失败，或用户取消。

## 常见问题

**下载很慢或 GitHub 连不上？**
先确认系统代理可用；没有代理时脚本会自动使用镜像。也可以手动指定：

```powershell
.\Update-MajdataPlay.ps1 -Proxy 'http://127.0.0.1:7890'
# 或
.\Update-MajdataPlay.ps1 -NoProxy -Mirror 'https://gh-proxy.org','https://ghproxy.net'
```

**不想让更新覆盖自定义皮肤/音效？**
保持默认即可；只有加 `-OverwriteStreamingAssets` 才会覆盖已有文件。

**提示安装目录不可写？**
把脚本放到游戏目录，或以管理员身份运行。

**想从 nightly 切回稳定版？**
本地 nightly 版本号通常高于稳定版，默认不会降级。显式执行：

```powershell
.\Update-MajdataPlay.ps1 -Channel Stable -Force
```

**自更新检查失败 / 404？**
确认新脚本已经推送到 `TeamMajdata/Majplay-update-cli` 的 `main` 分支；仅本地 commit 不会让其他机器看到。可临时用 `-SkipSelfUpdate` 跳过。
