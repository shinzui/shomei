#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cabal build exe:shomei-server
SHOMEI_TEST_SERVER_BIN=$(cabal list-bin exe:shomei-server)
export SHOMEI_TEST_SERVER_BIN
TASTY_NUM_THREADS=1 cabal test shomei-server:shomei-server-test \
  --test-options='-p /packaged/' --test-show-details=direct -j1
