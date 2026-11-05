-- Bound new/changed values without rechecking unchanged legacy identity fields.
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION shomei.enforce_field_budgets() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  incoming jsonb := to_jsonb(NEW);
  previous jsonb := '{}'::jsonb;
  field text;
  budget integer;
BEGIN
  IF TG_OP = 'UPDATE' THEN previous := to_jsonb(OLD); END IF;
  FOREACH field IN ARRAY ARRAY['login_id', 'email', 'display_name', 'label', 'role'] LOOP
    IF incoming ? field AND incoming->field IS DISTINCT FROM previous->field THEN
      budget := CASE field WHEN 'login_id' THEN 256 WHEN 'email' THEN 254
                WHEN 'display_name' THEN 256 ELSE 128 END;
      IF (CASE WHEN field = 'email' THEN octet_length(incoming->>field)
               ELSE char_length(incoming->>field) END) > budget THEN
        RAISE EXCEPTION 'field size exceeds new-write budget' USING ERRCODE = '22001';
      END IF;
    END IF;
  END LOOP;
  IF incoming ? 'allowed_scopes' AND incoming->'allowed_scopes' IS DISTINCT FROM previous->'allowed_scopes' THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(incoming->'allowed_scopes') AS s(value)
               WHERE char_length(value) > 128) THEN
      RAISE EXCEPTION 'scope size exceeds new-write budget' USING ERRCODE = '22001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_users
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_password_credentials
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_webauthn_credentials
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_roles
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_role_grants
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_oauth_clients
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
CREATE TRIGGER enforce_field_budgets BEFORE INSERT OR UPDATE ON shomei.shomei_service_accounts
  FOR EACH ROW EXECUTE FUNCTION shomei.enforce_field_budgets();
