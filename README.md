# One Action

One Action 是 One 平台唯一的公共仓库，也是所有产品统一的分发与部署中心。One User、
AMZ、Browser、Node、Notify、Pay、Object、Template、VPS 等产品源码仓库均保持私有；私有仓库不自行发布
Release、镜像、安装器或生产部署，也不把私有源码复制到本仓库。

One Action 集中维护 GitHub Actions workflow、发布脚本、公开安装器和产物合同。格式、
lint、测试和必要的本地编译门禁在 `make deploy-*` 触发远端工作流之前完成；Action 使用
受保护凭据读取精确的私有源码 commit/tag，再统一构建、分发，并按产品合同部署。公共日志
和产物不得包含私有源码、Token、环境文件或生产凭据。

公开安装器按产品命名空间组织：One Node 使用 `node/{install,upgrade,uninstall}.sh`
及 `node/scripts/`；仓库根目录不提供安装入口。

所有产品都通过 One Action 发布；One IP 是独立项目，不接入（由自身仓库 `make deploy-server`
部署）。当前本地发布入口如下，未在这里列出的产品不应视为已经具备正式分发或部署能力：

| 本地入口 | Action 触发方式 | 发布结果 |
|---|---|---|
| `make deploy-<key>-server` | 标签 `deploy/<key>-server/<version>` → `<key>-server.yml` | user、object、notify、pay、template、vps、amz、mail、node、browser：发布 Server 镜像并按 digest 部署，包含 Web（见「Server + Web 产品」） |
| `make deploy-<key>-web` | 标签 `deploy/<key>-web/<version>` → `<key>-web.yml` | 同上十个产品：仅部署 Web 静态文件，不重启 Server |
| `make deploy-<key>-app` | 标签 `deploy/<key>-app/<version>` → `<key>-app.yml` | browser、mail：Linux、Windows、macOS arm64/x64 安装包；node（PC 客户端）：Windows、macOS arm64/x64；均附 `SHA256SUMS` 和公开 One Action Release（见「桌面客户端」） |
| `make deploy-node` | 标签 `deploy/node-runtime/<version>` → `node-runtime.yml` | `ghcr.io/voiceofhu/one-node:<version>`、Linux 双架构二进制、macOS/Windows（监控节点）二进制、Ed25519 + RSA 双签名 `SHA256SUMS` 和公开 One Action Release |

`deploy-node` 只触发 Runtime 编译上传；Browser App 只发布产物。One Node 的 Backend 是 Go
（`products.json` 中 `"backend_language": "go"`）：发布时运行 `go vet` 与 `make test`，不提交版本号，
版本通过镜像构建参数 `VERSION` 写入。

## Workflow 命名规则

所有工作流直接放在 `.github/workflows/`，使用小写 kebab-case 和 `.yml` 后缀：

- 产品入口：`<product>-<component>[-<purpose>].yml`。产品省略统一的 `one-` 前缀；
  组件使用 `server`、`web`、`app`、`runtime`。例如 `user-server.yml`、
  `browser-app.yml`、`node-runtime.yml`；同一组件存在不同用途时才增加后缀。
- 共用工作流：`reusable-<action>-<target>.yml`，通过 `workflow_call` 调用。
  当前 `reusable-publish-server-image.yml` 负责构建 Web 和 Server 多架构镜像。
- Actions 展示名称使用 `One <Product> <Component> [Purpose]`；共用流程使用
  `Reusable <Action> <Target>`，与文件名对应。

新增工作流时按同产品已有文件创建：入口只监听自己的 `deploy/<文件名去掉 .yml>/*` 标签，
首个 job 用 `scripts/github/read-trigger.sh` 读取标签；同时更新对应 `scripts/release/` 入口、
产品测试和 `scripts/validate.sh` 定向检查范围。`make validate` 自动发现全部 `.yml` 工作流；
全量校验同时检查命名与本地 reusable 引用。新增产品入口也需补充上方表格。

重命名时同步更新标签前缀、`uses` 引用、脚本、测试和文档。文件名与发布合同分开：
`workflow_name`、镜像名、Release tag 和 concurrency 标识不能随文件名机械改写。
新 workflow 须先进入 `main`，推送的标签才能触发它。

