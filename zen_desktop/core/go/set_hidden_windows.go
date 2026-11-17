//go:build windows

package core

import "syscall"

// setHiddenWindows 在 Windows 上设置文件隐藏属性。
// 用进程内 SetFileAttributesW(HIDDEN) 而非 spawn attrib.exe，
// 避免 GUI 子系统进程拉起控制台子进程导致黑色终端一闪而过。
func setHiddenWindows(path string) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	_ = syscall.SetFileAttributes(pathPtr, syscall.FILE_ATTRIBUTE_HIDDEN)
}
