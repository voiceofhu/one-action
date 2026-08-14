# One Action

`one-action` is the central build, release, and public-download owner for the
One products. Product lifecycle entrypoints are namespaced so Browser Egress
and One Node cannot be mistaken for each other:

- `browser/egress/install.sh` and `browser/egress/uninstall.sh`;
- `node/install.sh`, `node/upgrade.sh`, and
  `node/uninstall.sh`.

There is deliberately no root `install.sh`, `upgrade.sh`, or `uninstall.sh`.
The historical `one-browser-action` and `one-node-action` repositories are
read-only migration sources, not runtime dependencies or current trust roots.

## Repository layout

The repository is split by ownership rather than by file type:

```text
browser/egress/          Browser Egress lifecycle entrypoints and local tests
node/                    One Node lifecycle entrypoints, modules, and local tests
.github/workflows/*.yml  Product workflow entrypoints
.github/workflows/reusable-*.yml
                         Internal reusable workflows
scripts/github/          Shared dispatch and exact-ref resolution
scripts/release/         Shared publication and checksum primitives
tests/                   Cross-product workflow and release contract tests
make/                    Local command delegation
```

GitHub does not support subdirectories under `.github/workflows`, so that
directory stays flat. Product entrypoints use their product names; internal
workflow implementations use the `reusable-` prefix. Product-owned installers
and fixtures remain inside their product namespace, while shared transport and
publication code stays in `scripts`.

## Current milestone

This milestone implements safe preparation, non-publishing build validation,
mutation-gated GHCR publication code for One User, One AMZ, and Browser
Backend, plus one coherent Egress Native/container public Release:

- read-only GitHub token and workflow visibility checks;
- bounded repository-ref resolution through the fixed GitHub API trust root;
- checkout of every source repository by an exact 40-character commit SHA;
- reusable Web + Rust backend verification for One User and One AMZ;
- reusable locked Rust + production Docker verification for Browser Backend and
  Egress;
- exact-SHA macOS/Windows Tauri and Windows debug build verification for App;
- frozen pnpm Web builds copied into `backend/web-dist`;
- strict locked Rust fmt/check/clippy/test and release-binary builds;
- local production Dockerfile builds with mandatory non-root `Config.User`;
- separate exact-SHA publisher workflows that rebuild without registry-token
  environment variables, then expose `github.token` only to the final
  login/push/readback step;
- fixed package trust anchors for User, One AMZ, and Browser Backend, with a
  unique run tag and digest-qualified output instead of mutable aliases;
- fixed Egress Action/source/GHCR trust anchors, Linux amd64/arm64 Native
  assets, architecture-specific image digests, and one `egress-vX.Y.Z` Release;
- runner-local provenance with Action/backend/Web SHAs, build metadata, file
  lists, SHA-256 checksums, and the local container image ID/user;
- dry-run-first workflow dispatch with fixed workflow/source allowlists and
  Action-SHA-bound dispatch and mutation mistake guards;
- deterministic `SHA256SUMS` generation for future public artifacts;
- dry-run-first Egress Native/Docker installer and conservative uninstaller
  contracts backed by immutable Action Release metadata;
- exact-SHA One Node source preparation, Go module/test/race/E2E gates,
  namespaced lifecycle tests, Linux amd64/arm64 builds, and locally read-back
  checksums/provenance with no upload, GHCR, Release, or deployment;
- eight declared workflow entrypoints: seven dry-run-first dispatchable
  validation contracts and Browser Runtime blocked on its source trust root.

`one-user.yml` and `one-amz.yml` continue after immutable source preparation and
run a central combined build validation. `one-browser-backend.yml` and
`egress.yml` continue through strict Rust and local production Docker builds.
When `publish=true` passes the dispatcher mutation gate, User, One AMZ, and
Browser Backend run a separate exact-source rebuild and publish only to their
compiled-in GHCR package. Egress publication additionally requires
`environment=prod`, rebuilds Linux amd64/arm64 Native and container outputs,
and creates one exact Action Release containing the installers and checksums.
`app.yml` validates macOS DMG and Windows NSIS builds, while `app-debug.yml`
requires a Windows debug binary, NSIS installer, and PDB. All generated bundles,
and non-publishing provenance stay inside their runner and are not uploaded,
except for Egress's one-day runner artifact used only to cross the protected
publication-job boundary.
Browser Runtime is rejected before ref resolution because its source repository
trust root is not approved. One Node uses the known migration-period
`voiceofhu/one-node-node` source trust root and is dispatchable only for
non-publishing exact-source validation. `publish=true` and `deploy=true` fail
before API access; central Node Release/GHCR publication is not yet enabled.
Generic workflow artifact upload,
App signing, App/Runtime release, and deployment are not implemented. App and
Runtime explicitly set `publish_supported=false`; App cannot publish unsigned
packages and the Runtime source contract is not final.

