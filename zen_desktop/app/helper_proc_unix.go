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
