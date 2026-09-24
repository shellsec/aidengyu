//go:build windows

package ui

import (
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modUser32   = windows.NewLazySystemDLL("user32.dll")
	modGdi32    = windows.NewLazySystemDLL("gdi32.dll")
	modShell32  = windows.NewLazySystemDLL("shell32.dll")
	modKernel32 = windows.NewLazySystemDLL("kernel32.dll")
	modDwmapi   = windows.NewLazySystemDLL("dwmapi.dll")

	procRegisterClassExW     = modUser32.NewProc("RegisterClassExW")
	procCreateWindowExW      = modUser32.NewProc("CreateWindowExW")
	procDestroyWindow        = modUser32.NewProc("DestroyWindow")
	procShowWindow           = modUser32.NewProc("ShowWindow")
	procFindWindowW          = modUser32.NewProc("FindWindowW")
	procUpdateWindow         = modUser32.NewProc("UpdateWindow")
	procGetMessageW          = modUser32.NewProc("GetMessageW")
	procTranslateMessage     = modUser32.NewProc("TranslateMessage")
	procDispatchMessageW     = modUser32.NewProc("DispatchMessageW")
	procDefWindowProcW       = modUser32.NewProc("DefWindowProcW")
	procPostQuitMessage      = modUser32.NewProc("PostQuitMessage")
	procPostMessageW         = modUser32.NewProc("PostMessageW")
	procSetTimer             = modUser32.NewProc("SetTimer")
	procKillTimer            = modUser32.NewProc("KillTimer")
	procInvalidateRect       = modUser32.NewProc("InvalidateRect")
	procGetClientRect        = modUser32.NewProc("GetClientRect")
	procGetWindowRect        = modUser32.NewProc("GetWindowRect")
	procSetWindowPos         = modUser32.NewProc("SetWindowPos")
	procMoveWindow           = modUser32.NewProc("MoveWindow")
	procSetLayeredWindowAttributes = modUser32.NewProc("SetLayeredWindowAttributes")
	procLoadCursorW          = modUser32.NewProc("LoadCursorW")
	procGetCursorPos         = modUser32.NewProc("GetCursorPos")
	procSetForegroundWindow  = modUser32.NewProc("SetForegroundWindow")
	procGetSystemMetrics     = modUser32.NewProc("GetSystemMetrics")
	procMonitorFromPoint     = modUser32.NewProc("MonitorFromPoint")
	procGetMonitorInfoW      = modUser32.NewProc("GetMonitorInfoW")
	procCreatePopupMenu      = modUser32.NewProc("CreatePopupMenu")
	procAppendMenuW          = modUser32.NewProc("AppendMenuW")
	procTrackPopupMenu       = modUser32.NewProc("TrackPopupMenu")
	procDestroyMenu          = modUser32.NewProc("DestroyMenu")
	procCheckMenuItem        = modUser32.NewProc("CheckMenuItem")
	procCheckMenuRadioItem   = modUser32.NewProc("CheckMenuRadioItem")
	procBeginPaint           = modUser32.NewProc("BeginPaint")
	procEndPaint             = modUser32.NewProc("EndPaint")
	procFillRect             = modUser32.NewProc("FillRect")
	procDrawTextW            = modUser32.NewProc("DrawTextW")
	procMessageBoxW          = modUser32.NewProc("MessageBoxW")
	procIsWindowVisible      = modUser32.NewProc("IsWindowVisible")
	procReleaseCapture       = modUser32.NewProc("ReleaseCapture")
	procSetCapture           = modUser32.NewProc("SetCapture")
	procSendMessageW         = modUser32.NewProc("SendMessageW")
	procGetDC                = modUser32.NewProc("GetDC")
	procReleaseDC            = modUser32.NewProc("ReleaseDC")

	procCreateSolidBrush = modGdi32.NewProc("CreateSolidBrush")
	procDeleteObject     = modGdi32.NewProc("DeleteObject")
	procSelectObject     = modGdi32.NewProc("SelectObject")
	procCreateFontW      = modGdi32.NewProc("CreateFontW")
	procSetBkMode        = modGdi32.NewProc("SetBkMode")
	procSetTextColor     = modGdi32.NewProc("SetTextColor")
	procEllipse          = modGdi32.NewProc("Ellipse")
	procCreatePen        = modGdi32.NewProc("CreatePen")
	procMoveToEx         = modGdi32.NewProc("MoveToEx")
	procLineTo           = modGdi32.NewProc("LineTo")
	procCreateCompatibleDC = modGdi32.NewProc("CreateCompatibleDC")
	procCreateCompatibleBitmap = modGdi32.NewProc("CreateCompatibleBitmap")
	procBitBlt           = modGdi32.NewProc("BitBlt")
	procDeleteDC         = modGdi32.NewProc("DeleteDC")

	procShellNotifyIconW = modShell32.NewProc("Shell_NotifyIconW")
	procShellExecuteW    = modShell32.NewProc("ShellExecuteW")
	procExtractIconExW   = modShell32.NewProc("ExtractIconExW")
	procPrivateExtractIconsW = modShell32.NewProc("PrivateExtractIconsW")

	procGetModuleHandleW = modKernel32.NewProc("GetModuleHandleW")
	procCreateMutexW     = modKernel32.NewProc("CreateMutexW")
	procGetLastError     = modKernel32.NewProc("GetLastError")
	procFreeConsole      = modKernel32.NewProc("FreeConsole")
	procAttachConsole    = modKernel32.NewProc("AttachConsole")

	procLoadImageW       = modUser32.NewProc("LoadImageW")
	procCopyIcon         = modUser32.NewProc("CopyIcon")
	procSetWindowTextW   = modUser32.NewProc("SetWindowTextW")
	procDwmSetWindowAttribute = modDwmapi.NewProc("DwmSetWindowAttribute")
)