The publication code has not been run. No remote Package, Release, tag, asset,
or digest is claimed by this repository state. Package/Release immutability
settings, the `ghcr-publish` and `public-release` protected environments,
repository permissions, and first real readbacks remain external milestones.
Official Marketplace actions are still major-tag referenced; full reviewed
commit pinning is also required before the first privileged publication run.
Source-owned Dockerfiles still use base-image tags, so reviewed base-digest
pinning in the backend repositories remains a separate reproducibility
milestone; consumers nevertheless receive only the final GHCR digest.

## Workflows

| Workflow | Source inputs | Intended output |
|---|---|---|
| `one-user.yml` | backend + web | combined validation; optional fixed-package GHCR image |
| `one-browser-backend.yml` | backend | Rust/Docker validation; optional fixed-package GHCR image |
| `app.yml` | app | non-publishing macOS/Windows Tauri validation |
| `app-debug.yml` | app | non-uploading Windows debug/PDB validation |
| `egress.yml` | egress | Rust/Docker validation; optional Native + multi-platform public Release |
| `browser-runtime.yml` | runtime | blocked until the fixed Runtime repository is approved |
| `one-amz.yml` | backend + web | combined validation; optional fixed-package GHCR image |
| `node.yml` | One Node source | exact-SHA Go/test/lifecycle/Linux build and local checksum provenance; publication/deployment blocked |

Backend workflows accept `environment=dev|stage|prod`; `deploy` defaults to
false. The local dispatcher may receive a bounded branch, tag, or commit, but
it resolves the Action and every fixed source repository through
`https://api.github.com`, then sends only exact lowercase 40-character SHAs.
The workflow-dispatch payload `ref` and `expected_action_sha` are the same
resolved Action SHA; `reusable-prepare.yml` requires `github.sha` to equal it and checks
every checkout HEAD. There is no fallback to a mutable branch or tag. GitHub's
remote acceptance and execution of a SHA-valued dispatch `ref` remains a first
run proof: rejection must stop the run rather than weaken this contract.

One Node follows the same dispatcher/preparation trust boundary. A dry-run
resolves `voiceofhu/one-action` and `voiceofhu/one-node-node` refs, prints the
exact payload, and sends no POST. A confirmed non-publishing run verifies both
checkout HEADs, source version/upstream metadata, Go modules, product/race/E2E
tests and the namespaced installer lifecycle; it builds Linux amd64/arm64
binaries and reads back deterministic runner-local checksums. Those bytes are
not uploaded or published. `publish=true` and `deploy=true` are rejected before
API access until a protected central Release/GHCR publisher with immutable
remote digest/asset readback is implemented.

## Local commands

Requirements for GitHub API commands are Bash, `curl`, `jq`, and `GH_TOKEN`.
Validation itself does not require network access.

```bash
make help
make validate
make egress-installer-test
make node-check
make node-bundle-installers
GH_TOKEN=github_pat_xxx make check-token
```

## Egress installer contract

The namespaced `browser/egress/install.sh` and
`browser/egress/uninstall.sh` are production-shaped contracts. They default to
`DRY_RUN=true`; a real operation requires both
`DRY_RUN=false` and an exact confirmation string:

```bash
DRY_RUN=true ./browser/egress/install.sh --mode native --version 26.810.1629
DRY_RUN=false ./browser/egress/install.sh --mode native --version 26.810.1629 \
  --confirm install:native:26.810.1629

DRY_RUN=true ./browser/egress/uninstall.sh --mode native
DRY_RUN=false ./browser/egress/uninstall.sh --mode native --confirm uninstall:native
```

`--version` is mandatory and never accepts `latest`. The trust root is compiled
into the script as `voiceofhu/one-action`. A real install reads
only this immutable release family:

