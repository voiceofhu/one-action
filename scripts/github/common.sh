#!/usr/bin/env bash

# Used by scripts that source this shared transport library.
# shellcheck disable=SC2034
readonly FIXED_ACTION_REPOSITORY=voiceofhu/one-action
readonly FIXED_GITHUB_API_URL=https://api.github.com
readonly MAX_GITHUB_BODY_BYTES=1048576
readonly MAX_DISPATCH_BODY_BYTES=32768

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

normalize_github_token() {
  local token="${GH_TOKEN:-}"
  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null || true)"
  fi
  if [[ -z "$token" ]] && command -v git >/dev/null 2>&1; then
    token="$(
      printf 'protocol=https\nhost=github.com\n\n' |
        GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null |
        sed -n 's/^password=//p'
    )" || true
  fi
  [[ "$token" =~ ^[A-Za-z0-9_]{20,255}$ ]] ||
    die 'GitHub dispatch credential is unavailable; authenticate gh or the Git HTTPS credential helper'
  GH_TOKEN="$token"
  export -n GH_TOKEN
}

validate_api_url() {
  [[ "${GITHUB_API_URL:-$FIXED_GITHUB_API_URL}" == "$FIXED_GITHUB_API_URL" ]] ||
    die 'GITHUB_API_URL must be the fixed https://api.github.com trust root'
}

validate_repository() {
  local repository="$1"
  ((${#repository} <= 140)) \
    && [[ "$repository" =~ ^[a-z0-9][a-z0-9-]{0,38}/[a-z0-9][a-z0-9._-]{0,99}$ ]] \
    && [[ "$repository" != *..* ]] \
    && [[ "$repository" != */.* ]] \
    && [[ "$repository" != *./ ]] ||
    die 'GitHub repository is not canonical lowercase owner/name'
}

validate_ref() {
  local source_ref="$1"
  ((${#source_ref} > 0 && ${#source_ref} <= 256)) \
    && [[ "$source_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$ ]] \
    && [[ "$source_ref" != *..* ]] \
    && [[ "$source_ref" != *//* ]] \
    && [[ "$source_ref" != */ ]] \
    && [[ "$source_ref" != *.lock ]] ||
    die 'GitHub ref is empty, unsafe, or outside the bounded ref grammar'
}

validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die 'GitHub returned a non-commit SHA'
}

validate_api_path() {
  local path="$1"
  ((${#path} > 0 && ${#path} <= 768)) \
    && [[ "$path" =~ ^[A-Za-z0-9._~/%-]+$ ]] \
    && [[ "$path" != /* ]] \
    && [[ "$path" != *..* ]] \
    && [[ "$path" != *//* ]] ||
    die 'GitHub API path is outside the fixed relative-path grammar'
}

github_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local data_file="${4:-}"
  local status
  local size
  local -a arguments

  [[ "$method" == GET || "$method" == POST ]] || die 'unsupported GitHub API method'
  validate_api_url
  validate_api_path "$path"
  [[ -f "$output_file" && ! -L "$output_file" ]] ||
    die 'GitHub response target must be a pre-created regular file'

  arguments=(
    --disable
    --config -
    --silent
    --show-error
    --output "$output_file"
    --write-out '%{http_code}'
    --request "$method"
    --url "$FIXED_GITHUB_API_URL/$path"
    --proto '=https'
    --proto-redir '=https'
    --max-redirs 0
    --noproxy '*'
    --connect-timeout 10
    --max-time 30
    --max-filesize "$MAX_GITHUB_BODY_BYTES"
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
  )
  if [[ "$method" == POST ]]; then
    [[ -f "$data_file" && ! -L "$data_file" ]] ||
      die 'GitHub POST body must be a pre-created regular file'
    size="$(wc -c < "$data_file" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ ]] && ((size > 0 && size <= MAX_DISPATCH_BODY_BYTES)) ||
      die 'GitHub POST body is empty or exceeds the fixed limit'
    arguments+=(
      --header 'Content-Type: application/json'
      --data-binary "@$data_file"
    )
  fi

  status="$(
    printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
      env -u GH_TOKEN -u GITHUB_TOKEN \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        curl "${arguments[@]}"
  )" || die 'GitHub API transport failed'
  [[ "$status" =~ ^[0-9]{3}$ ]] || die 'GitHub API returned an invalid status shape'
  size="$(wc -c < "$output_file" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] && ((size <= MAX_GITHUB_BODY_BYTES)) ||
    die 'GitHub API response exceeded the fixed body limit'
  printf '%s\n' "$status"
}

github_get() {
  local path="$1"
  local output_file="$2"
  local status
  status="$(github_request GET "$path" "$output_file")"
  [[ "$status" == 200 ]] || die "GitHub API GET failed with HTTP $status"
}

github_post() {
  local path="$1"
  local data_file="$2"
  local output_file="$3"
  local status
  status="$(github_request POST "$path" "$output_file" "$data_file")"
  [[ "$status" == 204 ]] || die "GitHub API POST failed with HTTP $status"
}
