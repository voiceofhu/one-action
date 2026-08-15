# One Action

`one-action` 是 One 系列产品统一的构建、验证、发布和公开下载仓库。

它主要提供三类能力：

- 通过本地 Make 命令安全地触发 GitHub Actions；
- 发布后端 GHCR 镜像和 Browser Egress Release；
- 提供 Browser Egress 与 One Node 的安装、升级和卸载脚本。

所有 GitHub Actions 调度默认都是 `DRY_RUN=true`：只解析分支或标签对应的精确
commit SHA、打印请求内容，不会发起工作流。真实调度和发布必须显式确认。

## 目录结构

```text
.github/workflows/   GitHub Actions 入口和可复用工作流
browser/egress/      Browser Egress 安装、卸载和本地测试
node/                One Node 安装、升级、卸载和本地测试
scripts/github/      GitHub ref 解析、token 检查和工作流调度
scripts/release/     checksum、GHCR 和 Egress Release 发布脚本
tests/               跨产品工作流契约测试
make/                Makefile 子模块
```

仓库根目录没有通用的 `install.sh` 或 `uninstall.sh`。请始终使用产品命名空间下的
脚本，避免把 Egress 和 Node 的生命周期混在一起。

## 1. 本地检查

进入仓库：

```bash
cd one-action
make help
```

常用检查命令：

```bash
# 检查 shell、workflow YAML 和全部契约测试
make validate

# 只测试 Browser Egress 安装器（使用本地 fixture，不访问网络）
make egress-installer-test

# 测试 One Node 安装、重配、重置和故障恢复
make node-check

# 在 node/dist 生成本地 Node 安装器快照
make node-bundle-installers
```

`make validate` 需要 Bash、ShellCheck、Ruby、Make 和项目测试所使用的基础命令。
GitHub 调度相关命令还需要 `curl`、`jq` 和可读取目标仓库的 `GH_TOKEN`。

## 2. 配置 GitHub 访问

推荐只在当前 shell 中设置 token：

```bash
export GH_TOKEN=github_pat_xxx
make check-token
```

`make check-token` 只读取当前 GitHub 用户、Action 仓库和工作流信息，不会触发
工作流。不要给 token 加额外引号，也不要把真实 token 提交到仓库。

也可以在仓库根目录创建未跟踪的 `.env`：

```dotenv
GH_TOKEN=github_pat_xxx
```

如需使用其他环境文件，可传入 `ENV_FILE`：

```bash
make check-token ENV_FILE=/absolute/path/to/one-action.env
```

## 3. 预览工作流调度

先运行 dry-run。下面的命令会访问 GitHub API，把 Action 和源码 ref 解析为精确的
40 位 commit SHA，然后打印最终 payload，但不会发送 POST 请求：

```bash
make dispatch-one-user
make dispatch-one-browser-backend
make dispatch-app
make dispatch-app-debug
make dispatch-egress
make dispatch-one-amz
make dispatch-node
```

默认源码 ref 是 `main`。可以按产品覆盖分支、标签或 commit：

```bash
make dispatch-one-user \
  ACTION_REF=main \
  ONE_USER_BACKEND_REF=feature/example \
  ONE_USER_WEB_REF=v1.2.3 \
  ENVIRONMENT=stage
```

dry-run 输出会包含两项重要信息：

```text
Workflow: voiceofhu/one-action@main -> <action-sha>
Real dispatch confirmation: dispatch:user.yml:<action-sha>
```

请检查打印出的仓库、精确 SHA、环境和其他输入，再决定是否真实执行。

## 4. 触发一次构建验证

将 dry-run 输出的确认字符串原样传给 `CONFIRM_DISPATCH`：

```bash
make dispatch-one-user \
  DRY_RUN=false \
  CONFIRM_DISPATCH='dispatch:user.yml:<action-sha>'
```

这只触发构建验证，不发布镜像，也不部署。其他工作流使用对应文件名，例如：

```bash
make dispatch-egress \
  DRY_RUN=false \
  CONFIRM_DISPATCH='dispatch:egress.yml:<action-sha>'
```

如果 Action 的 `main` 在 dry-run 后发生变化，确认字符串将失效。重新执行 dry-run，
检查新的 SHA 后再调度；不要用可变 ref 绕过确认。

