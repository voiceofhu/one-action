#!/usr/bin/env bash
# Writes a release's version into the App's own repository, for Apps whose
# apps.json entry sets `stamp_source`.
#
# CI stamps the version into the build either way (reusable-publish-tauri-app
# runs the App's scripts/update-version.mjs); without this the repository keeps
# whatever version it was created with, so a local build, `git log` and the
# About page of a dev run never say which release the source is.

# stamp_source_version DIR BRANCH VERSION
#
# DIR must be the clean, pushed checkout of BRANCH that was just validated.
# Runs DIR/scripts/update-version.mjs, commits what it changed as
# "chore(release): v<VERSION>" and pushes it to origin/BRANCH. Sets
# stamped_sha to the commit to release: the new one, or HEAD when the files
# already carried VERSION. When the push is refused the commit is taken back,
# so the checkout is as it was, and the function fails.
stamp_source_version() {
  local dir=$1 branch=$2 version=$3 before
  before="$(git -C "$dir" rev-parse --verify HEAD)"
  (cd -- "$dir" && node scripts/update-version.mjs "$version" >/dev/null)
  if [[ -z "$(git -C "$dir" status --porcelain --untracked-files=all)" ]]; then
    stamped_sha=$before
    return 0
  fi
  # Tracked files only: the script rewrites existing manifests, it creates none.
  if [[ -n "$(git -C "$dir" status --porcelain --untracked-files=all | grep -v '^ M ' || true)" ]]; then
    git -C "$dir" checkout --quiet -- .
    printf 'ERROR: update-version.mjs did more than modify tracked files in %s\n' "$dir" >&2
    return 1
  fi
  git -C "$dir" commit --quiet --all -m "chore(release): v$version"
  if ! git -C "$dir" push --quiet origin "HEAD:refs/heads/$branch"; then
    git -C "$dir" reset --quiet --hard "$before"
    printf 'ERROR: could not push the version commit to origin/%s; nothing was released\n' "$branch" >&2
    return 1
  fi
  stamped_sha="$(git -C "$dir" rev-parse --verify HEAD)"
  printf 'Version %s committed to %s as %s\n' "$version" "$branch" "$stamped_sha" >&2
}
