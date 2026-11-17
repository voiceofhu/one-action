# Every product ships a Server and a Web; three also ship a desktop App (pc).
# A new product of the same shape only needs its key added here.
SERVER_PRODUCTS := amz browser ip mail node notify object pay template user vps
APP_PRODUCTS := browser mail node

DEPLOY_SERVER_TARGETS := $(SERVER_PRODUCTS:%=deploy-%-server)
DEPLOY_WEB_TARGETS := $(SERVER_PRODUCTS:%=deploy-%-web)
DEPLOY_APP_TARGETS := $(APP_PRODUCTS:%=deploy-%-pc)

.PHONY: $(DEPLOY_SERVER_TARGETS) $(DEPLOY_WEB_TARGETS) $(DEPLOY_APP_TARGETS)
.PHONY: deploy-node deploy-browser-runtime deploy-servers deploy-webs

$(DEPLOY_SERVER_TARGETS): deploy-%-server:
	@DRY_RUN="$(DEPLOY_DRY_RUN)" VERSION="$(RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh $*

$(DEPLOY_WEB_TARGETS): deploy-%-web:
	@DRY_RUN="$(DEPLOY_DRY_RUN)" VERSION="$(RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh $*

$(DEPLOY_APP_TARGETS): deploy-%-pc:
	@DRY_RUN="$(DEPLOY_DRY_RUN)" VERSION="$(RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-app.sh $*

# One Node agent (runtime) release.
deploy-node:
	@DRY_RUN="$(DEPLOY_DRY_RUN)" VERSION="$(RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-node-release.sh

# Chromium runtime prebuilt by the chromium repository's `make release`:
#   make deploy-browser-runtime VERSION=<v> CHROMIUM_REF=<40-hex sha> [DRY_RUN=true]
deploy-browser-runtime:
	@DRY_RUN="$(DEPLOY_DRY_RUN)" VERSION="$(BROWSER_RUNTIME_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-browser-runtime.sh

# Batch deploys: `make deploy-servers` (all) or `make deploy-servers PRODUCTS="user mail"`.
deploy-servers:
	@KIND=server DRY_RUN="$(DEPLOY_DRY_RUN)" \
		VERSION="$(VERSION)" bash $(PROJECT_ROOT)/scripts/release/deploy-many.sh $(PRODUCTS)
deploy-webs:
	@KIND=web DRY_RUN="$(DEPLOY_DRY_RUN)" \
		VERSION="$(VERSION)" bash $(PROJECT_ROOT)/scripts/release/deploy-many.sh $(PRODUCTS)