const (
	WS_POPUP        = 0x80000000
	WS_VISIBLE      = 0x10000000
	WS_EX_TOPMOST   = 0x00000008
	WS_EX_TOOLWINDOW = 0x00000080
	WS_EX_LAYERED   = 0x00080000
	WS_EX_NOACTIVATE = 0x08000000

	SW_HIDE           = 0
	SW_SHOWNOACTIVATE = 4
	SW_SHOW           = 5

	WM_DESTROY       = 0x0002
	WM_CLOSE         = 0x0010
	WM_PAINT         = 0x000F
	WM_TIMER         = 0x0113
	WM_LBUTTONDOWN   = 0x0201
	WM_LBUTTONUP     = 0x0202
	WM_MOUSEMOVE     = 0x0200
	WM_RBUTTONUP     = 0x0205
	WM_COMMAND       = 0x0111
	WM_USER          = 0x0400
	WM_APP           = 0x8000
	WM_TRAYICON      = WM_APP + 1
	WM_NULL          = 0x0000

	NIM_ADD    = 0x00000000
	NIM_MODIFY = 0x00000001
	NIM_DELETE = 0x00000002
	NIF_MESSAGE = 0x00000001
	NIF_ICON    = 0x00000002
	NIF_TIP     = 0x00000004
	NIF_INFO    = 0x00000010

	niifWarning = 0x00000002
	niifError   = 0x00000003

	TPM_RIGHTBUTTON = 0x0002
	TPM_RETURNCMD   = 0x0100

	MF_STRING    = 0x00000000
	MF_SEPARATOR = 0x00000800
	MF_CHECKED   = 0x00000008
	MF_UNCHECKED = 0x00000000
	MF_GRAYED    = 0x00000001
	MF_POPUP     = 0x00000010
	MFS_CHECKED  = 0x00000008

	DT_LEFT     = 0x00000000
	DT_RIGHT    = 0x00000002
	DT_VCENTER  = 0x00000004
	DT_SINGLELINE = 0x00000020
	DT_END_ELLIPSIS = 0x00008000
	DT_NOPREFIX = 0x00000800

	TRANSPARENT = 1
	SRCCOPY     = 0x00CC0020

	SWP_NOACTIVATE = 0x0010
	SWP_SHOWWINDOW = 0x0040
	SWP_NOSIZE     = 0x0001
	SWP_NOMOVE     = 0x0002
	HWND_TOPMOST   = ^uintptr(0) // -1

	LWA_ALPHA = 0x00000002

	SM_CXSCREEN = 0
	SM_CYSCREEN = 1
	MONITOR_DEFAULTTONEAREST = 2

	IDI_APPLICATION = 32512
	IDC_ARROW       = 32512

	COLOR_WINDOW = 5
	PS_SOLID     = 0

	MB_OK       = 0x00000000
	MB_ICONINFO = 0x00000040

	ERROR_ALREADY_EXISTS = 183

	CS_HREDRAW = 0x0002
	CS_VREDRAW = 0x0001
	CS_DBLCLKS = 0x0008
)

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   windows.Handle
	Icon       windows.Handle
	Cursor     windows.Handle
	Background windows.Handle
	MenuName   *uint16
	ClassName  *uint16
	IconSm     windows.Handle
}

