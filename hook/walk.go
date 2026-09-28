package main

// walk follows parent links from pid, nearest first, for at most max processes. It
// stops at a process it cannot look up, at the root, and at a loop.
func walk(pid, max int, parentOf func(int) (int, bool)) []int {
	chain := []int{}
	seen := map[int]bool{}
	current := pid
	for len(chain) < max && current > 0 && !seen[current] {
		chain = append(chain, current)
		seen[current] = true
		parent, ok := parentOf(current)
		if !ok || parent == current {
			break
		}
		current = parent
	}
	return chain
}
