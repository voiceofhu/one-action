.PHONY: deploy-vps-server deploy-vps-web

deploy-vps-server: DRY_RUN = false
deploy-vps-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(VPS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-vps-release.sh

deploy-vps-web: DRY_RUN = false
deploy-vps-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(VPS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-vps-web-release.sh