type point struct {
	X, Y int32
}

type rect struct {
	Left, Top, Right, Bottom int32
}

type msg struct {
	Hwnd    windows.HWND
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type paintStruct struct {
	Hdc         windows.Handle
	Erase       int32
	Paint       rect
	Restore     int32
	IncUpdate   int32
	RgbReserved [32]byte
}

type monitorInfo struct {
	Size       uint32
	Monitor    rect
	Work       rect
	Flags      uint32
}

type notifyIconData struct {
	Size            uint32
	Wnd             windows.HWND
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            windows.Handle
	Tip             [128]uint16
}

func utf16Ptr(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		p, _ = windows.UTF16PtrFromString("")
	}
	return p
}

func getModuleHandle() windows.Handle {
	r, _, _ := procGetModuleHandleW.Call(0)
	return windows.Handle(r)
}

func loadCursor(id uintptr) windows.Handle {
	r, _, _ := procLoadCursorW.Call(0, id)
	return windows.Handle(r)
}

func registerClass(className string, wndProc uintptr, instance, icon, iconSm windows.Handle) error {
	name := utf16Ptr(className)
	wc := wndClassEx{
		Size:      uint32(unsafe.Sizeof(wndClassEx{})),
		Style:     CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
		WndProc:   wndProc,
		Instance:  instance,
		Icon:      icon,
		IconSm:    iconSm,
		Cursor:    loadCursor(IDC_ARROW),
		ClassName: name,
	}
	r, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	if r == 0 {
		return err
	}
	return nil
}

func createWindow(exStyle, style uint32, className, title string, x, y, w, h int32, parent windows.HWND, instance windows.Handle) (windows.HWND, error) {
	r, _, err := procCreateWindowExW.Call(
		uintptr(exStyle),
		uintptr(unsafe.Pointer(utf16Ptr(className))),
		uintptr(unsafe.Pointer(utf16Ptr(title))),
		uintptr(style),
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		uintptr(parent),
		0,
		uintptr(instance),
		0,
	)
	if r == 0 {
		return 0, err
	}
	return windows.HWND(r), nil
}

func defWindowProc(hwnd windows.HWND, msg uint32, wParam, lParam uintptr) uintptr {
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(msg), wParam, lParam)
	return r
}

func messageLoop() {
	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			return
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func showWindow(hwnd windows.HWND, cmd int32) {
	procShowWindow.Call(uintptr(hwnd), uintptr(cmd))
}

func isVisible(hwnd windows.HWND) bool {
	r, _, _ := procIsWindowVisible.Call(uintptr(hwnd))
	return r != 0
}

func invalidate(hwnd windows.HWND) {
	procInvalidateRect.Call(uintptr(hwnd), 0, 1)
}

func setTimer(hwnd windows.HWND, id, ms uintptr) {
	procSetTimer.Call(uintptr(hwnd), id, ms, 0)
}

func killTimer(hwnd windows.HWND, id uintptr) {
	procKillTimer.Call(uintptr(hwnd), id)
}

func postQuit(code int32) {
	procPostQuitMessage.Call(uintptr(code))
}

func getCursorPos() point {
	var p point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	return p
}

func getWindowRect(hwnd windows.HWND) rect {
	var r rect
	procGetWindowRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r)))
	return r
}

func moveWindow(hwnd windows.HWND, x, y, w, h int32, repaint bool) {
	rp := 0
	if repaint {
		rp = 1
	}
	procMoveWindow.Call(uintptr(hwnd), uintptr(x), uintptr(y), uintptr(w), uintptr(h), uintptr(rp))
}

