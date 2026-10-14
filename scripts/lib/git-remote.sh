# shellcheck shell=bash

# Prints a checkout's origin URL, rewriting an SSH host alias
# (git@alias:owner/repo) to git@github.com: only when `ssh -G` resolves the
# alias to github.com, so fixed-repository checks accept per-account aliases.
origin_remote_url() {
  local remote host
  remote="$(git -C "$1" config --get remote.origin.url)" || return
  if [[ "$remote" =~ ^git@([^:/]+):(.+)$ ]]; then
    host=${BASH_REMATCH[1]}
    if [[ "$host" != github.com ]] &&
      [[ "$(ssh -G "$host" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')" == github.com ]]; then
      remote="git@github.com:${BASH_REMATCH[2]}"
    fi
  fi
  printf '%s\n' "$remote"
}