## 5. 发布产物

目前只有以下发布路径可用：

| Make 目标 | 发布结果 | 额外要求 |
|---|---|---|
| `dispatch-one-user` | 固定包名的 GHCR 镜像 | `VERSION`，受保护的 `ghcr-publish` environment |
| `dispatch-one-amz` | 固定包名的 GHCR 镜像 | `VERSION`，受保护的 `ghcr-publish` environment |
| `dispatch-one-browser-backend` | 固定包名的 GHCR 镜像 | `VERSION`，受保护的 `ghcr-publish` environment |
| `dispatch-egress` | Native 产物、checksum、manifest 和多架构 GHCR 镜像 | `VERSION`、`ENVIRONMENT=prod`、受保护的 `public-release` environment |

发布需要两个互相独立的确认字符串。仍然先 dry-run：

```bash
make dispatch-one-user \
  PUBLISH=true \
  VERSION=1.2.3 \
  ENVIRONMENT=prod
```

检查输出后，再使用同一组参数真实执行：

```bash
make dispatch-one-user \
  PUBLISH=true \
  VERSION=1.2.3 \
  ENVIRONMENT=prod \
  DRY_RUN=false \
  CONFIRM_DISPATCH='dispatch:user.yml:<action-sha>' \
  CONFIRM_MUTATION='mutate:user.yml:<action-sha>'
```

发布 Egress：

```bash
make dispatch-egress \
  PUBLISH=true \
  VERSION=1.2.3 \
  ENVIRONMENT=prod

make dispatch-egress \
  PUBLISH=true \
  VERSION=1.2.3 \
  ENVIRONMENT=prod \
  DRY_RUN=false \
  CONFIRM_DISPATCH='dispatch:egress.yml:<action-sha>' \
  CONFIRM_MUTATION='mutate:egress.yml:<action-sha>'
```

版本必须是没有 `v` 前缀的三段数字，例如 `1.2.3`。发布确认只用于防止操作失误，
不能替代 GitHub environment 审批、仓库权限和最小化 secret 配置。

发布器不会创建或覆盖 `latest`。后端消费者应使用工作流回读得到的
`ghcr.io/...@sha256:<digest>`，不要依赖可变 tag。

## 6. 部署 One User 前后端

One User Web 会先编译进 Backend Docker 镜像。发布结果是同时包含 `linux/amd64` 和
`linux/arm64` 的精确 OCI index digest，每个平台镜像都包含同一份用户中心前端。
`make deploy-user` 负责在本地更新并发布源码版本；最后 push `one-action` 的
`user-v<version>` 控制 tag。该 tag 触发 `.github/workflows/user.yml`，工作流从 tag
提取版本并使用 Repository Secrets，依次完成：

1. 解析 Action、Backend 和 Web 的精确 commit SHA；
2. 只构建和验证一次 Web，并将同一份 `web-dist` 交给两个后端构建任务；
3. 在 `ubuntu-latest` 原生 amd64 runner 构建并上传 `linux/amd64` 镜像；
4. 在 `ubuntu-24.04-arm` 原生 arm64 runner 构建并上传 `linux/arm64` 镜像；
5. 合并两个平台镜像为 `ghcr.io/voiceofhu/one-user-backend-next` 的 OCI index，回读并
   锁定 index digest；
6. 通过 SSH 让服务器按自身架构拉取该 index digest、更新 Compose 服务并检查
   `/readyz`。

两个后端镜像都在对应架构的原生 runner 上构建，不安装或使用 QEMU。只有 OCI index
合并完成并确认同时包含 amd64、arm64 后，部署任务才会获得 digest 并连接服务器。

版本获取方式与旧 `one-browser-action` 保持一致：默认按上海时区生成
`YY.MDD.HHmm` 三段数字，并去掉每段前导零，例如：

```text
2026-08-15 09:30 Asia/Shanghai -> 26.815.930
```

默认直接执行真实发布和部署，不需要手动填写版本：

```bash
make deploy-user
```

如需先预览，显式启用 dry-run：

```bash
make deploy-user DRY_RUN=true
```

