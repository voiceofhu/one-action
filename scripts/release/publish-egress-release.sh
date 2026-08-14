#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly EXPECTED_ACTION_REPOSITORY='voiceofhu/one-action'
readonly EXPECTED_SOURCE_REPOSITORY='voiceofhu/one-browser-egress-next'
readonly IMAGE_REPOSITORY='ghcr.io/voiceofhu/one-browser-egress-next'
readonly RELEASE_BASE='https://github.com/voiceofhu/one-action/releases/download'

die() {
  printf 'Egress publication blocked: %s\n' "$1" >&2
  exit 1
}

require_value() {
  [[ -n "${!1:-}" ]] || die "$1 is required"
}

for name in \
  ACTION_REPOSITORY ACTION_SHA SOURCE_REPOSITORY SOURCE_SHA VERSION \
  DEPLOYMENT_ENVIRONMENT GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_ACTOR \
  GITHUB_TOKEN RUN_URL PUBLICATION_DIR GITHUB_OUTPUT GITHUB_STEP_SUMMARY; do
  require_value "$name"
done

[[ "$ACTION_REPOSITORY" == "$EXPECTED_ACTION_REPOSITORY" ]] ||
  die 'workflow repository is not the fixed Action repository'
[[ "$SOURCE_REPOSITORY" == "$EXPECTED_SOURCE_REPOSITORY" ]] ||
  die 'source repository is not the fixed Egress repository'
[[ "$ACTION_SHA" =~ ^[0-9a-f]{40}$ && "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  die 'Action and Egress revisions must be exact commit SHAs'
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'VERSION must be three numeric components without a v prefix'
[[ "$DEPLOYMENT_ENVIRONMENT" == prod ]] ||
  die 'public Egress releases require environment=prod'
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] ||
  die 'GitHub run identity is invalid'
[[ "$GITHUB_ACTOR" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] ||
  die 'GitHub actor is invalid'
[[ "$PUBLICATION_DIR" == publication/egress ]] ||
  die 'PUBLICATION_DIR is fixed'

release_tag="egress-v$VERSION"
publish_tag="run-a${ACTION_SHA:0:12}-s${SOURCE_SHA:0:12}-r${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}"
remote_ref="$IMAGE_REPOSITORY:$publish_tag"
release_url="$RELEASE_BASE/$release_tag"
amd64_name=one-browser-egress-linux-amd64
arm64_name=one-browser-egress-linux-arm64

for path in \
  "$PUBLICATION_DIR/$amd64_name" \
  "$PUBLICATION_DIR/$arm64_name" \
  "$PUBLICATION_DIR/install.sh" \
  "$PUBLICATION_DIR/uninstall.sh"; do
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] ||
    die "required release file is missing or unsafe: $path"
done

docker_config="$(mktemp -d)"
metadata_file="$(mktemp)"
index_file="$(mktemp)"
tag_index_file="$(mktemp)"
release_readback="$(mktemp)"
release_preflight="$(mktemp)"
run_tag_inspect_error="$(mktemp)"
asset_readback_dir="$(mktemp -d)"
logged_in=false
cleanup() {
  if [[ "$logged_in" == true ]]; then
    DOCKER_CONFIG="$docker_config" docker logout ghcr.io >/dev/null 2>&1 || true
  fi
  rm -rf -- "$docker_config" "$asset_readback_dir"
  rm -f -- \
    "$metadata_file" "$index_file" "$tag_index_file" "$release_readback" \
    "$release_preflight" "$run_tag_inspect_error"
}
trap cleanup EXIT

export GH_REPO="$ACTION_REPOSITORY"
export GH_TOKEN="$GITHUB_TOKEN"
unset GITHUB_TOKEN

if gh release view "$release_tag" >/dev/null 2>&1; then
  die 'release tag already has a GitHub Release and will not be overwritten'
fi
gh api graphql \
  -f query='query($owner:String!, $name:String!, $tag:String!, $ref:String!) {
    repository(owner: $owner, name: $name) {
      release(tagName: $tag) { id }
      ref(qualifiedName: $ref) { id }
    }
  }' \
  -F owner=voiceofhu \
  -F name=one-action \
  -F tag="$release_tag" \
  -F ref="refs/tags/$release_tag" \
  >"$release_preflight"
