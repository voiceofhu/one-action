# One Action

One Action 集中编译和上传发布产物。代码校验、格式、lint、测试和本地构建都在
`make deploy-*` 触发远端工作流之前完成；One Node Server 镜像发布成功后继续部署生产服务器。

当前只保留三条发布链：

| 本地入口 | Action 触发方式 | 发布结果 |
|---|---|---|
| `make deploy-user` | `user-v<version>` | `ghcr.io/voiceofhu/one-user:<version>` |
| `make deploy-node-server` | `node-server-v<version>` | `ghcr.io/voiceofhu/node-server:<version>`，随后部署该精确 OCI digest |
| `make deploy-node` | `one-node-v<version>` | `ghcr.io/voiceofhu/one-node:<version>`、双架构二进制、`SHA256SUMS` 和公开 One Action Release |

`deploy-user` 和 `deploy-node` 只触发编译上传；`deploy-node-server` 额外执行原有的
SSH/Compose 服务器部署。Browser、AMZ、Egress 和 App 的旧工作流不在活跃发布清单中。

## 发布边界

每次真实发布按固定顺序执行：

1. 确认 `one-action` 和源码仓库位于干净分支，origin 指向固定仓库；
2. 确认本地 `one-action/main` 与 `origin/main` 完全一致；
3. 本地运行 Action 契约检查以及对应产品的格式、lint、测试和构建；
4. One Node Server 要求本地 Backend/Web HEAD 已经与远端分支完全一致，把两个精确 SHA 写入 annotated Action 控制标签；其他产品仍按各自发布合同准备源码标签；
5. 推送当前 Action commit 上的产品触发标签；One Node Server 不再创建 Backend/Web `v*` 标签；
6. Action 只拉取固定源码、并行编译 amd64/arm64，并上传镜像或 Release 产物；
7. One Node Server 在镜像成功合并后，将 digest-qualified 镜像部署到 `one-node-prod`。

本地 Git 凭据用于 `git fetch/push`。发布入口不读取本机 `GH_TOKEN`；三条链路都使用 Action tag。One Node Server 的控制标签同时携带本地检查过的 Backend/Web SHA，Action 不读取可变的源码分支头。

## 使用

默认版本按上海时区生成三段数字，也可显式指定：

```bash
make deploy-user VERSION=26.821.1200
make deploy-node-server VERSION=26.821.1200
make deploy-node VERSION=26.821.1200
```

三个目标默认执行真实本地检查和 Action 标签推送；One Node Server 不再修改 Web 版本或推送源码标签。只查看计划时显式启用 dry-run；dry-run 不运行
产品检查、不修改文件、不创建标签，也不访问 GitHub API：

```bash
make deploy-user DRY_RUN=true
make deploy-node-server DRY_RUN=true
make deploy-node DRY_RUN=true
```

版本必须是无 `v` 前缀、无前导零的 `<major>.<minor>.<patch>`。

## 本地门禁

基础检查：

```bash
make validate
make node-check
make node-bundle-installers
```

`make validate` 检查活跃 shell、workflow YAML 和发布契约，并运行 One Node 生命周期 fixture。
真实 `deploy-*` 还会执行产品门禁：

- One User：Backend fmt/check/test/release build；Web frozen install、format、lint、test、build；
- One Node Server：Web frozen install/check/build；Backend model/test、vet、release build；
- One Node Runtime：安装器生命周期检查和完整 `verify-upgrade`。

任何本地门禁失败都会发生在源码 tag 和远程触发之前。

## Action 结构与时间上限

- One User / One Node Server：2 分钟源码解析；amd64 和 arm64 原生 runner 并行构建，
  每个最多 20 分钟；OCI index 合并最多 3 分钟。
- One Node Server 部署：镜像发布成功后运行，最多 20 分钟，同一时间只允许一个生产部署。
- One Node Runtime：2 分钟源码解析；两个架构并行编译和推送，每个最多 15 分钟；
  OCI index、checksum 和公开 One Action GitHub Release 上传最多 8 分钟。

Action 中没有 fmt、lint、test、race、e2e、installer lifecycle 或缓存上传。只有
One Node Server 保留 SSH/Compose 部署步骤。
不同版本可并行；相同产品、相同版本的重复触发由 concurrency group 串行保护。

## GitHub 配置

`one-action` 仓库需要配置 Repository Secret `GH_TOKEN`，用于：

- 读取固定的私有源码仓库；
- 向 `ghcr.io/voiceofhu/*` 推送架构镜像和 OCI index；
- 在 `voiceofhu/one-action@one-node-v<version>` 创建并上传公开 One Node Release。

One Node 的构建使用 `contents: read`；Release job 使用仓库 `GITHUB_TOKEN` 的 `contents: write`。

One Node Server 部署使用受保护的 `one-node-prod` environment，并需要：

- Secrets：`DEPLOY_HOST`、`DEPLOY_PORT`（可选，默认 `22`）、`DEPLOY_USER`、
  `DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS`；
- Variables：`DEPLOY_REMOTE_DIR`（默认 `/opt/one-node`）、`DEPLOY_URL`
  （默认 `https://marseo.eu.org`）。

部署 job 使用 `GH_TOKEN` 让服务器临时登录 GHCR，部署后始终尝试退出 Registry；服务器
Compose 文件来自同一 Server 源码 commit，部署脚本同时检查 `/api/healthz` 和首页。

## One Node 生命周期入口

稳定入口位于：

```text
node/install.sh
node/upgrade.sh
node/uninstall.sh
```

安装器未指定 `ONE_NODE_VERSION` 时会选择 `one-action` 仓库最新的 `one-node-v<version>` Release；显式设置版本
可固定安装或回滚。完整参数和生命周期约束见 [node/README.md](node/README.md)。

## 目录

```text
.github/workflows/   三个产品入口和一个 Web+Backend 复用发布工作流
node/                One Node 安装、升级、卸载和本地 fixture
scripts/release/     本地发布入口与上传辅助脚本
scripts/deploy/      One Node Server SSH、Registry 和 Compose 部署脚本
scripts/github/      GitHub 只读检查和历史调度辅助代码
tests/               当前三条发布链的本地契约测试
make/                Makefile 子模块
```

本地 YAML、shell 和测试通过只能证明提交内容满足当前发布契约；GHCR Package 权限、Runner
可用性、真实远端上传和服务器部署仍需由首次 GitHub Actions 运行证明。