```text
https://github.com/voiceofhu/one-action/releases/download/
  egress-v<version>/manifest.json
  egress-v<version>/SHA256SUMS
  egress-v<version>/<native-asset>
```

`manifest.json` must contain only the schema-1 fields defined by the installer:
the exact Action repository, Action commit, exact three-component numeric
version, `egress-v<version>` tag, lowercase 40-character Egress source commit,
two fixed Linux amd64/arm64 Native artifacts, the multiarch image-index digest,
and two architecture-specific image digests. Native names, sizes, checksums,
and direct GitHub Release URLs are exact. The selected digest and size must
match both the single `SHA256SUMS` entry and the downloaded temp file before
atomic replacement. Docker accepts only
`ghcr.io/voiceofhu/one-browser-egress-next@sha256:<64 lowercase hex>` and writes
that exact digest to Compose. Backend proxy URLs, PATs, credentials,
caller-supplied query strings, other GitHub repositories, mutable image tags,
and version discovery are not accepted.

The manifest binds the initial no-query URL in the fixed Action repository; it
does not claim that GitHub serves the asset body from that hostname. The
installer performs one non-following HEAD request, accepts at most one redirect
to the single allowlisted host `release-assets.githubusercontent.com`, and then
performs a GET with redirects disabled. GitHub's ephemeral signed CDN query is
kept out of process arguments and logs and is never treated as an application
credential. Any additional redirect or alternate HTTPS host fails closed. This
GitHub asset-CDN behavior is an external production boundary that still needs
remote release evidence.

The local `installation.env` audit record stores the exact Action commit,
Egress source commit, multiarch index reference, selected immutable source,
platform, architecture, and mode. Uninstall uses the record only to disambiguate
the managed runtime mode; it never evaluates the file as shell code and never
uses manifest data to widen its deletion scope.

Native installation executes the checksum-verified temporary binary's `version`
command before replacement and requires exact equality with `--version`.
Docker installation runs the digest-qualified image with no network and checks
the same command before configuration validation or Compose startup. A manifest
version therefore cannot relabel a different binary version.

The sourced lifecycle evidence currently covers Linux systemd on amd64/arm64.
Darwin and its architectures are recognized, but installation fails closed
because there is no verified launchd or Docker Desktop service contract yet.
Native and Docker modes cannot coexist. Re-running a complete same-version
install is a no-op; changing modes requires uninstall first.

The installer never invents or fetches backend enrollment configuration. A real
operation requires an operator-owned `/etc/one-browser-egress/egress.env`; that
file and `/var/lib/one-browser-egress` are preserved by default on uninstall.
The state directory is always mode `0700`: Native owns it as
`one-browser-egress:one-browser-egress`, while Docker owns it as numeric
`65532:65532` to match the fixed non-root container runtime identity. A broader
or root-owned state mount is rejected by the runtime or cannot be written.
Before either Native or Docker validation, the env file is parsed without
`source` or `eval`. Only `EGRESS_ID`, `EGRESS_BIND_ADDR`,
`EGRESS_CONTROL_URL`, `EGRESS_CONTROL_TOKEN`,
`EGRESS_HEARTBEAT_INTERVAL_SECONDS`, and
`EGRESS_SHUTDOWN_GRACE_SECONDS` are allowed; invalid lines, duplicate/unknown
keys, and NUL bytes fail closed. Values are exported literally, so command
substitutions and backticks are never executed.
`--purge --confirm purge:<mode>` removes only those two explicitly guarded
directories. Docker itself, pulled images, and unrelated host state remain.

`make egress-installer-test` uses local release fixtures plus fake curl,
systemctl, and Docker commands under a narrow `/tmp` root. It never accesses the
network or the host service manager. `egress.yml` now contains the separately
gated publication path described below, but that source has not been dispatched;
no corresponding public release is claimed to exist.

Dispatch commands are dry-run by default. A dry-run still performs read-only
GitHub API requests because its output must contain verified commit SHAs.

```bash
GH_TOKEN=github_pat_xxx make dispatch-one-user
```

The first dry-run prints the resolved Action SHA and the exact confirmation
strings. Starting a non-publishing GitHub Actions run then requires the
Action-SHA-bound dispatch confirmation:

