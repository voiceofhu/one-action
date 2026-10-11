.PHONY: deploy-mail-server deploy-mail-web

deploy-mail-server: DRY_RUN = false
deploy-mail-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(MAIL_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh mail

deploy-mail-web: DRY_RUN = false
deploy-mail-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(MAIL_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh mail
