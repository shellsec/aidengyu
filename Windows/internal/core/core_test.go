package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

func payload(event string, extra map[string]any) map[string]any {
	out := map[string]any{
		"session_id":      "session-1",
		"hook_event_name": event,
		"cwd":             `C:\work\example`,
	}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func TestStateForEvent(t *testing.T) {
	cases := []struct {
		event   string
		extra   map[string]any
		want    string
	}{
		{"SessionStart", nil, StateReady},
		{"UserPromptSubmit", nil, StateThinking},
		{"PreToolUse", nil, StateWorking},
		{"PreToolUse", map[string]any{"tool_name": "AskUserQuestion"}, StateWaitingInput},
		{"PermissionRequest", nil, StateWaitingApproval},
		{"PostToolUseFailure", nil, StateFailed},
		{"beforeSubmitPrompt", nil, StateThinking},
		{"stop", map[string]any{"status": "error"}, StateFailed},
		{"SubagentStop", nil, StateCompleted},
		{"Stop", map[string]any{"stop_reason": "rate_limit"}, StateBlocked},
	}
	for _, tc := range cases {
		got := StateForEvent(tc.event, tc.extra)
		if got != tc.want {
			t.Fatalf("%s => %s, want %s", tc.event, got, tc.want)
		}
	}
}

func TestResolveAgentDialects(t *testing.T) {
	mislabeled, err := MapHookPayload(map[string]any{
		"session_id":      "shared-session",
		"hook_event_name": "postToolUse",
		"cwd":             `C:\work\minx`,
	}, AgentClaude, "", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if mislabeled.Agent != AgentCursor {
		t.Fatalf("camelCase via Claude agent => %s", mislabeled.Agent)
	}
	if ResolveAgent(AgentClaude, "sessionStart") != AgentCursor {
		t.Fatal("sessionStart should be Cursor")
	}
	if ResolveAgent(AgentClaude, "SessionStart") != AgentClaude {
		t.Fatal("SessionStart should stay Claude")
	}
	if ResolveAgent(AgentCodex, "Stop") != AgentCodex {
		t.Fatal("Codex Stop should stay Codex")
	}
}

func TestClaudeAndCodexNeverReclassified(t *testing.T) {
	for _, event := range ClaudeHookEvents {
		if got := ResolveAgent(AgentClaude, event); got != AgentClaude {
			t.Fatalf("Claude %s => %s", event, got)
		}
	}
	for _, event := range CodexHookEvents {
		if got := ResolveAgent(AgentCodex, event); got != AgentCodex {
			t.Fatalf("Codex %s => %s", event, got)
		}
	}
	if ResolveAgent(AgentClaude, "beforeSubmitPrompt") != AgentCursor {
		t.Fatal("beforeSubmitPrompt is Cursor dialect")
	}
	if ResolveAgent(AgentClaude, "Stop") != AgentClaude {
		t.Fatal("Stop stays Claude")
	}
	if ResolveAgent(AgentClaude, "stop") != AgentCursor {
		t.Fatal("stop is Cursor")
	}
}

func TestDedupeCursorMislabeledClaude(t *testing.T) {
	root := t.TempDir()
	cursor, err := MapHookPayload(map[string]any{
		"session_id":      "dup-1",
		"hook_event_name": "sessionStart",
		"cwd":             `C:\work\gh-release-fetch`,
	}, AgentCursor, "", time.Date(2026, 9, 24, 3, 16, 36, 179000000, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := WriteSignal(cursor, root); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(root, "sessions", "claude-dup-1.json")
	imported := map[string]any{
		"schema_version": 1,
		"agent":          "claude",
		"session_id":     "dup-1",
		"state":          "ready",
		"event_name":     "sessionStart",
		"updated_at":     "2026-09-24T03:16:36.256Z",
		"cwd":            `C:\work\gh-release-fetch`,
	}
	data, _ := json.MarshalIndent(imported, "", "  ")
	if err := os.WriteFile(sibling, append(data, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	before := LoadSignals(root)
	if len(before) != 1 || before[0].Agent != AgentCursor {
		t.Fatalf("load before write: %+v", before)
	}
	next, err := MapHookPayload(map[string]any{
		"session_id":      "dup-1",
		"hook_event_name": "postToolUse",
		"cwd":             `C:\work\gh-release-fetch`,
	}, AgentClaude, "", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := WriteSignal(next, root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sibling); !os.IsNotExist(err) {
		t.Fatal("claude sibling should be removed")
	}
	signals := LoadSignals(root)
	if len(signals) != 1 || signals[0].Agent != AgentCursor || signals[0].State != StateWorking {
		t.Fatalf("after dedupe: %+v", signals)
	}
}

func TestClaudeSessionNotDeletedByCursorCleanup(t *testing.T) {
	root := t.TempDir()
	claude, err := MapHookPayload(map[string]any{
		"session_id":      "claude-only",
		"hook_event_name": "SessionStart",
		"cwd":             `C:\work\claude-project`,
	}, AgentClaude, "", time.Date(2026, 9, 24, 4, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := WriteSignal(claude, root); err != nil {
		t.Fatal(err)
	}
	cursor, err := MapHookPayload(map[string]any{
		"session_id":      "cursor-other",
		"hook_event_name": "sessionStart",
		"cwd":             `C:\work\cursor-project`,
	}, AgentCursor, "", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := WriteSignal(cursor, root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "sessions", "claude-claude-only.json")); err != nil {
		t.Fatal("claude file must survive")
	}
	var claudeCount int
	for _, s := range LoadSignals(root) {
		if s.Agent == AgentClaude && s.SessionID == "claude-only" {
			claudeCount++
		}
	}
	if claudeCount != 1 {
		t.Fatalf("want 1 claude session, got %d", claudeCount)
	}
}

func TestTaskTitleTruncation(t *testing.T) {
	title := TaskTitleFromPayload(map[string]any{
		"prompt": "  ## 优化登录页面的状态管理和错误提示\n不要修改接口协议",
	})
	if title != "优化登录页面的状态管理和错误提示" {
		t.Fatalf("title=%q", title)
	}
	long := TaskTitleFromPayload(map[string]any{"prompt": string(make([]byte, 50))})
	// "x" * 50 → 36 chars + "..."
	xs := make([]byte, 50)
	for i := range xs {
		xs[i] = 'x'
	}
	long = TaskTitleFromPayload(map[string]any{"prompt": string(xs)})
	if utf8.RuneCountInString(long) != 39 {
		t.Fatalf("rune count=%d title=%q", utf8.RuneCountInString(long), long)
	}
}

func TestRepairMojibakeTaskTitle(t *testing.T) {
	original := "你作为产品经理的话，这个还有什么需要优化和功能"
	mojibake, err := simplifiedchinese.GBK.NewDecoder().Bytes([]byte(original))
	if err != nil {
		t.Fatal(err)
	}
	title := TaskTitleFromPayload(map[string]any{"prompt": string(mojibake)})
	if title != original {
		t.Fatalf("title=%q", title)
	}
	if got := RepairMojibake("优化登录页面"); got != "优化登录页面" {
		t.Fatalf("correct chinese changed: %q", got)
	}
	if got := RepairMojibake("minx"); got != "minx" {
		t.Fatalf("ascii changed: %q", got)
	}
}

// Screenshot-shaped CP936/GB18030 mojibake: UTF-8 Chinese misread as GBK (panel subtitles).
func TestRepairMojibakeScreenshotCases(t *testing.T) {
	// 「项目名」UTF-8 read as GBK → 「椤圭洰鍚」(trailing byte of 名 often lost).
	const xiangmuMojibake = "椤圭洰鍚"
	if got := RepairMojibake(xiangmuMojibake); got != "项目" && got != "项目名" {
		t.Fatalf("项目名 mojibake: got %q", got)
	}
	if got := RepairMojibake(xiangmuMojibake + "\uFFFD"); got != "项目" && got != "项目名" {
		t.Fatalf("项目名 with trailing U+FFFD: got %q", got)
	}

	// Live panel form: UTF-8 misread as GB18030 (PUA + ℃), restored via Windows CP936.
	const want = "重复了两条正常吗，而且 都已经停止了"
	const liveMojibake = "閲嶅\ue632浜嗕袱鏉℃\ue11c甯稿悧锛岃€屼笖 閮藉凡缁忓仠姝\ue76d簡"
	if got := RepairMojibake(liveMojibake); got != want {
		t.Fatalf("live GB18030 mojibake: got %q want %q", got, want)
	}
	if got := RepairMojibake(want); got != want {
		t.Fatalf("correct chinese changed: %q", got)
	}

	title := TaskTitleFromPayload(map[string]any{"prompt": xiangmuMojibake + "\nnext line"})
	if title != "项目" && title != "项目名" {
		t.Fatalf("TaskTitleFromPayload: %q", title)
	}
}

func TestDisplayStateSettling(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	if DisplayState(Signal{State: StateCompleted, UpdatedAt: "2026-07-31T11:59:44.000Z"}, now) != StateReady {
		t.Fatal("completed settles")
	}
	if DisplayState(Signal{State: StateWaitingApproval, UpdatedAt: "2026-07-31T11:59:29.000Z"}, now) != StateAttention {
		t.Fatal("waiting_approval settles")
	}
	if DisplayState(Signal{State: StateWorking, UpdatedAt: "2026-07-31T11:49:59.000Z"}, now) != StateStale {
		t.Fatal("working goes stale")
	}
	// postToolUse without stop: settle to ready after 45s (not while preToolUse / long tools).
	if DisplayState(Signal{
		State: StateWorking, EventName: "postToolUse", UpdatedAt: "2026-07-31T11:59:10.000Z",
	}, now) != StateReady {
		t.Fatal("postToolUse working should settle to ready")
	}
	if DisplayState(Signal{
		State: StateWorking, EventName: "preToolUse", UpdatedAt: "2026-07-31T11:59:10.000Z",
	}, now) != StateWorking {
		t.Fatal("preToolUse working must not settle early")
	}
	if DisplayState(Signal{
		State: StateWorking, EventName: "postToolUse", UpdatedAt: "2026-07-31T11:59:30.000Z",
	}, now) != StateWorking {
		t.Fatal("fresh postToolUse stays working")
	}
}

func TestPhantomReadySessionHidden(t *testing.T) {
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	phantom := Signal{State: StateReady, EventName: "sessionStart", UpdatedAt: "2026-09-24T11:00:00.000Z"}
	if !IsPhantomReadySession(phantom) || ShouldShowSignal(phantom, now) {
		t.Fatal("empty sessionStart ready should be hidden")
	}
	withCwd := Signal{State: StateReady, EventName: "sessionStart", Cwd: `E:\proj`, UpdatedAt: "2026-09-24T11:00:00.000Z"}
	if IsPhantomReadySession(withCwd) || !ShouldShowSignal(withCwd, now) {
		t.Fatal("ready with cwd must show")
	}
	offlineFresh := Signal{State: StateOffline, UpdatedAt: "2026-09-24T11:59:58.000Z"}
	if !ShouldShowSignal(offlineFresh, now) {
		t.Fatal("fresh offline should show during fade")
	}
	offlineOld := Signal{State: StateOffline, UpdatedAt: "2026-09-24T11:59:50.000Z"}
	if ShouldShowSignal(offlineOld, now) {
		t.Fatal("old offline should hide")
	}
}

func TestMergeSignalKeepsCompletedOverLatePostToolUse(t *testing.T) {
	existing := Signal{
		State: StateCompleted, EventName: "stop", UpdatedAt: "2026-09-24T12:00:00.000Z",
		Cwd: `E:\proj`, TaskTitle: "fix lamps",
	}
	incoming := Signal{
		State: StateWorking, EventName: "postToolUse", UpdatedAt: "2026-09-24T12:00:01.000Z",
	}
	merged := MergeSignal(&existing, incoming)
	if merged.State != StateCompleted || merged.EventName != "stop" {
		t.Fatalf("completed overwritten: %+v", merged)
	}
	if merged.Cwd != `E:\proj` || merged.TaskTitle != "fix lamps" {
		t.Fatalf("fields lost: %+v", merged)
	}
}

func TestStatePriorityStaleSortsLast(t *testing.T) {
	// Valid display states must outrank stale so list sorting keeps expired sessions last.
	valid := []string{
		StateBlocked, StateFailed, StateWaitingApproval, StateWaitingInput,
		StateAttention, StateWorking, StateThinking, StateCompleted, StateReady, StateOffline,
	}
	for _, state := range valid {
		if StatePriority(StateStale) >= StatePriority(state) {
			t.Fatalf("stale priority %d should be below %s (%d)", StatePriority(StateStale), state, StatePriority(state))
		}
	}
	// Relative order among valid states stays: attention > working > ready > offline.
	if !(StatePriority(StateAttention) > StatePriority(StateWorking) &&
		StatePriority(StateWorking) > StatePriority(StateReady) &&
		StatePriority(StateReady) > StatePriority(StateOffline)) {
		t.Fatal("valid-state relative order changed")
	}

	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	signals := []Signal{
		{Agent: "codex", SessionID: "stale-1", State: StateWorking, UpdatedAt: "2026-07-31T11:49:59.000Z"},
		{Agent: "codex", SessionID: "ready-1", State: StateReady, UpdatedAt: "2026-07-31T11:59:50.000Z"},
		{Agent: "claude", SessionID: "working-1", State: StateWorking, UpdatedAt: "2026-07-31T11:59:55.000Z"},
	}
	SortSignalsByDisplay(signals, now)
	if DisplayState(signals[len(signals)-1], now) != StateStale {
		t.Fatalf("last item should be stale, got %s", DisplayState(signals[len(signals)-1], now))
	}
	if DisplayState(signals[0], now) == StateStale {
		t.Fatal("stale must not sort first among mixed valid/stale signals")
	}
}

func TestSortSignalsByDisplaySettledReadyAboveStaleWorking(t *testing.T) {
	// Mirrors the real Windows panel bug: disk working (priority 50) has gone stale in the UI,
	// while disk completed has settled to ready. Sorting by raw disk state puts yellow "状态过期"
	// above green "就绪"; sorting by DisplayState must put ready first.
	now := time.Date(2026, 9, 24, 5, 12, 0, 0, time.UTC)
	signals := []Signal{
		{Agent: "cursor", SessionID: "w1", State: StateWorking, UpdatedAt: "2026-09-24T03:33:47.000Z", Cwd: `/E:/devcoder/codex-claude-cursor-signal`},
		{Agent: "cursor", SessionID: "w2", State: StateThinking, UpdatedAt: "2026-09-24T04:32:25.000Z", Cwd: `/E:/devcoder/codex-claude-cursor-signal`},
		{Agent: "cursor", SessionID: "c1", State: StateCompleted, UpdatedAt: "2026-09-24T04:13:55.000Z", Cwd: `/e:/GITHUB/gh-release-fetch`},
		{Agent: "cursor", SessionID: "c2", State: StateCompleted, UpdatedAt: "2026-09-24T03:42:56.000Z", Cwd: `/E:/GITHUB/minx`},
		{Agent: "cursor", SessionID: "r1", State: StateReady, UpdatedAt: "2026-09-24T03:16:36.000Z"},
	}
	SortSignalsByDisplay(signals, now)

	if DisplayState(signals[0], now) != StateReady || DisplayState(signals[1], now) != StateReady {
		t.Fatalf("first two should be ready, got %s then %s", DisplayState(signals[0], now), DisplayState(signals[1], now))
	}
	for i := 2; i < len(signals); i++ {
		if DisplayState(signals[i], now) != StateStale {
			t.Fatalf("index %d should be stale, got %s (disk=%s)", i, DisplayState(signals[i], now), signals[i].State)
		}
	}
	// Settled ready rows must be the completed sessions, not leftover working/thinking.
	if signals[0].State != StateCompleted || signals[1].State != StateCompleted {
		t.Fatalf("top rows should be disk completed→ready, got %s and %s", signals[0].State, signals[1].State)
	}
}

func TestConstrainBounds(t *testing.T) {
	work := WorkArea{X: 100, Y: 40, Width: 1920, Height: 1040}
	got := ConstrainBounds(Bounds{X: -1000, Y: -900, Width: 294, Height: 278}, work, 72)
	if got.X != -122 || got.Y != -166 {
		t.Fatalf("got %+v", got)
	}
	got = ConstrainBounds(Bounds{X: 3000, Y: 2000, Width: 294, Height: 278}, work, 72)
	if got.X != 1948 || got.Y != 1008 {
		t.Fatalf("got %+v", got)
	}
}

func TestEffectIsAnimated(t *testing.T) {
	animated := []string{"breathe", "slow-blink", "fast-blink", "double-flash"}
	for _, effect := range animated {
		if !EffectIsAnimated(effect) {
			t.Fatalf("%s should be animated", effect)
		}
	}
	for _, effect := range []string{"steady", "off", ""} {
		if EffectIsAnimated(effect) {
			t.Fatalf("%s should not be animated", effect)
		}
	}
}

func TestEffectIntensityVariesForBlinkAndBreathe(t *testing.T) {
	base := time.UnixMilli(1_700_000_000_000)
	breatheA := EffectIntensity("breathe", base, base)
	breatheB := EffectIntensity("breathe", base.Add(800*time.Millisecond), base)
	if breatheA == breatheB {
		t.Fatalf("breathe intensity must change over time: %v vs %v", breatheA, breatheB)
	}

	on := EffectIntensity("slow-blink", base, base)
	off := EffectIntensity("slow-blink", base.Add(700*time.Millisecond), base)
	if on <= 0.5 || off >= 0.5 {
		t.Fatalf("slow-blink should alternate bright/dim, got on=%v off=%v", on, off)
	}

	fastOn := EffectIntensity("fast-blink", base, base)
	fastOff := EffectIntensity("fast-blink", base.Add(250*time.Millisecond), base)
	if fastOn <= 0.5 || fastOff >= 0.5 {
		t.Fatalf("fast-blink should alternate, got on=%v off=%v", fastOn, fastOff)
	}
}

func TestEffectIntensityDoubleFlash(t *testing.T) {
	start := time.UnixMilli(1_700_000_000_000)
	// First flash window (~0–160ms)
	if got := EffectIntensity("double-flash", start.Add(50*time.Millisecond), start); got < 0.9 {
		t.Fatalf("first flash should be bright, got %v", got)
	}
	// Gap between flashes (~160–300ms)
	if got := EffectIntensity("double-flash", start.Add(220*time.Millisecond), start); got > 0.3 {
		t.Fatalf("gap between flashes should be dim, got %v", got)
	}
	// After sequence settles to steady
	if got := EffectIntensity("double-flash", start.Add(1400*time.Millisecond), start); got != 1 {
		t.Fatalf("after double-flash should settle to 1, got %v", got)
	}
}

func TestSignalsNeedLampAnimation(t *testing.T) {
	now := time.Now()
	if SignalsNeedLampAnimation(nil, now) {
		t.Fatal("empty list should not need animation")
	}
	ready := []Signal{{State: StateReady, UpdatedAt: now.Format(time.RFC3339Nano)}}
	if SignalsNeedLampAnimation(ready, now) {
		t.Fatal("steady ready should not need animation")
	}
	thinking := []Signal{{State: StateThinking, UpdatedAt: now.Format(time.RFC3339Nano)}}
	if !SignalsNeedLampAnimation(thinking, now) {
		t.Fatal("thinking breathe must need panel animation")
	}
	working := []Signal{{State: StateWorking, UpdatedAt: now.Format(time.RFC3339Nano)}}
	if !SignalsNeedLampAnimation(working, now) {
		t.Fatal("working blink must need panel animation")
	}
}

func TestResolveAppDataRootPrefersNewAndMigratesLegacy(t *testing.T) {
	base := t.TempDir()
	preferred := filepath.Join(base, "aidengyu")
	legacy := filepath.Join(base, "CodexClaudeSignal")
	if err := os.MkdirAll(filepath.Join(legacy, "sessions"), 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(legacy, "sessions", "keep.json")
	if err := os.WriteFile(marker, []byte(`{"ok":true}`), 0o644); err != nil {
		t.Fatal(err)
	}

	got := resolveAppDataRoot(base, "aidengyu", []string{"CodexClaudeSignal"})
	if got != preferred {
		t.Fatalf("expected migrate to %s, got %s", preferred, got)
	}
	if !dirExists(preferred) {
		t.Fatal("preferred directory should exist after migrate")
	}
	if dirExists(legacy) {
		t.Fatal("legacy directory should be gone after successful rename")
	}
	if _, err := os.Stat(filepath.Join(preferred, "sessions", "keep.json")); err != nil {
		t.Fatalf("session data should move with directory: %v", err)
	}

	// Prefer existing new directory even when legacy also exists.
	base2 := t.TempDir()
	preferred2 := filepath.Join(base2, "aidengyu")
	legacy2 := filepath.Join(base2, "CodexClaudeSignal")
	if err := os.MkdirAll(preferred2, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(legacy2, 0o755); err != nil {
		t.Fatal(err)
	}
	got2 := resolveAppDataRoot(base2, "aidengyu", []string{"CodexClaudeSignal"})
	if got2 != preferred2 {
		t.Fatalf("should prefer existing new dir, got %s", got2)
	}
}

func TestIsManagedCommandAcceptsLegacyHookFlag(t *testing.T) {
	if !isManagedCommand(`"C:\aidengyu.exe" --aidengyu-hook --agent cursor`) {
		t.Fatal("new hook flag should be managed")
	}
	if !isManagedCommand(`"C:\CodexClaudeSignal.exe" --codex-claude-signal-hook --agent cursor`) {
		t.Fatal("legacy hook flag should still be managed for uninstall")
	}
	if isManagedCommand(`echo hello`) {
		t.Fatal("unrelated command must not be managed")
	}
}

func TestInstallHooksWritesAidengyuFlag(t *testing.T) {
	home := t.TempDir()
	exe := `C:\Tools\aidengyu.exe`
	if err := InstallHooks(exe, home); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(CursorHooksPath(home))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "--aidengyu-hook") {
		t.Fatalf("expected new hook flag in config, got %s", data)
	}
	if strings.Contains(string(data), "--codex-claude-signal-hook") {
		t.Fatal("new installs must not write legacy hook flag")
	}
	if !strings.Contains(string(data), "aidengyu.exe") {
		t.Fatal("hook command must point at aidengyu.exe")
	}
}