```bash
GH_TOKEN=github_pat_xxx make dispatch-one-user \
  DRY_RUN=false \
  CONFIRM_DISPATCH='dispatch:one-user.yml:<action-sha>'
```

Mutation inputs have a second independent gate:
`CONFIRM_MUTATION=mutate:<workflow-file>:<action-sha>`. The dispatcher rejects
caller-owned `confirmation` and `expected_action_sha` assignments and, after
the local gate passes, injects
`confirmation=enable:<workflow-base>:<action-sha>`. A non-publishing dispatch
rejects any mutation confirmation. Dry-run resolves refs with bounded GETs and
prints the exact payload but sends no POST. Unknown workflows, source
repositories, keys, refs, versions, environments, and mutation modes fail
closed; deployment and artifact upload are always rejected before API access.

Publication requires a numeric three-component version without `v` and the
dispatcher-populated exact Action SHA guard on every run. Browser Runtime is
blocked; App publication and App Debug upload are unsupported; Egress
publication additionally requires `environment=prod`. Dispatcher confirmation
is an operator mistake guard, not an authentication secret, and does not
replace protected-environment approval. A direct `workflow_dispatch` operator
can see and calculate declared inputs; remote environment protection,
repository permissions, and narrowly scoped secrets remain the authorization
boundary.

The dispatcher fixes the Action repository and API base in code. `GH_TOKEN`
must be supplied as an unquoted raw token; Make exports it instead of
interpolating it into recipe text, and the GitHub helper sends it through curl
configuration on standard input after removing it from curl's arguments and
environment. Curl ignores user configuration and proxies, follows no redirect,
accepts HTTPS only, has fixed connect/total/body limits, and requires exact
GET/POST status codes. `SOURCE_READ_TOKEN`, when a fixed private source needs
it, must be limited to read access on those source repositories; it is passed
explicitly rather than through `secrets: inherit`.
Preparation and ordinary build jobs retain `contents: read`; only reusable
publish jobs receive mutation permissions. User, One AMZ, and Browser Backend
use the protected `ghcr-publish` environment. Egress uses `public-release`,
requires `environment=prod`, and receives both `contents: write` and
`packages: write`. App, Runtime, and debug upload remain unsupported.

## Combined Web/backend verification

`one-user.yml` and `one-amz.yml` call `reusable-prepare.yml`, then pass only its verified
`primary_sha` and `secondary_sha` outputs to `reusable-build-web-backend.yml`. The build
workflow rejects anything other than exact 40-character SHAs and never resolves
branches or tags again.

The reusable build performs:

1. frozen pnpm install followed by format-check, lint, typecheck, and the Vite
   production build in the Web checkout;
2. copy of `web/dist` into a fresh `backend/web-dist`;
3. `cargo fmt`, locked check/clippy/test, and locked release build;
4. fail-closed build of `backend/Dockerfile` with a local exact-SHA tag, then
   rejection of an empty, `root`, or numeric-UID-0 final `Config.User`;
5. collection of every Rust binary target;
6. runner-local `manifest.json`, per-file SHA-256 lists, archives, image ID/user,
   and `SHA256SUMS` generated through the central checksum helper.

Missing `backend/Dockerfile` or packaged `backend/web-dist/index.html` fails the
build. The ordinary build remains read-only and publishes nothing. The separate
publisher repeats exact-SHA checkouts, Web verification, `web-dist` packaging,
locked Rust verification, and production image construction before its final
token-scoped push step. It proves each checkout HEAD equals its prepared SHA,
rejects symlinked package/lock/toolchain/Dockerfile inputs and non-regular
`web/dist` entries, and binds the requested version to both the fixed Web
package and fixed backend Cargo package. A tracked source mutation caused by an
install or build script fails closed. The Docker context is reconstructed from
the exact backend commit with replacement objects disabled, then receives only
the verified `web-dist`; untracked build output cannot silently enter the final
image. Immediately before registry access, the central push script's blob must
still equal the blob recorded by the exact Action commit.

The Web build mode is selected from the validated publication environment:
development mode for `dev`, `build:stage` for `stage`, and the production build
for `prod`. Thus the embedded Web environment cannot disagree with the OCI
environment provenance label.

## Standalone Rust/Docker verification

