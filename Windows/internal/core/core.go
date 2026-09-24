// Package core implements session state, hook config merge, and title repair for Windows.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/simplifiedchinese"
)

const (
	AgentCodex  = "codex"
	AgentClaude = "claude"
	AgentCursor = "cursor"
)

const (
	StateReady           = "ready"
	StateThinking        = "thinking"
	StateWorking         = "working"
	StateWaitingInput    = "waiting_input"
	StateWaitingApproval = "waiting_approval"
	StateAttention       = "attention"
	StateCompleted       = "completed"
	StateFailed          = "failed"
	StateBlocked         = "blocked"
	StateStale           = "stale"
	StateOffline         = "offline"
)

var CodexHookEvents = []string{
	"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
	"PermissionRequest", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
}

var ClaudeHookEvents = []string{
	"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
	"PostToolUseFailure", "PermissionRequest", "Notification",
	"SubagentStart", "SubagentStop", "Stop", "SessionEnd",
}

var CursorHookEvents = []string{
	"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse",
	"postToolUseFailure", "subagentStart", "subagentStop", "preCompact",
	"stop", "sessionEnd",
}

var stateTitles = map[string]string{
	StateReady:           "就绪",
	StateThinking:        "思考中",
	StateWorking:         "执行中",
	StateWaitingInput:    "等待回答",
	StateWaitingApproval: "等待授权",
	StateAttention:       "需要留意",
	StateCompleted:       "已完成",
	StateFailed:          "执行失败",
	StateBlocked:         "已阻塞",
	StateStale:           "状态过期",
	StateOffline:         "已退出",
}

var nonAlnum = regexp.MustCompile(`[^a-z0-9]+`)

// Signal is the on-disk session status record.
type Signal struct {
	SchemaVersion int    `json:"schema_version"`
	Agent         string `json:"agent"`
	SessionID     string `json:"session_id"`
	State         string `json:"state"`
	EventName     string `json:"event_name"`
	UpdatedAt     string `json:"updated_at"`
	Cwd           string `json:"cwd,omitempty"`
	Detail        string `json:"detail,omitempty"`
	TaskTitle     string `json:"task_title,omitempty"`
}

type Settings struct {
	LampMode      int             `json:"lampMode"`
	PanelPosition *PanelPosition  `json:"panelPosition"`
}

type PanelPosition struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type Bounds struct {
	X, Y, Width, Height float64
}

type WorkArea struct {
	X, Y, Width, Height float64
}

type HookStatus struct {
	CodexInstalled  bool `json:"codex_installed"`
	ClaudeInstalled bool `json:"claude_installed"`
	CursorInstalled bool `json:"cursor_installed"`
	AllInstalled    bool `json:"all_installed"`
}

func StateTitle(state string) string {
	if title, ok := stateTitles[state]; ok {
		return title
	}
	return "未知"
}

func StatePriority(state string) int {
	switch state {
	case StateBlocked:
		return 100
	case StateFailed:
		return 90
	case StateWaitingApproval:
		return 80
	case StateWaitingInput:
		return 70
	case StateAttention:
		return 60
	case StateWorking:
		return 50
	case StateThinking:
		return 40
	case StateCompleted:
		return 30
	case StateReady:
		return 20
	case StateOffline:
		return 10
	case StateStale:
		return 0
	default:
		return 0
	}
}

func DisplayState(signal Signal, now time.Time) string {
	state := signal.State
	if state == "" {
		state = StateStale
	}
	updatedAt, err := time.Parse(time.RFC3339Nano, signal.UpdatedAt)
	if err != nil {
		updatedAt, err = time.Parse(time.RFC3339, signal.UpdatedAt)
	}
	if err != nil {
		return StateStale
	}
	age := now.Sub(updatedAt)
	if state == StateCompleted && age > 15*time.Second {
		return StateReady
	}
	if state == StateWaitingApproval && age > 30*time.Second {
		return StateAttention
	}
	// Cursor frequently omits `stop` after the last postToolUse (Task subagents,
	// aborted turns). preToolUse must stay "working" so long-running tools remain
	// accurate; only settle post-tool working once idle.
	if state == StateWorking && age > 45*time.Second && postToolIdleEvent(signal.EventName) {
		return StateReady
	}
	terminal := map[string]bool{
		StateOffline: true, StateCompleted: true, StateFailed: true, StateBlocked: true,
	}
	if !terminal[state] && age > 600*time.Second {
		return StateStale
	}
	return state
}

