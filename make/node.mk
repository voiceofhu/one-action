.PHONY: node-check node-bundle-installers

node-check:
	@sh $(PROJECT_ROOT)/node/tests/scripts_test.sh
	@sh $(PROJECT_ROOT)/node/tests/firewall_test.sh
	@sh $(PROJECT_ROOT)/node/tests/latest_release_test.sh
	@sh $(PROJECT_ROOT)/node/tests/readiness_test.sh
	@sh $(PROJECT_ROOT)/node/tests/manager_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reset_test.sh
	@sh $(PROJECT_ROOT)/node/tests/native_recovery_test.sh
	@sh $(PROJECT_ROOT)/node/tests/updater_test.sh
	@sh $(PROJECT_ROOT)/node/tests/hardening_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reinstall_rollback_test.sh
	@sh $(PROJECT_ROOT)/node/tests/signing_test.sh
	@sh $(PROJECT_ROOT)/node/tests/tuning_test.sh
	@sh $(PROJECT_ROOT)/node/tests/firewall_host_rules_test.sh
	@sh $(PROJECT_ROOT)/node/tests/install_ps1_test.sh
	@sh $(PROJECT_ROOT)/node/tests/install_dir_test.sh

NODE_INSTALLER_DIST ?= $(PROJECT_ROOT)/node/dist

node-bundle-installers:
	@sh $(PROJECT_ROOT)/node/scripts/bundle-dev-installers.sh "$(NODE_INSTALLER_DIST)"
