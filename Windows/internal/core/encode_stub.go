//go:build !windows

package core

func encodeWindowsCodePage(codePage uint32, s string) ([]byte, bool) {
	return nil, false
}

const (
	codePageGBK     = 936
	codePageGB18030 = 54936
)
