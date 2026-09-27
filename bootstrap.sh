#!/bin/bash
# Installs the agent-ha-bridge on macOS, from nothing:
#
#   curl -fsSL https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.sh | bash
#
# The macOS counterpart of bootstrap.ps1. It needs Homebrew, installs PowerShell 7
# and tmux through it when they are missing (every bridge script runs under pwsh, and
# each session runs in tmux so the dashboard can type into it), downloads the branch
# and hands over to install.ps1 - which asks for everything else.
#
# BRANCH=<name> installs another branch.
set -euo pipefail

repo="danswett/agent-ha-bridge"
branch="${BRANCH:-main}"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This installer is for macOS. On Windows, run bootstrap.ps1." >&2
    exit 1
fi

# Homebrew may be installed but not on this shell's PATH yet.
load_brew() {
    for prefix in /opt/homebrew /usr/local; do
        if ! command -v brew >/dev/null 2>&1 && [ -x "$prefix/bin/brew" ]; then
            eval "$("$prefix/bin/brew" shellenv)"
        fi
    done
}
load_brew

# Without it, offer to install it with its own official installer. That asks for the
# Mac's password (Homebrew needs admin rights) and may install Apple's command line
# tools first, so it talks to the terminal directly - under `curl | bash` this
# script's stdin is the script itself.
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is not installed. It is used to install PowerShell 7 and tmux."
    answer="n"
    if [ -r /dev/tty ]; then
        printf "Install Homebrew now? It will ask for your Mac password. [Y/n] "
        read -r answer < /dev/tty || answer="n"
        answer="${answer:-y}"
    fi
    case "$answer" in
        [Yy]*)
            step "Installing Homebrew"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
            load_brew
            ;;
    esac
fi
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is needed to install PowerShell and tmux. Install it from https://brew.sh, then run this again." >&2
    exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
    step "Installing PowerShell 7"
    brew install --cask powershell
fi
if ! command -v tmux >/dev/null 2>&1; then
    step "Installing tmux"
    brew install tmux
fi
pwsh_path="$(command -v pwsh)"
echo "    using $pwsh_path"

staging="$(mktemp -d -t agent-ha-bridge)"
trap 'rm -rf "$staging"' EXIT

step "Downloading $repo ($branch)"
curl -fsSL "https://github.com/$repo/archive/refs/heads/$branch.tar.gz" | tar -xz -C "$staging"
root="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$root" ]; then
    echo "The downloaded archive did not contain the expected folder." >&2
    exit 1
fi

step "Running the installer"
# From the terminal, not this script's stdin: under `curl | bash` stdin is the script
# itself, and the installer's questions would read the rest of it as answers.
if [ -r /dev/tty ]; then
    "$pwsh_path" -NoProfile -File "$root/install.ps1" "$@" < /dev/tty
else
    "$pwsh_path" -NoProfile -File "$root/install.ps1" -NonInteractive "$@"
fi
