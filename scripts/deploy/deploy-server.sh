#!/usr/bin/env bash
# Deploys one products.json Server image over SSH + Compose, activates its Web
# (bundled in the Server image, or the separate Web image for web_runtime next),
# and restores the previous containers and Web on failure.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/product.sh
source "$SCRIPT_DIR/../lib/product.sh"

: "${PRODUCT:?PRODUCT is required}"
: "${SSH_HOST:?SSH_HOST is required}"
: "${DOCKER_IMAGE:?DOCKER_IMAGE is required}"
: "${COMPOSE_FILE:?COMPOSE_FILE is required}"
load_product "$PRODUCT"
REMOTE_DIR=${REMOTE_DIR:-$PRODUCT_REMOTE_DIR}
PUBLIC_URL=${PUBLIC_URL:-$PRODUCT_PUBLIC_URL}

[[ "$SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf '%s\n' 'SSH_HOST is invalid' >&2
  exit 1
}
[[ "$REMOTE_DIR" =~ ^/opt/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ ]] \
  && [[ "$REMOTE_DIR" != *//* ]] \
  && [[ "/$REMOTE_DIR/" != *'/../'* ]] || {
  printf '%s\n' 'REMOTE_DIR must be a canonical path below /opt' >&2
  exit 1
}
image_reference=${DOCKER_IMAGE#"$PRODUCT_IMAGE":}
[[ "$image_reference" != "$DOCKER_IMAGE" \
  && "$image_reference" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]] || {
  printf 'DOCKER_IMAGE must be a %s version pinned to an OCI index digest\n' "$PRODUCT_IMAGE" >&2
  exit 1
}
WEB_DOCKER_IMAGE=${WEB_DOCKER_IMAGE:-}
if [[ "$PRODUCT_WEB_RUNTIME" == next ]]; then
  web_image_reference=${WEB_DOCKER_IMAGE#"$PRODUCT_WEB_IMAGE":}
  [[ "$web_image_reference" != "$WEB_DOCKER_IMAGE" \
    && "$web_image_reference" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]] || {
    printf 'WEB_DOCKER_IMAGE must be a %s version pinned to an OCI index digest\n' "$PRODUCT_WEB_IMAGE" >&2
    exit 1
  }
elif [[ -n "$WEB_DOCKER_IMAGE" ]]; then
  printf '%s bundles its Web in the Server image; WEB_DOCKER_IMAGE must be empty\n' "$PRODUCT_TITLE" >&2
  exit 1
fi
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || {
  printf 'Compose file is missing or unsafe: %s\n' "$COMPOSE_FILE" >&2
  exit 1
}
PUBLIC_URL=${PUBLIC_URL%/}
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || {
  printf '%s\n' 'PUBLIC_URL must be an HTTPS origin without a path, query, fragment, or trailing slash' >&2
  exit 1
}

remote_checks="test -d '$REMOTE_DIR' && test -w '$REMOTE_DIR' && test -f '$REMOTE_DIR/.env' && test -r '$REMOTE_DIR/.env'"
required_layout='.env'
for directory in ${PRODUCT_REMOTE_REQUIRED_DIRS[@]+"${PRODUCT_REMOTE_REQUIRED_DIRS[@]}"}; do
  remote_checks+=" && test -d '$REMOTE_DIR/$directory'"
  required_layout+=" and $directory/"
done
# shellcheck disable=SC2029 # Every interpolated value was validated above.
ssh "$SSH_HOST" "$remote_checks && command -v curl >/dev/null && docker info >/dev/null" || {
  printf '%s\n' "$REMOTE_DIR must exist, contain $required_layout (.env readable by the deploy user), and be writable; curl and Docker must be available to the deploy user" >&2
  exit 1
}

scp "$COMPOSE_FILE" "$SSH_HOST:$REMOTE_DIR/docker-compose.yml.next"

remote_arguments=(
  "$REMOTE_DIR" "$DOCKER_IMAGE" "$PUBLIC_URL" "$PRODUCT_TITLE" "$PRODUCT_IMAGE"
  "$PRODUCT_CONTAINER" "$PRODUCT_SERVICE" "$PRODUCT_NAME" "$PRODUCT_WEB_DIST"
  "$PRODUCT_SERVICE_PORT" "$PRODUCT_READY_PATH"
  "$PRODUCT_WEB_HEALTH_PATH"
  "$PRODUCT_WEB_RUNTIME" "$WEB_DOCKER_IMAGE" "$PRODUCT_WEB_IMAGE"
  "$PRODUCT_WEB_CONTAINER" "$PRODUCT_WEB_SERVICE" "${PRODUCT_WEB_PORT:-0}"
)
# ssh joins its arguments into one string for the remote shell, so quote each
# value (the title contains a space) to keep the positional arguments intact.
remote_command="REGISTRY_CONFIG_NAME=$SSH_HOST bash -s --$(printf ' %q' "${remote_arguments[@]}")"
# shellcheck disable=SC2029 # The command is built from validated, quoted values.
ssh "$SSH_HOST" "$remote_command" <<'REMOTE_DEPLOY'
set -Eeuo pipefail

remote_dir=$1
image=$2
public_url=$3
title=$4
image_repository=$5
container_name=$6
service_name=$7
project_name=$8
web_dist=$9
service_port=${10}
ready_path=${11}
web_health_path=${12}
web_runtime=${13}
web_image=${14}
web_image_repository=${15}
web_container_name=${16}
web_service_name=${17}
web_port=${18}

services=("$service_name")
expected_images=$image
if [[ "$web_runtime" == next ]]; then
  services+=("$web_service_name")
  expected_images="$(printf '%s\n' "$image" "$web_image" | LC_ALL=C sort)"
fi

cd "$remote_dir"
test -f docker-compose.yml.next
mkdir -p web/releases
exec 9>web/.deploy.lock
flock -w 120 9

compose() {
  local compose_file=$1
  shift
  env DOCKER_IMAGE="$image" CONTAINER_NAME="$container_name" \
    WEB_DOCKER_IMAGE="$web_image" WEB_CONTAINER_NAME="$web_container_name" docker compose \
    --project-name "$project_name" \
    --project-directory "$remote_dir" \
    --env-file .env \
    --file "$compose_file" \
    "$@"
}

compose docker-compose.yml.next config --quiet
configured_images="$(compose docker-compose.yml.next config --images | LC_ALL=C sort)"
[[ "$configured_images" == "$expected_images" ]] || {
  printf 'Compose did not resolve exactly the requested immutable %s image\n' "$title" >&2
  exit 1
}
previous_image="$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"
previous_web_image=
if [[ "$web_runtime" == next ]]; then
  previous_web_image="$(docker inspect --format '{{.Config.Image}}' "$web_container_name" 2>/dev/null || true)"
fi

previous_web="$(readlink web/current 2>/dev/null || true)"
extract_container=

rollback() {
  local exit_code=$?
  trap - ERR
  if [[ -n "$extract_container" ]]; then
    docker rm "$extract_container" >/dev/null || true
  fi
  if [[ -n "$previous_web" ]]; then
    ln -s "$previous_web" web/current.rollback
    mv -Tf web/current.rollback web/current
  fi
  printf '%s deployment failed; attempting to restore the previous container\n' "$title" >&2
  if [[ "$previous_image" == "$image_repository":* \
    && "$previous_image" =~ @sha256:[0-9a-f]{64}$ \
    && "$previous_image" != "$image" \
    && -f docker-compose.yml ]]; then
    local failed_image=$image
    image=$previous_image
    compose docker-compose.yml up -d --no-deps --wait --wait-timeout 120 "$service_name" || true
    image=$failed_image
  fi
  if [[ "$previous_web_image" == "$web_image_repository":* \
    && "$previous_web_image" =~ @sha256:[0-9a-f]{64}$ \
    && "$previous_web_image" != "$web_image" \
    && -f docker-compose.yml ]]; then
    local failed_web_image=$web_image
    web_image=$previous_web_image
    compose docker-compose.yml up -d --no-deps --wait --wait-timeout 120 "$web_service_name" || true
    web_image=$failed_web_image
  fi
  rm -f docker-compose.yml.next
  exit "$exit_code"
}
trap rollback ERR

# The workflow logged this product in to its own Docker config (registry-auth.sh).
DOCKER_CONFIG="$HOME/.docker-deploy/${REGISTRY_CONFIG_NAME:?}" \
  compose docker-compose.yml.next pull "${services[@]}"
if [[ "$web_runtime" == static ]]; then
  # Server releases activate the Web bundled with the new Server image.
  release_web="releases/server-$(date +%s)-$$"
  mkdir "web/$release_web"
  extract_container="$(docker create "$image")"
  docker cp "$extract_container:$web_dist/." "web/$release_web/"
  docker rm "$extract_container" >/dev/null
  extract_container=
  test -f "web/$release_web/index.html"
  if [[ -d web/current/assets ]]; then
    mkdir -p "web/$release_web/assets"
    cp -an web/current/assets/. "web/$release_web/assets/"
  fi
  chmod -R a+rX "web/$release_web"
  ln -s "$release_web" web/current.next
  mv -Tf web/current.next web/current
fi
compose docker-compose.yml.next up -d --no-deps --wait --wait-timeout 120 "${services[@]}"

local_ready() {
  local container=$1 port=$2 path=$3 published_port
  published_port="$(docker port "$container" "$port/tcp" 2>/dev/null | sed -n '1s/.*://p' || true)"
  [[ -n "$published_port" ]] \
    && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:$published_port$path" >/dev/null || {
    docker logs --tail 120 "$container" >&2 || true
    false
  }
}
local_ready "$container_name" "$service_port" "$ready_path"
if [[ "$web_runtime" == next ]]; then
  local_ready "$web_container_name" "$web_port" "$web_health_path"
else
  local_ready "$container_name" "$service_port" "$web_health_path"
fi

running_image="$(docker inspect --format '{{.Config.Image}}' "$container_name")"
[[ "$running_image" == "$image" ]] || {
  printf 'Running container does not use the requested immutable %s image\n' "$title" >&2
  false
}
if [[ "$web_runtime" == next ]]; then
  running_web_image="$(docker inspect --format '{{.Config.Image}}' "$web_container_name")"
  [[ "$running_web_image" == "$web_image" ]] || {
    printf 'Running Web container does not use the requested immutable %s Web image\n' "$title" >&2
    false
  }
fi

public_ready=false
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
    "$public_url$ready_path" >/dev/null \
    && curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
      "$public_url$web_health_path" >/dev/null; then
    public_ready=true
    printf '%s public endpoint is ready: %s\n' "$title" "$public_url"
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    printf 'Public endpoint did not become ready: %s\n' "$public_url" >&2
    docker logs --tail 120 "$container_name" >&2 || true
    false
  fi
  sleep 2
done
[[ "$public_ready" == true ]]

mv -f docker-compose.yml.next docker-compose.yml
trap - ERR
REMOTE_DEPLOY