## 发布边界

每次真实发布按固定顺序执行：

1. 确认 `one-action` 和源码仓库位于干净分支，origin 指向固定仓库；
2. 确认本地 `one-action/main` 与 `origin/main` 完全一致；
3. Server 发布先自动修复对应 Rust 后端格式，再运行该产品的格式、lint、测试和构建；所有门禁通过后才将格式修改与版本号一起提交；
4. One User 推送版本文件提交；One Node Server、One Node Runtime 和 Browser 三条链路要求本地 HEAD 已与远端分支完全一致；这些链路不创建源码发布 tag；
5. 本地入口 `scripts/release/trigger.sh` 在已发布的 Action `main` 提交上创建注释标签
   `deploy/<workflow>/<version>` 并用普通 `git push` 推送；标签说明逐行写入精确源码 SHA
   （如 `backend_ref=<sha>`）。One Node / App Release workflow 另行创建公开 Release 所需的 `one-*-v<version>` 标签；
6. Action 只拉取固定源码、并行编译 amd64/arm64，并上传镜像或 Release 产物；
7. One User 与 One Node Server 在镜像成功合并后，将 digest-qualified 镜像分别部署到受保护的生产 environment。

本地触发不需要任何 GitHub API Token（不用 `GH_TOKEN`、`gh auth` 或 dispatch API），只用推送
one-action 的 Git 远端权限（SSH）。workflow 启动后由 `read-trigger.sh` 校验：标签必须是注释标签、
指向本次运行的提交且该提交在 `main` 上、只包含该 workflow 需要的 `*_ref=<40 位 SHA>` 行。
仓库 Secret `GH_TOKEN` 只在 workflow 内读取私有源码和发布产物。同一版本标签只能推送一次；
失败重跑使用 Actions 页面的 Re-run，或换一个 `VERSION` 重新发布。

## Server + Web 产品（products.json）

One User、One Object、One Notify、One Pay、One Template、One VPS、One AMZ、One Mail 共用同一套发布实现，差异只记录在
`products.json`：源码仓库、Cargo/npm 包名、默认公网地址、容器端口、readiness 路径、
部署目录内必须存在的子目录，以及本地 Web 检查命令。镜像 `ghcr.io/voiceofhu/one-<key>`、
Environment `one-<key>-prod`、部署目录 `/opt/one-<key>`、容器/Compose 项目 `one-<key>`、
服务名 `<key>`、本地源码 `../one-<key>/{backend,web}` 由 `scripts/lib/product.sh` 统一推导。

| 产品 | Backend 仓库 | 端口 / readiness | 公网地址 | 部署目录额外要求 | 本地 Web 检查 |
| --- | --- | --- | --- | --- | --- |
| user | `one-user-backend` | `27510/readyz` | `https://oa.aicbe.com` | `cert/` | format:check、lint、test、build |
| object | `one-object-server` | `27525/readyz` | `https://object.aicbe.com` | — | format:check、lint、test、build |
| notify | `one-notify-server` | `27520/readyz` | `https://notify.aicbe.com` | — | lint、build |
| pay | `one-pay-server` | `27521/health/ready` | `https://pay.aicbe.com` | — | lint、build |
| vps | `one-vps-server` | `27545/readyz` | `https://vps.aicbe.com` | — | lint、build |
| amz | `one-amz-server` | `27512/healthz` | `https://amz.aicbe.com` | — | lint、build |
| mail | `one-mail-backend` | `27540/readyz` | `https://mail.aicbe.com` | — | format:check、lint、test、build |
| template | `one-template-server` | `27543/readyz` | `https://tpl.aicbe.com` | — | format:check、lint、test、build |

