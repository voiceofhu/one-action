# One Node lifecycle

This namespace owns the One Node installer lifecycle inside the central
`voiceofhu/one-action` repository. Its stable public entrypoints are:

- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/upgrade.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/uninstall.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/open-ports.sh`

The entrypoints load the product-specific modules under `scripts`. A
remote invocation may set `ONE_ACTION_COMMIT` to the exact 40-character
lowercase commit containing the entrypoint and modules. If omitted, the
entrypoint resolves central `main` once through the fixed GitHub API, requires
exactly one 40-character commit, and loads every module from that immutable
commit. Resolution or validation failure stops before module loading.
`ONE_NODE_SCRIPT_BASE_URL` is restricted to explicitly enabled local HTTP
development fixtures and cannot redirect production loading to another HTTPS
repository. Native
and Docker installation, install-command replacement with manifest-owned cleanup,
readiness checks, immutable-version upgrade, automatic failed-upgrade recovery,
explicit rollback, and uninstall remain separate from Browser Egress lifecycle
code. When `ONE_NODE_VERSION` is omitted, installation resolves the newest
published `voiceofhu/one-action@one-node-v<version>` Release. Native then downloads that
exact Release, while Docker pulls its matching version tag and records the
resolved immutable digest. Explicit version and digest inputs remain available
for rollback or fixed-version installation.

`install.sh` treats the new installation command as authoritative. After the
new artifact is downloaded and verified, any existing manifest-managed One Node
installation and its complete runtime state are removed before a fresh install.
Use `upgrade.sh` when the existing node identity and runtime state must be kept.

Every successful Native or Docker installation retains the exact installer at
`/opt/one-node/install.sh`. Running it without arguments in a terminal opens the
interactive lifecycle menu. The same file also supports non-interactive status,
diagnostics, upgrade, rollback, restart, logs, and uninstall operations:

```sh
cd /opt/one-node
sudo ./install.sh
sudo ./install.sh --status
sudo ./install.sh --doctor
sudo ./install.sh --upgrade latest
sudo ./install.sh --upgrade 26.824.1520
sudo ./install.sh --rollback
sudo ./install.sh --restart
sudo ./install.sh --logs --follow
sudo ./install.sh --uninstall --yes
```

Status reports the installation mode, current and previous product versions,
Node ID, runtime state, host PID, memory use, and process uptime. Native status
reads systemd and `/proc`; Docker status reads the container state, PID, and
`docker stats`. The retained script never contains the enrollment bootstrap
token. Non-TTY execution without an explicit option prints help instead of
waiting for input.

Native mode supports Linux amd64/arm64 hosts using systemd, including the major
Debian/Ubuntu, RHEL-compatible, Fedora, Amazon Linux, SUSE, and Arch families.
Docker mode works on any supported Linux host with Docker Engine and Compose v2;
Debian/Ubuntu may install those packages automatically, while other families
must provide Docker first. Docker and Native installations use the same menu.

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
One Action release, GHCR image, Linux/systemd installation, Docker lifecycle,
real control-plane enrollment, multi-architecture behavior, or production
cutover.

## Local verification

From this directory:

```sh
sh tests/scripts_test.sh
sh tests/latest_release_test.sh
sh tests/readiness_test.sh
sh tests/reconfigure_test.sh
sh tests/reset_test.sh
sh tests/native_recovery_test.sh
```

A commit-pinned remote invocation has this form:

```sh
curl -fsSL "https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh" |
  ONE_ACTION_COMMIT="<action-commit>" sh -s -- --mode native
```

## Firewall ports

Managed One Node protocol inbounds use the public IPv4 TCP/UDP range
`20000-60000`. On a new server, run the commit-pinned firewall helper as root:

```sh
curl -fsSL "https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/open-ports.sh" |
  sudo sh
```

The helper detects active UFW, firewalld, nftables, or iptables rules, adds the
range idempotently, and uses an existing host persistence mechanism when one is
available. Cloud security groups, provider firewalls, and router ACLs remain
separate and must allow the same range.