func postToolIdleEvent(eventName string) bool {
	switch normalize(eventName) {
	case "posttooluse", "posttoolbatch", "taskcompleted":
		return true
	default:
		return false
	}
}

// IsPhantomReadySession reports idle Cursor/Codex rows that only ever got
// sessionStart with no workspace — empty-window multitask chatter that would
// otherwise linger as duplicated "未知项目 / 就绪".
func IsPhantomReadySession(signal Signal) bool {
	if signal.State != StateReady {
		return false
	}
	if strings.TrimSpace(signal.Cwd) != "" || strings.TrimSpace(signal.TaskTitle) != "" {
		return false
	}
	event := normalize(signal.EventName)
	return event == "sessionstart" || event == ""
}

// ShouldShowSignal applies offline fade-out and phantom-session filtering for the panel.
func ShouldShowSignal(signal Signal, now time.Time) bool {
	if IsPhantomReadySession(signal) {
		return false
	}
	if signal.State != StateOffline {
		return true
	}
	updated, err := time.Parse(time.RFC3339Nano, signal.UpdatedAt)
	if err != nil {
		updated, err = time.Parse(time.RFC3339, signal.UpdatedAt)
	}
	if err != nil {
		return false
	}
	return now.Sub(updated) <= 3*time.Second
}

// SortSignalsByDisplay orders sessions for the status list: higher StatePriority(DisplayState)
// first. Must use display state (not disk state) so expired "stale" rows sink below valid ones
// such as settled completed→ready, even when the on-disk state is still working/thinking.
func SortSignalsByDisplay(signals []Signal, now time.Time) {
	sort.SliceStable(signals, func(i, j int) bool {
		pi := StatePriority(DisplayState(signals[i], now))
		pj := StatePriority(DisplayState(signals[j], now))
		if pi != pj {
			return pi > pj
		}
		if signals[i].Agent != signals[j].Agent {
			return signals[i].Agent < signals[j].Agent
		}
		return signals[i].UpdatedAt > signals[j].UpdatedAt
	})
}

func LampPresentation(state string) (color, effect string) {
	switch state {
	case StateReady:
		return "green", "steady"
	case StateThinking:
		return "green", "breathe"
	case StateWorking:
		return "green", "slow-blink"
	case StateWaitingInput:
		return "yellow", "slow-blink"
	case StateWaitingApproval:
		return "yellow", "fast-blink"
	case StateAttention, StateStale:
		return "yellow", "steady"
	case StateCompleted:
		return "green", "double-flash"
	case StateFailed:
		return "red", "steady"
	case StateBlocked:
		return "red", "fast-blink"
	default:
		return "off", "off"
	}
}

// EffectIsAnimated reports whether a lamp effect changes over time and therefore
// requires periodic panel/tray redraws (macOS ASTrafficLightView animationTick).
func EffectIsAnimated(effect string) bool {
	switch effect {
	case "breathe", "slow-blink", "fast-blink", "double-flash":
		return true
	default:
		return false
	}
}

// EffectIntensity returns the current brightness multiplier for a lamp effect.
// updatedAt is used by double-flash; other effects key off now only.
func EffectIntensity(effect string, now, updatedAt time.Time) float64 {
	ms := float64(now.UnixMilli())
	switch effect {
	case "off":
		return 0
	case "steady":
		return 1
	case "breathe":
		return 0.32 + 0.68*((math.Sin(ms*math.Pi*2/1600)+1)/2)
	case "slow-blink":
		if int64(ms)%1000 < 580 {
			return 1
		}
		return 0.12
	case "fast-blink":
		if int64(ms)%400 < 200 {
			return 1
		}
		return 0.1
	case "double-flash":
		if updatedAt.IsZero() {
			updatedAt = now
		}
		elapsed := now.Sub(updatedAt).Seconds()
		if elapsed < 0 {
			elapsed = 0
		}
		if elapsed >= 1.35 {
			return 1
		}
		phase := math.Mod(elapsed, 0.8)
		if phase < 0.16 || (phase >= 0.3 && phase < 0.46) {
			return 1
		}
		return 0.12
	default:
		return 1
	}
}

