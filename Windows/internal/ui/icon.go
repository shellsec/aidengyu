//go:build windows

package ui

import (
	"image"
	"image/color"
	"image/draw"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procCreateIconIndirect = modUser32.NewProc("CreateIconIndirect")
	procDestroyIcon        = modUser32.NewProc("DestroyIcon")
	procCreateDIBSection   = modGdi32.NewProc("CreateDIBSection")
	procGetObjectW         = modGdi32.NewProc("GetObjectW")
)

type iconInfo struct {
	FIcon    int32
	XHotspot uint32
	YHotspot uint32
	HbmMask  windows.Handle
	HbmColor windows.Handle
}

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

func lampColor(name string) color.RGBA {
	switch name {
	case "red":
		return color.RGBA{R: 0xf2, G: 0x30, B: 0x2e, A: 0xff}
	case "yellow":
		return color.RGBA{R: 0xff, G: 0xb8, B: 0x1f, A: 0xff}
	case "green":
		return color.RGBA{R: 0x2e, G: 0xd1, B: 0x64, A: 0xff}
	default:
		return color.RGBA{R: 0x78, G: 0x78, B: 0x78, A: 0xff}
	}
}

func createCircleIcon(activeColor string, intensity float64, triple bool) windows.Handle {
	size := 16
	width := size
	if triple {
		width = 24
	}
	img := image.NewRGBA(image.Rect(0, 0, width, size))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: color.RGBA{0, 0, 0, 0}}, image.Point{}, draw.Src)

	drawDot := func(cx, cy, radius int, c color.RGBA, active bool) {
		a := uint8(0x33)
		if active {
			v := 0.42 + intensity*0.58
			if v > 1 {
				v = 1
			}
			a = uint8(v * 255)
		}
		fill := color.RGBA{R: c.R, G: c.G, B: c.B, A: a}
		for y := cy - radius; y <= cy+radius; y++ {
			for x := cx - radius; x <= cx+radius; x++ {
				dx, dy := x-cx, y-cy
				if dx*dx+dy*dy <= radius*radius {
					if x >= 0 && y >= 0 && x < width && y < size {
						img.Set(x, y, fill)
					}
				}
			}
		}
	}

	if triple {
		colors := []string{"red", "yellow", "green"}
		for i, name := range colors {
			drawDot(4+i*8, 8, 3, lampColor(name), name == activeColor)
		}
	} else {
		c := lampColor(activeColor)
		if activeColor == "off" {
			drawDot(8, 8, 5, c, false)
		} else {
			drawDot(8, 8, 5, c, true)
		}
	}

	hbmColor := createDIBFromRGBA(img)
	if hbmColor == 0 {
		return 0
	}
	// 1-bit mask: all opaque (0)
	mask := image.NewRGBA(image.Rect(0, 0, width, size))
	draw.Draw(mask, mask.Bounds(), &image.Uniform{C: color.RGBA{0, 0, 0, 0xff}}, image.Point{}, draw.Src)
	hbmMask := createDIBFromRGBA(mask)
	ii := iconInfo{
		FIcon:    1,
		XHotspot: 0,
		YHotspot: 0,
		HbmMask:  hbmMask,
		HbmColor: hbmColor,
	}
	r, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	deleteObject(hbmColor)
	deleteObject(hbmMask)
	return windows.Handle(r)
}

func destroyIcon(icon windows.Handle) {
	if icon != 0 {
		procDestroyIcon.Call(uintptr(icon))
	}
}

func createDIBFromRGBA(img *image.RGBA) windows.Handle {
	w := img.Bounds().Dx()
	h := img.Bounds().Dy()
	bih := bitmapInfoHeader{
		Size:     uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		Width:    int32(w),
		Height:   -int32(h), // top-down
		Planes:   1,
		BitCount: 32,
	}
	var bits unsafe.Pointer
	hdc := getDC(0)
	defer releaseDC(0, hdc)
	r, _, _ := procCreateDIBSection.Call(
		uintptr(hdc),
		uintptr(unsafe.Pointer(&bih)),
		0, // DIB_RGB_COLORS
		uintptr(unsafe.Pointer(&bits)),
		0, 0,
	)
	if r == 0 || bits == nil {
		return 0
	}
	dst := unsafe.Slice((*byte)(bits), w*h*4)
	// Windows expects BGRA
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := img.RGBAAt(x, y)
			i := (y*w + x) * 4
			dst[i+0] = c.B
			dst[i+1] = c.G
			dst[i+2] = c.R
			dst[i+3] = c.A
		}
	}
	return windows.Handle(r)
}
