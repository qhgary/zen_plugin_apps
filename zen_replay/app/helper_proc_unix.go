//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

func setupHelperSysProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func hideWindowSysProcAttr(cmd *exec.Cmd) {
	// Unix 平台不需要隐藏控制台窗口
}

// setHiddenWindows 在 Windows 上设置文件隐藏属性；macOS/Linux 的 dotfile 前缀已自动隐藏
func setHiddenWindows(path string) {
	// no-op on non-Windows platforms
}