func setWindowPos(hwnd windows.HWND, x, y, w, h int32, flags uint32) {
	procSetWindowPos.Call(uintptr(hwnd), HWND_TOPMOST, uintptr(x), uintptr(y), uintptr(w), uintptr(h), uintptr(flags))
}

func setLayeredAlpha(hwnd windows.HWND, alpha byte) {
	procSetLayeredWindowAttributes.Call(uintptr(hwnd), 0, uintptr(alpha), LWA_ALPHA)
}

func createSolidBrush(color uint32) windows.Handle {
	r, _, _ := procCreateSolidBrush.Call(uintptr(color))
	return windows.Handle(r)
}

func deleteObject(obj windows.Handle) {
	procDeleteObject.Call(uintptr(obj))
}

func createFont(height int32, weight int32, face string) windows.Handle {
	r, _, _ := procCreateFontW.Call(
		uintptr(height), 0, 0, 0, uintptr(weight),
		0, 0, 0, 1, 0, 0, 0, 0,
		uintptr(unsafe.Pointer(utf16Ptr(face))),
	)
	return windows.Handle(r)
}

func rgb(r, g, b byte) uint32 {
	return uint32(r) | uint32(g)<<8 | uint32(b)<<16
}

func messageBox(title, text string) {
	procMessageBoxW.Call(0,
		uintptr(unsafe.Pointer(utf16Ptr(text))),
		uintptr(unsafe.Pointer(utf16Ptr(title))),
		MB_OK|MB_ICONINFO,
	)
}

func trySingleInstance(name string) bool {
	// CreateMutexW sets ERROR_ALREADY_EXISTS when the named mutex already exists.
	// Must read errno from this Call's return value — a later GetLastError() is racy
	// under Go's syscall layer and was letting a second GUI instance start.
	r, _, err := procCreateMutexW.Call(0, 1, uintptr(unsafe.Pointer(utf16Ptr(name))))
	if r == 0 {
		return false
	}
	if errno, ok := err.(syscall.Errno); ok && errno == ERROR_ALREADY_EXISTS {
		return false
	}
	return true
}

func activateExistingPanel() {
	hwnd, _, _ := procFindWindowW.Call(
		uintptr(unsafe.Pointer(utf16Ptr(wndClassPanel))),
		0,
	)
	if hwnd == 0 {
		return
	}
	showWindow(windows.HWND(hwnd), SW_SHOWNOACTIVATE)
	procSetForegroundWindow.Call(hwnd)
}

func monitorWorkAreaAtCursor() rect {
	p := getCursorPos()
	packed := uintptr(uint32(p.X)) | (uintptr(uint32(p.Y)) << 32)
	hmon, _, _ := procMonitorFromPoint.Call(packed, MONITOR_DEFAULTTONEAREST)
	var mi monitorInfo
	mi.Size = uint32(unsafe.Sizeof(mi))
	r, _, _ := procGetMonitorInfoW.Call(hmon, uintptr(unsafe.Pointer(&mi)))
	if r == 0 {
		w, _, _ := procGetSystemMetrics.Call(SM_CXSCREEN)
		h, _, _ := procGetSystemMetrics.Call(SM_CYSCREEN)
		return rect{0, 0, int32(w), int32(h)}
	}
	return mi.Work
}

type notifyBalloon struct {
	Size            uint32
	Wnd             windows.HWND
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            windows.Handle
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Timeout         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
}

type trayCmd struct {
	icon    windows.Handle
	balloon bool
	title   string
	body    string
	flags   uint32
}

func showBalloon(hwnd windows.HWND, icon windows.Handle, title, body string, infoFlags uint32) {
	var data notifyBalloon
	data.Size = uint32(unsafe.Sizeof(data))
	data.Wnd = hwnd
	data.ID = 1
	data.Flags = NIF_INFO
	data.Icon = icon
	data.InfoFlags = infoFlags
	copyUTF16(data.InfoTitle[:], title)
	copyUTF16(data.Info[:], body)
	procShellNotifyIconW.Call(NIM_MODIFY, uintptr(unsafe.Pointer(&data)))
}