// SignalsNeedLampAnimation is true when any visible session uses a time-varying lamp effect.
func SignalsNeedLampAnimation(signals []Signal, now time.Time) bool {
	for _, signal := range signals {
		_, effect := LampPresentation(DisplayState(signal, now))
		if EffectIsAnimated(effect) {
			return true
		}
	}
	return false
}

func ConstrainBounds(bounds Bounds, workArea WorkArea, minimumVisible float64) Bounds {
	if minimumVisible == 0 {
		minimumVisible = 72
	}
	bounds.X = minFloat(maxFloat(bounds.X, workArea.X-bounds.Width+minimumVisible),
		workArea.X+workArea.Width-minimumVisible)
	bounds.Y = minFloat(maxFloat(bounds.Y, workArea.Y-bounds.Height+minimumVisible),
		workArea.Y+workArea.Height-minimumVisible)
	return bounds
}

func firstString(payload map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := payload[key].(string); ok && value != "" {
			return value
		}
	}
	return ""
}

func normalize(value string) string {
	return nonAlnum.ReplaceAllString(strings.ToLower(value), "")
}

func TaskTitleFromPayload(payload map[string]any) string {
	prompt := firstString(payload, "prompt", "user_prompt", "userPrompt")
	if prompt == "" {
		return ""
	}
	var firstLine string
	for _, line := range strings.Split(strings.ReplaceAll(prompt, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			firstLine = trimmed
			break
		}
	}
	if firstLine == "" {
		return ""
	}
	space := regexp.MustCompile(`\s+`)
	clean := space.ReplaceAllString(firstLine, " ")
	trimMarks := regexp.MustCompile(`^[ #>*\-\x60\t]+|[ #>*\-\x60\t]+$`)
	clean = trimMarks.ReplaceAllString(clean, "")
	clean = RepairMojibake(clean)
	if clean == "" {
		return ""
	}
	runes := []rune(clean)
	if len(runes) > 36 {
		return string(runes[:36]) + "..."
	}
	return clean
}

// RepairMojibake fixes task titles whose UTF-8 bytes were decoded as GBK/GB18030
// (classic Windows CP936 mojibake). Correct Chinese and plain ASCII are unchanged.
//
// Live Cursor hooks on Chinese Windows often produce GB18030 mojibake that includes
// BMP private-use codepoints (e.g. U+E632) and signs like ℃. golang.org/x/text
// encodes those PUA runes as 4-byte GB18030 sequences, which does not reverse the
// original UTF-8. Windows WideCharToMultiByte(936/54936) maps them back to the
// original 2-byte sequences and restores the title.
func RepairMojibake(s string) string {
	if s == "" || !hasHan(s) {
		return s
	}
	// Drop Unicode replacement chars left by earlier failed decodes; they block
	// Windows CP936 round-trips and are never part of the recovered UTF-8.
	s = stripReplacementRunes(s)
	if s == "" || !hasHan(s) {
		return s
	}
	if fixed, ok := repairMojibakeWindows(s); ok {
		return fixed
	}
	if fixed, ok := repairMojibakeWith(s, simplifiedchinese.GBK); ok {
		return fixed
	}
	if fixed, ok := repairMojibakeWith(s, simplifiedchinese.GB18030); ok {
		return fixed
	}
	return s
}

func stripReplacementRunes(s string) string {
	if !strings.ContainsRune(s, '\uFFFD') {
		return s
	}
	return strings.Map(func(r rune) rune {
		if r == '\uFFFD' {
			return -1
		}
		return r
	}, s)
}

func repairMojibakeWindows(s string) (string, bool) {
	for _, cp := range []uint32{codePageGBK, codePageGB18030} {
		raw, ok := encodeWindowsCodePage(cp, s)
		if !ok || len(raw) == 0 {
			continue
		}
		// Require a contiguous valid UTF-8 payload. Correct Chinese encoded as
		// CP936 is not valid UTF-8; mojibake reversed through CP936 is.
		trimmed := raw
		for len(trimmed) > 0 && !utf8.Valid(trimmed) && len(raw)-len(trimmed) < 3 {
			trimmed = trimmed[:len(trimmed)-1]
		}
		if !utf8.Valid(trimmed) {
			continue
		}
		if fixed, ok := acceptMojibakeRepair(s, string(trimmed)); ok {
			return fixed, true
		}
	}
	return "", false
}

