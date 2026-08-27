SET search_path TO shomei, pg_catalog;

-- Which credential the attempt proved or failed to prove; every pre-existing row was a password
-- attempt. Counting stays by outcome (all factors share one lockout), so 0011's indexes stay right.
ALTER TABLE shomei_login_attempts
  ADD COLUMN IF NOT EXISTS factor text NOT NULL DEFAULT 'password';
