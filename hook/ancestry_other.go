//go:build !windows && !darwin

package main

import (
	"fmt"
	"os"
	"strings"
)

// parentChain walks up from pid through /proc: the ids of pid and each of its
// ancestors, nearest first. The bridge ships for Windows and macOS; this keeps the
// program building and testable elsewhere.
func parentChain(pid, max int) []int {
	return walk(pid, max, func(p int) (int, bool) {
		stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", p))
		if err != nil {
			return 0, false
		}
		// The name, in parentheses, may itself hold spaces; the fields after it do not.
		fields := strings.Fields(string(stat[strings.LastIndexByte(string(stat), ')')+1:]))
		if len(fields) < 2 {
			return 0, false
		}
		var parent int
		fmt.Sscan(fields[1], &parent)
		return parent, true
	})
}
