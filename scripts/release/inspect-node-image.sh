#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" == 1 && -n "$1" ]] || {
  printf '%s\n' 'usage: inspect-node-image.sh <registry/image:tag>' >&2
  exit 1
}
: "${EXPECTED_VERSION:?EXPECTED_VERSION is required}"
: "${EXPECTED_COMMIT:?EXPECTED_COMMIT is required}"
: "${EXPECTED_UPSTREAM_VERSION:?EXPECTED_UPSTREAM_VERSION is required}"
: "${EXPECTED_UPSTREAM_COMMIT:?EXPECTED_UPSTREAM_COMMIT is required}"

image_ref=$1
manifest_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$manifest_file" "$error_file"' EXIT

if ! docker buildx imagetools inspect --raw "$image_ref" >"$manifest_file" 2>"$error_file"; then
  error_text="$(tr '[:upper:]' '[:lower:]' <"$error_file")"
  if [[ "$error_text" == *'manifest unknown'* || "$error_text" == *'name unknown'* \
    || "$error_text" == *'no such manifest'* || "$error_text" == *': not found'* \
    || "$error_text" == *'404 not found'* ]]; then
    printf 'Image does not exist: %s\n' "$image_ref"
    exit 2
  fi
  printf 'Failed to inspect %s; refusing to treat the error as a missing image.\n' "$image_ref" >&2
  cat "$error_file" >&2
  exit 1
fi

jq -e '
  [.manifests[]? | {os: .platform.os, architecture: .platform.architecture}]
  | sort_by(.architecture)
  == [{os: "linux", architecture: "amd64"}, {os: "linux", architecture: "arm64"}]
' "$manifest_file" >/dev/null || {
  printf '%s must contain exactly linux/amd64 and linux/arm64.\n' "$image_ref" >&2
  exit 1
}

image_repository=$image_ref
if [[ "${image_ref##*/}" == *:* ]]; then
  image_repository="${image_ref%:*}"
fi
for architecture in amd64 arm64; do
  digest="$(jq -er --arg architecture "$architecture" '
    .manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture) | .digest
  ' "$manifest_file")"
  platform_ref="$image_repository@$digest"
  docker pull --platform "linux/$architecture" "$platform_ref" >/dev/null
  [[ "$(docker image inspect --format '{{.Architecture}}' "$platform_ref")" == "$architecture" ]]
  [[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$platform_ref")" == '["/usr/local/bin/one-node"]' ]]
  while IFS='|' read -r label expected; do
    actual="$(docker image inspect --format "{{ index .Config.Labels \"$label\" }}" "$platform_ref")"
    [[ "$actual" == "$expected" ]] || {
      printf '%s label %s is %s, expected %s.\n' "$platform_ref" "$label" "$actual" "$expected" >&2
      exit 1
    }
  done <<EOF
org.opencontainers.image.version|$EXPECTED_VERSION
org.opencontainers.image.revision|$EXPECTED_COMMIT
io.one-node.upstream.version|$EXPECTED_UPSTREAM_VERSION
io.one-node.upstream.commit|$EXPECTED_UPSTREAM_COMMIT
EOF
  [[ "$(docker run --rm --platform "linux/$architecture" "$platform_ref" version --name)" == "$EXPECTED_UPSTREAM_VERSION" ]]
done
printf 'Validated linux/amd64 and linux/arm64 image %s\n' "$image_ref"