func openFolder(path string) {
	procShellExecuteW.Call(0, uintptr(unsafe.Pointer(utf16Ptr("explore"))), uintptr(unsafe.Pointer(utf16Ptr(path))), 0, 0, 1)
}

func copyUTF16(dst []uint16, s string) {
	u, err := windows.UTF16FromString(s)
	if err != nil || len(u) == 0 {
		return
	}
	n := len(u)
	if n > len(dst) {
		n = len(dst)
		u[n-1] = 0
	}
	copy(dst[:n], u[:n])
}

func shellNotifyIcon(dwMessage uint32, data *notifyIconData) bool {
	r, _, _ := procShellNotifyIconW.Call(uintptr(dwMessage), uintptr(unsafe.Pointer(data)))
	return r != 0
}

func createPopupMenu() windows.Handle {
	r, _, _ := procCreatePopupMenu.Call()
	return windows.Handle(r)
}

func appendMenu(menu windows.Handle, flags uint32, id uintptr, text string) {
	var textPtr uintptr
	if text != "" {
		textPtr = uintptr(unsafe.Pointer(utf16Ptr(text)))
	}
	procAppendMenuW.Call(uintptr(menu), uintptr(flags), id, textPtr)
}

func trackPopupMenu(menu windows.Handle, x, y int32, hwnd windows.HWND) uint32 {
	procSetForegroundWindow.Call(uintptr(hwnd))
	r, _, _ := procTrackPopupMenu.Call(uintptr(menu), TPM_RIGHTBUTTON|TPM_RETURNCMD, uintptr(x), uintptr(y), 0, uintptr(hwnd), 0)
	procPostMessageW.Call(uintptr(hwnd), WM_NULL, 0, 0)
	return uint32(r)
}

func destroyMenu(menu windows.Handle) {
	procDestroyMenu.Call(uintptr(menu))
}

func checkMenuRadioItem(menu windows.Handle, first, last, check uint32) {
	procCheckMenuRadioItem.Call(uintptr(menu), uintptr(first), uintptr(last), uintptr(check), MF_BYCOMMAND)
}

const MF_BYCOMMAND = 0x00000000

func destroyWindow(hwnd windows.HWND) {
	procDestroyWindow.Call(uintptr(hwnd))
}

func setCapture(hwnd windows.HWND) {
	procSetCapture.Call(uintptr(hwnd))
}

func releaseCapture() {
	procReleaseCapture.Call()
}

func beginPaint(hwnd windows.HWND, ps *paintStruct) windows.Handle {
	r, _, _ := procBeginPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(ps)))
	return windows.Handle(r)
}

func endPaint(hwnd windows.HWND, ps *paintStruct) {
	procEndPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(ps)))
}

func getClientRect(hwnd windows.HWND) rect {
	var r rect
	procGetClientRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r)))
	return r
}

func fillRect(hdc windows.Handle, r *rect, brush windows.Handle) {
	procFillRect.Call(uintptr(hdc), uintptr(unsafe.Pointer(r)), uintptr(brush))
}

func selectObject(hdc, obj windows.Handle) windows.Handle {
	r, _, _ := procSelectObject.Call(uintptr(hdc), uintptr(obj))
	return windows.Handle(r)
}

func setBkMode(hdc windows.Handle, mode int32) {
	procSetBkMode.Call(uintptr(hdc), uintptr(mode))
}

func setTextColor(hdc windows.Handle, color uint32) {
	procSetTextColor.Call(uintptr(hdc), uintptr(color))
}

func ellipse(hdc windows.Handle, left, top, right, bottom int32) {
	procEllipse.Call(uintptr(hdc), uintptr(left), uintptr(top), uintptr(right), uintptr(bottom))
}

func createPen(style int32, width int32, color uint32) windows.Handle {
	r, _, _ := procCreatePen.Call(uintptr(style), uintptr(width), uintptr(color))
	return windows.Handle(r)
}

func drawText(hdc windows.Handle, text string, r *rect, format uint32) {
	ptr := utf16Ptr(text)
	procDrawTextW.Call(uintptr(hdc), uintptr(unsafe.Pointer(ptr)), uintptr(^uint32(0)), uintptr(unsafe.Pointer(r)), uintptr(format))
}

