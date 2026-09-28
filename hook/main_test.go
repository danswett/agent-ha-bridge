package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setup points the program at a temporary TEMP, with a heartbeat of the given age
// (negative for none), and records any fallback run.
func setup(t *testing.T, heartbeatAge time.Duration) (temp string, fallbacks *[]string) {
	t.Helper()
	temp = t.TempDir()
	t.Setenv("TEMP", temp)
	t.Setenv("AGENT_BRIDGE_HOOKS_PUBLISH", "")
	if heartbeatAge >= 0 {
		beat := filepath.Join(temp, "agent-bridge-daemon.heartbeat")
		os.WriteFile(beat, []byte("1"), 0o600)
		at := time.Now().Add(-heartbeatAge)
		os.Chtimes(beat, at, at)
	}
	var runs []string
	fallbacks = &runs
	previous := runFallback
	runFallback = func(script string, event []byte, stdout io.Writer) error {
		runs = append(runs, script+"|"+string(event))
		io.WriteString(stdout, "FROM-POWERSHELL")
		return nil
	}
	previousAncestry := ancestry
	ancestry = func(pid, max int) []int { return []int{20, 30} }
	t.Cleanup(func() { runFallback = previous; ancestry = previousAncestry })
	return temp, fallbacks
}

func spoolFiles(t *testing.T, temp string) []string {
	t.Helper()
	entries, _ := os.ReadDir(filepath.Join(temp, "agent-bridge-spool"))
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func invoke(args []string, stdin string) string {
	var out bytes.Buffer
	run(args, strings.NewReader(stdin), &out, time.Now())
	return out.String()
}

func TestRepliesMatchTheScripts(t *testing.T) {
	setup(t, 0)
	cases := map[string]string{
		"claude/stop":        "",
		"codex/hook":         "",
		"copilot/ask_user":   "{\"permissionDecision\":\"allow\"}\n",
		"copilot/agent_stop": "{}\n",
		"copilot/permission": "{}\n",
	}
	for key, want := range cases {
		parts := strings.Split(key, "/")
		if got := invoke(parts, `{"a":1}`); got != want {
			t.Errorf("%s replied %q, want %q", key, got, want)
		}
	}
}

func TestSpoolsWhenTheDaemonIsAlive(t *testing.T) {
	temp, fallbacks := setup(t, 5*time.Second)
	out := invoke([]string{"claude", "stop", "notify-claude-stop.ps1"}, "  {\"session_id\":\"s1\"}\n")
	if out != "" {
		t.Fatalf("a Claude hook printed %q", out)
	}
	if len(*fallbacks) != 0 {
		t.Fatalf("ran PowerShell with the daemon alive: %v", *fallbacks)
	}
	names := spoolFiles(t, temp)
	if len(names) != 1 || !strings.HasSuffix(names[0], ".json") {
		t.Fatalf("spool holds %v, want one .json and no .tmp", names)
	}
	body, _ := os.ReadFile(filepath.Join(temp, "agent-bridge-spool", names[0]))
	var got spooled
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("spool file is not JSON: %v", err)
	}
	if got.Version != 1 || got.Agent != "claude" || got.Hook != "stop" || len(got.Ancestors) != 2 || got.Ancestors[1] != 30 {
		t.Errorf("spooled %+v", got)
	}
	if string(got.Event) != `{"session_id":"s1"}` {
		t.Errorf("event %s, want it verbatim", got.Event)
	}
}

func TestSpoolNamesSortByTime(t *testing.T) {
	temp, _ := setup(t, 0)
	start := time.Now()
	for i := 0; i < 3; i++ {
		run([]string{"codex", "hook"}, strings.NewReader(`{"n":1}`), io.Discard, start.Add(time.Duration(2-i)*time.Millisecond))
	}
	names := spoolFiles(t, temp)
	if len(names) != 3 {
		t.Fatalf("spool holds %v", names)
	}
	// ReadDir sorts by name, so the earliest event must come first.
	var first spooled
	body, _ := os.ReadFile(filepath.Join(temp, "agent-bridge-spool", names[0]))
	json.Unmarshal(body, &first)
	if first.ReceivedAt != start.Format(time.RFC3339Nano) {
		t.Errorf("first file is from %s, want the earliest %s", first.ReceivedAt, start.Format(time.RFC3339Nano))
	}
}

