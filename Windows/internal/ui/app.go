//go:build windows

package ui

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/sxlisme/aidengyu/windows/internal/core"
	"golang.org/x/sys/windows"
)

const (
	productTitle    = "灯语"
	wndClassMsg     = "aidengyuMsg"
	wndClassPanel   = "aidengyuPanel"
	singleInstMutex = "Local\\aidengyuWin"
	panelWidth      = 294
	headerHeight    = 34
	rowHeightSingle = 78
	rowHeightTriple = 110
	panelPadding    = 10
	timerMonitor    = 1
	timerTrayAnim   = 2

	cmdInstallHooks   = 1001
	cmdUninstallHooks = 1002
	cmdTogglePanel    = 1003
	cmdLampSingle     = 1004
	cmdLampTriple     = 1005
	cmdResetPos       = 1006
	cmdClearHistory   = 1007
	cmdExit           = 1008
	cmdSessionBase    = 2000

	// Resource id written by akavel/rsrc for -ico.
	resourceIconID = 1
)

// App is the native Windows tray + floating panel.
type App struct {
	instance     windows.Handle
	msgHwnd      windows.HWND
	panelHwnd    windows.HWND
	trayIcon     windows.Handle
	appIconBig   windows.Handle
	appIconSmall windows.Handle
	notifyData   notifyIconData
	settings     core.Settings
	signals      []core.Signal
	fingerprint  string
	panelVisible bool
	dragging     bool
	dragMoved    bool
	dragOffsetX  int32
	dragOffsetY  int32
	notified     map[string]string
	trayCh       chan trayCmd
	exePath      string
	mu           sync.Mutex
	quitting     bool

	bgBrush     windows.Handle
	headerBrush windows.Handle
	fontTitle   windows.Handle
	fontMeta    windows.Handle
	fontAgent   windows.Handle
	fontHeader  windows.Handle
}

var appSingleton *App

// ShowStartupError shows a non-console failure dialog for GUI builds.
func ShowStartupError(detail string) {
	messageBox("无法启动 "+productTitle, detail)
}

// Run starts the GUI message loop. Blocks until quit.
func Run() error {
	// The window procedure and GetMessage must stay on the thread that
	// created the window. Without this, Go can move the goroutine and the
	// window stops processing messages ("未响应").
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// Belt-and-suspenders if linked without -H windowsgui.
	freeConsole()

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if !trySingleInstance(singleInstMutex) {
		activateExistingPanel()
		return nil
	}

	a := &App{
		instance:     getModuleHandle(),
		settings:     core.LoadSettings(""),
		exePath:      exe,
		panelVisible: true,
		notified:     map[string]string{},
	}
	appSingleton = a

	a.appIconBig = loadImageIcon(a.instance, resourceIconID, 32, 32)
	a.appIconSmall = loadImageIcon(a.instance, resourceIconID, 16, 16)
	if a.appIconBig == 0 {
		a.appIconBig = extractExeIcon(exe, true)
	}
	if a.appIconSmall == 0 {
		a.appIconSmall = extractExeIcon(exe, false)
	}

	a.bgBrush = createSolidBrush(rgb(0x14, 0x1a, 0x1b))
	a.headerBrush = createSolidBrush(rgb(0x1a, 0x22, 0x24))
	a.fontTitle = createFont(-15, 600, "Segoe UI")
	a.fontMeta = createFont(-12, 400, "Segoe UI")
	a.fontAgent = createFont(-12, 600, "Segoe UI")
	a.fontHeader = createFont(-13, 600, "Segoe UI")

	wndProc := windows.NewCallback(appWndProc)
	if err := registerClass(wndClassMsg, wndProc, a.instance, a.appIconBig, a.appIconSmall); err != nil {
		return err
	}
	if err := registerClass(wndClassPanel, wndProc, a.instance, a.appIconBig, a.appIconSmall); err != nil {
		return err
	}

	msgHwnd, err := createWindow(0, 0, wndClassMsg, productTitle, 0, 0, 0, 0, hwndMessage, a.instance)
	if err != nil {
		return err
	}
	a.msgHwnd = msgHwnd

	work := monitorWorkAreaAtCursor()
	x, y := a.initialPanelPos(work)
	panelHwnd, err := createWindow(
		WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_LAYERED|WS_EX_NOACTIVATE,
		WS_POPUP,
		wndClassPanel,
		productTitle,
		x, y, panelWidth, headerHeight+rowHeightSingle+panelPadding,
		0, a.instance,
	)
	if err != nil {
		return err
	}
	a.panelHwnd = panelHwnd
	setWindowText(panelHwnd, productTitle)
	setWindowIcon(panelHwnd, a.appIconBig, a.appIconSmall)
	setLayeredAlpha(panelHwnd, 235)
	enableRoundedCorners(panelHwnd)
	setWindowPos(panelHwnd, x, y, panelWidth, headerHeight+rowHeightSingle+panelPadding, SWP_NOACTIVATE|SWP_SHOWWINDOW)

	a.addTray()
	a.trayCh = make(chan trayCmd, 1)
	go a.trayWorker()
	a.refreshSignals(true)
	showWindow(panelHwnd, SW_SHOWNOACTIVATE)
	setTimer(msgHwnd, timerMonitor, 250)
	setTimer(msgHwnd, timerTrayAnim, 200)

	messageLoop()
	return nil
}

