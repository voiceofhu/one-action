.PHONY: deploy-browser-app deploy-app-server deploy-browser-egress

deploy-browser-app: DRY_RUN = false
deploy-browser-app:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-release.sh

.PHONY: deploy-browser-server deploy-browser-web
deploy-app-server: deploy-browser-server

deploy-browser-web: DRY_RUN = false
deploy-browser-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_SERVER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-web-release.sh

deploy-browser-server: DRY_RUN = false
deploy-browser-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_SERVER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-server-release.sh

deploy-browser-egress: DRY_RUN = false
deploy-browser-egress:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_EGRESS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-egress-release.sh
