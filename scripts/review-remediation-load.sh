#!/usr/bin/env sh
# MasterPlan 9 acceptance: provision an ephemeral DB and internal loopback listener.
# No external base URL or deployment database is accepted. All JSON fields are numeric,
# static labels or aggregate configuration; credentials remain in the fixture process.
set -eu
scenario=all
output=/tmp/shomei-review-load.json
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) [ "$#" -ge 2 ] || exit 2; scenario="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || exit 2; output="$2"; shift 2 ;;
    *) echo 'Only --scenario and --output are accepted; external targets are refused.' >&2; exit 2 ;;
  esac
done
case "$scenario" in all|sessions|openapi|argon2) : ;; *) echo 'Unknown bounded workload scenario.' >&2; exit 2 ;; esac
[ -n "$output" ] || exit 2
repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_dir"
cabal run -v0 -freview-load shomei-review-load -- --scenario "$scenario" --output "$output" +RTS -N2 --nonmoving-gc -RTS
printf 'Wrote redacted isolated workload report: %s\n' "$output"