func (a *App) initialPanelPos(work rect) (int32, int32) {
	if a.settings.PanelPosition != nil {
		return int32(a.settings.PanelPosition.X), int32(a.settings.PanelPosition.Y)
	}
	width := int32(panelWidth)
	x := work.Left + (work.Right-work.Left-width)/2
	y := work.Top + 7
	return x, y
}

func (a *App) addTray() {
	a.trayIcon = a.makeTrayIcon()
	a.notifyData = notifyIconData{
		Size:            uint32(unsafe.Sizeof(notifyIconData{})),
		Wnd:             a.msgHwnd,
		ID:              1,
		Flags:           NIF_MESSAGE | NIF_ICON | NIF_TIP,
		CallbackMessage: WM_TRAYICON,
		Icon:            a.trayIcon,
	}
	tip, _ := windows.UTF16FromString("Codex / Claude Code / Cursor 状态")
	copy(a.notifyData.Tip[:], tip)
	shellNotifyIcon(NIM_ADD, &a.notifyData)
}

func (a *App) makeTrayIcon() windows.Handle {
	state := a.aggregateState()
	color, effect := core.LampPresentation(state)
	now := time.Now()
	intensity := core.EffectIntensity(effect, now, now)
	icon := createCircleIcon(color, intensity, a.settings.LampMode == 3)
	if icon != 0 {
		return icon
	}
	// Fall back to the product icon embedded in the exe.
	if a.appIconSmall != 0 {
		return copyIcon(a.appIconSmall)
	}
	if a.appIconBig != 0 {
		return copyIcon(a.appIconBig)
	}
	return 0
}

func (a *App) updateTrayIcon() {
	icon := a.makeTrayIcon()
	if icon == 0 || a.trayCh == nil {
		destroyIcon(icon)
		return
	}
	a.enqueueTray(trayCmd{icon: icon})
}

// trayWorker calls Shell_NotifyIcon off the UI thread. That API can block
// for seconds when Explorer is busy, which Windows then reports as a hang.
func (a *App) trayWorker() {
	shown := a.trayIcon
	for cmd := range a.trayCh {
		if cmd.icon != 0 {
			nd := a.notifyData
			nd.Icon = cmd.icon
			nd.Flags = NIF_ICON
			shellNotifyIcon(NIM_MODIFY, &nd)
			if shown != 0 && shown != cmd.icon {
				destroyIcon(shown)
			}
			shown = cmd.icon
			a.trayIcon = cmd.icon
		}
		if cmd.balloon {
			showBalloon(a.msgHwnd, shown, cmd.title, cmd.body, cmd.flags)
		}
	}
}

