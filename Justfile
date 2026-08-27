# Justfile — Shōmei project recipes.

# Build all packages in the cabal workspace.
build:
    cabal build all

# Create the dev database if it does not exist, then migrate it. Idempotent.
# Called by process-compose.yaml via: create_schema: command: just create-database
create-database:
    @if [ -z "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'")" ]; then \
        createdb "$PGDATABASE"; \
        echo "Created database $PGDATABASE"; \
    else \
        echo "Database $PGDATABASE already exists"; \
    fi
    just migrate

# Apply all embedded migrations to $PGDATABASE via the shomei-migrate executable.
# Idempotent: already-applied migrations are reported and skipped.
migrate:
    DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 shomei-migrate -- up

# Show which migrations are applied and which are pending, without changing anything.
migration-status:
    DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 shomei-migrate -- status

# Validate the manifest against the SQL files on disk (syntax, membership, checksums).
migration-check:
    cabal run -v0 shomei-migrate -- check --manifest shomei-migrations/migrations/shomei/manifest

# The slug is positional: `just new-migration name=x` passes "name=x" AS the slug and is rejected.
# `shomei-migrate new` creates the .sql file and appends it to the manifest in one step, so
# there is no separate "remember to wire it in" action. Rebuild afterwards to re-embed it.

# Scaffold a new migration: just new-migration add-something
new-migration name:
    @echo "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug: {{name}}"; exit 1; }
    @next=$(printf '%04d' $(( $(sed -n '$p' shomei-migrations/migrations/shomei/manifest | cut -c1-4 | sed 's/^0*//') + 1 ))); \
    cabal run -v0 shomei-migrate -- new \
      --manifest shomei-migrations/migrations/shomei/manifest \
      --name "$next-{{name}}" \
      --description "{{name}}"

# Strictly enforce the shared assurance.reviews profile and its update log.
reviews-validate:
    okf validate docs/reviews --strict --profile docs/reviews/profile.dhall --profile-enforce --log-enforce

# Strictly enforce the shared architecture-decisions profile and its update log.
adr-validate:
    okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
