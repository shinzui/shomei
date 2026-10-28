-- remembered-sessions

SET LOCAL search_path = pg_catalog, pg_temp;

-- Whether the person asked to stay signed in when this session began. A remembered session gets
-- the longer remembered lifetime, and its embedder keeps its cookies across browser restarts.
-- Rows that predate the column default to true, so their cookies stay persistent as before.
ALTER TABLE shomei.shomei_sessions
  ADD COLUMN IF NOT EXISTS remembered boolean NOT NULL DEFAULT true;
