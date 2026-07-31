# Codex Claude Signal for Windows

Windows 10/11 x64 桌面状态灯。功能与 macOS 版保持一致：置顶面板、系统托盘、多会话、单灯/三灯、任务短标题和 Codex/Claude Code/Cursor Hook。

## 使用

1. 解压 `CodexClaudeSignal-Windows-x64.zip`，保留文件夹内的所有文件。
2. 运行 `Codex Claude Signal.exe`。
3. 右键系统托盘中的状态灯，选择“安装/修复状态连接”。
4. 新开 Codex、Claude Code 和 Cursor 会话。Codex 首次发现 Hook 时需要确认信任。

程序没有代码签名。Windows SmartScreen 首次提示时，选择“更多信息”后再选择“仍要运行”。安装 Hook 不需要管理员权限。

Hook 使用当前 `.exe` 的绝对路径。移动解压目录后，请重新选择“安装/修复状态连接”。

## 操作

- 左键单击托盘图标：显示或隐藏状态面板。
- 拖动面板：移动位置；至少保留 72 像素在当前屏幕工作区内。
- 托盘菜单“指示灯样式”：切换单灯或三灯并持久保存。
- 托盘菜单“重置窗口位置”：移回鼠标所在屏幕顶部中央。
- 托盘菜单“清除历史灯组”：删除本地会话状态。

## 本地数据

```text
%APPDATA%\CodexClaudeSignal\
```

每个会话使用一个 JSON 文件。只保存 Agent、会话 ID、工作目录、状态、时间、简短原因和最多 36 个字符的任务标题，不保存完整 prompt、模型输出或工具参数。

Hook 配置位于：

```text
%USERPROFILE%\.codex\hooks.json
%USERPROFILE%\.claude\settings.json
%USERPROFILE%\.cursor\hooks.json
```

安装和卸载只修改本应用管理的 Hook 条目，并在写入前生成备份。

## 构建

要求 Node.js 20 或更高版本。

PowerShell：

```powershell
.\Windows\build-windows.ps1
```

macOS 交叉打包 Windows x64：

```bash
Windows/build-windows.sh
```

产物位于 `dist-windows/CodexClaudeSignal-Windows-x64.zip`。

Codex/OpenAI、Claude 与 Cursor 标志来自 [Simple Icons](https://simpleicons.org/)，按 CC0-1.0 提供。
