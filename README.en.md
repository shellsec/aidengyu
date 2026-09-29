**语言 / Language:** [中文](README.md) | English

[aiv123.com](https://aiv123.com/) · AI tools directory, 600+ tools in one place

## 🚀 Recommended: [ofox.ai](https://ofox.io/x/aiv123)

> **In short**: One account for the latest GPT / Claude / Gemini and **100+** top models. First top-up gets an extra **$3** credit.

Text, image, video, and embeddings in one place. Caching supported — repeat calls stay cheaper and faster.

[👉 Sign up](https://ofox.io/x/aiv123) · Global dedicated lines · Enterprise SLA · No conversation retention

| ⚡️ Faster & Leaner | 🧠 Models & Modalities | 🛡️ Privacy |
|:---:|:---:|:---:|
| Global lines, enterprise SLA, plus caching | 100+ models · text / image / video / embeddings | No conversation retention |

## ☕ Buy Me a Coke

Open source takes effort — sponsorship is welcome:  
👉 [爱发电 / Afdian](https://ifdian.net/a/shellsec)

---

# aidengyu (AI灯语)

Local agent status lights for macOS and Windows. The app lives in the system tray (menu bar on macOS) and a top-of-desktop panel. Each Codex, Claude Code, or Cursor session gets its own light group.

Color and blink semantics: [docs/STATE_LANGUAGE.md](docs/STATE_LANGUAGE.md).

## Implementation

| Platform | Stack | Entry |
| --- | --- | --- |
| macOS | Objective-C / AppKit (`LSUIElement`, no Dock icon) | `Native/AgentSignalApp.m` + helper `AgentSignalHook` |
| Windows | Go + Win32 (single-file GUI exe) | `Windows/cmd/signal` |

Both sides share the same status model: install hooks, read local session JSON, show ready / thinking / working / waiting / failed (etc.) on the panel and tray. State stays on-device; the app itself does not make network requests.

## Requirements

**macOS**

- macOS 13+ (`LSMinimumSystemVersion` / `-mmacosx-version-min=13.0`)
- Xcode Command Line Tools (`clang`); full Xcode not required
- DMG packaging must run on macOS (`hdiutil`)

**Windows**

- [Go](https://go.dev/dl/) 1.22+ (`Windows/go.mod`)
- The Windows build script uses `rsrc` to embed `Windows/assets/app.ico` (`go install` if missing)

## Layout

```text
Native/                  macOS core + UI (SignalCore, AgentSignalApp, AgentSignalHook)
NativeTests/             macOS core unit tests
Assets/                  Agent logos for the macOS panel (openai/claude/cursor.svg)
Resources/Info.plist     macOS bundle metadata (name AI灯语, version 0.1.0)
Windows/cmd/signal/      Windows entry (tray UI + hook CLI)
Windows/internal/core/   status map, session storage, hook merge
Windows/internal/ui/     Win32 tray and top panel
Windows/assets/app.ico   Windows app icon (embedded at build time)
Windows/go.mod           Go module
Scripts/test.sh          build and run macOS core tests
Scripts/build-app.sh     Universal .app (+ create-dmg.sh)
Scripts/create-dmg.sh    drag-install DMG (macOS only)
Windows/build-windows.ps1  native Windows build + zip
Windows/build-windows.sh   cross-compile Windows x64 (macOS/Linux)
.github/workflows/build.yml  CI: parallel macOS / Windows artifacts
docs/STATE_LANGUAGE.md   status-light language
```

## macOS: test and build

```bash
Scripts/test.sh
Scripts/build-app.sh
```

`Scripts/test.sh` compiles `Native/SignalCore.m` + `NativeTests/SignalCoreTests.m` with `clang` and runs the binary.

`Scripts/build-app.sh` produces:

- `dist/aidengyu.app` (arm64 + x86_64 Universal, ad-hoc signed)
- `dist/aidengyu-macOS-universal.dmg` (via `Scripts/create-dmg.sh` on Darwin)

DMG only (existing `.app`, macOS required):

```bash
Scripts/create-dmg.sh dist/aidengyu.app
```

Dev launch: `open dist/aidengyu.app`.

**Unsigned open (Gatekeeper):** Release `.app` / DMG builds are not notarized. If macOS blocks a double-click, **Control-click → Open** and confirm; if it still blocks, use **System Settings → Privacy & Security → Open Anyway**.

Helper CLI:

```bash
dist/aidengyu.app/Contents/Helpers/AgentSignalHook --install
dist/aidengyu.app/Contents/Helpers/AgentSignalHook --uninstall
```

Or use the menu-bar item **Install / repair status connection**.

Session data:

```text
~/Library/Application Support/aidengyu/sessions/
```

If a legacy `CodexClaudeSignal` folder still exists, the first launch tries to migrate to `aidengyu`.

## Windows: build and run

See [Windows/README.md](Windows/README.md). Summary:

```powershell
.\Windows\build-windows.ps1
```

Cross-compile from macOS / Linux:

```bash
Windows/build-windows.sh
```

Artifacts: `dist-windows/aidengyu.exe`, `dist-windows/aidengyu-Windows-x64.zip`.

## Download

**v0.1.0** installers are on [GitHub Releases](https://github.com/shellsec/aidengyu/releases/tag/v0.1.0):

| Platform | GitHub direct | Accelerated (gh-proxy) |
| --- | --- | --- |
| macOS (dmg) | [aidengyu-macOS-universal.dmg](https://github.com/shellsec/aidengyu/releases/download/v0.1.0/aidengyu-macOS-universal.dmg) | [accelerated](https://gh-proxy.com/https://github.com/shellsec/aidengyu/releases/download/v0.1.0/aidengyu-macOS-universal.dmg) |
| Windows (zip) | [aidengyu-Windows-x64.zip](https://github.com/shellsec/aidengyu/releases/download/v0.1.0/aidengyu-Windows-x64.zip) | [accelerated](https://gh-proxy.com/https://github.com/shellsec/aidengyu/releases/download/v0.1.0/aidengyu-Windows-x64.zip) |

- **macOS:** Open the DMG and drag the app to Applications. For unsigned Gatekeeper prompts, see above.
- **Windows:** Unzip and run `aidengyu.exe` directly. On first launch SmartScreen may appear — choose **Run anyway**.

Formula: `accelerated URL = https://gh-proxy.com/ + original GitHub download URL`.

## CI artifacts

On push to `main`, PRs, or manual **Build** workflow runs:

- `aidengyu-macOS-universal.zip` / `aidengyu-macOS-universal.dmg`
- `aidengyu-Windows-x64.zip`

Pushing a `v*` tag creates or updates a GitHub Release with those files. See **Download** above for direct and accelerated links.

## Connect agents

1. After launch, install or repair the status connection from the menu bar / tray.
2. Start **new** Codex, Claude Code, and Cursor sessions (already-open sessions usually do not re-send `sessionStart`).
3. On first Codex hook discovery, confirm trust in `/hooks`.

Hook config paths:

```text
~/.codex/hooks.json
~/.claude/settings.json
~/.cursor/hooks.json
```

Install/uninstall only touch entries managed by this app, with a backup before write.

## License

[MIT](LICENSE)