func createCompatibleDC(hdc windows.Handle) windows.Handle {
	r, _, _ := procCreateCompatibleDC.Call(uintptr(hdc))
	return windows.Handle(r)
}

func createCompatibleBitmap(hdc windows.Handle, w, h int32) windows.Handle {
	r, _, _ := procCreateCompatibleBitmap.Call(uintptr(hdc), uintptr(w), uintptr(h))
	return windows.Handle(r)
}

func bitBlt(dst windows.Handle, x, y, w, h int32, src windows.Handle, sx, sy int32) {
	procBitBlt.Call(uintptr(dst), uintptr(x), uintptr(y), uintptr(w), uintptr(h), uintptr(src), uintptr(sx), uintptr(sy), SRCCOPY)
}

func deleteDC(hdc windows.Handle) {
	procDeleteDC.Call(uintptr(hdc))
}

func getDC(hwnd windows.HWND) windows.Handle {
	r, _, _ := procGetDC.Call(uintptr(hwnd))
	return windows.Handle(r)
}

func releaseDC(hwnd windows.HWND, hdc windows.Handle) {
	procReleaseDC.Call(uintptr(hwnd), uintptr(hdc))
}

func loWord(v uintptr) int32 {
	return int32(uint16(v))
}

func hiWord(v uintptr) int32 {
	return int32(uint16(v >> 16))
}

const (
	imageIcon           = 1
	lrDefaultSize       = 0x00000040
	lrShared            = 0x00008000
	lrDefaultColor      = 0x00000000
	iconBig             = 1
	iconSmall           = 0
	wmSetIcon           = 0x0080
	attachParentProcess = ^uint32(0) // (DWORD)-1
	hwndMessage         = ^windows.HWND(2) // HWND_MESSAGE = -3
	dwmwaWindowCornerPreference = 33
	dwmwcpRound         = 2
)

func freeConsole() {
	procFreeConsole.Call()
}

func attachParentConsole() bool {
	r, _, _ := procAttachConsole.Call(uintptr(attachParentProcess))
	return r != 0
}

func loadImageIcon(instance windows.Handle, resourceID uintptr, cx, cy int32) windows.Handle {
	r, _, _ := procLoadImageW.Call(
		uintptr(instance),
		resourceID, // MAKEINTRESOURCE
		imageIcon,
		uintptr(cx),
		uintptr(cy),
		lrDefaultColor,
	)
	return windows.Handle(r)
}

func extractExeIcon(exePath string, large bool) windows.Handle {
	var largeIcon, smallIcon windows.Handle
	procExtractIconExW.Call(
		uintptr(unsafe.Pointer(utf16Ptr(exePath))),
		0,
		uintptr(unsafe.Pointer(&largeIcon)),
		uintptr(unsafe.Pointer(&smallIcon)),
		1,
	)
	if large {
		if smallIcon != 0 {
			destroyIcon(smallIcon)
		}
		return largeIcon
	}
	if largeIcon != 0 {
		destroyIcon(largeIcon)
	}
	return smallIcon
}

func copyIcon(icon windows.Handle) windows.Handle {
	if icon == 0 {
		return 0
	}
	r, _, _ := procCopyIcon.Call(uintptr(icon))
	return windows.Handle(r)
}

func setWindowIcon(hwnd windows.HWND, big, small windows.Handle) {
	if big != 0 {
		procSendMessageW.Call(uintptr(hwnd), wmSetIcon, iconBig, uintptr(big))
	}
	if small != 0 {
		procSendMessageW.Call(uintptr(hwnd), wmSetIcon, iconSmall, uintptr(small))
	}
}

func setWindowText(hwnd windows.HWND, title string) {
	procSetWindowTextW.Call(uintptr(hwnd), uintptr(unsafe.Pointer(utf16Ptr(title))))
}

func enableRoundedCorners(hwnd windows.HWND) {
	pref := int32(dwmwcpRound)
	procDwmSetWindowAttribute.Call(uintptr(hwnd), dwmwaWindowCornerPreference, uintptr(unsafe.Pointer(&pref)), 4)
}

// Ensure unused import doesn't break when syscall only used for NewCallback
var _ = syscall.NewCallback
