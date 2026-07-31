# Codex Claude Cursor Signal

[![Build](https://github.com/sxlisme/codex-claude-cursor-signal/actions/workflows/build.yml/badge.svg)](https://github.com/sxlisme/codex-claude-cursor-signal/actions/workflows/build.yml)

面向 macOS 和 Windows 的本地 Agent 状态指示灯。应用同时常驻系统托盘和桌面顶部；每打开一个 Codex、Claude Code 或 Cursor 会话，就显示一组独立状态灯。

<p align="center">
  <img src="docs/app-preview.jpg" width="294" alt="Codex、Claude Code 和 Cursor 状态灯预览">
</p>

## 当前能力

- macOS 使用原生 AppKit 且不显示 Dock 图标；Windows 使用 Electron 并常驻系统托盘。
- 顶部 `NSPanel` 始终置顶，并加入所有桌面与全屏辅助空间；可拖动，且至少保留一部分在当前屏幕内。
- 默认使用紧凑单灯显示状态，也可从菜单切换为街头红绿灯三灯样式；多个会话垂直排列，异常和等待状态优先。
- 面板使用半透明毛玻璃背景，会话之间以轻量分割线区分。
- 使用 Codex/OpenAI、Claude 与 Cursor 图标区分 Agent，不显示名称；有用户输入时显示从首行提取的任务短标题。
- Codex、Claude Code 与 Cursor 生命周期 Hook 实时上报。
- 菜单栏可安装、修复、卸载 Hook，显示/隐藏顶部面板并清除历史灯组。
- 结构化合并 `~/.codex/hooks.json`、`~/.claude/settings.json` 和 `~/.cursor/hooks.json`，保留已有字段与 Hook；写入前生成时间戳备份。
- 所有状态只保存在本机，无网络请求、遥测或后台服务。

完整颜色和闪烁语义见 [docs/STATE_LANGUAGE.md](docs/STATE_LANGUAGE.md)。

## 构建

要求 macOS 13 或更高版本，以及 Xcode Command Line Tools。无需完整 Xcode。

```bash
Scripts/test.sh
Scripts/build-app.sh
open dist/CodexClaudeSignal.app
```

`build-app.sh` 生成同时支持 Apple Silicon 和 Intel Mac 的 Universal 应用，并做本地 ad-hoc 签名。

Windows 10/11 x64 版本、使用方法和构建命令见 [Windows/README.md](Windows/README.md)。

## GitHub 自动构建

推送到 `main`、创建 Pull Request，或从 Actions 页面手动运行 `Build`，都会并行构建：

- `CodexClaudeCursorSignal-macOS-universal.zip`
- `CodexClaudeSignal-Windows-x64.zip`

构建完成后可在对应 Workflow Run 的 **Artifacts** 区域下载。推送 `v*` 标签时还会自动创建 GitHub Release，并附加两个平台的 ZIP：

```bash
git tag v0.4.1
git push origin v0.4.1
```

## 连接 Codex、Claude Code 和 Cursor

1. 打开菜单栏的三色灯图标。
2. 选择“安装/修复状态连接”。
3. 新开 Codex、Claude Code 和 Cursor 会话。
4. Codex 首次发现 Hook 时，在 `/hooks` 页面确认信任。

也可以用打包后的 Helper 安装：

```bash
dist/CodexClaudeSignal.app/Contents/Helpers/AgentSignalHook --install
```

卸载只移除本应用管理的 Hook 条目：

```bash
dist/CodexClaudeSignal.app/Contents/Helpers/AgentSignalHook --uninstall
```

## 本地数据

状态文件位于：

```text
~/Library/Application Support/CodexClaudeSignal/sessions/
```

每个会话一个 JSON 文件，只记录：Agent 类型、`session_id`、工作目录、事件名、状态、更新时间、简短错误原因，以及从用户输入首行提取的最多 36 个字符任务标题。Hook 不保存完整 prompt、模型输出、工具参数或对话正文。

## 项目结构

```text
Native/SignalCore.*       状态映射、文件存储、Hook 配置合并
Native/AgentSignalHook.m  Codex / Claude Code / Cursor Hook 可执行文件
Native/AgentSignalApp.m   菜单栏、置顶面板和灯光动画
NativeTests/              无外部依赖的核心测试
Windows/                  Electron Windows 应用、Node 核心测试和打包脚本
Scripts/                  构建与测试脚本
docs/                     状态规范
```

## 开源参考

本项目在产品交互和事件接入调研中参考了以下开源项目，但实现代码为独立编写：

- [guan-ops/Agent-Signal-Bar](https://github.com/guan-ops/Agent-Signal-Bar), Apache-2.0
- [yelog/vibebar](https://github.com/yelog/vibebar), MIT
- [michalstrnadel/AgentBar](https://github.com/michalstrnadel/AgentBar), MIT

Codex/OpenAI、Claude 与 Cursor 标志取自 [Simple Icons](https://simpleicons.org/)，按 CC0-1.0 提供。

Codex Hook 事件以 [OpenAI Codex Hooks 文档](https://learn.chatgpt.com/docs/hooks) 为准；Cursor 事件以 [Cursor Hooks 文档](https://cursor.com/docs/agent/hooks) 为准；Claude Code 使用当前 CLI 支持的生命周期 Hook 事件。

## License

[MIT](LICENSE)
