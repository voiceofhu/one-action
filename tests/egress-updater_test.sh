#!/usr/bin/env bash
# Execute only isolated updater fixtures; no host services or runtime are installed.
set -Eeuo pipefail
UPDATER=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/egress/scripts/install/updater.sh}
bash -s -- "$UPDATER" <<'TEST'
set -Eeuo pipefail
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/update"
awk '/^#!\/usr\/bin\/env bash$/ { copy=1 } /^EOF$/ && copy { exit } copy { print }' "$1" |
  sed "s|readonly install_dir=/opt/one-browser-egress|readonly install_dir=$fixture|" >"$fixture/updater.sh"
printf 'runtime=docker\nversion=26.902.1000\n' >"$fixture/.installation"
cat >"$fixture/install.sh" <<'MANAGER'
#!/usr/bin/env bash
printf '%s\n' "$*"
if [ "${TEST_UPGRADE_EXIT:-0}" = wait ]; then
  sleep 30
  exit 0
fi
if [ "${TEST_UPGRADE_EXIT:-0}" = 143 ]; then
  kill -TERM "$PPID"
fi
exit "${TEST_UPGRADE_EXIT:-0}"
MANAGER
# Linux uses real permissions, flock and fsync; macOS lacks these GNU tools.
if [ "$(uname -s)" != Linux ]; then
  stat() { printf '600\n'; }
  chown() { :; }
  flock() { :; }
  export -f stat chown flock
fi
sync() {
  [ "${TEST_SYNC_EXIT:-0}" = 0 ] || return 1
  if [ "$(uname -s)" = Linux ]; then command sync "$@"; fi
}
export -f sync
for result in 0 1 143; do
  printf 'upgrade_id=test-upgrade\nversion=26.902.1200\nstate=pending\nrequested_at=2026-09-06T00:00:00Z\nupdated_at=2026-09-06T00:00:00Z\nmessage=\n' >"$fixture/update/request"
  chmod 0600 "$fixture/update/request"
  actual=0
  TEST_UPGRADE_EXIT=$result bash "$fixture/updater.sh" || actual=$?
  [[ "$actual" == "$result" ]]
  if [ "$result" = 0 ]; then state=succeeded; else state=failed; fi
  grep -qx "state=$state" "$fixture/update/status"
  grep -qx -- '--upgrade 26.902.1200' "$fixture/last-upgrade.log"
  [[ ! -e "$fixture/update/request.running" && ! -e "$fixture/update/request" ]]
done
# Exercise real process-group TERM timeout and SIGKILL on Linux.
if [ "$(uname -s)" = Linux ]; then
  for signal in TERM KILL; do
    printf 'upgrade_id=timeout-test\nversion=26.902.1200\nstate=pending\nrequested_at=2026-09-06T00:00:00Z\nupdated_at=2026-09-06T00:00:00Z\nmessage=\n' >"$fixture/update/request"
    chmod 0600 "$fixture/update/request"
    actual=0
    TEST_UPGRADE_EXIT=wait timeout --signal="$signal" --kill-after=1s 1s bash "$fixture/updater.sh" || actual=$?
    [[ "$actual" = 124 || "$actual" = 137 ]]
    if [ "$signal" = KILL ]; then
      [[ -f "$fixture/update/request.running" ]]
      bash "$fixture/updater.sh"
    fi
    grep -qx 'state=failed' "$fixture/update/status"
    [[ ! -e "$fixture/update/request.running" ]]
  done
fi
# If status persistence fails, retain the running request until storage recovers.
printf 'upgrade_id=status-failure\nversion=26.902.1200\nstate=pending\nrequested_at=2026-09-06T00:00:00Z\nupdated_at=2026-09-06T00:00:00Z\nmessage=\n' >"$fixture/update/request"
chmod 0600 "$fixture/update/request"
actual=0
TEST_SYNC_EXIT=1 bash "$fixture/updater.sh" || actual=$?
[[ "$actual" != 0 && -f "$fixture/update/request.running" ]]
bash "$fixture/updater.sh"
grep -qx 'state=failed' "$fixture/update/status"
[[ ! -e "$fixture/update/request.running" ]]
# An orphan from SIGKILL/reboot must finish without replaying the installer.
for version in 26.902.1000 26.902.1200; do
  printf 'runtime=docker\nversion=%s\n' "$version" >"$fixture/.installation"
  printf 'upgrade_id=orphan\nversion=26.902.1200\nstate=pending\nrequested_at=2026-09-06T00:00:00Z\nupdated_at=2026-09-06T00:00:00Z\nmessage=\n' >"$fixture/update/request.running"
  chmod 0600 "$fixture/update/request.running"
  rm -f "$fixture/last-upgrade.log"
  bash "$fixture/updater.sh"
  if [ "$version" = 26.902.1200 ]; then state=succeeded; else state=failed; fi
  grep -qx "state=$state" "$fixture/update/status"
  [[ ! -e "$fixture/update/request.running" && ! -e "$fixture/last-upgrade.log" ]]
done
# Booting with no outstanding request is a successful no-op.
bash "$fixture/updater.sh"
TEST
printf '%s\n' 'Egress host updater success/failure/interruption/recovery tests passed.'