func (a *App) enqueueTray(cmd trayCmd) {
	select {
	case a.trayCh <- cmd:
		return
	default:
	}
	select {
	case pending := <-a.trayCh:
		if pending.icon != 0 && pending.icon != cmd.icon {
			destroyIcon(pending.icon)
		}
		if pending.balloon && !cmd.balloon {
			cmd.balloon = true
			cmd.title = pending.title
			cmd.body = pending.body
			cmd.flags = pending.flags
		}
	default:
	}
	select {
	case a.trayCh <- cmd:
	default:
		destroyIcon(cmd.icon)
	}
}

func (a *App) removeTray() {
	shellNotifyIcon(NIM_DELETE, &a.notifyData)
	destroyIcon(a.trayIcon)
}

func (a *App) aggregateState() string {
	best := core.StateOffline
	bestPriority := -1
	now := time.Now()
	for _, signal := range a.signals {
		state := core.DisplayState(signal, now)
		priority := core.StatePriority(state)
		if priority > bestPriority {
			best = state
			bestPriority = priority
		}
	}
	return best
}

func visibleSignals(now time.Time) []core.Signal {
	loaded := core.LoadSignals("")
	out := make([]core.Signal, 0, len(loaded))
	for _, signal := range loaded {
		if core.ShouldShowSignal(signal, now) {
			out = append(out, signal)
		}
	}
	core.SortSignalsByDisplay(out, now)
	return out
}

func (a *App) refreshSignals(force bool) {
	now := time.Now()
	signals := visibleSignals(now)
	var b strings.Builder
	for _, s := range signals {
		b.WriteString(s.Agent)
		b.WriteByte(':')
		b.WriteString(s.SessionID)
		b.WriteByte(':')
		b.WriteString(s.UpdatedAt)
		b.WriteByte(':')
		b.WriteString(core.DisplayState(s, now))
		b.WriteByte('|')
	}
	fp := b.String()
	a.mu.Lock()
	changed := force || fp != a.fingerprint
	if changed {
		a.fingerprint = fp
		a.signals = signals
	}
	a.mu.Unlock()
	if changed {
		a.layoutPanel()
		invalidate(a.panelHwnd)
		a.notifyAttention(signals, now)
	}
}

func (a *App) rowHeight() int32 {
	if a.settings.LampMode == 3 {
		return rowHeightTriple
	}
	return rowHeightSingle
}

func (a *App) layoutPanel() {
	a.mu.Lock()
	n := len(a.signals)
	a.mu.Unlock()
	if n < 1 {
		n = 1
	}
	work := monitorWorkAreaAtCursor()
	height := headerHeight + int32(n)*a.rowHeight() + panelPadding
	maxH := work.Bottom - work.Top - 24
	if height > maxH {
		height = maxH
	}
	r := getWindowRect(a.panelHwnd)
	x, y := r.Left, r.Top
	bounds := core.ConstrainBounds(core.Bounds{
		X: float64(x), Y: float64(y), Width: panelWidth, Height: float64(height),
	}, core.WorkArea{
		X: float64(work.Left), Y: float64(work.Top),
		Width: float64(work.Right - work.Left), Height: float64(work.Bottom - work.Top),
	}, 72)
	moveWindow(a.panelHwnd, int32(bounds.X), int32(bounds.Y), panelWidth, height, true)
}

func (a *App) savePanelPosition() {
	r := getWindowRect(a.panelHwnd)
	a.settings.PanelPosition = &core.PanelPosition{X: float64(r.Left), Y: float64(r.Top)}
	_ = core.SaveSettings(a.settings, "")
}

func (a *App) togglePanel() {
	if isVisible(a.panelHwnd) {
		showWindow(a.panelHwnd, SW_HIDE)
		a.panelVisible = false
	} else {
		showWindow(a.panelHwnd, SW_SHOWNOACTIVATE)
		a.panelVisible = true
	}
}

