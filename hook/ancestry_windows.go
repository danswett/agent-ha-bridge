//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// parentChain walks up from pid through one process snapshot: the ids of pid and each
// of its ancestors, nearest first. A parent that has already exited ends the chain.
func parentChain(pid, max int) []int {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return []int{pid}
	}
	defer windows.CloseHandle(snapshot)

	parents := map[uint32]uint32{}
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		parents[entry.ProcessID] = entry.ParentProcessID
	}
	return walk(pid, max, func(p int) (int, bool) {
		parent, ok := parents[uint32(p)]
		return int(parent), ok
	})
}
