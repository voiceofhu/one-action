.PHONY: deploy-pay-server deploy-pay-web

deploy-pay-server: DRY_RUN = false
deploy-pay-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(PAY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-pay-release.sh

deploy-pay-web: DRY_RUN = false
deploy-pay-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(PAY_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-pay-web-release.sh