func repairMojibakeWith(s string, enc encoding.Encoding) (string, bool) {
	encoder := enc.NewEncoder()
	raw := make([]byte, 0, len(s)*2)
	for _, r := range s {
		if r == '\uFFFD' || isPrivateUse(r) {
			continue
		}
		part, err := encoder.Bytes([]byte(string(r)))
		if err != nil || len(part) == 0 {
			continue
		}
		raw = append(raw, part...)
	}
	if len(raw) == 0 {
		return "", false
	}
	trimmed := raw
	for len(trimmed) > 0 && !utf8.Valid(trimmed) && len(raw)-len(trimmed) < 3 {
		trimmed = trimmed[:len(trimmed)-1]
	}
	if !utf8.Valid(trimmed) {
		return "", false
	}
	return acceptMojibakeRepair(s, string(trimmed))
}

func acceptMojibakeRepair(original, fixed string) (string, bool) {
	fixed = strings.TrimSpace(fixed)
	if fixed == "" || fixed == original || strings.ContainsRune(fixed, '\uFFFD') || !hasHan(fixed) {
		return "", false
	}
	// Misread UTF-8 as GBK usually expands rune count; reject "repairs" that do not shrink.
	if utf8.RuneCountInString(fixed) >= utf8.RuneCountInString(original) {
		return "", false
	}
	// Prefer repairs that drop private-use / degree-C junk typical of GB18030 mojibake.
	if hasPrivateUse(fixed) {
		return "", false
	}
	return fixed, true
}

func isPrivateUse(r rune) bool {
	return (r >= 0xE000 && r <= 0xF8FF) || (r >= 0xF0000 && r <= 0xFFFFD) || (r >= 0x100000 && r <= 0x10FFFD)
}

func hasPrivateUse(s string) bool {
	for _, r := range s {
		if isPrivateUse(r) {
			return true
		}
	}
	return false
}

func hasHan(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

func valueMeansFailure(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case float64:
		return v != 0
	case string:
		return v != ""
	default:
		return true
	}
}

func hasStructuredFailure(payload map[string]any) bool {
	for _, key := range []string{"error", "failure", "exception"} {
		if valueMeansFailure(payload[key]) {
			return true
		}
	}
	for _, key := range []string{"exit_status", "exitStatus", "exit_code", "exitCode"} {
		if value, ok := payload[key]; ok {
			switch v := value.(type) {
			case float64:
				if v != 0 {
					return true
				}
			case string:
				n, err := strconv.ParseFloat(v, 64)
				if err == nil && n != 0 {
					return true
				}
			default:
				if valueMeansFailure(value) {
					return true
				}
			}
		}
	}
	for _, key := range []string{"is_error", "isError"} {
		if payload[key] == true {
			return true
		}
	}
	if nested, ok := payload["tool_response"].(map[string]any); ok {
		return hasStructuredFailure(nested)
	}
	if nested, ok := payload["toolResponse"].(map[string]any); ok {
		return hasStructuredFailure(nested)
	}
	return false
}

func isHardBlock(payload map[string]any, event string) bool {
	reason := firstString(payload, "error", "failure", "reason", "stop_reason", "stopReason")
	combined := normalize(event) + normalize(reason)
	for _, term := range []string{
		"ratelimit", "usagelimit", "maxbudget", "maxtokens", "authentication",
		"unauthorized", "forbidden", "permissiondenied", "blocked",
	} {
		if strings.Contains(combined, term) {
			return true
		}
	}
	return false
}

