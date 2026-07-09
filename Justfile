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
#
# NOTE: a newly added .sql file is only re-embedded when shomei-migrations/src/Shomei/Migrations.hs
# is RECOMPILED (embedDir is a compile-time Template Haskell splice). Touching the .cabal, as the
# line below does, does NOT force that under cabal >= 3.16, which detects changes by content hash
# rather than mtime. After adding a migration, append a line to the comment block above
# `embeddedFiles` in that module — that is what every migration wave has actually relied on.
# CODD_MIGRATION_DIRS / CODD_EXPECTED_SCHEMA_DIR are read unconditionally by getCoddSettings even
# though we override migrations and skip verification, so we pass harmless placeholders.
migrate:
    touch shomei-migrations/shomei-migrations.cabal
    CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=shomei \
    cabal run shomei-migrate

# The slug is positional: `just new-migration name=x` passes "name=x" AS the slug and is rejected.
# After adding one, append a line to the comment block above `embeddedFiles` in
# shomei-migrations/src/Shomei/Migrations.hs, or the new .sql file is never re-embedded.

# Scaffold a new migration: just new-migration add-something
new-migration name:
    @echo "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug: {{name}}"; exit 1; }
    @ts=$(date -u '+%Y-%m-%d-%H-%M-%S'); \
    f="shomei-migrations/sql-migrations/$ts-{{name}}.sql"; \
    if [ -e "$f" ]; then echo "Refusing to overwrite $f"; exit 1; fi; \
    printf -- '-- codd: in-txn\n\nSET search_path TO shomei, pg_catalog;\n\n' > "$f"; \
    echo "Wrote $f"
