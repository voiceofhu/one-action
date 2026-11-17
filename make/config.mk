# Deploy targets publish unless DRY_RUN was given, either on the command line
# (`make deploy-x DRY_RUN=true`) or in the environment (`DRY_RUN=true make deploy-x`).
# Captured before the default below, so the origin still says who set it.
DEPLOY_DRY_RUN := $(if $(filter environment command,$(origin DRY_RUN)),$(DRY_RUN),false)
DRY_RUN ?= true

SOURCE_ROOT ?= $(abspath $(PROJECT_ROOT)/..)
GENERATED_VERSION ?= $(shell node -e "\
  const d=new Date(new Date().toLocaleString('en-US',{timeZone:'Asia/Shanghai'}));\
  const strip=value=>String(Number(value));\
  const year=String(d.getFullYear()).slice(-2);\
  const monthDay=String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');\
  const hourMinute=String(d.getHours()).padStart(2,'0')+String(d.getMinutes()).padStart(2,'0');\
  process.stdout.write([year,monthDay,hourMinute].map(strip).join('.'));\
")
# Every release uses VERSION when given, else the generated timestamp version.
RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

ONE_BROWSER_APP_REF ?= main
ONE_BROWSER_APP_DIR ?= $(SOURCE_ROOT)/one-browser/pc
# No generated default: the runtime version names an existing staging release.
BROWSER_RUNTIME_VERSION = $(patsubst v%,%,$(strip $(VERSION)))
CHROMIUM_REF ?=

ONE_NODE_REPOSITORY ?= voiceofhu/one-node-node
ONE_NODE_REF ?= main
ONE_NODE_DIR ?= $(SOURCE_ROOT)/one-node/node

VERSION ?=
ENVIRONMENT ?= dev
PUBLISH ?= false
DEPLOY ?= false

ENV_FILE ?= $(PROJECT_ROOT)/.env
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

# Export values so recipes expand them inside quoted shell parameters rather
# than interpolating untrusted Make values into recipe source.
export DRY_RUN
export GENERATED_VERSION
export ONE_BROWSER_APP_REF
export ONE_BROWSER_APP_DIR
export CHROMIUM_REF
export ONE_NODE_REPOSITORY ONE_NODE_REF
export ONE_NODE_DIR
export VERSION ENVIRONMENT PUBLISH DEPLOY
