#!/usr/bin/env bash
#
# Build the current checkout and drive the opencode systemd unit.
#
# Usage: script/build-serve.sh [restart|start|stop|status|none] [--skip-build] [--skip-install]
#
#   restart (default)  build, install, then restart the unit
#   start / stop       build, install, then start or stop the unit
#   status             build, install, then print the unit status
#   none               build and install only
#
# Environment:
#   OPENCODE_SERVICE  systemd unit name (default: opencode)
#   OPENCODE_BIN      install target (default: ~/.opencode/bin/opencode)
#   WSL_DISTRO        distro passed to wsl.exe -d (default: $WSL_DISTRO_NAME)
#   BUN               bun executable (default: bun from PATH, then ~/.bun/bin/bun)
#
# systemctl runs as root through wsl.exe, so no sudo password is needed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service="${OPENCODE_SERVICE:-opencode}"
dest="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
action="restart"
build=1
install=1

for arg in "$@"; do
  case "$arg" in
    restart|start|stop|status|none) action="$arg" ;;
    --skip-build) build=0 ;;
    --skip-install) install=0 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

bun="${BUN:-}"
if [[ -z "$bun" ]]; then
  bun="$(command -v bun || true)"
  [[ -n "$bun" ]] || bun="$HOME/.bun/bin/bun"
fi
[[ -x "$bun" ]] || { echo "bun not found; set BUN or install bun" >&2; exit 1; }

if (( build )); then
  echo "==> build packages/cli (single target)"
  "$bun" run --cwd "$root/packages/cli" script/build.ts --single
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
artifact="$root/packages/cli/dist/cli-$os-$arch/bin/opencode"

if (( install )); then
  [[ -f "$artifact" ]] || { echo "artifact not found: $artifact" >&2; exit 1; }
  mkdir -p "$(dirname "$dest")"
  echo "==> install $artifact -> $dest"
  install -m 755 "$artifact" "$dest.new"
  mv -f "$dest.new" "$dest"
fi

[[ "$action" == "none" ]] && exit 0

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "not inside WSL; run 'systemctl $action $service' with your own privileges" >&2
  exit 1
fi

distro="${WSL_DISTRO:-${WSL_DISTRO_NAME:-}}"
echo "==> systemctl $action $service (root via wsl.exe)"
if [[ -n "$distro" ]]; then
  wsl.exe -d "$distro" -u root -- systemctl "$action" "$service"
else
  wsl.exe -u root -- systemctl "$action" "$service"
fi

if [[ "$action" == restart || "$action" == start ]]; then
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    echo "==> $service is active"
  else
    echo "==> $service is not active; check: wsl.exe -u root -- journalctl -u $service -n 50" >&2
    exit 1
  fi
fi
