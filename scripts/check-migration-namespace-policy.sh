#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
manifest=${1:-"$repo_root/shomei-migrations/migrations/shomei/manifest"}
migrations_dir=$(dirname -- "$manifest")
canonical_header='SET LOCAL search_path = pg_catalog, pg_temp;'
failed=0

report_failure() {
  printf 'migration namespace policy: %s: %s\n' "$1" "$2" >&2
  failed=1
}

while IFS= read -r migration_name || [[ -n "$migration_name" ]]; do
  [[ -n "$migration_name" ]] || continue
  migration_path="$migrations_dir/$migration_name"

  if [[ ! -f "$migration_path" ]]; then
    report_failure "$migration_path" 'manifest entry does not name a readable file'
    continue
  fi

  if grep -Eq '^[[:space:]]*--[[:space:]]*pg-migrate: no-transaction[[:space:]]*$' "$migration_path"; then
    if grep -Eiq '^[[:space:]]*SET([[:space:]]+LOCAL)?[[:space:]]+search_path' "$migration_path"; then
      report_failure "$migration_path" 'nontransactional migrations must not mutate search_path'
    fi
  else
    header_count=$(grep -Fxc "$canonical_header" "$migration_path" || true)
    if [[ "$header_count" -ne 1 ]]; then
      report_failure "$migration_path" "transactional migration must contain exactly one '$canonical_header' header"
    fi

    if grep -Fvx "$canonical_header" "$migration_path" \
      | grep -Eiq '^[[:space:]]*SET([[:space:]]+LOCAL)?[[:space:]]+search_path'; then
      report_failure "$migration_path" 'only the canonical transaction-local search_path header is allowed'
    fi
  fi

  if sed 's/--.*$//' "$migration_path" \
    | grep -Eiq '(^|[^[:alnum:]_.])(CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?|ALTER[[:space:]]+TABLE|UPDATE|INSERT[[:space:]]+INTO|DELETE[[:space:]]+FROM|FROM|JOIN|REFERENCES|ON|DROP[[:space:]]+INDEX([[:space:]]+IF[[:space:]]+EXISTS)?)[[:space:]]+shomei_[[:alnum:]_]+'; then
    report_failure "$migration_path" 'Shomei relation or index targets must use the shomei schema qualifier'
  fi
done <"$manifest"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

printf 'migration namespace policy: checked %s\n' "$manifest"
