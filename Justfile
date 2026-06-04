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
# Touch the .cabal first so a newly added .sql file is re-embedded (embedDir is a
# compile-time Template Haskell splice). CODD_MIGRATION_DIRS / CODD_EXPECTED_SCHEMA_DIR
# are read unconditionally by getCoddSettings even though we override migrations and
# skip verification, so we pass harmless placeholders.
migrate:
    touch shomei-migrations/shomei-migrations.cabal
    CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=shomei \
    cabal run shomei-migrate

# Scaffold a new migration: just new-migration name=add-something
new-migration name:
    @echo "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug: {{name}}"; exit 1; }
    @ts=$(date -u '+%Y-%m-%d-%H-%M-%S'); \
    f="shomei-migrations/sql-migrations/$ts-{{name}}.sql"; \
    if [ -e "$f" ]; then echo "Refusing to overwrite $f"; exit 1; fi; \
    printf -- '-- codd: in-txn\n\nSET search_path TO shomei, pg_catalog;\n\n' > "$f"; \
    echo "Wrote $f"