func TestFallsBackWhenTheDaemonIsNotRunning(t *testing.T) {
	for name, age := range map[string]time.Duration{"stale": 2 * time.Minute, "missing": -1} {
		t.Run(name, func(t *testing.T) {
			temp, fallbacks := setup(t, age)
			out := invoke([]string{"copilot", "ask_user", "route-ask-user-v3.ps1"}, `{"q":1}`)
			if len(*fallbacks) != 1 || (*fallbacks)[0] != `route-ask-user-v3.ps1|{"q":1}` {
				t.Fatalf("fallbacks %v", *fallbacks)
			}
			if out != "FROM-POWERSHELL" {
				t.Errorf("printed %q; the script's own reply should pass through alone", out)
			}
			if len(spoolFiles(t, temp)) != 0 {
				t.Error("spooled with no daemon to read it")
			}
		})
	}
}

func TestHooksPublishOverride(t *testing.T) {
	_, fallbacks := setup(t, 0)
	t.Setenv("AGENT_BRIDGE_HOOKS_PUBLISH", "1")
	invoke([]string{"claude", "stop", "x.ps1"}, `{}`)
	if len(*fallbacks) != 1 {
		t.Error("AGENT_BRIDGE_HOOKS_PUBLISH should make the PowerShell hook run")
	}
}

func TestReplyWhenTheFallbackCannotRun(t *testing.T) {
	setup(t, -1)
	runFallback = func(string, []byte, io.Writer) error { return errors.New("no pwsh") }
	if got := invoke([]string{"copilot", "agent_stop", "x.ps1"}, `{}`); got != "{}\n" {
		t.Errorf("printed %q, want the fixed reply", got)
	}
	if got := invoke([]string{"copilot", "permission"}, `{}`); got != "{}\n" {
		t.Errorf("with no fallback script printed %q", got)
	}
}

func TestIgnoresWhatTheScriptWouldIgnore(t *testing.T) {
	temp, fallbacks := setup(t, 0)
	for _, stdin := range []string{"", "   ", "not json"} {
		if got := invoke([]string{"copilot", "ask_user"}, stdin); got != "{\"permissionDecision\":\"allow\"}\n" {
			t.Errorf("stdin %q printed %q", stdin, got)
		}
	}
	if len(spoolFiles(t, temp)) != 0 || len(*fallbacks) != 0 {
		t.Error("an unusable event was handed on")
	}
	if got := invoke([]string{"gemini", "stop"}, `{}`); got != "" {
		t.Errorf("an unknown hook printed %q", got)
	}
	if got := invoke(nil, ""); got != "" {
		t.Errorf("no arguments printed %q", got)
	}
}

func readLog(t *testing.T, temp string) []outcomeLine {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(temp, logName))
	if err != nil {
		return nil
	}
	var lines []outcomeLine
	for _, raw := range strings.Split(strings.TrimSpace(string(body)), "\n") {
		var line outcomeLine
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			t.Fatalf("log line %q is not JSON: %v", raw, err)
		}
		lines = append(lines, line)
	}
	return lines
}

