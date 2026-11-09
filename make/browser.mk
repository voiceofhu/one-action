.PHONY: deploy-browser-pc deploy-app-server

deploy-browser-pc: DRY_RUN = false
deploy-browser-pc:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-app.sh browser

.PHONY: deploy-browser-server deploy-browser-web
deploy-app-server: deploy-browser-server

deploy-browser-web: DRY_RUN = false
deploy-browser-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh browser

deploy-browser-server: DRY_RUN = false
deploy-browser-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh browser

# Chromium runtime prebuilt by the chromium repository's `make release`:
#   make deploy-browser-runtime VERSION=<v> CHROMIUM_REF=<40-hex sha> [DRY_RUN=true]
.PHONY: deploy-browser-runtime
deploy-browser-runtime: DRY_RUN = false
deploy-browser-runtime:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_RUNTIME_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-browser-runtime.sh