dry-run 会打印生成的版本、两个本地源码仓库和将要创建的三个 tag，不访问 GitHub
API，也不要求本机提供 `GH_TOKEN` 或 `CONFIRM_*`；它不会修改源码、创建 tag、push、
触发 Action 或部署。

默认真实执行同样不需要本机 `GH_TOKEN` 或确认字符串，并按以下流程发布：

1. 要求本地 `one-action` 位于干净的 `main`，且 HEAD 与 `origin/main` 完全一致；
2. 要求本地 `../one-user/backend` 和 `../one-user/web` 均处于干净分支；
3. 确认 origin 分别是 `voiceofhu/one-user-backend` 和 `voiceofhu/one-user-web`；
4. 将 Backend `Cargo.toml`、`Cargo.lock` 与 Web `package.json` 更新为同一版本；
5. 两个仓库分别创建版本 commit 和同名 `v<version>` tag，并原子 push 分支与 tag；
6. 在当前 `one-action` commit 创建并 push `user-v<version>` 控制 tag；
7. `user.yml` 从控制 tag 提取版本，使用 `secrets.GH_TOKEN` 解析两个
   `v<version>` 源码 tag，然后构建并部署精确版本。

本地发布只使用各仓库已有的 Git 凭据进行 push，`deploy-user` 不读取环境变量或
`.env` 中的 `GH_TOKEN`。部署所需的 `GH_TOKEN` 只保存在 `one-action` 的 GitHub
Repository Secrets 中，供 runner 读取私有源码以及让服务器临时登录 GHCR。

如需固定版本，可在预览和真实执行时都显式传入，例如
`VERSION=26.815.930`。版本必须是没有 `v` 前缀、没有前导零的三段数字。该目标固定
使用 `ENVIRONMENT=prod`、`PUBLISH=true` 和 `DEPLOY=true`，不能部署未发布或非生产镜像。

GitHub 中需要建立受保护的 `one-user-prod` environment，并在 `one-action` 仓库的
Actions Secrets and variables 中配置：

| 类型 | 名称 | 说明 |
|---|---|---|
| Secret | `GH_TOKEN` | runner 读取 Backend/Web 私有仓库，并让服务器临时读取 GHCR |
| Secret | `DEPLOY_USER` | SSH 用户，例如 `gh-deploy` |
| Secret | `DEPLOY_SSH_KEY` | SSH 私钥 |
| Secret | `DEPLOY_KNOWN_HOSTS` | 已核验的服务器 host key，禁止运行时信任未知主机 |
| Secret | `DEPLOY_HOST` | 服务器域名或 IP，例如 `98.65.67.83`，不要包含端口 |
| Secret | `DEPLOY_PORT` | SSH 端口，可选；未设置时使用 `22` |
| Variable | `DEPLOY_REMOTE_DIR` | 部署目录，默认 `/opt/one-user` |
| Variable | `DEPLOY_COMPOSE_SERVICE` | Compose 服务名，默认 `user` |
| Variable | `DEPLOY_READY_URL` | 服务器本机 readiness URL，默认 `http://127.0.0.1:27510/readyz` |
| Variable | `DEPLOY_USE_SUDO` | Docker 是否使用免密 sudo：`0` 或 `1`，默认 `0` |
| Variable | `DEPLOY_URL` | environment 页面展示的生产 URL，可选 |

服务器需要预先准备 `/opt/one-user/.env` 和
`/opt/one-user/docker-compose.yml`。Compose 中的目标服务必须使用：

```yaml
services:
  user:
    image: ${ONE_USER_IMAGE:?ONE_USER_IMAGE is required}
    env_file:
      - .env
```

数据库、OIDC 私钥、OAuth secret 和其他运行时配置由服务器拥有。工作流不会上传、
覆盖、回传或打印 `.env`；它只原子更新权限为 `0600` 的 `.one-user-image.env`，其中
记录已发布的精确 image digest。生产数据库必须在部署前已满足当前只读 Schema
Contract，服务启动不会自动迁移数据库。

## 7. Browser Egress 安装与卸载

Egress 支持 Linux amd64/arm64 的 `native` 和 `docker` 模式。安装前，运维人员需要
准备 `/etc/one-browser-egress/egress.env`。允许的配置键为：