各 Backend 仓库提供 `deploy/docker/Dockerfile` 与 `deploy/docker/docker-compose.yml`；Compose 服务名为
`<key>`，镜像内 Web 位于 `/opt/one-<key>/web-dist`，运行时从挂载的 `/opt/one-<key>/web/current` 托管。
One Node Server 使用根目录 `Dockerfile` 与 `deploy/docker-compose.yml`，Compose 服务名为 `server`，
容器名为 `one-node-server`，镜像内 Web 位于 `/app/web-dist`，运行时从挂载的 `/app/web/current` 托管。
Server 镜像发布到 `ghcr.io/voiceofhu/one-node-server`；`ghcr.io/voiceofhu/one-node` 用于 Node Runtime。
One Browser 也使用根目录 `Dockerfile` 与 `deploy/docker-compose.yml`，保留 Compose 服务 `server`、
容器 `one-browser-server` 和镜像仓库 `ghcr.io/voiceofhu/one-browser-backend`，Web 目录沿用上述 `/opt/one-browser` 布局。
One AMZ 以单容器 `all` 模式同时运行 API 与全部后台 Worker；One Mail 的镜像需要 OpenSSL（IMAP/SMTP 的 native-tls）。
One AMZ 的 Web 健康检查使用 `/login`；`/` 属于公开店铺路由，未配置店铺的管理域名会按契约返回 404。
每个产品的 pnpm 版本也记录在 `products.json`，镜像构建与独立 Web 构建使用同一版本。

```mermaid
flowchart TD
    start[make deploy-{key}-server] --> plan[生成版本并检查 Action/Backend/Web 三个仓库]
    plan --> action[确认 one-action HEAD 等于 origin/main]
    action --> fix[修复当前 Rust Backend 格式: fix-servers]
    fix --> contract[validate-{key}]
    contract --> backend[Backend: cargo fmt --check + make test]
    backend --> web[Web: frozen install + products.json 中的检查]
    web --> version[提交并推送 Backend 格式修改与 Backend/Web 版本文件]
    version --> control[推送标签 deploy/{key}-server/{version}<br/>说明中写精确 Backend/Web SHA]
    control --> resolve[reusable-deploy-server.yml 读取标签并校验调用方、清单和 SHA]
    resolve --> image[amd64 + arm64 原生构建，发布 OCI index]
    image --> deploy[SSH + Compose 部署精确 digest，激活镜像内 Web]
    deploy --> result[本机与公网 readiness 通过，否则回滚容器和 Web]
```

| 层 | 文件 |
| --- | --- |
| 本地入口 | `scripts/release/release-server.sh <key>`、`scripts/release/release-web.sh <key>` |
| Workflow | `<key>-server.yml` / `<key>-web.yml` 只监听自己的 deploy 标签并传入 `product`，逻辑在 `reusable-deploy-server.yml` / `reusable-deploy-web.yml` |
| 服务器部署 | `scripts/deploy/deploy-server.sh`、`scripts/deploy/deploy-web.sh`（`PRODUCT=<key>`） |
| 测试 | `tests/products_test.sh`（清单与入口一致），`release-*_test.sh`、`deploy-*_test.sh` 对每个产品实跑 |

- `make deploy-<key>-server` 发布 Server 镜像并激活镜像内 Web；`make deploy-<key>-web` 只检查并发布 Web，
  不依赖 Server checkout，不重启 Server。首次先部署 Server 建立 `/opt/one-<key>/web` 持久化目录与挂载。
- 均支持 `VERSION=26.912.1200` 和 `DRY_RUN=true`（只显示计划）；本地检查 `make validate-<key>`。
- 可复用 workflow 校验调用方必须是 `voiceofhu/one-action/.github/workflows/<key>-server.yml`（或 `-web.yml`），
  源码仓库固定取自清单。Server 与 Web 共享部署锁，保留旧静态资源，健康检查失败时回滚。
- 每个 Environment `one-<key>-prod` 需要 Secrets `DEPLOY_HOST`、`DEPLOY_USER`、`DEPLOY_SSH_KEY`、
  `DEPLOY_KNOWN_HOSTS`，可选 `DEPLOY_PORT`（默认 22）；仓库 Secret `GH_TOKEN` 读取私有源码并发布 GHCR。
  可选 Variables `DEPLOY_URL`（默认取清单公网地址）、`DEPLOY_REMOTE_DIR`（默认 `/opt/one-<key>`）。
