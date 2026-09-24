package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLiveSessionTitlesRepair(t *testing.T) {
	if os.Getenv("AIDENGYU_LIVE_TEST") == "" && os.Getenv("CODEX_CLAUDE_SIGNAL_LIVE_TEST") == "" {
		t.Skip("set AIDENGYU_LIVE_TEST=1 to scan live session files")
	}
	dir := SessionsDirectory(SignalRoot())
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Skip("no live sessions directory: ", err)
	}
	var report strings.Builder
	foundBad := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var sig Signal
		if json.Unmarshal(raw, &sig) != nil || sig.TaskTitle == "" {
			continue
		}
		title := sig.TaskTitle
		repaired := RepairMojibake(title)
		fmt.Fprintf(&report, "file=%s\n  title=%q\n  repaired=%q changed=%v\n",
			e.Name(), title, repaired, repaired != title)
		if looksLikeCP936Mojibake(repaired) {
			foundBad++
			fmt.Fprintf(&report, "  STILL_BAD\n")
		}
	}
	t.Log("\n" + report.String())
	if foundBad > 0 {
		t.Fatalf("%d titles still look like mojibake after RepairMojibake", foundBad)
	}
}

func looksLikeCP936Mojibake(s string) bool {
	if s == "" || !hasHan(s) {
		return false
	}
	if RepairMojibake(s) == s {
		return false
	}
	return true
}

func TestRepairScreenshotLiterals(t *testing.T) {
	const want = "重复了两条正常吗，而且 都已经停止了"
	const liveMojibake = "閲嶅\ue632浜嗕袱鏉℃\ue11c甯稿悧锛岃€屼笖 閮藉凡缁忓仠姝\ue76d簡"
	if got := RepairMojibake(liveMojibake); got != want {
		t.Fatalf("GB18030/PUA mojibake: got %q want %q", got, want)
	}
	if got := RepairMojibake("椤圭洰鍚"); got != "项目" && got != "项目名" {
		t.Fatalf("项目名: %q", got)
	}
	if got := RepairMojibake("椤圭洰鍚\uFFFD"); got != "项目" && got != "项目名" {
		t.Fatalf("项目名 with trailing FFFD: %q", got)
	}
	if got := RepairMojibake("优化登录页面"); got != "优化登录页面" {
		t.Fatalf("correct chinese changed: %q", got)
	}
	if got := RepairMojibake(want); got != want {
		t.Fatalf("correct long chinese changed: %q", got)
	}
	// 丼 is a one-byte corruption of 个, not whole-string GBK mojibake.
	const don = "对于这三丼codex-claude-cursor 都可以适配吧？"
	if got := RepairMojibake(don); got != don {
		t.Fatalf("single-char corruption should be left alone: %q", got)
	}
}