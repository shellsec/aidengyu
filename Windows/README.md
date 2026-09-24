# 灯语（aidengyu）Windows

Windows 10/11 x64 原生托盘状态灯（Go + Win32，单文件 exe，无 Electron / WebView）。功能与 macOS 版对齐：置顶面板、系统托盘、多会话、单灯/三灯、任务短标题，以及 Codex / Claude Code / Cursor Hook。

## 使用

1. 解压 `aidengyu-Windows-x64.zip`，或直接使用 `aidengyu.exe`。
2. 双击运行后，屏幕顶部应出现「灯语」面板；无会话时显示「无活动会话」（灯熄灭属正常）。托盘里也有同一个状态图标。
3. 右键系统托盘中的状态灯，选择「安装/修复状态连接」。
4. **新开** Codex、Claude Code 和 Cursor 会话（已打开的窗口不会补发 `sessionStart`）。面板会出现绿灯「就绪」；发送提示或跑工具后会呼吸/闪烁。Codex 首次发现 Hook 时需要确认信任。

程序没有代码签名。Windows SmartScreen 首次提示时，选择「更多信息」后再选择「仍要运行」。安装 Hook 不需要管理员权限。

Hook 使用当前 `.exe` 的绝对路径。移动文件后，请重新选择「安装/修复状态连接」。若看不到面板，用托盘菜单「重置窗口位置」或左键单击托盘图标显示面板。

## 操作

- 左键单击托盘图标：显示或隐藏状态面板。
- 拖动面板：移动位置；至少保留 72 像素在当前屏幕工作区内。
- 托盘菜单「指示灯样式」：切换单灯或三灯并持久保存。
- 托盘菜单「重置窗口位置」：移回鼠标所在屏幕顶部中央。
- 托盘菜单「清除历史灯组」：删除本地会话状态。

## 本地数据

```text
%APPDATA%\aidengyu\
```

若仍存在旧目录 `%APPDATA%\CodexClaudeSignal\`，首次启动会尝试一次性迁移到 `aidengyu`；迁移失败时继续从旧目录读取，避免会话灯状态丢失。

每个会话使用一个 JSON 文件。只保存 Agent、会话 ID、工作目录、状态、时间、简短原因和最多 36 个字符的任务标题，不保存完整 prompt、模型输出或工具参数。

Hook 配置位于：

```text
%USERPROFILE%\.codex\hooks.json
%USERPROFILE%\.claude\settings.json
%USERPROFILE%\.cursor\hooks.json
```

安装和卸载只修改本应用管理的 Hook 条目，并在写入前生成备份。

## 构建

要求 [Go](https://go.dev/dl/) 1.22 或更高。构建脚本会运行 `internal/core` 测试、用 `rsrc` 将 `assets/app.ico` 嵌入 exe，并打出单文件 GUI 子系统产物。

PowerShell（Windows 本机）：

```powershell
.\Windows\build-windows.ps1
```

macOS / Linux 交叉编译 Windows x64：

```bash
Windows/build-windows.sh
```

产物：

- `dist-windows/aidengyu.exe`（单文件，约数 MB）
- `dist-windows/aidengyu-Windows-x64.zip`（内含 exe 与本 README）

CI 使用同一脚本：见仓库根目录 [.github/workflows/build.yml](../.github/workflows/build.yml)。

## 项目结构

```text
Windows/cmd/signal/        入口：托盘 UI 与 Hook CLI
Windows/internal/core/     状态映射、会话存储、Hook 配置合并
Windows/internal/ui/       Win32 托盘、置顶面板、绘制
Windows/assets/app.ico     应用图标（构建时嵌入）
Windows/go.mod             Go module
```

命令行（与托盘共用同一 exe）：

```powershell
.\aidengyu.exe --install-hooks
.\aidengyu.exe --uninstall-hooks
.\aidengyu.exe --hook-status
```

Hook 由 Agent 通过 stdin JSON 调用：

```text
aidengyu.exe --aidengyu-hook --agent <codex|claude|cursor>
```

Codex/OpenAI、Claude 与 Cursor 标志语义与 macOS 版一致。面板用文字标注来源（Codex / Claude / Cursor）。