func StateForEvent(eventName string, payload map[string]any) string {
	if payload == nil {
		payload = map[string]any{}
	}
	event := normalize(eventName)
	tool := normalize(firstString(payload, "tool_name", "toolName"))
	notification := normalize(firstString(payload, "notification_type", "notificationType", "type"))
	status := normalize(firstString(payload, "status"))

	if status == "error" || hasStructuredFailure(payload) || strings.Contains(event, "failure") || strings.Contains(event, "error") {
		if isHardBlock(payload, event) {
			return StateBlocked
		}
		return StateFailed
	}
	if strings.Contains(event, "permissiondenied") {
		return StateBlocked
	}
	if event == "permissionrequest" {
		return StateWaitingApproval
	}
	if event == "notification" {
		if strings.Contains(notification, "permission") {
			return StateWaitingApproval
		}
		if strings.Contains(notification, "idleprompt") || strings.Contains(notification, "question") {
			return StateWaitingInput
		}
		return StateAttention
	}
	if event == "pretooluse" {
		for _, term := range []string{"askuserquestion", "requestuserinput", "elicitation"} {
			if strings.Contains(tool, term) {
				return StateWaitingInput
			}
		}
		return StateWorking
	}
	if event == "sessionstart" {
		return StateReady
	}
	if event == "userpromptsubmit" || event == "userpromptexpansion" || event == "beforesubmitprompt" {
		return StateThinking
	}
	if event == "subagentstop" {
		return StateCompleted
	}
	working := map[string]bool{
		"posttooluse": true, "posttoolbatch": true, "precompact": true, "postcompact": true,
		"subagentstart": true, "taskcreated": true, "taskcompleted": true, "worktreecreate": true,
		"elicitationresult": true,
	}
	if working[event] {
		return StateWorking
	}
	waiting := map[string]bool{"askuserquestion": true, "requestuserinput": true, "elicitation": true}
	if waiting[event] {
		return StateWaitingInput
	}
	attention := map[string]bool{
		"configchange": true, "cwdchanged": true, "filechanged": true,
		"instructionsloaded": true, "worktreeremove": true,
	}
	if attention[event] {
		return StateAttention
	}
	if event == "stop" {
		if isHardBlock(payload, event) {
			return StateBlocked
		}
		return StateCompleted
	}
	if event == "sessionend" {
		return StateOffline
	}
	return StateThinking
}

// ResolveAgent attributes by event-name dialect (exact, case-sensitive).
// Cursor alone imports ~/.claude/settings.json and re-invokes those commands with
// camelCase payloads while keeping --agent claude. Claude Code / Codex do not
// execute ~/.cursor/hooks.json; their PascalCase events must stay put.
func ResolveAgent(agent, eventName string) string {
	for _, event := range CursorHookEvents {
		if eventName == event {
			return AgentCursor
		}
	}
	if agent == AgentClaude || agent == AgentCursor || agent == AgentCodex {
		return agent
	}
	return AgentCodex
}

func MapHookPayload(payload map[string]any, agent, fallbackEvent string, now time.Time) (Signal, error) {
	if payload == nil {
		payload = map[string]any{}
	}
	sessionID := firstString(payload, "session_id", "sessionId", "conversation_id", "conversationId")
	if sessionID == "" {
		return Signal{}, errors.New("Hook input has no session id.")
	}
	eventName := firstString(payload, "hook_event_name", "hookEventName", "event", "event_name", "eventName")
	if eventName == "" {
		if fallbackEvent != "" {
			eventName = fallbackEvent
		} else {
			eventName = "Unknown"
		}
	}
	var cwd string
	cwd = firstString(payload, "cwd", "working_directory", "workingDirectory")
	if cwd == "" {
		if roots, ok := payload["workspace_roots"].([]any); ok {
			for _, root := range roots {
				if s, ok := root.(string); ok && s != "" {
					cwd = s
					break
				}
			}
		}
	}
	detail := firstString(payload, "message", "error", "reason", "stop_reason", "stopReason", "notification_type", "notificationType")
	signal := Signal{
		SchemaVersion: 1,
		Agent:         ResolveAgent(agent, eventName),
		SessionID:     sessionID,
		State:         StateForEvent(eventName, payload),
		EventName:     eventName,
		UpdatedAt:     now.UTC().Format("2006-01-02T15:04:05.000Z"),
	}
	if cwd != "" {
		signal.Cwd = cwd
	}
	if detail != "" {
		signal.Detail = detail
	}
	if title := TaskTitleFromPayload(payload); title != "" {
		signal.TaskTitle = title
	}
	return signal, nil
}