func (a *App) resetPanelPosition() {
	work := monitorWorkAreaAtCursor()
	x := work.Left + (work.Right-work.Left-panelWidth)/2
	y := work.Top + 7
	a.settings.PanelPosition = &core.PanelPosition{X: float64(x), Y: float64(y)}
	_ = core.SaveSettings(a.settings, "")
	r := getWindowRect(a.panelHwnd)
	moveWindow(a.panelHwnd, x, y, panelWidth, r.Bottom-r.Top, true)
	showWindow(a.panelHwnd, SW_SHOWNOACTIVATE)
	a.panelVisible = true
}

func (a *App) setLampMode(mode int) {
	if mode != 3 {
		mode = 1
	}
	a.settings.LampMode = mode
	_ = core.SaveSettings(a.settings, "")
	a.layoutPanel()
	invalidate(a.panelHwnd)
	a.updateTrayIcon()
}

func (a *App) installHooks() {
	if err := core.InstallHooks(a.exePath, ""); err != nil {
		messageBox("无法安装状态连接", err.Error())
		return
	}
	messageBox("状态连接已安装", "请新开 Codex、Claude Code 和 Cursor 会话。Codex 首次加载时还需要确认 Hook 信任。")
}

func (a *App) uninstallHooks() {
	if err := core.UninstallHooks(""); err != nil {
		messageBox("无法卸载状态连接", err.Error())
		return
	}
	messageBox("状态连接已卸载", "现有会话不受影响，新会话将不再上报状态。")
}

func (a *App) clearHistory() {
	_ = core.ClearSignals("")
	a.fingerprint = ""
	a.refreshSignals(true)
}

func (a *App) showContextMenu() {
	p := getCursorPos()
	menu := createPopupMenu()
	a.mu.Lock()
	signals := append([]core.Signal(nil), a.signals...)
	a.mu.Unlock()
	now := time.Now()
	if len(signals) == 0 {
		appendMenu(menu, MF_STRING|MF_GRAYED, cmdSessionBase, "无活动会话")
	} else {
		for i, signal := range signals {
			project := projectName(signal.Cwd)
			title := core.RepairMojibake(signal.TaskTitle)
			if title == "" || title == project {
				title = project
			}
			label := title + " · " + core.StateTitle(core.DisplayState(signal, now))
			appendMenu(menu, MF_STRING, uintptr(cmdSessionBase+i), label)
		}
	}
	appendMenu(menu, MF_SEPARATOR, 0, "")
	appendMenu(menu, MF_STRING, cmdInstallHooks, "安装/修复状态连接")
	appendMenu(menu, MF_STRING, cmdUninstallHooks, "卸载状态连接")
	panelFlags := uint32(MF_STRING)
	if isVisible(a.panelHwnd) {
		panelFlags |= MF_CHECKED
	}
	appendMenu(menu, panelFlags, cmdTogglePanel, "显示顶部指示灯")

	style := createPopupMenu()
	appendMenu(style, MF_STRING, cmdLampSingle, "单灯")
	appendMenu(style, MF_STRING, cmdLampTriple, "三灯")
	if a.settings.LampMode == 3 {
		checkMenuRadioItem(style, cmdLampSingle, cmdLampTriple, cmdLampTriple)
	} else {
		checkMenuRadioItem(style, cmdLampSingle, cmdLampTriple, cmdLampSingle)
	}
	appendMenu(menu, MF_POPUP, uintptr(style), "指示灯样式")

	appendMenu(menu, MF_STRING, cmdResetPos, "重置窗口位置")
	appendMenu(menu, MF_STRING, cmdClearHistory, "清除历史灯组")
	appendMenu(menu, MF_SEPARATOR, 0, "")
	appendMenu(menu, MF_STRING, cmdExit, "退出")

	cmd := trackPopupMenu(menu, p.X, p.Y, a.msgHwnd)
	destroyMenu(style)
	destroyMenu(menu)
	a.handleCommand(cmd)
}

