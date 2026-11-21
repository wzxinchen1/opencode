#!/usr/bin/env bash
#
# Install and drive the opencode systemd unit on a single deployment target.
#
# This runs as root inside the target's WSL distro. script/build-serve.sh calls
# it locally with --source and remotely (over WinRM) with --url-base, so the
# bootstrap, install, verify and rollback logic lives in exactly one place.
#
# Usage: deploy-target.sh --action restart|start|stop|status|none
#                         (--source DIR | --url-base URL)
#                         [--user USER] [--unit UNIT] [--bin PATH]
#                         [--name NAME] [--port PORT]
#
# The install is idempotent: missing unit and environment file are created,
# the unit itself always follows this script. Verification is stricter than
# "systemctl is-active": the process listening on --port must be the unit's
# MainPID, otherwise a user-level opencode left by a client can hold the port
# while the system unit crash-loops and still look "active" from a distance.
# A failed restart restores the previous binary and restarts again.
set -euo pipefail

action=restart
source=""
urlbase=""
user="${OPENCODE_TARGET_USER:-wzxinchen}"
unit="${OPENCODE_SERVICE:-opencode}"
bin=""
name=""
port="${OPENCODE_SERVE_PORT:-4096}"

while (( $# )); do
  case "$1" in
    --action) action="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    --url-base) urlbase="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --unit) unit="$2"; shift 2 ;;
    --bin) bin="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $(id -u) -eq 0 ]] || { echo "deploy-target must run as root" >&2; exit 1; }
[[ -n $bin ]] || bin="/home/$user/.opencode/bin/opencode"
[[ -n $name ]] || name="$(hostname)"
[[ -n $source || -n $urlbase ]] || { echo "one of --source or --url-base is required" >&2; exit 2; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

fetch() {
  if [[ -n $source ]]; then
    cp "$source/$1" "$stage/$1"
    return
  fi
  curl -fsSL --retry 3 --retry-delay 1 "$urlbase/$1" -o "$stage/$1"
}

fetch opencode
fetch sha256
fetch manifest
(cd "$stage" && sha256sum -c --quiet sha256)

version="$(sed -n 's/^version=//p' "$stage/manifest")"
[[ -n $version ]] || { echo "manifest has no version" >&2; exit 1; }

port_owner() {
  ss -ltnpH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\),.*/\1/p' | head -1
}

verify_serving() {
  local main_pid owner
  main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
  [[ -n $main_pid && $main_pid != 0 ]] || return 1
  owner="$(port_owner)"
  [[ $owner == "$main_pid" ]]
}

wait_serving() {
  local attempt
  for attempt in $(seq 1 20); do
    systemctl is-active --quiet "$unit" && verify_serving && return 0
    sleep 0.5
  done
  return 1
}

if [[ $action == restart || $action == start ]]; then
  owner="$(port_owner)"
  main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
  if [[ -n $owner && $owner != "$main_pid" ]]; then
    echo "port $port is held by pid $owner, not by $unit (MainPID ${main_pid:-0}); refusing to touch the unit" >&2
    echo "stop that process first, or set OPENCODE_SERVE_PORT to another port" >&2
    echo "RESULT failed host=$name version=$version action=$action reason=port-conflict owner=$owner"
    exit 1
  fi
fi

bindir="$(dirname "$bin")"
group="$(id -gn "$user")"
install -d -m 755 -o "$user" -g "$group" "$(dirname "$bindir")"
install -d -m 755 -o "$user" -g "$group" "$bindir"
ln -sfn "$bin" /usr/local/bin/opencode

if [[ -f $bin ]]; then
  cp -a "$bin" "$bin.prev"
fi
install -m 755 -o "$user" -g "$group" "$stage/opencode" "$bin.new"
mv -f "$bin.new" "$bin"

cat > "/etc/systemd/system/$unit.service" <<UNIT
[Unit]
Description=OpenCode headless server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$user
EnvironmentFile=/etc/opencode.env
ExecStart=/usr/local/bin/opencode serve --hostname 0.0.0.0 --port $port
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# 部署不负责认证：旧版本留下的密码 drop-in 会在重启后继续生效，必须主动移除。
dropin="/etc/systemd/system/$unit.service.d/10-password.conf"
if [[ -f $dropin ]]; then
  rm -f "$dropin"
  rmdir "/etc/systemd/system/$unit.service.d" 2>/dev/null || true
fi

if [[ ! -f /etc/opencode.env ]]; then
  cat > /etc/opencode.env <<ENV
HOME=/home/$user
PATH=/home/$user/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OPENCODE_DISABLE_EVENT_PERSIST=1
ENV
fi

systemctl daemon-reload
systemctl enable "$unit" >/dev/null 2>&1 || true

rollback() {
  [[ -f $bin.prev ]] || return 1
  install -m 755 "$bin.prev" "$bin.new"
  mv -f "$bin.new" "$bin"
  systemctl restart "$unit" || true
  wait_serving
}

if [[ $action == none ]]; then
  echo "RESULT ok host=$name version=$version action=none"
  exit 0
fi

if [[ $action == stop ]]; then
  systemctl stop "$unit"
  echo "RESULT ok host=$name version=$version action=stop"
  exit 0
fi

if [[ $action == status ]]; then
  if systemctl is-active --quiet "$unit" && verify_serving; then
    echo "RESULT ok host=$name version=$version action=status"
    exit 0
  fi
  echo "RESULT failed host=$name version=$version action=status reason=not-serving"
  exit 1
fi

if systemctl restart "$unit" && wait_serving; then
  echo "RESULT ok host=$name version=$version action=$action"
  exit 0
fi

echo "restart of $unit failed to serve port $port on $name; rolling back to the previous binary" >&2
if rollback; then
  echo "RESULT failed host=$name version=$version action=$action reason=restart-failed rolledBack=yes"
  exit 1
fi

echo "rollback also failed on $name" >&2
systemctl --no-pager -l status "$unit" >&2 || true
journalctl --no-pager -u "$unit" -n 50 >&2 || true
echo "RESULT failed host=$name version=$version action=$action reason=restart-failed rolledBack=no"
exit 1
