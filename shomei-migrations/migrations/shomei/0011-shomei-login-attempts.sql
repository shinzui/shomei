SET LOCAL search_path = pg_catalog, pg_temp;

CREATE TABLE IF NOT EXISTS shomei.shomei_login_attempts (
  attempt_id  uuid PRIMARY KEY,
  account_key text NOT NULL,
  client_ip   text NOT NULL,
  outcome     text NOT NULL,
  occurred_at timestamptz NOT NULL
);

-- Windowed counting reads "failures since cutoff" by account and by IP, so index both
-- (key, occurred_at) pairs; partial on failures keeps the index small and hot.
CREATE INDEX IF NOT EXISTS shomei_login_attempts_account_failures_idx
  ON shomei.shomei_login_attempts (account_key, occurred_at)
  WHERE outcome = 'failure';

CREATE INDEX IF NOT EXISTS shomei_login_attempts_ip_failures_idx
  ON shomei.shomei_login_attempts (client_ip, occurred_at)
  WHERE outcome = 'failure';

-- Counter-reset-on-success reads "most recent success for an account", so index successes too.
CREATE INDEX IF NOT EXISTS shomei_login_attempts_account_successes_idx
  ON shomei.shomei_login_attempts (account_key, occurred_at)
  WHERE outcome = 'success';
