.PHONY: node-check node-bundle-installers dispatch-node

node-check:
	@sh $(PROJECT_ROOT)/node/tests/scripts_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reconfigure_test.sh
	@sh $(PROJECT_ROOT)/node/tests/reset_test.sh
	@sh $(PROJECT_ROOT)/node/tests/native_recovery_test.sh

NODE_INSTALLER_DIST ?= $(PROJECT_ROOT)/node/dist

node-bundle-installers:
	@sh $(PROJECT_ROOT)/node/scripts/bundle-dev-installers.sh "$(NODE_INSTALLER_DIST)"

dispatch-node:
	@bash $(PROJECT_ROOT)/scripts/github/dispatch-workflow.sh node.yml \
		node_repository="$${ONE_NODE_REPOSITORY}" \
		node_ref="$${ONE_NODE_REF}" version="$${VERSION}" \
		publish="$${PUBLISH}" deploy="$${DEPLOY}"
