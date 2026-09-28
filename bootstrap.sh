#!/bin/bash
# Installs the agent-ha-bridge on macOS, from nothing:
#
#   curl -fsSL https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.sh | bash
#
# The macOS counterpart of bootstrap.ps1. It makes sure PowerShell 7 (every bridge
# script runs under pwsh) and tmux (each session runs in tmux, so the dashboard can
# type into it) are installed, downloads the branch and hands over to install.ps1 -
# which asks for everything else.
#
# Apple silicon: both come from Homebrew, which is offered if it is missing.
# Intel: Homebrew no longer supports Intel Macs, so PowerShell comes from Microsoft's
# own package and tmux from MacPorts (offered too, with Apple's command line tools it
# needs). Homebrew is still used on an Intel Mac that already has a working one.
#
# BRANCH=<name> installs another branch.
set -euo pipefail

repo="danswett/agent-ha-bridge"
branch="${BRANCH:-main}"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
fail() { echo "$1" >&2; exit 1; }

# Questions go to the terminal: under `curl | bash` this script's stdin is the script.
ask() {
    local answer="n"
    if [ -r /dev/tty ]; then
        printf "%s [Y/n] " "$1"
        read -r answer < /dev/tty || answer="n"
        answer="${answer:-y}"
    fi
    case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if [ "$(uname -s)" != "Darwin" ]; then
    fail "This installer is for macOS. On Windows, run bootstrap.ps1."
fi
arch="$(uname -m)"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"

# Whatever is installed but not on this shell's PATH yet.
load_paths() {
    for prefix in /opt/homebrew /usr/local; do
        if ! command -v brew >/dev/null 2>&1 && [ -x "$prefix/bin/brew" ]; then
            eval "$("$prefix/bin/brew" shellenv)"
        fi
    done
    case ":$PATH:" in *":/opt/local/bin:"*) ;; *) [ -d /opt/local/bin ] && PATH="$PATH:/opt/local/bin" ;; esac
    case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="$PATH:/usr/local/bin" ;; esac
    export PATH
}
load_paths

# The newest release asset of a GitHub repository whose name matches a pattern, or
# nothing. Never fails: under pipefail a lookup that finds nothing would end the script.
#
# `--` before the pattern is load-bearing: the macOS lookup passes "-13-[A-Za-z]+\.pkg$",
# and grep read a leading hyphen as an option - "grep: unknown option" - so every
# MacPorts lookup found nothing and the install died reporting no package for this macOS.
latest_asset() {
    { curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
        grep -Eo '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 | grep -E -- "$2" | head -n 1; } || true
}

# `installer` decides what it has been handed from the file name, so the download has
# to keep its .pkg suffix - a bare mktemp name is rejected as an invalid package path.
install_pkg() {
    local url="$1" dir pkg
    dir="$(mktemp -d -t bridge-pkg)"
    pkg="$dir/${url##*/}"
    case "$pkg" in *.pkg | *.mpkg) ;; *) pkg="$dir/download.pkg" ;; esac
    curl -fsSL -o "$pkg" "$url" || { rm -rf "$dir"; return 1; }
    sudo installer -pkg "$pkg" -target / || { rm -rf "$dir"; return 1; }
    rm -rf "$dir"
}

# ----------------------------------------------------------------- Apple silicon
use_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is not installed. It is used to install PowerShell 7 and tmux."
        if ask "Install Homebrew now? It will ask for your Mac password."; then
            step "Installing Homebrew"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
            load_paths
        fi
    fi
    command -v brew >/dev/null 2>&1 ||
        fail "Homebrew is needed to install PowerShell and tmux. Install it from https://brew.sh, then run this again."
    if ! command -v pwsh >/dev/null 2>&1; then
        step "Installing PowerShell 7"
        brew install --cask powershell
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        step "Installing tmux"
        brew install tmux
    fi
}

# ------------------------------------------------------------------------- Intel
install_pwsh_pkg() {
    step "Installing PowerShell 7 (Microsoft's package for Intel Macs)"
    echo "    It will ask for your Mac password."
    local url
    url="$(latest_asset PowerShell/PowerShell 'osx-x64\.pkg$')"
    if [ -n "$url" ] && install_pkg "$url"; then return 0; fi
    # The newest release may need a newer macOS than this one; 7.4, the long-term
    # release, supports older ones.
    echo "    that release did not install; trying PowerShell 7.4 (long-term support)"
    url="$({ curl -fsSL "https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=100" |
        grep -Eo '"browser_download_url": *"[^"]+powershell-7\.4\.[0-9]+-osx-x64\.pkg"' | cut -d'"' -f4 | head -n 1; } || true)"
    [ -n "$url" ] && install_pkg "$url"
}

ensure_command_line_tools() {
    xcode-select -p >/dev/null 2>&1 && return 0
    echo "MacPorts needs Apple's command line tools. macOS will now ask to install them."
    xcode-select --install >/dev/null 2>&1 || true
    printf "    waiting for the command line tools to finish installing"
    until xcode-select -p >/dev/null 2>&1; do printf "."; sleep 10; done
    echo
}

install_tmux_macports() {
    if ! command -v port >/dev/null 2>&1; then
        echo "tmux comes from MacPorts on an Intel Mac, and MacPorts is not installed."
        ask "Install MacPorts now? It will ask for your Mac password." ||
            fail "tmux is needed for replies from the dashboard. Install MacPorts from https://www.macports.org, then run this again."
        ensure_command_line_tools
        step "Installing MacPorts"
        local url
        url="$(latest_asset macports/macports-base "-${macos_major}-[A-Za-z]+\.pkg$")"
        [ -n "$url" ] || fail "No MacPorts package was found for macOS $macos_major. See https://www.macports.org/install.php"
        install_pkg "$url" || fail "MacPorts did not install. See https://www.macports.org/install.php"
        load_paths
    fi
    step "Installing tmux (MacPorts)"
    sudo port -N install tmux
}

use_intel_packages() {
    command -v pwsh >/dev/null 2>&1 || install_pwsh_pkg || fail "PowerShell 7 could not be installed. See https://aka.ms/powershell"
    load_paths
    command -v tmux >/dev/null 2>&1 || install_tmux_macports
    load_paths
}

if [ "$arch" = "arm64" ] || command -v brew >/dev/null 2>&1; then
    use_homebrew
else
    use_intel_packages
fi

command -v pwsh >/dev/null 2>&1 || fail "PowerShell 7 is not on PATH. Open a new terminal and run this again."
command -v tmux >/dev/null 2>&1 || echo "Note: tmux is not installed, so replies from the dashboard will not reach sessions." >&2
pwsh_path="$(command -v pwsh)"
echo "    using $pwsh_path"

staging="$(mktemp -d -t agent-ha-bridge)"
trap 'rm -rf "$staging"' EXIT

step "Downloading $repo ($branch)"
curl -fsSL "https://github.com/$repo/archive/refs/heads/$branch.tar.gz" | tar -xz -C "$staging"
root="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$root" ] || fail "The downloaded archive did not contain the expected folder."

step "Running the installer"
if [ -r /dev/tty ]; then
    "$pwsh_path" -NoProfile -File "$root/install.ps1" "$@" < /dev/tty
else
    "$pwsh_path" -NoProfile -File "$root/install.ps1" -NonInteractive "$@"
fi
