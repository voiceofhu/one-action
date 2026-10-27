.PHONY: deploy-browser-app deploy-app-server

deploy-browser-app: DRY_RUN = false
deploy-browser-app:
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
