#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$PROJECT_ROOT/.github/workflows/reusable-publish-egress.yml"
caller="$PROJECT_ROOT/.github/workflows/egress.yml"
publisher="$PROJECT_ROOT/scripts/release/publish-egress-release.sh"

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || {
    printf 'Missing Egress release contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

require_text "$caller" 'publish_supported: true'
require_text "$caller" 'uses: ./.github/workflows/reusable-publish-egress.yml'
require_text "$caller" 'source_sha: ${{ needs.prepare.outputs.primary_sha }}'
require_text "$caller" 'contents: write'
require_text "$caller" 'packages: write'
if grep -Fq 'secrets: inherit' "$caller"; then
  printf '%s\n' 'Egress workflow must not inherit caller secrets.' >&2
  exit 1
fi

require_text "$workflow" 'environment: public-release'
require_text "$workflow" 'name: Build credential-free release inputs'
require_text "$workflow" 'name: Publish Native and container release'
require_text "$workflow" 'permissions:'
require_text "$workflow" 'group: egress-release-${{ inputs.version }}'
require_text "$workflow" '[ "$ACTION_REPOSITORY" = voiceofhu/one-action ]'
require_text "$workflow" '[ "$SOURCE_REPOSITORY" = voiceofhu/one-browser-egress-next ]'
require_text "$workflow" 'platforms: amd64,arm64'
require_text "$workflow" '--platform linux/amd64'
require_text "$workflow" '--platform linux/arm64'
require_text "$workflow" '--target release'
require_text "$workflow" 'SOURCE_SHA: ${{ inputs.source_sha }}'
require_text "$workflow" 'action/browser/egress/install.sh'
require_text "$workflow" 'action/browser/egress/uninstall.sh'
require_text "$workflow" 'Requested version does not match one-browser-egress Cargo.toml.'
require_text "$workflow" 'linux/amd64 Native binary version does not match the release version.'
require_text "$workflow" 'linux/arm64 Native binary version does not match the release version.'
require_text "$workflow" 'actions/upload-artifact@v4'
require_text "$workflow" 'actions/download-artifact@v4'
require_text "$workflow" 'GITHUB_TOKEN: ${{ github.token }}'
require_text "$workflow" 'working-directory: workspace'
require_text "$workflow" 'run: bash action/scripts/release/publish-egress-release.sh'
[[ "$(grep -Fc 'GITHUB_TOKEN: ${{ github.token }}' "$workflow")" -eq 1 ]] || {
  printf '%s\n' 'Publication token must be exposed to exactly one final step.' >&2
  exit 1
}

require_text "$publisher" "readonly EXPECTED_ACTION_REPOSITORY='voiceofhu/one-action'"
require_text "$publisher" "readonly EXPECTED_SOURCE_REPOSITORY='voiceofhu/one-browser-egress-next'"
require_text "$publisher" "readonly IMAGE_REPOSITORY='ghcr.io/voiceofhu/one-browser-egress-next'"
require_text "$publisher" 'public Egress releases require environment=prod'
require_text "$publisher" 'release_tag="egress-v$VERSION"'
require_text "$publisher" 'could not prove GitHub Release and tag absence'
require_text "$publisher" 'unique Egress image tag already exists and will not be overwritten'
require_text "$publisher" 'could not prove the unique Egress image tag is absent'
require_text "$publisher" '--platform linux/amd64,linux/arm64'
require_text "$publisher" '--provenance=false'
require_text "$publisher" '--metadata-file "$metadata_file"'
require_text "$publisher" 'docker buildx imagetools inspect "$IMAGE_REPOSITORY@$index_digest" --raw'
require_text "$publisher" 'unique run tag does not resolve to the published index digest'
require_text "$publisher" 'imageIndex: $image_index'
require_text "$publisher" 'source-commit.txt'
require_text "$publisher" 'one-browser-egress-linux-amd64'
require_text "$publisher" 'one-browser-egress-linux-arm64'
require_text "$publisher" 'gh release create "$release_tag"'
require_text "$publisher" '--draft'
require_text "$publisher" '--latest=false'
require_text "$publisher" 'GitHub Release readback does not match the intended asset set'
require_text "$publisher" 'gh release download "$release_tag" --dir "$asset_readback_dir"'
require_text "$publisher" 'published Git tag does not point to the exact Action commit'

if grep -Eq '(:latest|:dev|:stage|:prod|docker tag .*VERSION|gh release upload)' "$publisher"; then
  printf '%s\n' 'Egress publisher contains a mutable alias or release overwrite path.' >&2
  exit 1
fi

printf '%s\n' 'Egress public release workflow contract tests passed.'
