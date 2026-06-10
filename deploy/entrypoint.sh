#!/usr/bin/env sh
# Container entrypoint (EP-5): run migrations and ensure an active signing key via the
# shomei-admin CLI (the EP-5 -> EP-4 hard dependency), then exec the server so SIGTERM from
# `docker stop` reaches it for graceful shutdown.
set -eu

echo "[entrypoint] applying migrations"
shomei-admin migrate

if shomei-admin keys list | grep -q KeyActive; then
  echo "[entrypoint] an active signing key already exists"
else
  echo "[entrypoint] no active key; generating and activating one"
  kid="$(shomei-admin keys generate | sed 's/.*key: //')"
  shomei-admin keys activate "$kid"
fi

echo "[entrypoint] starting shomei-server"
exec shomei-server
