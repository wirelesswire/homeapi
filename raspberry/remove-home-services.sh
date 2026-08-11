#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${BASE_DIR:-${HOME}/home-services}"
exec "${BASE_DIR}/home-services.sh" uninstall