`one-browser-backend.yml` and `egress.yml` pass only the exact SHA produced by
`reusable-prepare.yml` to `reusable-build-rust-docker.yml`. The reusable workflow runs locked
fmt/check/clippy/test/release build, requires the source repository's own
production `Dockerfile`, and builds an exact-SHA-tagged `local/...` image.
The Browser Backend publisher additionally binds the checkout to the fixed
`one-browser-backend` Cargo package and requires its package version to equal
the requested publication version. Its final Docker context is likewise
reconstructed from the exact source commit with Git replacement objects
disabled.

The final image must declare a non-empty, non-root, non-UID-0 `Config.User`.
The source SHA, release-binary checksums, local image ID, and image user are
written to runner-local provenance and `SHA256SUMS`. Browser Backend may then
enter its image publisher. Egress may enter only its separate coherent
Native/container Release publisher. The ordinary build itself does not upload,
publish, release, or deploy anything.

## GHCR publication contract

Only these targets are compiled into the publisher and accepted by the final
push helper:

```text
ghcr.io/voiceofhu/one-user-backend-next
ghcr.io/voiceofhu/one-amz-backend-next
ghcr.io/voiceofhu/one-browser-backend-next
```

The dispatch payload cannot select another registry or package. Publication
also binds each product to its fixed `voiceofhu/*-next` backend/Web source
repositories and requires execution from
`voiceofhu/one-action` on `https://github.com`; a copied workflow
or manually supplied repository cannot publish under an official package name.
Publication
creates exactly one run tag. Combined images use
`run-a<action>-b<backend>-w<web>-r<run_id>-a<attempt>`; Browser Backend uses
`run-a<action>-s<source>-r<run_id>-a<attempt>`. SHA fragments are twelve
lowercase characters. The publisher refuses a pre-existing run tag and never
creates `latest`, environment aliases, or version aliases. `version` is only an
OCI label and provenance value, is limited to 32 characters, and must equal the
fixed source package version. Local image labels are read back before login and
must bind the exact Action repository/SHA, backend/Web SHAs, source repository,
version, and environment.

The three backend callers pass only the explicit source-read secret to prepare,
ordinary build, and publish rather than inheriting every repository secret. A
publisher has no fallback from that read-only checkout credential to its
package-writing `github.token`. The registry credential is scoped to the last
step, passed to Docker through stdin, and unset immediately after login. Before
push, an authenticated bounded GHCR manifest `HEAD` must return
exactly `404`; authentication, network, rate-limit, and all other responses
fail closed instead of being treated as tag absence. After push, the helper
accepts exactly one canonical target-tag
`digest: sha256:<64hex> size: <n>` result from Docker, reads the
digest-qualified manifest back, and requires the run tag's registry
`Docker-Content-Digest` to equal that same digest. It writes
runner-local `publication/published-image.json` and the job summary with
`published=true`, exact Action/source SHAs, version, run URL, tag, digest, and
`deployment.performed=false`. The Action repository is also recorded in the
publication JSON. Consumers must use
`ghcr.io/...@sha256:<64hex>`, never the run tag. The JSON is not uploaded by this
milestone, and no deployment is attempted.

GitHub permissions are job-scoped, so this final-step token boundary is not a
sandbox for hostile source code. Publication assumes the fixed exact source
commits have been reviewed; untrusted-source builds would require a separate
sealed build job and privileged push job.

## Egress public Release contract

`egress.yml` accepts publication only after exact Action/Egress SHA resolution,
the dispatcher mutation confirmation, `environment=prod`, and approval of the
protected `public-release` environment. Repository administrators must actually
configure required reviewers/protection on that environment; workflow source
cannot prove the remote rule exists. `reusable-publish-egress.yml` first uses a
read-only job to bind the requested version to `Cargo.toml`, build the source
Dockerfile's exact `/one-browser-egress` `release` output independently for
Linux amd64 and arm64, execute each exported binary's `version` command, and
seal the exact source plus Native inputs in an
immutable, runner-scoped GitHub Actions artifact. This is an internal job
handoff with one-day retention, not a public Release artifact and not the
user-facing `upload_artifact` dispatch input (which remains fail-closed). The
protected job receives no inherited secret. Only its final mutation step is
passed `GITHUB_TOKEN`; it builds and pushes one
multi-platform image under a unique run tag, reads the exact two-platform index
back by digest, and records the index plus each architecture-specific digest.

