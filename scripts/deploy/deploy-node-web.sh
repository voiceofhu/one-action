#!/usr/bin/env bash
set -Eeuo pipefail
: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${WEB_ARCHIVE:?WEB_ARCHIVE is required}"
: "${WEB_SHA:?WEB_SHA is required}"
PUBLIC_URL=${PUBLIC_URL:-https://marseo.eu.org}
[[ "$SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
[[ "$REMOTE_DIR" =~ ^/opt/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ && "$REMOTE_DIR" != *..* && "$REMOTE_DIR" != *//* ]]
[[ "$WEB_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$ ]]
[[ -f "$WEB_ARCHIVE" && ! -L "$WEB_ARCHIVE" ]]
archive_sha="$(sha256sum "$WEB_ARCHIVE" | cut -d ' ' -f1)"
ssh "$SSH_HOST" "test -L '$REMOTE_DIR/web/current' && test -f '$REMOTE_DIR/web/current/index.html'" || {
  echo 'Deploy Node Server with the persistent Web mount before publishing Web separately.' >&2
  exit 1
}
scp "$WEB_ARCHIVE" "$SSH_HOST:$REMOTE_DIR/web/$WEB_SHA.tar.gz"
ssh "$SSH_HOST" bash -s -- "$REMOTE_DIR" "$WEB_SHA" "$archive_sha" "${PUBLIC_URL%/}" <<'REMOTE_DEPLOY'
set -Eeuo pipefail
remote_dir=$1
web_sha=$2
archive_sha=$3
public_url=$4
cd "$remote_dir/web"
exec 9>.deploy.lock
flock -w 120 9
printf '%s  %s.tar.gz\n' "$archive_sha" "$web_sha" | sha256sum -c -
previous=$(readlink current)
release=$(mktemp -d "releases/web-$web_sha-XXXXXX")
tar -xzf "$web_sha.tar.gz" -C "$release" --no-same-owner
rm "$web_sha.tar.gz"
test -f "$release/index.html"
[[ "$(cat "$release/one-web-revision.txt")" == "$web_sha" ]]
# Preserve hashed assets referenced by pages already open in a node.
if [[ -d current/assets ]]; then
  mkdir -p "$release/assets"
  cp -an current/assets/. "$release/assets/"
fi
chmod -R a+rX "$release"
rollback() {
  local status=${1:-$?}
  trap - ERR
  ln -s "$previous" current.rollback
  mv -Tf current.rollback current
  echo 'Web health check failed; restored the previous Web version.' >&2
  exit "$status"
}
trap rollback ERR
ln -s "$release" current.next
mv -Tf current.next current
ready=false
for attempt in $(seq 1 15); do
  revision=$(curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
    "$public_url/one-web-revision.txt?release=$web_sha" || true)
  if [[ "$revision" == "$web_sha" ]] && curl --fail --silent --show-error --max-time 10 "$public_url/" >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  rollback 1
fi
trap - ERR
printf 'Web updated to %s; Server container was not changed.\n' "$web_sha"
REMOTE_DEPLOY