func (a *App) handleCommand(cmd uint32) {
	switch cmd {
	case cmdInstallHooks:
		a.installHooks()
	case cmdUninstallHooks:
		a.uninstallHooks()
	case cmdTogglePanel:
		a.togglePanel()
	case cmdLampSingle:
		a.setLampMode(1)
	case cmdLampTriple:
		a.setLampMode(3)
	case cmdResetPos:
		a.resetPanelPosition()
	case cmdClearHistory:
		a.clearHistory()
	case cmdExit:
		a.quit()
	default:
		if cmd >= cmdSessionBase {
			a.openSession(int(cmd - cmdSessionBase))
		}
	}
}

func (a *App) quit() {
	a.quitting = true
	killTimer(a.msgHwnd, timerMonitor)
	killTimer(a.msgHwnd, timerTrayAnim)
	a.removeTray()
	destroyWindow(a.panelHwnd)
	destroyWindow(a.msgHwnd)
	postQuit(0)
}

func (a *App) openSession(index int) {
	a.mu.Lock()
	if index < 0 || index >= len(a.signals) {
		a.mu.Unlock()
		return
	}
	cwd := a.signals[index].Cwd
	a.mu.Unlock()
	if strings.TrimSpace(cwd) == "" {
		messageBox(productTitle, "这个会话没有记录工作目录。")
		return
	}
	openFolder(cwd)
}

func (a *App) notifyAttention(signals []core.Signal, now time.Time) {
	for _, signal := range signals {
		state := core.DisplayState(signal, now)
		prev := a.notified[signal.SessionID]
		a.notified[signal.SessionID] = state
		if prev == "" || prev == state || !needsAttention(state) {
			continue
		}
		project := projectName(signal.Cwd)
		task := core.RepairMojibake(signal.TaskTitle)
		body := project
		if task != "" && task != project {
			body = project + "\n" + task
		}
		a.enqueueTray(trayCmd{
			balloon: true,
			title:   core.StateTitle(state),
			body:    body,
			flags:   balloonFlags(state),
		})
	}
}

func needsAttention(state string) bool {
	switch state {
	case core.StateWaitingInput, core.StateWaitingApproval, core.StateFailed, core.StateBlocked:
		return true
	default:
		return false
	}
}

func balloonFlags(state string) uint32 {
	switch state {
	case core.StateFailed, core.StateBlocked:
		return niifError
	default:
		return niifWarning
	}
}

func (a *App) rowAt(screenY int32) int {
	r := getWindowRect(a.panelHwnd)
	local := screenY - r.Top - headerHeight
	if local < 0 {
		return -1
	}
	index := int(local / a.rowHeight())
	a.mu.Lock()
	n := len(a.signals)
	a.mu.Unlock()
	if index < 0 || index >= n {
		return -1
	}
	return index
}

func absInt32(v int32) int32 {
	if v < 0 {
		return -v
	}
	return v
}