- 服务器预置可写部署目录、`.env`、Docker Compose、curl、flock 和外部数据库网络（默认 `db-networks`）；
  数据库须事先初始化，部署不会运行 SQL。服务环境配置以各 Backend README 和 `.env.example` 为准。
- 新增同类产品：在 `products.json` 加一条，复制一对入口 workflow 并改 `product:`，在 `make/` 加两个目标，
  并把 `<key>|<key>-web` 加到 `scripts/validate.sh` 的产品范围。

## 桌面客户端（apps.json）

One Browser、One Mail 与 One Node PC 客户端（Tauri）共用 `reusable-publish-tauri-app.yml`。`apps.json` 记录源码仓库、
本地目录、Cargo 包名、pnpm 版本和 macOS 专用配置；Release 标签统一为
`one-<key>-app-v<version>`，入口为 `<key>-app.yml`。可选字段：

- `platforms`：构建矩阵名（`linux-amd64`、`windows-amd64`、`macos-arm64`、`macos-amd64`），默认全部；
- `web_repository`：随包内置的 Web，CI 检出到客户端旁的 `../web`，deploy 标签另以 `web_ref` 固定其 SHA；
- `backend_repository`：sidecar 用 Go `replace` 引用的 Server 共享包（One Node：`pkg/rulespec` 规则语言与规则引擎），CI 检出到客户端旁的 `../backend`，deploy 标签另以 `backend_ref` 固定其 SHA；
- `go_version_file`：客户端内 go.mod 路径，CI 据此安装 Go，用于构建 sidecar。
- `runners`：按平台替换默认 runner（One Node：`macos-amd64` 在 Apple Silicon 的 `macos-15` 上交叉编译 x64 包）；
  Intel Mac runner 上 pnpm 11 由 npm 安装（pnpm/pnpm#11423）。

| 客户端 | 源码仓库 | 本地目录 | 正式版连接地址 |
| --- | --- | --- | --- |
| browser | `voiceofhu/one-browser-app` | `../one-browser/app` | `https://browser.aicbe.com` |
| mail | `voiceofhu/one-mail-app` | `../one-mail/app` | `https://mail.aicbe.com` |
| node | `voiceofhu/one-node-pc` | `../one-node/pc`（Web：`../one-node/web`，Server：`../one-node/backend`） | `https://marseo.eu.org/pc`，不可达时用内置离线副本 |

- `make deploy-<key>-app` 要求 one-action 与 `origin/main` 一致、客户端仓库干净、HEAD 与 `main` 一致且已推送，本地运行依赖安装、`scripts/*.mjs` 语法检查、
  `scripts/tests` 存在时的 Node 测试，以及 `cargo fmt`、Clippy（warnings 视为错误）和 `cargo test`，通过后推送 `deploy/<key>-app/<version>` 标签固定精确源码 SHA。
- 客户端仓库须提供 `scripts/update-version.mjs`；CI 在各平台打包前写入 package.json、`tauri.conf.json`、Cargo.toml 与 Cargo.lock 的版本。
- 客户端提供 `scripts/prepare-bundle.mjs` 时（One Node：离线 Web 副本、Go `onecore` sidecar、Windows 的 `wintun.dll`），本地校验在 Rust 检查前先运行它；
  CI 由 Tauri 的 `beforeBuildCommand` 按目标平台运行。带 `web_repository` 的客户端，其 `../web` 同样须干净、与 `main`（`ONE_<KEY>_APP_WEB_REF`）一致且已推送；
  带 `backend_repository` 的客户端，其 `../backend` 也一样（`ONE_<KEY>_APP_BACKEND_REF`），本地 `go test` 与 CI 构建都用这份源码；
  带 `go_version_file` 的客户端另跑 `go vet` 与 `go test`。
- 已存在的 Release 或标签不会被覆盖；源码仓库不打发布标签，标签只在 One Action 上绑定本次 Action SHA。
- 客户端加载远端页面：正式版连接上表地址，开发版连接本机 Backend；对应的 Server/Web 先按「Server + Web 产品」部署（One Node 客户端的 `/pc` 页面随 `deploy-node-web` 上线，宜先于客户端发布；线上缺 `/pc` 时客户端 8 秒后改用内置副本）。

