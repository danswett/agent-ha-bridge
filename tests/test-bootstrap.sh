#!/bin/bash
# Tests for bootstrap.sh, the macOS installer (run by the macOS CI job).
#
# Only install_pkg so far, and for one reason: it downloaded PowerShell to a bare
# mktemp name, and `installer` decides what it has been handed from the file name -
# so every Intel Mac install died on "the package path specified was invalid". A
# syntax check cannot see that, so what it hands to `installer` is checked here.
#
# curl, sudo and installer are stood in for; nothing is downloaded or installed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/bootstrap.sh}"

fails=0
check() {
    if [ "$2" = "$3" ]; then echo "  PASS  $1"
    else echo "  FAIL  $1 - got [$2] want [$3]"; fails=$((fails + 1)); fi
}

# BSD mktemp, which is what macOS has. Said plainly rather than skipped silently,
# so running this on Linux reports why instead of failing as a bug in bootstrap.sh.
if ! probe="$(mktemp -d -t bootstrap-test 2>/dev/null)"; then
    echo "  SKIP  this needs BSD mktemp, as macOS has; bootstrap.sh is macOS-only" >&2
    exit 0
fi
rmdir "$probe"

# The function under test, lifted verbatim from the installer.
eval "$(awk '/^install_pkg\(\) \{/,/^\}/' "$src")"

seen=''
downloaded=''
curl() {
    local out=''
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    downloaded="$out"
    printf 'not really a package' > "$out"
}
sudo() { "$@"; }
installer() {
    local pkg=''
    while [ $# -gt 0 ]; do case "$1" in -pkg) pkg="$2"; shift 2 ;; *) shift ;; esac; done
    seen="$pkg"
    # What macOS itself does with a path that does not name a package.
    case "$pkg" in
        *.pkg | *.mpkg) ;;
        *) echo "installer: Error - the package path specified was invalid: '$pkg'" >&2; return 1 ;;
    esac
    [ -s "$pkg" ] || { echo 'installer: empty package' >&2; return 1; }
}

echo '--- what install_pkg hands to installer ---'
install_pkg 'https://example.test/powershell-7.5.0-osx-x64.pkg'
check 'a release asset keeps its own name' "$(basename "$seen")" 'powershell-7.5.0-osx-x64.pkg'
check 'the download went to exactly that path' "$downloaded" "$seen"

install_pkg 'https://example.test/MacPorts-2.11.5-15-Sequoia.pkg'
check 'and so does a MacPorts package' "$(basename "$seen")" 'MacPorts-2.11.5-15-Sequoia.pkg'

install_pkg 'https://example.test/releases/download'
check 'a url that names no package still gets a package path' "$(basename "$seen")" 'download.pkg'

echo '--- it leaves nothing behind ---'
check 'the temporary directory is removed' "$([ -e "$(dirname "$seen")" ] && echo present || echo gone)" 'gone'

echo '--- a download that fails is never installed ---'
curl() { return 22; }
seen='none'
if install_pkg 'https://example.test/gone.pkg'; then rc=0; else rc=1; fi
check 'install_pkg reports the failure' "$rc" '1'
check 'and installer is not reached' "$seen" 'none'

echo ''
if [ "$fails" -eq 0 ]; then echo 'All bootstrap checks passed'; exit 0; fi
echo "$fails check(s) failed"
exit 1
