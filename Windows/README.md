# AI灯语（aidengyu）— Windows

Windows 10/11 x64 原生托盘状态灯：Go + Win32 单文件 `aidengyu.exe`（无 Electron / WebView）。功能与 macOS 版对齐：置顶面板、系统托盘、多会话、单灯/三灯、任务短标题，以及 Codex / Claude Code / Cursor Hook。

状态语义见仓库根目录 [docs/STATE_LANGUAGE.md](../docs/STATE_LANGUAGE.md)。

## 依赖

- [Go](https://go.dev/dl/) 1.22+（`go.mod` 要求 `go 1.22.0`）
- 本机构建时脚本会安装/调用 `rsrc`，将 `assets/app.ico` 嵌入 exe

## 源码结构

```text
cmd/signal/           入口：CLI Hook 与托盘 UI（package main）
internal/core/        状态映射、会话 JSON、Hook 安装/卸载与测试
internal/ui/          Win32 托盘、置顶面板、绘制
assets/app.ico        应用图标（构建嵌入，勿删）
build-windows.ps1     Windows 本机构建
build-windows.sh      交叉编译（在 macOS/Linux 上打 Windows amd64）
go.mod / go.sum       模块与依赖校验和
```

## 构建

在仓库根目录执行。

PowerShell（推荐，Windows 本机）：

```powershell
.\Windows\build-windows.ps1
```

脚本会：

1. 用 `rsrc` 生成资源并嵌入图标
2. 运行 `go test ./internal/core/ -count=1`
3. `CGO_ENABLED=0 GOOS=windows GOARCH=amd64` 以 `-H windowsgui` 编译 `cmd/signal`
4. 打包 zip

交叉编译（macOS / Linux；该脚本不嵌入图标资源，适合 CI 以外的快速交叉验证）：

```bash
Windows/build-windows.sh
```

产物：

| 路径 | 说明 |
| --- | --- |
| `dist-windows/aidengyu.exe` | 单文件 exe |
| `dist-windows/aidengyu-Windows-x64.zip` | 含 exe 与本 README 副本 |

CI 使用 `build-windows.ps1`，见 [.github/workflows/build.yml](../.github/workflows/build.yml)。

## 运行

1. 解压 zip 或直接运行 `aidengyu.exe`。
2. 顶部应出现状态面板；无会话时显示空状态属正常。托盘有同一应用图标。
3. 托盘右键 →「安装/修复状态连接」。
4. **新开** Codex / Claude Code / Cursor 会话后再观察灯效。

程序未代码签名。SmartScreen 提示时选「更多信息」→「仍要运行」。安装 Hook 不需要管理员权限。

Hook 写入的是当前 exe 的绝对路径；移动 exe 后请重新安装连接。面板不见时可用托盘「重置窗口位置」或左键单击托盘图标显示。

## 命令行（与托盘同一 exe）

```powershell
.\aidengyu.exe --install-hooks
.\aidengyu.exe --uninstall-hooks
.\aidengyu.exe --hook-status
```

Agent 通过 stdin JSON 调用 Hook：

```text
aidengyu.exe --aidengyu-hook --agent <codex|claude|cursor>
```

（仍兼容旧标志 `--codex-claude-signal-hook`。）

## 本地数据

```text
%APPDATA%\aidengyu\
```

若存在旧目录 `%APPDATA%\CodexClaudeSignal\`，首次启动会尝试迁移。

Hook 配置：

```text
%USERPROFILE%\.codex\hooks.json
%USERPROFILE%\.claude\settings.json
%USERPROFILE%\.cursor\hooks.json
```

## 操作摘要

- 托盘左键：显示/隐藏面板
- 拖动面板：移动位置（至少保留一部分在屏幕工作区内）
- 托盘菜单：指示灯样式（单灯/三灯）、重置窗口位置、清除历史灯组、安装/卸载 Hook
