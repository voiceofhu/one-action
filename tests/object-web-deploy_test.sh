#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname -- "${BASH_SOURCE[0]}")/object-web-deploy_test.py"
