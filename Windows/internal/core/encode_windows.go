//go:build windows

package core

import (
	"syscall"
	"unicode/utf16"
	"unsafe"
)

var (
	modKernel32           = syscall.NewLazyDLL("kernel32.dll")
	procWideCharToMultiByte = modKernel32.NewProc("WideCharToMultiByte")
)

const (
	codePageGBK     = 936
	codePageGB18030 = 54936
)

// encodeWindowsCodePage encodes s with WideCharToMultiByte. Unlike
// golang.org/x/text, Windows CP936/54936 maps GB18030 PUA codepoints
// (U+E000..) back to the original 2-byte sequences, which is required to
// reverse "UTF-8 bytes misread as GBK/GB18030" mojibake.
func encodeWindowsCodePage(codePage uint32, s string) ([]byte, bool) {
	if s == "" {
		return nil, false
	}
	u := utf16.Encode([]rune(s))
	n, _, _ := procWideCharToMultiByte.Call(
		uintptr(codePage), 0,
		uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)),
		0, 0, 0, 0,
	)
	if n == 0 {
		return nil, false
	}
	buf := make([]byte, n)
	n2, _, _ := procWideCharToMultiByte.Call(
		uintptr(codePage), 0,
		uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)),
		0, 0,
	)
	if n2 == 0 {
		return nil, false
	}
	return buf[:n2], true
}