## 使用

默认版本按上海时区生成三段数字，也可显式指定：

```bash
make deploy-user-server VERSION=26.821.1200
make deploy-node-server VERSION=26.821.1200
make deploy-node VERSION=26.821.1200
make deploy-browser-app
make deploy-node-app
make deploy-browser-server
```

One User 和 One Node 目标执行各自产品的本地检查；Browser App 在推送标签前安装锁定依赖、检查 Node 脚本语法，并运行 Rust fmt、Clippy 和测试；失败即停止，成功后将本地校验过的源码 SHA 交给工作流构建。App 工作区须干净，HEAD 须匹配配置的源码 ref。App 默认使用与其他部署入口相同的上海时间版本（YY.MMDD.HHmm，去除各段前导零），也可通过 `VERSION=...` 显式指定；不再复用源码 package.json 的旧版本。CI 在各平台打包前调用 App 的 `scripts/update-version.mjs`，同步写入 package.json、Tauri 配置、Cargo.toml 和 Cargo.lock，版本修改仅发生在 CI 检出目录。构建前先检查同名 Release，已存在或无法确认时停止，发布阶段仍保留不可覆盖保护。同一分钟内重复发布时需等下一分钟或指定未使用的版本。 与 One Node 一样，App 发布时在 one-action 公共仓库显式创建 `one-browser-app-v<版本>` tag，绑定本次 Action SHA；已有 tag 必须指向相同提交，禁止移动或覆盖。创建 Release 使用 `--verify-tag --latest=false`，源码 SHA 记录在发布说明中，源码仓库不打发布 tag。Browser Server/Web 在本地校验后推送 deploy 标签。`browser-app.yml` 从标签读取源码 SHA，所有平台统一检出该 SHA。生产页面地址由 App 的 `src-tauri/tauri.conf.json` 管理（`https://browser.aicbe.com`），无需设置 Action 后端地址变量。修改 workflow 后须先推送到 `main`，新入口才能被标签触发。源码仓库不创建发布 tag；One Node Server 不修改 Web 版本，One Node Runtime 和 Browser 也不修改源码版本。只查看计划时显式启用 dry-run；dry-run 不运行
产品检查、不修改文件、不创建或推送标签：

```bash
make deploy-user-server DRY_RUN=true
make deploy-node-server DRY_RUN=true
make deploy-node DRY_RUN=true
make deploy-browser-app DRY_RUN=true
make deploy-node-app DRY_RUN=true
make deploy-browser-server DRY_RUN=true
```

版本必须是无 `v` 前缀、无前导零的 `<major>.<minor>.<patch>`。

## 本地门禁

本地需要 `shellcheck`、`actionlint`、`zizmor`、`ruby`、`node` 和 `python3`：

```bash
brew install shellcheck actionlint zizmor
```

自动修复 Rust 后端格式：

```bash
make fix
make fix-servers PRODUCTS="object user pay amz browser"
```

`fix` 与 `fix-servers` 是同一入口，默认处理 `products.json` 中所有 Rust 后端，
也可用 `PRODUCTS` 选择产品；Go 后端 One Node 会跳过。命令仅执行 `cargo fmt --all`
写回格式，不运行检查、编译或部署。源码路径沿用 `SOURCE_ROOT` 与各产品的
`ONE_<PRODUCT>_BACKEND_DIR` 配置。

`make deploy-<key>-server` 和批量 `make deploy-servers` 会在各产品的本地校验前
自动执行该产品的 `fix-servers`。全部门禁通过后，Rust 后端的格式修改与版本号一起提交、
推送；校验失败则停止，格式修改保留在工作区，不提交、不推送。发布入口仍要求运行前
源码仓库干净，`DRY_RUN=true` 不执行格式修复。

基础检查：

```bash
make validate
make validate-user
make validate-node-runtime
make node-check
make node-bundle-installers
```

