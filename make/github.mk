.PHONY: validate validate-node-server check-token

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

validate-node-server:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node-server

check-token:
	@bash $(PROJECT_ROOT)/scripts/github/check-token.sh
