//go:build !windows

package core

// macos/linux 靠文件名 dotfile 前缀(.xx)自动隐藏，无需额外设置
func setHiddenWindows(path string) {
}