func MergeSignal(existing *Signal, incoming Signal) Signal {
	if existing == nil {
		return incoming
	}
	oldState := existing.State
	newState := incoming.State
	event := normalize(incoming.EventName)
	oldNeedsProtection := oldState == StateAttention || oldState == StateFailed || oldState == StateBlocked
	resolvingEvent := event == "sessionstart" || event == "userpromptsubmit" || event == "posttooluse"
	lowPriorityEvent := event == "stop" || strings.HasPrefix(event, "subagent")

	if oldState == StateWaitingApproval && newState == StateWaitingApproval && event == "notification" {
		merged := incoming
		if existing.UpdatedAt != "" {
			merged.UpdatedAt = existing.UpdatedAt
		}
		if merged.TaskTitle == "" {
			merged.TaskTitle = existing.TaskTitle
		}
		if merged.Cwd == "" {
			merged.Cwd = existing.Cwd
		}
		return merged
	}
	// In-flight postToolUse can arrive after stop; do not reopen completed as working.
	if oldState == StateCompleted && newState == StateWorking && postToolIdleEvent(incoming.EventName) {
		merged := *existing
		if incoming.TaskTitle != "" {
			merged.TaskTitle = incoming.TaskTitle
		}
		if incoming.Cwd != "" {
			merged.Cwd = incoming.Cwd
		}
		return merged
	}
	if oldNeedsProtection && !resolvingEvent && lowPriorityEvent && StatePriority(oldState) > StatePriority(newState) {
		return *existing
	}
	merged := incoming
	if merged.TaskTitle == "" {
		merged.TaskTitle = existing.TaskTitle
	}
	if merged.Cwd == "" {
		merged.Cwd = existing.Cwd
	}
	return merged
}

func SignalRoot() string {
	if home := os.Getenv("AIDENGYU_HOME"); home != "" {
		return filepath.Clean(home)
	}
	if home := os.Getenv("CODEX_CLAUDE_SIGNAL_HOME"); home != "" {
		return filepath.Clean(home)
	}
	base := ""
	if appData := os.Getenv("APPDATA"); appData != "" {
		base = appData
	} else {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "AppData", "Roaming")
	}
	return resolveAppDataRoot(base, "aidengyu", []string{"CodexClaudeSignal"})
}

// resolveAppDataRoot prefers the new product directory. If it does not exist but a
// legacy directory does, attempt a one-time rename; on failure keep reading the legacy path.
func resolveAppDataRoot(base, preferredName string, legacyNames []string) string {
	preferred := filepath.Join(base, preferredName)
	if dirExists(preferred) {
		return preferred
	}
	for _, name := range legacyNames {
		legacy := filepath.Join(base, name)
		if !dirExists(legacy) {
			continue
		}
		if err := os.Rename(legacy, preferred); err == nil {
			return preferred
		}
		return legacy
	}
	return preferred
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func safeFilePart(value string) string {
	runes := []rune(value)
	if len(runes) > 160 {
		runes = runes[:160]
	}
	var b strings.Builder
	for _, r := range runes {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func SessionsDirectory(root string) string {
	if root == "" {
		root = SignalRoot()
	}
	return filepath.Join(root, "sessions")
}

func loadJSON(file string, dest any) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, dest)
}

func writeJSONAtomic(file string, value any) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	temporary := fmt.Sprintf("%s.%d.%d.tmp", file, os.Getpid(), time.Now().UnixNano())
	if err := os.WriteFile(temporary, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(temporary, file); err != nil {
		_ = os.Remove(file)
		return os.Rename(temporary, file)
	}
	return nil
}

func WriteSignal(signal Signal, root string) (string, error) {
	if root == "" {
		root = SignalRoot()
	}
	corrected := signal
	corrected.Agent = ResolveAgent(signal.Agent, signal.EventName)
	directory := SessionsDirectory(root)
	file := filepath.Join(directory, fmt.Sprintf("%s-%s.json", corrected.Agent, safeFilePart(corrected.SessionID)))
	var existing Signal
	var existingPtr *Signal
	if err := loadJSON(file, &existing); err == nil && existing.SchemaVersion == 1 {
		existingPtr = &existing
	}
	merged := MergeSignal(existingPtr, corrected)
	if err := writeJSONAtomic(file, merged); err != nil {
		return "", err
	}
	if corrected.Agent == AgentCursor {
		for _, other := range []string{AgentCodex, AgentClaude} {
			sibling := filepath.Join(directory, fmt.Sprintf("%s-%s.json", other, safeFilePart(corrected.SessionID)))
			var prior Signal
			if err := loadJSON(sibling, &prior); err != nil {
				continue
			}
			if ResolveAgent(prior.Agent, prior.EventName) == AgentCursor {
				_ = os.Remove(sibling)
			}
		}
	}
	return file, nil
}

func LoadSignals(root string) []Signal {
	if root == "" {
		root = SignalRoot()
	}
	directory := SessionsDirectory(root)
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil
	}
	var loaded []Signal
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		var signal Signal
		if err := loadJSON(filepath.Join(directory, entry.Name()), &signal); err != nil {
			continue
		}
		if signal.SchemaVersion != 1 {
			continue
		}
		signal.Agent = ResolveAgent(signal.Agent, signal.EventName)
		signal.TaskTitle = RepairMojibake(signal.TaskTitle)
		loaded = append(loaded, signal)
	}
	byKey := map[string]Signal{}
	for _, signal := range loaded {
		key := signal.Agent + "\x00" + signal.SessionID
		previous, ok := byKey[key]
		if !ok {
			byKey[key] = signal
			continue
		}
		if signal.UpdatedAt >= previous.UpdatedAt {
			merged := MergeSignal(&previous, signal)
			byKey[key] = merged
		} else {
			merged := MergeSignal(&signal, previous)
			byKey[key] = merged
		}
	}
	out := make([]Signal, 0, len(byKey))
	for _, signal := range byKey {
		out = append(out, signal)
	}
	return out
}