func projectName(cwd string) string {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return "未知项目"
	}
	base := filepath.Base(strings.ReplaceAll(cwd, "/", `\`))
	if base == "" || base == `.` || base == `\` {
		return "未知项目"
	}
	return base
}

func agentLabel(agent string) string {
	switch agent {
	case core.AgentClaude:
		return "Claude"
	case core.AgentCursor:
		return "Cursor"
	default:
		return "Codex"
	}
}

func agentAccent(agent string) uint32 {
	switch agent {
	case core.AgentClaude:
		return rgb(0xd9, 0x77, 0x57)
	case core.AgentCursor:
		return rgb(0xf0, 0xf0, 0xf0)
	default:
		return rgb(0x10, 0xa3, 0x7f)
	}
}

func paintPanel(hwnd windows.HWND) {
	a := appSingleton
	if a == nil {
		return
	}
	var ps paintStruct
	hdc := beginPaint(hwnd, &ps)
	defer endPaint(hwnd, &ps)

	client := getClientRect(hwnd)
	memDC := createCompatibleDC(hdc)
	bmp := createCompatibleBitmap(hdc, client.Right-client.Left, client.Bottom-client.Top)
	old := selectObject(memDC, bmp)

	fillRect(memDC, &client, a.bgBrush)
	header := rect{Left: 0, Top: 0, Right: client.Right, Bottom: headerHeight}
	fillRect(memDC, &header, a.headerBrush)

	setBkMode(memDC, TRANSPARENT)
	selectObject(memDC, a.fontHeader)
	setTextColor(memDC, rgb(0xe8, 0xee, 0xef))
	titleRect := rect{Left: 14, Top: 0, Right: client.Right - 14, Bottom: headerHeight}
	drawText(memDC, productTitle, &titleRect, DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX)

	// subtle header divider
	divBrush := createSolidBrush(rgb(0x2c, 0x36, 0x38))
	div := rect{Left: 0, Top: headerHeight - 1, Right: client.Right, Bottom: headerHeight}
	fillRect(memDC, &div, divBrush)
	deleteObject(divBrush)

	pen := createPen(PS_SOLID, 1, rgb(0x4a, 0x54, 0x56))
	oldPen := selectObject(memDC, pen)
	nullBrush := createSolidBrush(rgb(0x14, 0x1a, 0x1b))
	oldBrush := selectObject(memDC, nullBrush)
	procMoveToEx.Call(uintptr(memDC), 0, 0, 0)
	procLineTo.Call(uintptr(memDC), uintptr(client.Right-1), 0)
	procLineTo.Call(uintptr(memDC), uintptr(client.Right-1), uintptr(client.Bottom-1))
	procLineTo.Call(uintptr(memDC), 0, uintptr(client.Bottom-1))
	procLineTo.Call(uintptr(memDC), 0, 0)
	selectObject(memDC, oldPen)
	selectObject(memDC, oldBrush)
	deleteObject(pen)
	deleteObject(nullBrush)

	now := time.Now()
	a.mu.Lock()
	signals := append([]core.Signal(nil), a.signals...)
	lampMode := a.settings.LampMode
	a.mu.Unlock()

	rowH := a.rowHeight()
	contentTop := int32(headerHeight)
	if len(signals) == 0 {
		a.paintRow(memDC, contentTop, rowH, core.Signal{State: core.StateOffline}, lampMode, now, true)
	} else {
		for i, signal := range signals {
			top := contentTop + int32(i)*rowH
			a.paintRow(memDC, top, rowH, signal, lampMode, now, false)
			if i+1 < len(signals) {
				sep := rect{Left: 14, Top: top + rowH - 1, Right: client.Right - 14, Bottom: top + rowH}
				sepBrush := createSolidBrush(rgb(0x28, 0x30, 0x32))
				fillRect(memDC, &sep, sepBrush)
				deleteObject(sepBrush)
			}
		}
	}

	bitBlt(hdc, 0, 0, client.Right, client.Bottom, memDC, 0, 0)
	selectObject(memDC, old)
	deleteObject(bmp)
	deleteDC(memDC)
}

func (a *App) paintRow(hdc windows.Handle, top, height int32, signal core.Signal, lampMode int, now time.Time, empty bool) {
	state := core.DisplayState(signal, now)
	if empty {
		state = core.StateOffline
	}
	colorName, effect := core.LampPresentation(state)
	updatedAt := now
	if parsed, err := time.Parse(time.RFC3339Nano, signal.UpdatedAt); err == nil {
		updatedAt = parsed
	} else if parsed, err := time.Parse(time.RFC3339, signal.UpdatedAt); err == nil {
		updatedAt = parsed
	}
	intensity := core.EffectIntensity(effect, now, updatedAt)

	cx, cy := int32(28), top+height/2
	if lampMode == 3 {
		colors := []string{"red", "yellow", "green"}
		for i, name := range colors {
			brush := lampBrush(name, intensity, name == colorName)
			old := selectObject(hdc, brush)
			pen := createPen(PS_SOLID, 1, rgb(0x14, 0x1a, 0x1b))
			oldPen := selectObject(hdc, pen)
			lx := int32(14 + i*14)
			ellipse(hdc, lx, cy-6, lx+12, cy+6)
			selectObject(hdc, oldPen)
			selectObject(hdc, old)
			deleteObject(pen)
			deleteObject(brush)
		}
	} else {
		brush := lampBrush(colorName, intensity, colorName != "off")
		old := selectObject(hdc, brush)
		pen := createPen(PS_SOLID, 1, rgb(0x14, 0x1a, 0x1b))
		oldPen := selectObject(hdc, pen)
		ellipse(hdc, cx-9, cy-9, cx+9, cy+9)
		selectObject(hdc, oldPen)
		selectObject(hdc, old)
		deleteObject(pen)
		deleteObject(brush)
	}

	leftText := int32(56)
	if lampMode == 3 {
		leftText = 60
	}

	if empty {
		selectObject(hdc, a.fontTitle)
		setTextColor(hdc, rgb(0xa8, 0xb0, 0xb2))
		r := rect{Left: leftText, Top: top + 24, Right: panelWidth - 14, Bottom: top + 52}
		drawText(hdc, "无活动会话", &r, DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX)
		return
	}

	selectObject(hdc, a.fontAgent)
	setTextColor(hdc, agentAccent(signal.Agent))
	agentRect := rect{Left: leftText, Top: top + 8, Right: leftText + 54, Bottom: top + 28}
	drawText(hdc, agentLabel(signal.Agent), &agentRect, DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX)

	project := projectName(signal.Cwd)
	task := core.RepairMojibake(signal.TaskTitle)
	if task == project {
		task = ""
	}

	selectObject(hdc, a.fontTitle)
	setTextColor(hdc, rgb(0xf5, 0xf7, 0xf7))
	titleRect := rect{Left: leftText + 56, Top: top + 6, Right: panelWidth - 14, Bottom: top + 30}
	drawText(hdc, project, &titleRect, DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX)

	selectObject(hdc, a.fontMeta)
	setTextColor(hdc, rgb(0x92, 0x9c, 0x9e))
	if task != "" {
		projRect := rect{Left: leftText, Top: top + 36, Right: panelWidth - 78, Bottom: top + 58}
		drawText(hdc, task, &projRect, DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX)
	}

	stateColor := rgb(0xc0, 0xc8, 0xca)
	switch state {
	case core.StateReady:
		stateColor = rgb(0x2e, 0xd1, 0x64)
	case core.StateWorking, core.StateThinking:
		stateColor = rgb(0x7d, 0xe0, 0xa0)
	case core.StateFailed, core.StateBlocked:
		stateColor = rgb(0xf2, 0x30, 0x2e)
	case core.StateWaitingInput, core.StateWaitingApproval, core.StateAttention, core.StateStale:
		stateColor = rgb(0xff, 0xb8, 0x1f)
	}
	setTextColor(hdc, stateColor)
	stateRect := rect{Left: panelWidth - 74, Top: top + 36, Right: panelWidth - 12, Bottom: top + 58}
	drawText(hdc, core.StateTitle(state), &stateRect, DT_RIGHT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX)
}

func blendRGBABytes(r, g, b, a, bgR, bgG, bgB byte) uint32 {
	af := float64(a) / 255
	outR := byte(float64(r)*af + float64(bgR)*(1-af))
	outG := byte(float64(g)*af + float64(bgG)*(1-af))
	outB := byte(float64(b)*af + float64(bgB)*(1-af))
	return rgb(outR, outG, outB)
}

func lampBrush(colorName string, intensity float64, active bool) windows.Handle {
	c := lampColor(colorName)
	if !active || colorName == "off" {
		return createSolidBrush(blendRGBABytes(c.R, c.G, c.B, 0x33, 0x14, 0x1a, 0x1b))
	}
	alpha := byte((0.42 + intensity*0.58) * 255)
	return createSolidBrush(blendRGBABytes(c.R, c.G, c.B, alpha, 0x14, 0x1a, 0x1b))
}

func appWndProc(hwnd windows.HWND, message uint32, wParam, lParam uintptr) uintptr {
	a := appSingleton
	switch message {
	case WM_TRAYICON:
		switch loWord(lParam) {
		case WM_LBUTTONUP:
			if a != nil {
				a.togglePanel()
			}
		case WM_RBUTTONUP:
			if a != nil {
				a.showContextMenu()
			}
		}
		return 0
	case WM_TIMER:
		if a == nil {
			return 0
		}
		if wParam == timerMonitor {
			a.refreshSignals(false)
		} else if wParam == timerTrayAnim {
			// Tray icons already rebuild each tick. The panel must also repaint
			// or breathe/blink lamps freeze after the last state change
			// (macOS ASTrafficLightView invalidates every animation tick).
			a.updateTrayIcon()
			a.mu.Lock()
			needAnim := core.SignalsNeedLampAnimation(a.signals, time.Now())
			a.mu.Unlock()
			if needAnim && a.panelHwnd != 0 && isVisible(a.panelHwnd) {
				invalidate(a.panelHwnd)
			}
		}
		return 0
	case WM_COMMAND:
		if a != nil {
			a.handleCommand(uint32(loWord(wParam)))
		}
		return 0
	case WM_PAINT:
		if a != nil && hwnd == a.panelHwnd {
			paintPanel(hwnd)
			return 0
		}
	case WM_LBUTTONDOWN:
		if a != nil && hwnd == a.panelHwnd {
			p := getCursorPos()
			r := getWindowRect(hwnd)
			a.dragging = true
			a.dragMoved = false
			a.dragOffsetX = p.X - r.Left
			a.dragOffsetY = p.Y - r.Top
			setCapture(hwnd)
			return 0
		}
	case WM_MOUSEMOVE:
		if a != nil && a.dragging && hwnd == a.panelHwnd {
			p := getCursorPos()
			x := p.X - a.dragOffsetX
			y := p.Y - a.dragOffsetY
			r := getWindowRect(hwnd)
			if absInt32(x-r.Left) > 4 || absInt32(y-r.Top) > 4 {
				a.dragMoved = true
			}
			work := monitorWorkAreaAtCursor()
			bounds := core.ConstrainBounds(core.Bounds{
				X: float64(x), Y: float64(y),
				Width: float64(r.Right - r.Left), Height: float64(r.Bottom - r.Top),
			}, core.WorkArea{
				X: float64(work.Left), Y: float64(work.Top),
				Width: float64(work.Right - work.Left), Height: float64(work.Bottom - work.Top),
			}, 72)
			moveWindow(hwnd, int32(bounds.X), int32(bounds.Y), r.Right-r.Left, r.Bottom-r.Top, true)
			return 0
		}
	case WM_LBUTTONUP:
		if a != nil && a.dragging {
			a.dragging = false
			releaseCapture()
			if !a.dragMoved {
				if index := a.rowAt(getCursorPos().Y); index >= 0 {
					a.openSession(index)
				}
			} else {
				a.savePanelPosition()
			}
			return 0
		}
	case WM_CLOSE:
		if a != nil && hwnd == a.panelHwnd && !a.quitting {
			showWindow(hwnd, SW_HIDE)
			a.panelVisible = false
			return 0
		}
	case WM_DESTROY:
		if a != nil && hwnd == a.msgHwnd {
			postQuit(0)
		}
		return 0
	}
	return defWindowProc(hwnd, message, wParam, lParam)
}