`make validate` 检查全部活跃 shell、workflow YAML 和发布契约，并运行 One Node 生命周期 fixture。
每个范围都会对相关 workflow 运行 actionlint（含 shellcheck）和 zizmor 离线安全审计；
规则例外分别记录在 `.github/actionlint.yaml` 和 `.github/zizmor.yml`，单个步骤的例外使用
`# zizmor: ignore[...]` 注释并写明原因。
`make validate-<key>`（user、object、notify、pay、template、vps、amz、mail、node、browser 及其 `-web`）检查共享的 Server/Web 发布实现，
对 `products.json` 中每个产品实跑发布与部署测试，不运行 One Node 生命周期 fixture。
`make validate-node-runtime` 只检查 One Node Runtime 的安装生命周期、标签触发、构建和 Release 合同；
`deploy-node` 使用这一范围，并在 Node 源码仓库独立运行 `verify-upgrade`。
真实 `deploy-*` 还会执行产品门禁：

- One User：Backend fmt/test；Web frozen install、format、lint、test、build；
- One Node Server：Backend `go vet` 与 `make test`；Web 按 `products.json` 的 `web_gates`；
- One Node Runtime：仅在 Node 源码仓库执行完整 `verify-upgrade`。

Browser App 要求本地源码仓库干净、已推送且 Rust 门禁通过，再推送标签固定
精确源码 SHA。

任何本地门禁失败都会发生在版本提交或推送 deploy 标签之前。

## Action 结构与时间上限

- One User / One Node Server：2 分钟源码解析；amd64 和 arm64 原生 runner 并行构建，
  每个最多 20 分钟；OCI index 合并最多 3 分钟。
- One User / One Node Server 部署：镜像发布成功后运行，各自最多 20 分钟，同一产品同一时间只允许一个生产部署。
- One Node Runtime：2 分钟源码解析；两个架构并行编译和推送，每个最多 15 分钟；
  OCI index、checksum 和公开 One Action GitHub Release 上传最多 8 分钟。
- One Browser App：2 分钟源码解析；Linux、Windows、macOS arm64/x64 并行打包；
- One Browser App Server：复用 Web+Backend 双架构镜像发布器；

Action 中没有 fmt、lint、test、race、e2e 或 installer lifecycle；双架构 Docker 构建使用
按产品和架构隔离的 GHA layer cache。One User 与 One Node Server 保留各自隔离的
SSH/Compose 部署步骤。
不同版本可并行；相同产品、相同版本的重复触发由 concurrency group 串行保护。

## Workflow 安全约定

- 所有第三方 Action 固定到完整 commit SHA，并以 `# vX.Y.Z` 注释标注版本；
  `.github/dependabot.yml` 每周合并提交一个更新 PR（新版本发布 7 天后才提出）。
- Workflow 顶层只授予 `contents: read`；`contents: write`、`packages: write` 只写在需要的 job 上。
- `actions/checkout` 一律 `persist-credentials: false`；标签内容只由 `read-trigger.sh` 严格解析，
  其输出先进入 `env` 再在 shell 中使用，不直接拼接进脚本。

## GitHub 配置

`one-action` 仓库需要配置 Repository Secret `GH_TOKEN`，用于：

- 读取固定的私有源码仓库；
- 向 `ghcr.io/voiceofhu/*` 推送架构镜像和 OCI index；
- 在 `voiceofhu/one-action@one-node-v<version>` 创建并上传公开 One Node Release。
- 在 One Action 创建 One Browser App 的产品前缀 Release。

One Node 的构建使用 `contents: read`；Release job 使用仓库 `GITHUB_TOKEN` 的 `contents: write`。

One User 和 One Node Server 分别使用受保护的 `one-user-prod`、`one-node-prod` environment，并需要：

- Secrets：`DEPLOY_HOST`、`DEPLOY_PORT`（可选，默认 `22`）、`DEPLOY_USER`、
  `DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS`；
- Variables：`DEPLOY_REMOTE_DIR`、`DEPLOY_URL`。One User 默认 `/opt/one-user` 与
  `https://oa.aicbe.com`；One Node Server 默认 `/opt/one-node` 与
  `https://marseo.eu.org`。

