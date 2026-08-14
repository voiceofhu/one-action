# One Node lifecycle

This namespace owns the One Node installer lifecycle inside the central
`voiceofhu/one-action` repository. Its stable public entrypoints are:

- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/upgrade.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/uninstall.sh`

The entrypoints load the product-specific modules under `scripts`. A
remote invocation may set `ONE_ACTION_COMMIT` to the exact 40-character
lowercase commit containing the entrypoint and modules. If omitted, the
entrypoint resolves central `main` once through the fixed GitHub API, requires
exactly one 40-character commit, and loads every module from that immutable
commit. Resolution or validation failure stops before module loading.
`ONE_NODE_SCRIPT_BASE_URL` is restricted to explicitly enabled local HTTP
development fixtures and cannot redirect production loading to another HTTPS
repository. Native
and Docker installation, registration reconfiguration, manifest-owned cleanup,
readiness checks, immutable-version upgrade, automatic failed-upgrade recovery,
explicit rollback, and uninstall remain separate from Browser Egress lifecycle
code. Public downloads require the exact central `one-node-v<version>` Release;
the runtime image must be
`ghcr.io/voiceofhu/one-node@sha256:<digest>`. Neither defaults to `latest`.

## Migration record

- Read-only source: `/Volumes/sn@root/Documents/workspaces/voh/one-node/one-node-action`
- Source remote: `https://github.com/voiceofhu/one-node-action.git`
- Exact source commit: `256a6cb3453588df4dbfc3ccfb034f7a1daeeaa5`
- Source worktree at migration: clean

Migrated: the three lifecycle entrypoints, `scripts/**`, the local
installer bundler, and the four self-contained shell lifecycle tests.

Deliberately excluded: source Git metadata, `.env`, GitHub workflows, Make
deployment/release orchestration, `dist` snapshots and binaries, Server deploy
code, and the cross-repository proto contract test. Those files either contain
local state/build output, belong to central workflow integration, or validate a
Server/Node source contract rather than the installer lifecycle.

This is source and local-shell evidence only. It does not prove a published
One Action release, GHCR image, Debian/systemd installation, Docker lifecycle,
real control-plane enrollment, multi-architecture behavior, or production
cutover.

## Local verification

From this directory:

```sh
sh tests/scripts_test.sh
sh tests/reconfigure_test.sh
sh tests/reset_test.sh
sh tests/native_recovery_test.sh
```

A commit-pinned remote invocation has this form:

```sh
curl -fsSL "https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh" |
  ONE_ACTION_COMMIT="<action-commit>" sh -s -- --mode native
```
