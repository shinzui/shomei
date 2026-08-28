-- Create the dedicated Shōmei namespace. Idempotent.
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE SCHEMA IF NOT EXISTS shomei;
