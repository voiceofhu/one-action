.PHONY: node-check node-bundle-installers deploy-node-server deploy-node

node-check:
	@sh $(PROJECT_ROOT)/node/tests/scripts_test.sh
	@sh $(PROJECT_ROOT)/node/tests/firewall_test.sh
	@sh $(PROJECT_ROOT)/node/tests/latest_release_test.sh
	@sh $(PROJECT_ROOT)/node/tests/readiness_test.sh
	@sh $(PROJECT_ROOT)/node/tests/manager_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reconfigure_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reset_test.sh
	@sh $(PROJECT_ROOT)/node/tests/native_recovery_test.sh
	@sh $(PROJECT_ROOT)/node/tests/updater_test.sh

NODE_INSTALLER_DIST ?= $(PROJECT_ROOT)/node/dist

node-bundle-installers:
	@sh $(PROJECT_ROOT)/node/scripts/bundle-dev-installers.sh "$(NODE_INSTALLER_DIST)"

deploy-node-server: DRY_RUN = false
deploy-node-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NODE_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-node-server-release.sh

deploy-node: DRY_RUN = false
deploy-node:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(NODE_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-node-release.sh
