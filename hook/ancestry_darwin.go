//go:build darwin

package main

import "golang.org/x/sys/unix"

// parentChain walks up from pid with one sysctl per process: the ids of pid and each
// of its ancestors, nearest first.
func parentChain(pid, max int) []int {
	return walk(pid, max, func(p int) (int, bool) {
		info, err := unix.SysctlKinfoProc("kern.proc.pid", p)
		if err != nil {
			return 0, false
		}
		return int(info.Eproc.Ppid), true
	})
}