部署 job 使用 `GH_TOKEN` 让服务器临时登录 GHCR，部署后始终尝试退出 Registry；服务器
Compose 文件来自同一 Backend/Server 源码 commit；One User 检查 `/readyz` 和首页，
One Node Server 检查 `/api/healthz` 和首页。

## One Node 生命周期入口

稳定入口位于：

```text
node/install.sh
node/upgrade.sh
node/uninstall.sh
```

安装器未指定 `ONE_NODE_VERSION` 时会选择 `one-action` 仓库最新的 `one-node-v<version>` Release；显式设置版本
可固定安装或回滚。完整参数和生命周期约束见 [node/README.md](node/README.md)。

安装成功后会保留 `/opt/one-node/install.sh`。在节点服务器执行
`sudo /opt/one-node/install.sh` 可进入交互菜单；也可使用 `--status`、
`--doctor`、`--upgrade`、`--rollback`、`--restart`、`--logs` 和
`--uninstall --yes` 直接管理 Native 或 Docker 节点。状态输出包含运行模式、版本、
PID、内存、运行时长和服务/容器状态。

## 目录

```text
.github/workflows/   产品入口和一个 Web+Backend 复用发布工作流
node/                One Node 安装、升级、卸载和本地 fixture
scripts/release/     本地发布入口与上传辅助脚本
scripts/deploy/      各产品 SSH、Registry、Compose 和 Web 部署脚本
scripts/github/      CI 内读取并校验 deploy 标签（read-trigger.sh）
tests/               各发布链的本地契约测试
make/                Makefile 子模块
```

本地 YAML、shell 和测试通过只能证明提交内容满足当前发布契约；GHCR Package 权限、Runner
可用性、真实远端上传和服务器部署仍需由首次 GitHub Actions 运行证明。

## Browser Server 与 Web 发布

`make deploy-browser-server` 按 One Node Server 的流程校验源码、发布双架构镜像并部署。
每次 Server 部署都会将镜像内配套 Web 切换到 `/opt/one-browser/web/current`；失败时同时回滚 Server 和 Web。
`make deploy-browser-web` 只校验 Web、构建生产静态文件并通过 SSH 发布，失败回滚到上一目录，不构建或重启 Server。
Web 目录通过只读挂载提供给 Server，两个工作流共用部署锁。旧入口 `deploy-app-server` 保留为 Server 入口别名。

先执行一次新版 Server 部署以建立持久化 Web 挂载，再使用独立 Web 发布。
两条链使用 `one-browser-prod` environment，与 One Node Server 一样配置 `DEPLOY_HOST`、`DEPLOY_PORT`、
`DEPLOY_USER`、`DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS` secrets，以及源码/镜像凭据 `GH_TOKEN`。
`DEPLOY_REMOTE_DIR` 默认 `/opt/one-browser`，`DEPLOY_URL` 默认 `https://browser.aicbe.com`。
服务器目录应预先存在且包含生产 `.env`；反向代理指向本地 27514 端口。

## One Node Web 独立更新

`make deploy-node-web` 仅安装锁定的 Web 依赖、执行 lint 和生产构建（含 TypeScript 检查），
然后推送 `deploy/node-web/<version>` 标签触发 `node-web.yml`，上传静态文件并切换 `/opt/one-node/web/current`。
不编译后台、不发布后台镜像、不重启后台容器；健康检查失败时回滚 Web。
首次需先通过新版 `make deploy-node-server` 部署带持久化 Web 挂载的 Compose。
独立更新的 Web 在普通容器重启/重建后仍保留；再次发布 Server 时切换到新镜像配套 Web。
使用现有 `one-node-prod` environment 的 SSH secrets、`DEPLOY_REMOTE_DIR` 和 `DEPLOY_URL`，
默认目录 `/opt/one-node`，默认站点 `https://marseo.eu.org`；与 Server 发布共用部署锁。
`make validate-node-web` 检查此发布链，`make deploy-node-web DRY_RUN=true` 只显示计划。

Browser 与 Node 的 Web 均由后台在 `/` 路由提供，API 路由保持不变。
