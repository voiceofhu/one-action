# `make validate` checks everything; `make validate-<scope>` one release contract.
VALIDATE_SCOPES := $(SERVER_PRODUCTS) $(SERVER_PRODUCTS:%=%-web) $(APP_PRODUCTS:%=%-pc) node-runtime browser-runtime
VALIDATE_TARGETS := $(VALIDATE_SCOPES:%=validate-%)

.PHONY: validate $(VALIDATE_TARGETS)

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

$(VALIDATE_TARGETS): validate-%:
	@bash $(PROJECT_ROOT)/scripts/validate.sh $*
