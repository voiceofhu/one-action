SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/user.mk
include $(PROJECT_ROOT)/make/node.mk

.PHONY: help
help:
	@printf '%s\n' \
		"One Action" \
		"" \
		"Local checks:" \
		"  make validate               Validate active shell and workflow contracts locally" \
		"  make node-check             Test the One Node lifecycle locally" \
		"  make node-bundle-installers Build local One Node installer snapshots" \
		"  make check-token            Check read-only access to active workflows" \
		"" \
		"Tag-triggered releases:" \
		"  make deploy-user            Tag One User sources for compile and upload" \
		"  make deploy-node-server     Compile, upload, and deploy One Node Server" \
		"  make deploy-node            Tag One Node source for compile and upload"