```dotenv
EGRESS_ID=...
EGRESS_BIND_ADDR=...
EGRESS_CONTROL_URL=...
EGRESS_CONTROL_TOKEN=...
EGRESS_HEARTBEAT_INTERVAL_SECONDS=...
EGRESS_SHUTDOWN_GRACE_SECONDS=...
```

先预览安装计划。dry-run 不访问网络，也不修改主机：

```bash
DRY_RUN=true ./browser/egress/install.sh \
  --mode native \
  --version 1.2.3
```

确认版本和模式后真实安装：

```bash
sudo env DRY_RUN=false ./browser/egress/install.sh \
  --mode native \
  --version 1.2.3 \
  --confirm install:native:1.2.3
```

Docker 模式将两处 `native` 改为 `docker`。`--version` 为必填项，不接受
`latest`；安装器只接受 `voiceofhu/one-action` 中不可变的
`egress-v<version>` Release 和 manifest 指定的精确镜像 digest。

卸载前同样先 dry-run：

```bash
DRY_RUN=true ./browser/egress/uninstall.sh --mode native

sudo env DRY_RUN=false ./browser/egress/uninstall.sh \
  --mode native \
  --confirm uninstall:native
```

默认卸载会保留 `/etc/one-browser-egress` 和 `/var/lib/one-browser-egress`。
只有明确使用 `--purge` 和对应确认字符串时才删除这两个目录：

```bash
sudo env DRY_RUN=false ./browser/egress/uninstall.sh \
  --mode native \
  --purge \
  --confirm purge:native
```

## 8. One Node 生命周期

One Node 的稳定入口位于：

```text
node/install.sh
node/upgrade.sh
node/uninstall.sh
```

安装需要由控制面提供节点 ID、bootstrap token、目标版本和版本对应的不可变产物
信息。Native 示例：

```bash
sudo env \
  ONE_NODE_SERVER='https://server.example.com' \
  ONE_NODE_ID='123' \
  ONE_NODE_BOOTSTRAP_TOKEN='replace-me' \
  ONE_NODE_VERSION='1.2.3' \
  ONE_NODE_BINARY_SHA256_AMD64='<64-hex-sha256>' \
  ONE_NODE_BINARY_SHA256_ARM64='<64-hex-sha256>' \
  ./node/install.sh --mode native
```

Docker 模式使用精确 digest：

```bash
sudo env \
  ONE_NODE_SERVER='https://server.example.com' \
  ONE_NODE_ID='123' \
  ONE_NODE_BOOTSTRAP_TOKEN='replace-me' \
  ONE_NODE_VERSION='1.2.3' \
  ONE_NODE_DOCKER_IMAGE='ghcr.io/voiceofhu/one-node@sha256:<64-hex-digest>' \
  ./node/install.sh --mode docker
```

升级时传入新版本及其 checksum 或镜像 digest：

```bash
sudo env \
  ONE_NODE_VERSION='1.2.4' \
  ONE_NODE_RELEASE_BASE_URL='https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.4' \
  ONE_NODE_BINARY_SHA256_AMD64='<64-hex-sha256>' \
  ONE_NODE_BINARY_SHA256_ARM64='<64-hex-sha256>' \
  ./node/upgrade.sh

sudo ./node/upgrade.sh --rollback
sudo ./node/uninstall.sh
```

卸载会保留预先存在的凭据和运行状态。完整的远程 commit 固定调用方式、重配、
开发重置和生命周期约束见 [node/README.md](node/README.md)。

## 当前限制

- `dispatch-browser-runtime` 当前会直接失败，因为 Runtime 源仓库信任根尚未确定；
- `dispatch-node` 只支持精确源码的构建与测试，不支持发布或部署；
- App 和 App Debug 只做构建验证，不支持签名、发布或 artifact 上传；
- 只有 `deploy-user` 支持服务器部署，其他工作流仍拒绝 `DEPLOY=true`；
- Egress 以外的公开 App/Runtime Release 尚未实现；
- 本仓库代码本身不能证明远端 protected environment、审批人、权限或 secret 已正确配置。

仓库当前状态不代表远端 Package、Release 或部署已经存在。首次发布后必须在 GitHub
和 GHCR 回读 tag、asset、checksum 与 digest，才能把它们视为可供生产使用的证据。