func TestRecordsEveryPath(t *testing.T) {
	cases := []struct {
		name         string
		heartbeatAge time.Duration
		env          string
		args         []string
		stdin        string
		fallbackErr  error
		breakSpool   bool
		wantPath     string
		wantReason   string
	}{
		{name: "spooled", heartbeatAge: 0, args: []string{"claude", "stop", "s.ps1"}, stdin: `{}`, wantPath: "spool"},
		{name: "no heartbeat", heartbeatAge: -1, args: []string{"claude", "stop", "s.ps1"}, stdin: `{}`, wantPath: "fallback", wantReason: "no daemon heartbeat"},
		{name: "stale heartbeat", heartbeatAge: 5 * time.Minute, args: []string{"codex", "hook", "s.ps1"}, stdin: `{}`, wantPath: "fallback", wantReason: "daemon heartbeat 300s old"},
		{name: "override", heartbeatAge: 0, env: "1", args: []string{"claude", "stop", "s.ps1"}, stdin: `{}`, wantPath: "fallback", wantReason: "AGENT_BRIDGE_HOOKS_PUBLISH set"},
		{name: "fallback fails", heartbeatAge: -1, args: []string{"claude", "stop", "s.ps1"}, stdin: `{}`, fallbackErr: errors.New("no pwsh"), wantPath: "reply", wantReason: "no daemon heartbeat; fallback failed: no pwsh"},
		{name: "no fallback script", heartbeatAge: -1, args: []string{"copilot", "permission"}, stdin: `{}`, wantPath: "reply", wantReason: "no daemon heartbeat"},
		{name: "unusable event", heartbeatAge: 0, args: []string{"claude", "stop", "s.ps1"}, stdin: `not json`, wantPath: "reply", wantReason: "unusable event"},
		{name: "spool fails", heartbeatAge: 0, args: []string{"claude", "stop", "s.ps1"}, stdin: `{}`, breakSpool: true, wantPath: "fallback", wantReason: "spool failed: "},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			temp, _ := setup(t, c.heartbeatAge)
			t.Setenv("AGENT_BRIDGE_HOOKS_PUBLISH", c.env)
			if c.fallbackErr != nil {
				runFallback = func(string, []byte, io.Writer) error { return c.fallbackErr }
			}
			if c.breakSpool {
				// A file where the spool folder should be.
				os.WriteFile(filepath.Join(temp, "agent-bridge-spool"), []byte("x"), 0o600)
			}
			invoke(c.args, c.stdin)
			lines := readLog(t, temp)
			if len(lines) != 1 {
				t.Fatalf("log has %d lines, want 1", len(lines))
			}
			got := lines[0]
			if got.Path != c.wantPath || !strings.HasPrefix(got.Reason, c.wantReason) || (c.wantReason == "" && got.Reason != "") {
				t.Errorf("recorded path=%q reason=%q, want path=%q reason starting %q", got.Path, got.Reason, c.wantPath, c.wantReason)
			}
			if got.Agent != c.args[0] || got.Hook != c.args[1] || got.At == "" || got.Ms < 0 {
				t.Errorf("recorded %+v", got)
			}
		})
	}
}

func TestRecordsNothingForUnknownHooks(t *testing.T) {
	temp, _ := setup(t, 0)
	invoke([]string{"gemini", "stop"}, `{}`)
	invoke([]string{"--version"}, ``)
	if lines := readLog(t, temp); len(lines) != 0 {
		t.Errorf("logged %v", lines)
	}
}

func TestLogRotatesAtAMegabyte(t *testing.T) {
	temp, _ := setup(t, 0)
	path := filepath.Join(temp, logName)
	os.WriteFile(path, bytes.Repeat([]byte("x"), logMaxBytes), 0o600)
	invoke([]string{"claude", "stop"}, `{}`)
	if info, err := os.Stat(path + ".1"); err != nil || info.Size() != logMaxBytes {
		t.Fatalf("the full log was not kept as %s.1", logName)
	}
	if lines := readLog(t, temp); len(lines) != 1 {
		t.Errorf("new log has %d lines, want 1", len(lines))
	}
}

func TestVersion(t *testing.T) {
	if got := invoke([]string{"--version"}, ""); strings.TrimSpace(got) != version {
		t.Errorf("--version printed %q", got)
	}
}

func TestWalk(t *testing.T) {
	parents := map[int]int{10: 20, 20: 30, 30: 1, 1: 0}
	lookup := func(p int) (int, bool) { v, ok := parents[p]; return v, ok }
	if got := walk(10, 12, lookup); len(got) != 4 || got[0] != 10 || got[3] != 1 {
		t.Errorf("walk = %v", got)
	}
	if got := walk(10, 2, lookup); len(got) != 2 {
		t.Errorf("max not honoured: %v", got)
	}
	loop := map[int]int{5: 6, 6: 5}
	if got := walk(5, 12, func(p int) (int, bool) { v, ok := loop[p]; return v, ok }); len(got) != 2 {
		t.Errorf("a loop is not stopped: %v", got)
	}
	if got := walk(99, 12, lookup); len(got) != 1 || got[0] != 99 {
		t.Errorf("an unknown process is still reported itself: %v", got)
	}
}

func TestRealAncestryIncludesThisProcess(t *testing.T) {
	chain := parentChain(os.Getpid(), 12)
	if len(chain) < 2 || chain[0] != os.Getpid() || chain[1] != os.Getppid() {
		t.Errorf("parentChain(self) = %v, want [%d %d ...]", chain, os.Getpid(), os.Getppid())
	}
}
