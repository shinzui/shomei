# Justfile — Shōmei project recipes.
# EP-3 extends create-database with real migration logic.

# Build all packages in the cabal workspace.
build:
    cabal build all

# Create the shomei database. Called by process-compose.yaml via:
#   create_schema: command: just create-database
# EP-3 replaces this stub with real schema creation and migration steps.
create-database:
    psql -c "CREATE DATABASE shomei;" || echo "Database already exists, skipping."
