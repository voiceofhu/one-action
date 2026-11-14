.PHONY: deploy-notify-server deploy-notify-web

deploy-notify-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-notify-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NOTIFY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh notify

deploy-notify-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-notify-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NOTIFY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh notify
