-- enforce-session-provenance-upgrades

SET LOCAL search_path = pg_catalog, pg_temp;

-- 0029 defaulted pre-provenance rows (and omitted-kind writes) to interactive.
-- Recover non-interactive provenance from authoritative associations before enforcing it.
-- Every real interactive mint persists a refresh token atomically with the session;
-- pre-provenance machines/delegations have none. Missing evidence requires a new login.
UPDATE shomei.shomei_sessions
SET kind = 'delegated'
WHERE actor_user_id IS NOT NULL AND kind IS DISTINCT FROM 'delegated';

UPDATE shomei.shomei_sessions AS s
SET kind = 'machine'
WHERE s.actor_user_id IS NULL
  AND s.kind = 'interactive'
  AND (
    EXISTS (SELECT 1 FROM shomei.shomei_service_accounts AS a WHERE a.user_id = s.user_id)
    OR NOT EXISTS (SELECT 1 FROM shomei.shomei_refresh_tokens AS r WHERE r.session_id = s.session_id)
  );

-- Explicit NULL has no trustworthy provenance. Preserve the session's ordinary access
-- lifetime but deny interactive authorization; the owner can authenticate again.
UPDATE shomei.shomei_sessions SET kind = 'machine' WHERE kind IS NULL;

-- Old or direct SQL writers that omit provenance must never manufacture an interactive
-- session. Current interpreters always supply a kind. Stop old issuers during upgrade.
ALTER TABLE shomei.shomei_sessions ALTER COLUMN kind SET DEFAULT 'machine';
ALTER TABLE shomei.shomei_sessions ALTER COLUMN kind SET NOT NULL;
ALTER TABLE shomei.shomei_sessions ADD CONSTRAINT shomei_sessions_kind_check
  CHECK (kind IN ('interactive', 'machine', 'delegated'));
