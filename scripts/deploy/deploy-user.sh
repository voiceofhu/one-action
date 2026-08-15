#!/usr/bin/env bash
set -Eeuo pipefail

: "${IMAGE_REF:?IMAGE_REF is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${COMPOSE_SERVICE:?COMPOSE_SERVICE is required}"
: "${READY_URL:?READY_URL is required}"

[[ "$IMAGE_REF" =~ ^ghcr\.io/voiceofhu/one-user-backend-next@sha256:[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'IMAGE_REF must be the fixed digest-qualified One User image' >&2
  exit 1
}
[[ "$REMOTE_DIR" =~ ^/opt/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ ]] \
  && [[ "$REMOTE_DIR" != *//* ]] \
  && [[ "/$REMOTE_DIR/" != *'/../'* ]] || {
  printf '%s\n' 'REMOTE_DIR must be a canonical path below /opt' >&2
  exit 1
}
[[ "$COMPOSE_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf '%s\n' 'COMPOSE_SERVICE is invalid' >&2
  exit 1
}
[[ "$READY_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?/readyz$ ]] || {
  printf '%s\n' 'READY_URL must be a loopback /readyz URL' >&2
  exit 1
}
case "${USE_SUDO:-0}" in
  0|1) ;;
  *) printf '%s\n' 'USE_SUDO must be 0 or 1' >&2; exit 1 ;;
esac

ssh one-user-deploy bash -s -- \
  "$IMAGE_REF" "$REMOTE_DIR" "$COMPOSE_SERVICE" "$READY_URL" "${USE_SUDO:-0}" <<'REMOTE'
set -Eeuo pipefail

image_ref=$1
remote_dir=$2
service=$3
ready_url=$4
use_sudo=$5

docker_cmd=(docker)
if [[ "$use_sudo" == 1 ]]; then
  docker_cmd=(sudo -n docker)
fi

[[ -d "$remote_dir" && ! -L "$remote_dir" ]] || {
  printf '%s\n' "Deployment directory is missing or unsafe: $remote_dir" >&2
  exit 1
}
[[ -f "$remote_dir/.env" && ! -L "$remote_dir/.env" ]] || {
  printf '%s\n' "Server-owned environment file is missing or unsafe: $remote_dir/.env" >&2
  exit 1
}
[[ -f "$remote_dir/docker-compose.yml" && ! -L "$remote_dir/docker-compose.yml" ]] || {
  printf '%s\n' "Server-owned Compose file is missing or unsafe: $remote_dir/docker-compose.yml" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'curl is required on the deployment host' >&2
  exit 1
}
"${docker_cmd[@]}" compose version >/dev/null

image_env="$remote_dir/.one-user-image.env"
image_env_tmp="$remote_dir/.one-user-image.env.tmp.$$"
cleanup() {
  rm -f -- "$image_env_tmp"
}
trap cleanup EXIT
umask 077
printf 'ONE_USER_IMAGE=%s\n' "$image_ref" >"$image_env_tmp"
chmod 0600 "$image_env_tmp"
mv -f -- "$image_env_tmp" "$image_env"

compose=("${docker_cmd[@]}" compose \
  --project-directory "$remote_dir" \
  --env-file "$remote_dir/.env" \
  --env-file "$image_env" \
  --file "$remote_dir/docker-compose.yml")

"${compose[@]}" config --quiet
"${compose[@]}" pull "$service"
"${compose[@]}" up -d --no-deps "$service"

container_id=$("${compose[@]}" ps -q "$service")
[[ -n "$container_id" ]] || {
  printf '%s\n' 'Compose did not return the deployed service container' >&2
  exit 1
}
running=$("${docker_cmd[@]}" inspect --format '{{.State.Running}}' "$container_id")
[[ "$running" == true ]] || {
  "${compose[@]}" logs --tail 120 "$service" >&2 || true
  printf '%s\n' 'One User container is not running' >&2
  exit 1
}

ready=false
for _ in {1..30}; do
  if curl --fail --silent --show-error --max-time 5 "$ready_url" >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  "${compose[@]}" logs --tail 120 "$service" >&2 || true
  printf '%s\n' "One User readiness check failed: $ready_url" >&2
  exit 1
fi

actual_image=$("${docker_cmd[@]}" inspect --format '{{.Config.Image}}' "$container_id")
[[ "$actual_image" == "$image_ref" ]] || {
  printf '%s\n' 'Running container image does not match the published digest' >&2
  exit 1
}
printf 'Deployed One User image %s\n' "$image_ref"
REMOTE
