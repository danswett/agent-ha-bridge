// agent-bridge-hook is the fast entry point for the bridge's agent hooks.
//
// The agents wait for every hook, and a PowerShell hook takes half a second before it
// has done anything. This program instead hands the event to the bridge daemon, which
// runs the same PowerShell hook code (see docs/fast-hooks.md):
//
//	agent-bridge-hook <agent> <hook> [fallback-script]
//
// It reads the event from stdin, records its process ancestry (the owning agent
// process is found from it later, when the shells in between have exited), writes
// both to the daemon's spool folder and prints the reply the agent expects. When the
// daemon is not running it runs fallback-script - the PowerShell hook - instead, with
// the same stdin, so the bridge still works without its daemon.
//
// It never fails the agent: anything unexpected prints the reply and exits 0.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Set at build time: -ldflags "-X main.version=1.12.0".
var version = "dev"

// The reply each hook's PowerShell script prints, which the agent reads. Claude and
// Codex hooks print nothing: their output would reach the model or change a decision.
var replies = map[string]string{
	"claude/register":     "",
	"claude/stop":         "",
	"claude/ask":          "",
	"claude/notification": "",
	"codex/hook":          "",
	"copilot/ask_user":    `{"permissionDecision":"allow"}` + "\n",
	"copilot/agent_stop":  "{}\n",
	"copilot/permission":  "{}\n",
}

const (
	// As Test-BridgeDaemonAlive: a daemon that has not completed a pass for a minute
	// is treated as stopped.
	heartbeatMaxAge = 60 * time.Second
	maxAncestors    = 12
	maxEventBytes   = 16 << 20
)

// runFallback runs the PowerShell hook; a variable so tests can replace it.
var runFallback = runPowerShell

// ancestry returns the chain of parent process ids, nearest first; a variable so
// tests can replace it.
var ancestry = parentChain

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, time.Now()))
}

// run is main, testable. It always returns 0.
func run(args []string, stdin io.Reader, stdout io.Writer, now time.Time) (code int) {
	reply := ""
	defer func() {
		if recover() != nil {
			io.WriteString(stdout, reply)
		}
	}()

	if len(args) >= 1 && args[0] == "--version" {
		fmt.Fprintln(stdout, version)
		return 0
	}
	if len(args) < 2 {
		return 0
	}
	key := args[0] + "/" + args[1]
	known := false
	reply, known = replies[key]
	if !known {
		return 0
	}
	fallback := ""
	if len(args) >= 3 {
		fallback = args[2]
	}

	event, _ := io.ReadAll(io.LimitReader(stdin, maxEventBytes))
	temp := tempDir()

	if !daemonAlive(temp, now) {
		if fallback != "" && runFallback(fallback, event, stdout) == nil {
			return 0
		}
		io.WriteString(stdout, reply)
		return 0
	}

	// An event the PowerShell hook could not parse either: it would do nothing.
	trimmed := bytes.TrimSpace(event)
	if len(trimmed) == 0 || !json.Valid(trimmed) {
		io.WriteString(stdout, reply)
		return 0
	}

	if err := spool(temp, args[0], args[1], trimmed, ancestry(os.Getppid(), maxAncestors), now); err != nil {
		// The daemon cannot be reached this way; the PowerShell hook still works.
		if fallback != "" && runFallback(fallback, event, stdout) == nil {
			return 0
		}
	}
	io.WriteString(stdout, reply)
	return 0
}

// tempDir is the folder the bridge's PowerShell uses as $env:TEMP: TEMP when set
// (always, on Windows), otherwise the system's (TMPDIR on macOS), as
// Initialize-BridgePlatform does.
func tempDir() string {
	if t := os.Getenv("TEMP"); t != "" {
		return t
	}
	return strings.TrimRight(os.TempDir(), "/")
}

// daemonAlive mirrors Test-BridgeDaemonAlive.
func daemonAlive(temp string, now time.Time) bool {
	// Hooks publish for themselves under this, for tests beside a running daemon.
	if os.Getenv("AGENT_BRIDGE_HOOKS_PUBLISH") != "" {
		return false
	}
	info, err := os.Stat(filepath.Join(temp, "agent-bridge-daemon.heartbeat"))
	if err != nil {
		return false
	}
	return now.Sub(info.ModTime()) < heartbeatMaxAge
}

type spooled struct {
	Version    int             `json:"v"`
	Agent      string          `json:"agent"`
	Hook       string          `json:"hook"`
	Ancestors  []int           `json:"ancestors"`
	ReceivedAt string          `json:"receivedAt"`
	Event      json.RawMessage `json:"event"`
}

// spool writes the event where the daemon picks it up (daemon-hookspool.ps1): under a
// temporary name, then renamed, so the daemon never reads half a file. The name sorts
// by time, which is the order the daemon handles events in.
func spool(temp, agent, hook string, event []byte, ancestors []int, now time.Time) error {
	dir := filepath.Join(temp, "agent-bridge-spool")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if ancestors == nil {
		ancestors = []int{}
	}
	body, err := json.Marshal(spooled{
		Version: 1, Agent: agent, Hook: hook, Ancestors: ancestors,
		ReceivedAt: now.Format(time.RFC3339Nano), Event: event,
	})
	if err != nil {
		return err
	}
	suffix := make([]byte, 4)
	rand.Read(suffix)
	name := fmt.Sprintf("%020d-%d-%s.json", now.UnixNano(), os.Getpid(), hex.EncodeToString(suffix))
	final := filepath.Join(dir, name)
	partial := final + ".tmp"
	if err := os.WriteFile(partial, body, 0o600); err != nil {
		return err
	}
	if err := os.Rename(partial, final); err != nil {
		os.Remove(partial)
		return err
	}
	return nil
}

// runPowerShell runs a hook script the way run-hook.cmd does, with the event on its
// stdin. Its reply is passed on only when it succeeded: a script that could not run
// has pwsh print its error to stdout, which must never reach the agent in place of
// the reply.
func runPowerShell(script string, event []byte, stdout io.Writer) error {
	if _, err := os.Stat(script); err != nil {
		return err
	}
	pwsh := findPowerShell()
	if pwsh == "" {
		return fmt.Errorf("pwsh not found")
	}
	var reply bytes.Buffer
	cmd := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script)
	cmd.Stdin = bytes.NewReader(event)
	cmd.Stdout = &reply
	if err := cmd.Run(); err != nil {
		return err
	}
	_, err := stdout.Write(reply.Bytes())
	return err
}

func findPowerShell() string {
	if path, err := exec.LookPath("pwsh"); err == nil {
		return path
	}
	candidates := []string{"/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh", "/usr/local/microsoft/powershell/7/pwsh", "/opt/local/bin/pwsh"}
	if runtime.GOOS == "windows" {
		candidates = []string{
			filepath.Join(os.Getenv("ProgramFiles"), "PowerShell", "7", "pwsh.exe"),
			filepath.Join(os.Getenv("LOCALAPPDATA"), "Microsoft", "WindowsApps", "pwsh.exe"),
		}
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}
