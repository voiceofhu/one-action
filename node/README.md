# One Node lifecycle

This namespace owns the One Node installer lifecycle inside the central
`voiceofhu/one-action` repository. Its stable public entrypoints are:

- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/upgrade.sh`
- `https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/uninstall.sh`

The entrypoints load the product-specific modules under `scripts` from the
commit of the selected `one-node-v<version>` release tag. They resolve that
commit through the fixed GitHub API and verify each module against the signed
release manifest. An inherited `ONE_ACTION_COMMIT` from an older manager is
replaced if it differs from the selected release's commit. Resolution or
validation failure stops before module loading.
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

Native and Docker installation requires systemd and nftables. It owns
`one-node-firewall.path` and `one-node-firewall.service`; the Node writes only
validated inbound TCP/UDP ports under its state directory, while the host
service atomically replaces the dedicated nftables sets. Unused ports in the
managed `20000-60000` allocation range are dropped. Existing host firewall and
cloud security-group policy remain separate.

The installation also owns
`one-node-updater.path` and `one-node-updater.service`. The Node process can
only queue an exact three-component numeric version in its state directory;
the host service then invokes `/opt/one-node/install.sh --upgrade VERSION` and
persists pending, running, succeeded, or failed status for the restarted Node
to report. A manual upgrade from an older installation migrates the existing
environment without replacing credentials and installs this host boundary.

The native runtime runs as the dedicated `one-node` user. SSH with a normal
administrator account and use `sudo` for the one-time installation or migration;
the root-owned updater and firewall services handle later panel requests.
Keep `/opt/one-node` and its scripts root-owned. Runtime state under
`/var/lib/one-node` belongs to `one-node`, with directories `0700` and status
files `0600`.

Release verification uses OpenSSL 3 or, on older distributions, system Python 3
with `python3-cryptography`. Ubuntu 20.04 can install the latter without replacing
its system OpenSSL:

```sh
sudo apt-get update
sudo apt-get install -y python3 python3-cryptography
```

An old retained installer still requires OpenSSL 3. For the first migration,
download `node/install.sh` from the published `one-node-v<version>` tag that
contains the compatibility fix, then run the downloaded script with
`sudo /bin/sh ./install.sh --upgrade <version>`. A successful upgrade atomically
refreshes `/opt/one-node/install.sh`, so later panel upgrades use the new verifier.

Native mode supports Linux amd64/arm64 hosts using systemd, including the major
Debian/Ubuntu, RHEL-compatible, Fedora, Amazon Linux, SUSE, and Arch families.
Docker mode works on supported systemd Linux hosts with nftables, Docker Engine, and Compose v2;
Debian/Ubuntu may install those packages automatically, while other families
must provide Docker first. Docker and Native installations use the same menu.

## Host network tuning

Install, reconfiguration, and upgrade check the effective host network settings
before the runtime starts. The lifecycle persists `fq`, BBR when the kernel
provides it, and dynamic socket-buffer limits in
`/etc/sysctl.d/99-zz-one-node.conf`. TCP maxima scale at 64 MiB per rounded GiB of
RAM, with a 32 MiB floor for hosts below roughly 768 MiB and a 512 MiB ceiling.
Initial receive/send buffers scale more conservatively and stop at 16 MiB.
Matching settings are left untouched, while changed settings are applied
immediately and reported in the installation output. Host tuning files are
preserved on uninstall because they may benefit other host services.

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
sh tests/updater_test.sh
```

A commit-pinned remote invocation has this form:

```sh
curl -fsSL "https://raw.githubusercontent.com/voiceofhu/one-action/<action-commit>/node/install.sh" |
  ONE_ACTION_COMMIT="<action-commit>" sh -s -- --mode native
```

## Firewall ports

One Node dynamically publishes only the inbound TCP/UDP ports in the active
runtime configuration. The host service accepts those ports and drops unused
ports in the managed `20000-60000` allocation range. A configuration switch
updates the nftables sets before listeners are exposed and restores the prior
set if the runtime transaction fails. Cloud security groups, provider
firewalls, and router ACLs cannot be changed by the host and must still permit
the allocation range.
