**语言 / Language:** 中文 | [English](README.en.md)

# AI灯语（aidengyu）

面向 macOS 与 Windows 的本地 Agent 状态指示灯。应用常驻系统托盘（macOS 为菜单栏）和桌面顶部面板；每个 Codex、Claude Code 或 Cursor 会话对应一组状态灯。

状态颜色与闪烁语义见 [docs/STATE_LANGUAGE.md](docs/STATE_LANGUAGE.md)。

## 实现概览

| 平台 | 技术 | 入口 |
| --- | --- | --- |
| macOS | Objective-C / AppKit（`LSUIElement`，无 Dock 图标） | `Native/AgentSignalApp.m` + Helper `AgentSignalHook` |
| Windows | Go + Win32（单文件 GUI exe） | `Windows/cmd/signal` |

两端共用同一套状态语义：安装 Hook、读本地会话 JSON、在顶部面板与托盘中展示就绪 / 思考 / 工作 / 等待 / 失败等状态。所有状态只保存在本机，应用本身不发起网络请求。

## 依赖

**macOS**

- macOS 13+（`LSMinimumSystemVersion` / 编译 `-mmacosx-version-min=13.0`）
- Xcode Command Line Tools（`clang`）；无需完整 Xcode
- 打 DMG 需在 macOS 上运行（依赖系统 `hdiutil`）

**Windows**

- [Go](https://go.dev/dl/) 1.22+（见 `Windows/go.mod`）
- Windows 构建脚本会调用 `rsrc` 将 `Windows/assets/app.ico` 嵌入 exe（本机无则 `go install`）

## 目录结构

```text
Native/                  macOS 核心与 UI（SignalCore、AgentSignalApp、AgentSignalHook）
NativeTests/             macOS 核心单元测试源码
Assets/                  macOS 面板用 Agent 图标（openai/claude/cursor.svg）
Resources/Info.plist     macOS 应用包信息（Bundle 名「AI灯语」，版本 0.1.0）
Windows/cmd/signal/      Windows 入口（托盘 UI + Hook CLI）
Windows/internal/core/   Windows 状态映射、会话存储、Hook 合并
Windows/internal/ui/     Win32 托盘与置顶面板
Windows/assets/app.ico   Windows 应用图标（构建时嵌入）
Windows/go.mod           Go module
Scripts/test.sh          编译并运行 macOS 核心测试
Scripts/build-app.sh     打 Universal .app，并调用 create-dmg.sh
Scripts/create-dmg.sh    生成拖拽安装 DMG（仅 macOS）
Windows/build-windows.ps1  Windows 本机构建与打包
Windows/build-windows.sh   交叉编译 Windows x64（macOS/Linux）
.github/workflows/build.yml  CI：并行构建 macOS / Windows 产物
docs/STATE_LANGUAGE.md   状态灯语义说明
```

## macOS：测试与构建

```bash
Scripts/test.sh
Scripts/build-app.sh
```

`Scripts/test.sh` 用 `clang` 编译 `Native/SignalCore.m` + `NativeTests/SignalCoreTests.m` 并执行。

`Scripts/build-app.sh` 产出：

- `dist/aidengyu.app`（arm64 + x86_64 Universal，ad-hoc 签名）
- `dist/aidengyu-macOS-universal.dmg`（在 Darwin 上由 `Scripts/create-dmg.sh` 生成）

单独打 DMG（需已有 `.app`，且必须在 macOS 上）：

```bash
Scripts/create-dmg.sh dist/aidengyu.app
```

开发时直接打开：`open dist/aidengyu.app`。

未签名发布包首次打开可能被 Gatekeeper 拦截：对 `.app` **右键 → 打开**并确认；若仍被拦，到 **系统设置 → 隐私与安全性** 里点「仍要打开」。

Helper 命令行：

```bash
dist/aidengyu.app/Contents/Helpers/AgentSignalHook --install
dist/aidengyu.app/Contents/Helpers/AgentSignalHook --uninstall
```

也可在菜单栏图标菜单中选择「安装/修复状态连接」或卸载。

macOS 会话数据目录：

```text
~/Library/Application Support/aidengyu/sessions/
```

若仍存在旧目录名 `CodexClaudeSignal`，首次启动会尝试迁移到 `aidengyu`。

## Windows：构建与运行

详见 [Windows/README.md](Windows/README.md)。摘要：

```powershell
.\Windows\build-windows.ps1
```

或在 macOS / Linux 交叉编译：

```bash
Windows/build-windows.sh
```

产物：`dist-windows/aidengyu.exe`、`dist-windows/aidengyu-Windows-x64.zip`。

## 下载

构建产物发布在 [GitHub Releases](https://github.com/shellsec/aidengyu/releases)。推送 `v*` 标签后 Release 会附带：

- `aidengyu-macOS-universal.zip` / `aidengyu-macOS-universal.dmg`
- `aidengyu-Windows-x64.zip`（解压后直接运行 `aidengyu.exe`；首次可能出现 SmartScreen，选「仍要运行」）

macOS 未签名时：右键打开 `.app`，或在 **系统设置 → 隐私与安全性** 中「仍要打开」。

有 Release 后可在页面直接下载，或按下述方式拼接链接。

- **GitHub 原链**（示例）：  
  `https://github.com/shellsec/aidengyu/releases/download/<tag>/aidengyu-macOS-universal.dmg`
- **加速下载**：在原始 GitHub 文件链接前加上 `https://gh-proxy.com/`，例如：  
  `https://gh-proxy.com/https://github.com/shellsec/aidengyu/releases/download/<tag>/aidengyu-macOS-universal.dmg`

将 `<tag>` 换成实际版本标签（如 `v0.1.0`），文件名换成上表中的对应资产即可。Windows 等同理：`aidengyu-Windows-x64.zip`。

## CI 产物

推送到 `main`、PR 或手动运行 workflow `Build` 时，并行产出：

- `aidengyu-macOS-universal.zip` / `aidengyu-macOS-universal.dmg`
- `aidengyu-Windows-x64.zip`

推送 `v*` 标签时，workflow 会创建或更新 GitHub Release 并附上上述文件。下载与加速方式见上一节。

## 连接 Agent

1. 启动应用后，在菜单栏 / 托盘中选择安装或修复状态连接。
2. **新开** Codex、Claude Code、Cursor 会话（已打开的会话通常不会补发 `sessionStart`）。
3. Codex 首次发现 Hook 时，需在其 `/hooks` 界面确认信任。

Hook 配置文件（本机）：

```text
~/.codex/hooks.json
~/.claude/settings.json
~/.cursor/hooks.json
```

安装/卸载只改写本应用管理的条目，写入前会备份。

## License

[MIT](LICENSE)
