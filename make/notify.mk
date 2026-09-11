.PHONY: deploy-notify-server deploy-notify-web

deploy-notify-server: DRY_RUN = false
deploy-notify-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NOTIFY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-notify-release.sh

deploy-notify-web: DRY_RUN = false
deploy-notify-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NOTIFY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-notify-web-release.sh