The same step creates one draft Action Release named `egress-v<version>` at the
exact Action SHA, reads every asset byte back, then makes it non-draft and
verifies the final tag target. Its fixed assets are both Native binaries,
`install.sh`, `uninstall.sh`, `manifest.json`, `source-commit.txt`, and
`SHA256SUMS`. The manifest binds the Action repository and commit, Egress source
SHA, release tag, exact Native names/sizes/URLs/checksums, the GHCR index, and
architecture-specific GHCR references. Existing tags/releases or run image
tags are never overwritten. No `latest`, environment, or version image alias
is created, and no deployment runs or is reported.

## App build verification

`app.yml` and `app-debug.yml` run only in
`voiceofhu/one-action`, accept only
`voiceofhu/one-browser-app-next`, and receive only the exact App SHA produced by
`reusable-prepare.yml`. The public workflow input itself must already be a lowercase
40-character commit SHA; the local dispatcher resolves a branch/tag before
dispatch. Their caller policy rejects publish/upload requests before source
resolution and runs with an empty permission map. The callers do not inherit
repository secrets; checkout uses only
the job's read-only `github.token`, so a private cross-repository source that is
not readable by that token fails closed instead of falling back to a PAT.

After both checkouts, the reusable workflows verify Action/App HEAD against the
exact requested SHAs and require non-symlinked, bounded `package.json`, pnpm and
Cargo lockfiles, Rust toolchain, Cargo manifest, and Tauri config. Node.js is
fixed to `24.0.0`, pnpm to `10.32.1`, and Rust to `1.97.1`; the package, Tauri,
and Cargo versions must agree. Both use a frozen pnpm install, Prettier check,
lint, typecheck, frontend build, and locked Cargo fmt/check/clippy/test before
invoking the App's installed Tauri CLI. A second HEAD and tracked-diff check
runs after the build to reject ordinary source drift.

The fixed matrix uses `macos-14` for macOS arm64 and `windows-2022` for Windows
x64, with an in-runner architecture assertion before source commands. The debug
workflow runs the source-compatible command
`pnpm exec tauri build --debug --bundles nsis --ci --no-sign` and fails unless
the exact debug binary, one NSIS installer, and
`target/debug/one-browser-app.pdb` exist. Formal builds also pass `--no-sign`.
Raw binaries are limited to 512 MiB; installers/PDBs are limited to 2 GiB.
Collected inputs must be nonempty regular non-symlink files with bounded safe
basenames, and each expected category has an exact count. Each runner creates
only repository-relative artifact paths, SHA-256 values, `manifest.json`, and
`SHA256SUMS` locally; the checksum loop supports macOS `shasum` and does not rely
on GNU `sort -z`. No artifact is uploaded, signed, released, pushed, or deployed.

This hardening is source-only and was not parsed, linted, built, dispatched, or
run on macOS/Windows in this milestone. Runner-label architecture, Marketplace
Action commit pins, actual Tauri output names, and any future
signing/notarization evidence remain separate remote milestones.

Temporary remote repository names default to `-next` during migration. Browser
Runtime dispatch and preparation remain fail-closed because its final remote
owner has not been approved; a caller cannot select one dynamically.

## Public artifact contract

All public App, Egress, and Browser Runtime downloads will be served directly
from this repository's immutable GitHub Releases, Raw files, or GHCR packages.
Business backends may return metadata or a temporary redirect, but must not
proxy artifact bodies.

Release families are reserved as follows:

```text
app-v<version>
egress-v<version>
browser-v<version>
```

Each release must contain platform artifacts, `SHA256SUMS`, `manifest.json`,
and `source-commit.txt`. Published immutable tags and assets must never be
overwritten. The three backend publishers do not create `latest` at all, and
production deployment must use exact image digests.

## Repository rules

- Do not import the legacy repository's `.git` directory or history.
- Do not reference the legacy filesystem path at build or runtime.
- Keep build/release/deploy implementations here; source repositories may use
  only thin callers for PR checks or dispatch.
- Add a build implementation only when its target source project and its
  verification command exist.

See [MIGRATION-SOURCES.md](MIGRATION-SOURCES.md) for the selected legacy
components and their adaptations. The intentionally deferred validation and
first protected remote proof are listed in
[VALIDATION-HANDOFF.md](VALIDATION-HANDOFF.md).
