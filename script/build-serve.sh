#!/usr/bin/env bash
#
# Build the current checkout once and roll it out to every deployment target.
# Usage: script/build-serve.sh [restart|start|stop|status|none] [--skip-build|--deploy-only] [--skip-install] [--skip-remote]
#   restart (default)  build, install on every target, then restart the unit
#   start / stop       build, install, then start or stop the unit
#   status             build, install, then check the unit is active
#   none               build and install only
#   --skip-build       reuse the existing packages/cli/dist artifact, still republish it
#   --deploy-only      reuse the newest published version under OPENCODE_DEPLOY_ROOT; no build, no republish
# Environment:
#   OPENCODE_SERVICE       systemd unit name (default: opencode)
#   OPENCODE_BIN           install target on this host (default: ~/.opencode/bin/opencode)
#   OPENCODE_CHANNEL       build channel (default: dev, which shares the release database)
#   OPENCODE_DEPLOY_ROOT   shared publish directory on this host (default: /mnt/d/wsl/opencode-deploy)
#   OPENCODE_DEPLOY_UNC    the same directory as a Windows UNC path (default: \\192.168.50.236\D\wsl\opencode-deploy)
#   OPENCODE_DEPLOY_HOSTS  space separated target names to limit the rollout
#   BUN                    bun executable (default: bun from PATH, then ~/.bun/bin/bun)
#
# 本脚本不再下发 OPENCODE_SERVER_PASSWORD：deploy-target.sh 会删除目标机上的
# 10-password.conf，opencode 以无认证模式运行（SECURITY.md 的未认证服务警告）。
# Targets live in DEPLOY_TARGETS below as name|transport|address|distro|user|unit|bin.
# "local" installs from the shared directory through wsl.exe -u root on this
# host. "winrm" runs PowerShell Invoke-Command into wsl.exe -u root on the
# target; that session maps the shared directory, copies the artifact to the
# target's TEMP, and runs the same deploy-target.sh, so no extra service runs
# on this host and the target needs no SSH daemon.
# Remote targets need two DPAPI credential files, created once with:
#   powershell.exe -Command '$c = Get-Credential; $c | Export-Clixml "$env:USERPROFILE\.opencode-deploy\credential.xml"'
#   powershell.exe -Command '$c = Get-Credential; $c | Export-Clixml "$env:USERPROFILE\.opencode-deploy\share-credential.xml"'
# The first is the target's Windows account; the second is the account that may
# read OPENCODE_DEPLOY_UNC.
# A target whose restart never becomes active is rolled back to the previous
# binary and restarted again; the remaining targets still deploy.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action=restart
build=1
install=1
remote=1
deploy_only=0
hosts_filter="${OPENCODE_DEPLOY_HOSTS:-}"
deploy_root="${OPENCODE_DEPLOY_ROOT:-/mnt/d/wsl/opencode-deploy}"
deploy_unc="${OPENCODE_DEPLOY_UNC:-\\\\192.168.50.236\\D\\wsl\\opencode-deploy}"

DEPLOY_TARGETS=(
  "hp|local|||${USER}|${OPENCODE_SERVICE:-opencode}|${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
  "asus|winrm|192.168.50.200|Ubuntu-26.04|wzxin|opencode|/home/wzxin/.opencode/bin/opencode"
)

for arg in "$@"; do
  case "$arg" in
    restart|start|stop|status|none) action="$arg" ;;
    --skip-build) build=0 ;;
    --deploy-only) deploy_only=1; build=0 ;;
    --skip-install) install=0 ;;
    --skip-remote) remote=0 ;;
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if (( deploy_only && !install )); then
  echo "--deploy-only cannot be combined with --skip-install" >&2
  exit 2
fi

bun="${BUN:-}"
if [[ -z "$bun" ]]; then
  bun="$(command -v bun || true)"
  [[ -n "$bun" ]] || bun="$HOME/.bun/bin/bun"
fi
[[ -x "$bun" ]] || { echo "bun not found; set BUN or install bun" >&2; exit 1; }

# 分支名当 channel 会让构建自带一个独立数据库（packages/cli/src/database-path.ts 经
# packages/script/src/index.ts 取 channel），长期驻留的服务就会落到空库上；dev 是上游
# 定义为「共享服务与数据库」的频道。
export OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-dev}"

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

if (( ! install )); then
  echo "==> build only (--skip-install)"
  exit 0
fi

if (( deploy_only )); then
  version="${OPENCODE_DEPLOY_VERSION:-}"
  if [[ -z "$version" ]]; then
    for candidate in $(ls -1t "$deploy_root"); do
      if [[ -f "$deploy_root/$candidate/opencode" ]]; then version="$candidate"; break; fi
    done
  fi
  [[ -n "$version" ]] || { echo "no published version under $deploy_root" >&2; exit 1; }
  publish="$deploy_root/$version"
  [[ -f "$publish/opencode" && -f "$publish/sha256" && -f "$publish/manifest" ]] || {
    echo "incomplete publish directory: $publish" >&2
    exit 1
  }
  cp "$root/script/deploy-target.sh" "$publish/deploy-target.sh"
  chmod 755 "$publish/deploy-target.sh"
  echo "==> reuse $publish (--deploy-only)"