func ClearSignals(root string) error {
	if root == "" {
		root = SignalRoot()
	}
	directory := SessionsDirectory(root)
	entries, err := os.ReadDir(directory)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".json") {
			_ = os.Remove(filepath.Join(directory, entry.Name()))
		}
	}
	return nil
}

func CodexHooksPath(home string) string {
	return filepath.Join(home, ".codex", "hooks.json")
}

func ClaudeSettingsPath(home string) string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, "settings.json")
	}
	return filepath.Join(home, ".claude", "settings.json")
}

func CursorHooksPath(home string) string {
	return filepath.Join(home, ".cursor", "hooks.json")
}

func windowsQuote(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `""`) + `"`
}

func isManagedCommand(command any) bool {
	s, ok := command.(string)
	if !ok {
		return false
	}
	return strings.Contains(s, "--aidengyu-hook") || strings.Contains(s, "--codex-claude-signal-hook")
}

func isManagedGroup(group any) bool {
	m, ok := group.(map[string]any)
	if !ok {
		return false
	}
	hooks, ok := m["hooks"].([]any)
	if !ok {
		return false
	}
	for _, handler := range hooks {
		hm, ok := handler.(map[string]any)
		if !ok {
			continue
		}
		if isManagedCommand(hm["command"]) {
			return true
		}
	}
	return false
}