jq -e '
  ((.errors? // []) | length) == 0 and
  .data.repository != null
' "$release_preflight" >/dev/null ||
  die 'could not prove GitHub Release and tag absence'
jq -e '.data.repository.release == null' "$release_preflight" >/dev/null ||
  die 'release tag already has a GitHub Release and will not be overwritten'
jq -e '.data.repository.ref == null' "$release_preflight" >/dev/null ||
  die 'release Git ref already exists and will not be moved'

export DOCKER_CONFIG="$docker_config"
printf '%s' "$GH_TOKEN" |
  docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin >/dev/null
logged_in=true

if docker buildx imagetools inspect "$remote_ref" --raw \
  >/dev/null 2>"$run_tag_inspect_error"; then
  die 'unique Egress image tag already exists and will not be overwritten'
fi
grep -Eiq '(manifest unknown|no such manifest|404[[:space:]]+not found)' "$run_tag_inspect_error" ||
  die 'could not prove the unique Egress image tag is absent'

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file source/Dockerfile \
  --provenance=false \
  --label "org.opencontainers.image.created=$created_at" \
  --label "org.opencontainers.image.source=https://github.com/$SOURCE_REPOSITORY" \
  --label "org.opencontainers.image.revision=$SOURCE_SHA" \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "one.action.revision=$ACTION_SHA" \
  --metadata-file "$metadata_file" \
  --tag "$remote_ref" \
  --push \
  source

index_digest="$(jq -er '."containerimage.digest" | select(test("^sha256:[0-9a-f]{64}$"))' "$metadata_file")" ||
  die 'multi-platform build did not return a canonical registry digest'
docker buildx imagetools inspect "$IMAGE_REPOSITORY@$index_digest" --raw >"$index_file"
[[ "$(wc -c <"$index_file")" -le 8388608 ]] || die 'registry index exceeds 8 MiB'
docker buildx imagetools inspect "$remote_ref" --raw >"$tag_index_file"
[[ "$(wc -c <"$tag_index_file")" -le 8388608 ]] || die 'run-tag registry index exceeds 8 MiB'
cmp -s "$index_file" "$tag_index_file" ||
  die 'unique run tag does not resolve to the published index digest'
jq -e '
  .schemaVersion == 2 and
  (.mediaType == "application/vnd.oci.image.index.v1+json" or
   .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json") and
  (.manifests | type == "array" and length == 2)
' "$index_file" >/dev/null ||
  die 'registry response is not the exact two-platform image index'

platform_digest() {
  local architecture=$1 count
  count="$(jq -er --arg arch "$architecture" \
    '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | length' \
    "$index_file")"
  [[ "$count" == 1 ]] || die "registry index must contain exactly one linux/$architecture image"
  jq -er --arg arch "$architecture" \
    '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) |
     .digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "$index_file"
}

amd64_image_digest="$(platform_digest amd64)"
arm64_image_digest="$(platform_digest arm64)"
[[ "$amd64_image_digest" != "$arm64_image_digest" ]] ||
  die 'architecture-specific image digests must be distinct'
[[ "$index_digest" != "$amd64_image_digest" && "$index_digest" != "$arm64_image_digest" ]] ||
  die 'multi-platform index digest must differ from child image digests'
amd64_sha="$(sha256sum "$PUBLICATION_DIR/$amd64_name" | awk '{print $1}')"
arm64_sha="$(sha256sum "$PUBLICATION_DIR/$arm64_name" | awk '{print $1}')"
amd64_size="$(stat -c '%s' "$PUBLICATION_DIR/$amd64_name")"
arm64_size="$(stat -c '%s' "$PUBLICATION_DIR/$arm64_name")"
[[ "$amd64_size" =~ ^[1-9][0-9]*$ && "$arm64_size" =~ ^[1-9][0-9]*$ ]] ||
  die 'Native asset sizes are invalid'
((amd64_size <= 268435456 && arm64_size <= 268435456)) ||
  die 'Native asset exceeds the 256 MiB installer limit'

jq -n \
  --arg action_repository "$ACTION_REPOSITORY" \
  --arg action_commit "$ACTION_SHA" \
  --arg version "$VERSION" \
  --arg release_tag "$release_tag" \
  --arg source_commit "$SOURCE_SHA" \
  --arg amd64_name "$amd64_name" \
  --arg amd64_sha "$amd64_sha" \
  --argjson amd64_size "$amd64_size" \
  --arg amd64_url "$release_url/$amd64_name" \
  --arg arm64_name "$arm64_name" \
  --arg arm64_sha "$arm64_sha" \
  --argjson arm64_size "$arm64_size" \
  --arg arm64_url "$release_url/$arm64_name" \
  --arg image_index "$IMAGE_REPOSITORY@$index_digest" \
  --arg amd64_image "$IMAGE_REPOSITORY@$amd64_image_digest" \
  --arg arm64_image "$IMAGE_REPOSITORY@$arm64_image_digest" \
  '{
    schemaVersion: 1,
    actionRepository: $action_repository,
    actionCommit: $action_commit,
    version: $version,
    releaseTag: $release_tag,
    sourceCommit: $source_commit,
    artifacts: [
      {name: $amd64_name, platform: "linux", arch: "amd64", size: $amd64_size, sha256: $amd64_sha, url: $amd64_url},
      {name: $arm64_name, platform: "linux", arch: "arm64", size: $arm64_size, sha256: $arm64_sha, url: $arm64_url}
    ],
    imageIndex: $image_index,
    images: [
      {platform: "linux", arch: "amd64", reference: $amd64_image},
      {platform: "linux", arch: "arm64", reference: $arm64_image}
    ]
  }' >"$PUBLICATION_DIR/manifest.json"

printf '%s\n' "$SOURCE_SHA" >"$PUBLICATION_DIR/source-commit.txt"

(
  cd "$PUBLICATION_DIR"
  LC_ALL=C sha256sum \
    "$amd64_name" "$arm64_name" install.sh uninstall.sh manifest.json source-commit.txt \
    >SHA256SUMS
)

cat >"$PUBLICATION_DIR/release-notes.md" <<EOF
One Browser Egress $VERSION

- Action revision: $ACTION_SHA
- Egress source: $SOURCE_REPOSITORY@$SOURCE_SHA
- Multi-platform image index: $IMAGE_REPOSITORY@$index_digest
- Workflow run: $RUN_URL
- Linux Native and container architectures: amd64, arm64
- Deployment performed: false

Installers require an explicit version and verify the exact Action Release,
native SHA-256, or architecture-specific GHCR digest. No latest alias is used.
EOF

gh release create "$release_tag" \
  --target "$ACTION_SHA" \
  --title "One Browser Egress $VERSION" \
  --notes-file "$PUBLICATION_DIR/release-notes.md" \
  --draft \
  --latest=false \
  "$PUBLICATION_DIR/$amd64_name" \
  "$PUBLICATION_DIR/$arm64_name" \
  "$PUBLICATION_DIR/install.sh" \
  "$PUBLICATION_DIR/uninstall.sh" \
  "$PUBLICATION_DIR/manifest.json" \
  "$PUBLICATION_DIR/source-commit.txt" \
  "$PUBLICATION_DIR/SHA256SUMS"

gh release view "$release_tag" \
  --json tagName,isDraft,isPrerelease,assets \
  >"$release_readback"
jq -e \
  --arg tag "$release_tag" \
  --arg amd64 "$amd64_name" \
  --arg arm64 "$arm64_name" '
    .tagName == $tag and .isDraft == true and .isPrerelease == false and
    ([.assets[].name] | sort) ==
      ([$amd64, $arm64, "SHA256SUMS", "install.sh", "manifest.json",
        "source-commit.txt", "uninstall.sh"] | sort)
  ' "$release_readback" >/dev/null || die 'GitHub Release readback does not match the intended asset set'

gh release download "$release_tag" --dir "$asset_readback_dir"
for name in \
  "$amd64_name" "$arm64_name" SHA256SUMS install.sh manifest.json source-commit.txt uninstall.sh; do
  [[ -f "$asset_readback_dir/$name" && ! -L "$asset_readback_dir/$name" ]] ||
    die "GitHub Release readback asset is missing or unsafe: $name"
  cmp -s "$PUBLICATION_DIR/$name" "$asset_readback_dir/$name" ||
    die "GitHub Release readback asset differs from the publication input: $name"
done

gh release edit "$release_tag" --draft=false --latest=false
gh release view "$release_tag" \
  --json tagName,isDraft,isPrerelease,assets \
  >"$release_readback"
jq -e \
  --arg tag "$release_tag" \
  --arg amd64 "$amd64_name" \
  --arg arm64 "$arm64_name" '
    .tagName == $tag and .isDraft == false and .isPrerelease == false and
    ([.assets[].name] | sort) ==
      ([$amd64, $arm64, "SHA256SUMS", "install.sh", "manifest.json",
        "source-commit.txt", "uninstall.sh"] | sort)
  ' "$release_readback" >/dev/null || die 'published GitHub Release failed final readback'

published_target="$(gh api "repos/$ACTION_REPOSITORY/git/ref/tags/$release_tag" --jq '.object.sha')"
[[ "$published_target" == "$ACTION_SHA" ]] ||
  die 'published Git tag does not point to the exact Action commit'

{
  echo '## One Browser Egress public release published'
  echo
  echo "- Release: \`$release_tag\`"
  echo "- Action SHA: \`$ACTION_SHA\`"
  echo "- Egress SHA: \`$SOURCE_SHA\`"
  echo "- GHCR index: \`$IMAGE_REPOSITORY@$index_digest\`"
  echo "- Native assets: \`$amd64_name\`, \`$arm64_name\`"
  echo '- Mutable image aliases: none'
  echo '- Deployment: not run'
} >>"$GITHUB_STEP_SUMMARY"

{
  echo "release_tag=$release_tag"
  echo "image_index_digest=$index_digest"
  echo "image_index_ref=$IMAGE_REPOSITORY@$index_digest"
} >>"$GITHUB_OUTPUT"
