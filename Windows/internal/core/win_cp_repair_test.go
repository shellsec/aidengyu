package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsCP936RepairsLiveGB18030Mojibake(t *testing.T) {
	const mojibake = "閲嶅\ue632浜嗕袱鏉℃\ue11c甯稿悧锛岃€屼笖 閮藉凡缁忓仠姝\ue76d簡"
	const want = "重复了两条正常吗，而且 都已经停止了"

	b, ok := encodeWindowsCodePage(codePageGBK, mojibake)
	if !ok {
		t.Fatal("encodeWindowsCodePage failed")
	}
	if string(b) != want {
		t.Fatalf("cp936 encode: got %q want %q", string(b), want)
	}
	if got := RepairMojibake(mojibake); got != want {
		t.Fatalf("RepairMojibake: got %q want %q", got, want)
	}

	candidates := []string{
		filepath.Join(os.Getenv("APPDATA"), "aidengyu", "sessions", "cursor-7e77d9c4-7a4f-43f5-a8ba-b2ef2118a268.json"),
		filepath.Join(os.Getenv("APPDATA"), "CodexClaudeSignal", "sessions", "cursor-7e77d9c4-7a4f-43f5-a8ba-b2ef2118a268.json"),
	}
	for _, path := range candidates {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var sig Signal
		if json.Unmarshal(data, &sig) != nil || sig.TaskTitle == "" {
			t.Fatalf("bad session json: %s", path)
		}
		got := RepairMojibake(sig.TaskTitle)
		// File may already be repaired on disk; either way display path must be correct Chinese.
		if got != want && sig.TaskTitle != want {
			t.Fatalf("live file %s: in=%q got=%q want=%q", path, sig.TaskTitle, got, want)
		}
		if got != want && sig.TaskTitle == want {
			// already correct on disk
			return
		}
		if got != want {
			t.Fatalf("live file %s: got %q want %q", path, got, want)
		}
		return
	}
	t.Log("live session file not found; constant mojibake case passed")
}