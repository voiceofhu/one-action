#!/usr/bin/env bash
set -Eeuo pipefail

for name in IMAGE IMAGE_REVISION_TAG IMAGE_VERSION IMAGE_BUILD_TAG IMAGE_SOURCE \
  IMAGE_DESCRIPTION IMAGE_REVISION EXPECTED_VERSION EXPECTED_COMMIT \
  EXPECTED_UPSTREAM_VERSION EXPECTED_UPSTREAM_COMMIT; do
  [[ -n "${!name:-}" ]] || {
    printf '%s is required\n' "$name" >&2
    exit 1
  }
done

revision_ref="$IMAGE:$IMAGE_REVISION_TAG"
version_ref="$IMAGE:$IMAGE_VERSION"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
inspect_script="$script_dir/inspect-node-image.sh"

inspect_image() {
  bash "$inspect_script" "$1"
}

platform_fingerprint() {
  docker buildx imagetools inspect --raw "$1" |
    jq -er '[.manifests[] | select(.platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64")) | "\(.platform.architecture)=\(.digest)"] | sort | join(",")'
}

if [[ "${SHOULD_BUILD:-false}" == true ]]; then
  if inspect_image "$revision_ref"; then
    printf '%s was published by an earlier queued run; keeping it unchanged.\n' "$revision_ref"
  else
    status=$?
    [[ "$status" == 2 ]] || exit "$status"
    docker buildx imagetools create \
      --annotation "index:org.opencontainers.image.description=$IMAGE_DESCRIPTION" \
      --annotation "index:org.opencontainers.image.revision=$IMAGE_REVISION" \
      --annotation "index:org.opencontainers.image.source=$IMAGE_SOURCE" \
      --annotation "index:org.opencontainers.image.version=$EXPECTED_VERSION" \
      --tag "$revision_ref" "$IMAGE:$IMAGE_BUILD_TAG"
    inspect_image "$revision_ref"
  fi
else
  inspect_image "$revision_ref"
fi

revision_fingerprint="$(platform_fingerprint "$revision_ref")"
if inspect_image "$version_ref"; then
  [[ "$(platform_fingerprint "$version_ref")" == "$revision_fingerprint" ]] || {
    printf '%s already points to a different multi-architecture image.\n' "$version_ref" >&2
    exit 1
  }
  printf '%s already points to the requested image; keeping it unchanged.\n' "$version_ref"
else
  status=$?
  [[ "$status" == 2 ]] || exit "$status"
  docker buildx imagetools create \
    --annotation "index:org.opencontainers.image.description=$IMAGE_DESCRIPTION" \
    --annotation "index:org.opencontainers.image.revision=$IMAGE_REVISION" \
    --annotation "index:org.opencontainers.image.source=$IMAGE_SOURCE" \
    --annotation "index:org.opencontainers.image.version=$EXPECTED_VERSION" \
    --tag "$version_ref" "$revision_ref"
  inspect_image "$version_ref"
fi

printf 'Published immutable image %s\nPublished version image %s\n' "$revision_ref" "$version_ref"