func backupAndWriteConfig(file string, root map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(file); err == nil {
		stamp := time.Now().UTC().Format("20060102150405")
		_ = copyFile(file, file+".bak-"+stamp+"000")
	}
	return writeJSONAtomic(file, root)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

func loadObject(file string) (map[string]any, error) {
	var root map[string]any
	if err := loadJSON(file, &root); err != nil {
		if os.IsNotExist(err) {
			return map[string]any{}, nil
		}
		return nil, err
	}
	if root == nil {
		return nil, fmt.Errorf("配置文件不是有效 JSON 对象：%s", file)
	}
	return root, nil
}

func mergeHooksAtPath(file string, events []string, agent, executablePath string) error {
	root, err := loadObject(file)
	if err != nil {
		return err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	command := windowsQuote(executablePath) + " --aidengyu-hook --agent " + agent
	for _, event := range events {
		current, _ := hooks[event].([]any)
		filtered := make([]any, 0, len(current))
		for _, group := range current {
			if !isManagedGroup(group) {
				filtered = append(filtered, group)
			}
		}
		timeout := 3
		if event == "PermissionRequest" {
			timeout = 5
		}
		filtered = append(filtered, map[string]any{
			"hooks": []any{
				map[string]any{"type": "command", "command": command, "timeout": timeout},
			},
		})
		hooks[event] = filtered
	}
	root["hooks"] = hooks
	return backupAndWriteConfig(file, root)
}

func mergeCursorHooksAtPath(file, executablePath string) error {
	root, err := loadObject(file)
	if err != nil {
		return err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	command := windowsQuote(executablePath) + " --aidengyu-hook --agent " + AgentCursor
	for _, event := range CursorHookEvents {
		current, _ := hooks[event].([]any)
		filtered := make([]any, 0, len(current))
		for _, entry := range current {
			em, ok := entry.(map[string]any)
			if ok && isManagedCommand(em["command"]) {
				continue
			}
			filtered = append(filtered, entry)
		}
		filtered = append(filtered, map[string]any{"command": command})
		hooks[event] = filtered
	}
	if _, ok := root["version"]; !ok {
		root["version"] = 1
	}
	root["hooks"] = hooks
	return backupAndWriteConfig(file, root)
}

func InstallHooks(executablePath, home string) error {
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return err
		}
	}
	if err := mergeHooksAtPath(CodexHooksPath(home), CodexHookEvents, AgentCodex, executablePath); err != nil {
		return err
	}
	if err := mergeHooksAtPath(ClaudeSettingsPath(home), ClaudeHookEvents, AgentClaude, executablePath); err != nil {
		return err
	}
	return mergeCursorHooksAtPath(CursorHooksPath(home), executablePath)
}

func removeHooksAtPath(file string) error {
	if _, err := os.Stat(file); err != nil {
		return nil
	}
	root, err := loadObject(file)
	if err != nil {
		return err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	for event, groups := range hooks {
		list, ok := groups.([]any)
		if !ok {
			continue
		}
		filtered := make([]any, 0, len(list))
		for _, group := range list {
			if !isManagedGroup(group) {
				filtered = append(filtered, group)
			}
		}
		if len(filtered) > 0 {
			hooks[event] = filtered
		} else {
			delete(hooks, event)
		}
	}
	root["hooks"] = hooks
	return backupAndWriteConfig(file, root)
}

func removeCursorHooksAtPath(file string) error {
	if _, err := os.Stat(file); err != nil {
		return nil
	}
	root, err := loadObject(file)
	if err != nil {
		return err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	for event, entries := range hooks {
		list, ok := entries.([]any)
		if !ok {
			continue
		}
		filtered := make([]any, 0, len(list))
		for _, entry := range list {
			em, ok := entry.(map[string]any)
			if ok && isManagedCommand(em["command"]) {
				continue
			}
			filtered = append(filtered, entry)
		}
		if len(filtered) > 0 {
			hooks[event] = filtered
		} else {
			delete(hooks, event)
		}
	}
	root["hooks"] = hooks
	return backupAndWriteConfig(file, root)
}

func UninstallHooks(home string) error {
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return err
		}
	}
	_ = removeHooksAtPath(CodexHooksPath(home))
	_ = removeHooksAtPath(ClaudeSettingsPath(home))
	return removeCursorHooksAtPath(CursorHooksPath(home))
}

func configContainsHook(file, executablePath, agent string) bool {
	root, err := loadObject(file)
	if err != nil {
		return false
	}
	hooks, _ := root["hooks"].(map[string]any)
	groups, _ := hooks["SessionStart"].([]any)
	for _, group := range groups {
		gm, ok := group.(map[string]any)
		if !ok {
			continue
		}
		handlers, _ := gm["hooks"].([]any)
		for _, handler := range handlers {
			hm, ok := handler.(map[string]any)
			if !ok {
				continue
			}
			command, _ := hm["command"].(string)
			if strings.Contains(command, executablePath) && strings.Contains(command, "--agent "+agent) {
				return true
			}
		}
	}
	return false
}

func cursorConfigContainsHook(file, executablePath string) bool {
	root, err := loadObject(file)
	if err != nil {
		return false
	}
	hooks, _ := root["hooks"].(map[string]any)
	entries, _ := hooks["sessionStart"].([]any)
	for _, entry := range entries {
		em, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		command, _ := em["command"].(string)
		if strings.Contains(command, executablePath) && strings.Contains(command, "--agent "+AgentCursor) {
			return true
		}
	}
	return false
}

func GetHookStatus(executablePath, home string) HookStatus {
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	codex := configContainsHook(CodexHooksPath(home), executablePath, AgentCodex)
	claude := configContainsHook(ClaudeSettingsPath(home), executablePath, AgentClaude)
	cursor := cursorConfigContainsHook(CursorHooksPath(home), executablePath)
	return HookStatus{
		CodexInstalled:  codex,
		ClaudeInstalled: claude,
		CursorInstalled: cursor,
		AllInstalled:    codex && claude && cursor,
	}
}

func settingsPath(root string) string {
	if root == "" {
		root = SignalRoot()
	}
	return filepath.Join(root, "settings.json")
}

func LoadSettings(root string) Settings {
	var value Settings
	_ = loadJSON(settingsPath(root), &value)
	if value.LampMode != 3 {
		value.LampMode = 1
	}
	if value.PanelPosition != nil {
		// keep as-is
	}
	return value
}

func SaveSettings(settings Settings, root string) error {
	return writeJSONAtomic(settingsPath(root), settings)
}

func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func maxFloat(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
