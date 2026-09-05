.PHONY: deploy-browser-app deploy-app-server deploy-browser-egress

deploy-browser-app: DRY_RUN = false
deploy-browser-app:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-release.sh

deploy-app-server: DRY_RUN = false
deploy-app-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_SERVER_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-server-release.sh

deploy-browser-egress: DRY_RUN = false
deploy-browser-egress:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_EGRESS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-egress-release.sh
