.PHONY: deploy-app deploy-app-server deploy-app-egress

deploy-app: DRY_RUN = false
deploy-app:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-release.sh

deploy-app-server: DRY_RUN = false
deploy-app-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_SERVER_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-server-release.sh

deploy-app-egress: DRY_RUN = false
deploy-app-egress:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(BROWSER_APP_EGRESS_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-browser-app-egress-release.sh