else
  [[ -f "$artifact" ]] || { echo "artifact not found: $artifact" >&2; exit 1; }

  version="$("$bun" -e "console.log(require('$root/packages/cli/package.json').version)")"
  publish="$deploy_root/$version"
  mkdir -p "$publish"
  install -m 755 "$artifact" "$publish/opencode"
  hash="$(sha256sum "$publish/opencode" | cut -d' ' -f1)"
  printf '%s  opencode\n' "$hash" > "$publish/sha256"
  printf 'version=%s\n' "$version" > "$publish/manifest"
  cp "$root/script/deploy-target.sh" "$publish/deploy-target.sh"
  chmod 755 "$publish/deploy-target.sh"
  echo "==> published $version to $publish"
fi

if (( remote )); then
  mkdir -p "$HOME/.opencode-deploy"
  cat > "$HOME/.opencode-deploy/remote-run.ps1" <<'PS1'
param(
  [Parameter(Mandatory=$true)][string]$Address,
  [Parameter(Mandatory=$true)][string]$Distro,
  [Parameter(Mandatory=$true)][string]$Share,
  [Parameter(Mandatory=$true)][string]$Action,
  [Parameter(Mandatory=$true)][string]$User,
  [Parameter(Mandatory=$true)][string]$Unit,
  [Parameter(Mandatory=$true)][string]$Bin,
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$Credential = "$env:USERPROFILE\.opencode-deploy\credential.xml",
  [string]$ShareCredential = "$env:USERPROFILE\.opencode-deploy\share-credential.xml"
)
$ErrorActionPreference = "Stop"
$cred = Import-Clixml -LiteralPath $Credential
$shareCred = Import-Clixml -LiteralPath $ShareCredential
$shareSecret = $shareCred.GetNetworkCredential().Password
Invoke-Command -ComputerName $Address -Credential $cred -ScriptBlock {
  param($Share, $ShareUser, $ShareSecret, $Distro, $Action, $User, $Unit, $Bin, $Name)
  $ErrorActionPreference = "Stop"
  $secure = ConvertTo-SecureString $ShareSecret -AsPlainText -Force
  $drive = New-PSDrive -Name OCDEPLOY -PSProvider FileSystem -Root $Share -Credential (New-Object System.Management.Automation.PSCredential($ShareUser, $secure)) -ErrorAction Stop
  $stage = Join-Path $env:TEMP "opencode-deploy"
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $stage | Out-Null
  Copy-Item -Path "OCDEPLOY:\*" -Destination $stage -Force -Recurse
  Remove-PSDrive -Name OCDEPLOY -ErrorAction SilentlyContinue
  $wslStage = "/mnt/c/" + (($stage -replace '^[A-Za-z]:\\', '') -replace '\\', '/')
  $command = "bash '$wslStage/deploy-target.sh' --action '$Action' --source '$wslStage' --user '$User' --unit '$Unit' --bin '$Bin' --name '$Name'"
  & wsl.exe -d $Distro -u root -- bash -c $command
  Write-Output ("DEPLOY_EXIT=" + $LASTEXITCODE)
} -ArgumentList $Share, $shareCred.UserName, $shareSecret, $Distro, $Action, $User, $Unit, $Bin, $Name
PS1
  ps1_win="$(wslpath -w "$HOME/.opencode-deploy/remote-run.ps1")"
fi

failed=0
summary=()

for spec in "${DEPLOY_TARGETS[@]}"; do
  IFS='|' read -r -a fields <<< "$spec"
  name="${fields[0]}"
  transport="${fields[1]}"
  address="${fields[2]}"
  distro="${fields[3]}"
  target_user="${fields[4]}"
  unit="${fields[5]}"
  target_bin="${fields[6]}"

  if [[ -n "$hosts_filter" && " $hosts_filter " != *" $name "* ]]; then continue; fi
  if [[ "$transport" == winrm ]] && (( ! remote )); then continue; fi

  echo "==> deploy $name ($transport)"
  if [[ "$transport" == local ]]; then
    cmd=(wsl.exe -u root -- bash "$publish/deploy-target.sh" --action "$action" --source "$publish" --user "$target_user" --unit "$unit" --bin "$target_bin" --name "$name")
    output="$("${cmd[@]}" 2>&1 | tr -d '\r' || true)"
  else
    ps_args=(-Address "$address" -Distro "$distro" -Share "$deploy_unc\\$version" -Action "$action" -User "$target_user" -Unit "$unit" -Bin "$target_bin" -Name "$name")
    output="$( (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps1_win" "${ps_args[@]}") 2>&1 | tr -d '\r' || true )"
  fi

  printf '%s\n' "$output" | sed 's/^/    /'
  if grep -q '^RESULT ok' <<< "$output" && { [[ "$transport" == local ]] || grep -q '^DEPLOY_EXIT=0' <<< "$output"; }; then
    summary+=("ok   $name")
  else
    summary+=("FAIL $name")
    failed=$((failed + 1))
  fi
done

echo "==> summary (version $version)"
printf '  %s\n' "${summary[@]}"
(( failed == 0 )) || exit 1
