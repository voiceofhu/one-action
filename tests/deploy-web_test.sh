#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname -- "${BASH_SOURCE[0]}")/deploy-web_test.py"
