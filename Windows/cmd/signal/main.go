// aidengyu (灯语) for Windows — native single-file client.
package main

import (
	"encoding/json"
	"io"
	"os"
	"syscall"
	"time"

	"github.com/sxlisme/aidengyu/windows/internal/core"
	"github.com/sxlisme/aidengyu/windows/internal/ui"
)

const (
	hookFlag       = "--aidengyu-hook"
	legacyHookFlag = "--codex-claude-signal-hook"
)

func argumentValue(argv []string, name string) string {
	for i, arg := range argv {
		if arg == name && i+1 < len(argv) {
			return argv[i+1]
		}
	}
	return ""
}

func hasFlag(argv []string, name string) bool {
	for _, arg := range argv {
		if arg == name {
			return true
		}
	}
	return false
}

// trimUTF8BOM strips a leading UTF-8 BOM. Cursor (and some Windows hosts) prefix
// hook stdin JSON with U+FEFF; encoding/json rejects that and the session would
// never be recorded while still returning {} for Cursor.
func trimUTF8BOM(data []byte) []byte {
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return data[3:]
	}
	return data
}

func readHookPayload() map[string]any {
	data, err := io.ReadAll(os.Stdin)
	if err != nil || len(data) == 0 {
		return map[string]any{}
	}
	data = trimUTF8BOM(data)
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil || payload == nil {
		return map[string]any{}
	}
	return payload
}

// attachParentConsole reconnects stdout/stderr when launched from an existing
// terminal while the binary is linked with -H windowsgui.
func attachParentConsole() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	attach := kernel32.NewProc("AttachConsole")
	attach.Call(^uintptr(0)) // ATTACH_PARENT_PROCESS
	getStdHandle := kernel32.NewProc("GetStdHandle")
	const (
		stdOutput = ^uintptr(10) // STD_OUTPUT_HANDLE = -11
		stdError  = ^uintptr(11) // STD_ERROR_HANDLE = -12
	)
	if h, _, _ := getStdHandle.Call(stdOutput); h != 0 && h != ^uintptr(0) {
		os.Stdout = os.NewFile(h, "stdout")
	}
	if h, _, _ := getStdHandle.Call(stdError); h != 0 && h != ^uintptr(0) {
		os.Stderr = os.NewFile(h, "stderr")
	}
}

func runCommandLine(argv []string) (handled bool, code int) {
	cli := hasFlag(argv, hookFlag) ||
		hasFlag(argv, legacyHookFlag) ||
		hasFlag(argv, "--install-hooks") ||
		hasFlag(argv, "--uninstall-hooks") ||
		hasFlag(argv, "--hook-status")
	if !cli {
		return false, 0
	}
	attachParentConsole()

	if hasFlag(argv, hookFlag) || hasFlag(argv, legacyHookFlag) {
		agent := argumentValue(argv, "--agent")
		if agent != core.AgentCodex && agent != core.AgentClaude && agent != core.AgentCursor {
			return true, 0
		}
		payload := readHookPayload()
		if _, ok := payload["session_id"]; !ok {
			if session := argumentValue(argv, "--session"); session != "" {
				payload["session_id"] = session
			}
		}
		if _, ok := payload["cwd"]; !ok {
			if cwd := argumentValue(argv, "--cwd"); cwd != "" {
				payload["cwd"] = cwd
			}
		}
		signal, err := core.MapHookPayload(payload, agent, argumentValue(argv, "--event"), time.Now())
		if err == nil {
			_, _ = core.WriteSignal(signal, "")
		}
		if agent == core.AgentCursor {
			_, _ = os.Stdout.WriteString("{}\n")
		}
		return true, 0
	}

	exe, err := os.Executable()
	if err != nil {
		exe = argv[0]
	}

	if hasFlag(argv, "--install-hooks") {
		if err := core.InstallHooks(exe, ""); err != nil {
			return true, 1
		}
		return true, 0
	}
	if hasFlag(argv, "--uninstall-hooks") {
		if err := core.UninstallHooks(""); err != nil {
			return true, 1
		}
		return true, 0
	}
	if hasFlag(argv, "--hook-status") {
		status := core.GetHookStatus(exe, "")
		enc := json.NewEncoder(os.Stdout)
		_ = enc.Encode(status)
		return true, 0
	}
	return false, 0
}

func main() {
	if handled, code := runCommandLine(os.Args); handled {
		os.Exit(code)
	}
	if err := ui.Run(); err != nil {
		// Linked as GUI subsystem — surface failures via MessageBox, not a console.
		ui.ShowStartupError(err.Error())
		os.Exit(1)
	}
}
