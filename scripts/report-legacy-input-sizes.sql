-- Read-only counts, no submitted identifiers or credential data. Run with psql -f.
BEGIN READ ONLY;
SELECT 'user.login_id' AS field, count(*) AS oversized_rows FROM shomei.shomei_users WHERE char_length(login_id) > 256
UNION ALL SELECT 'user.email', count(*) FROM shomei.shomei_users WHERE octet_length(email) > 254
UNION ALL SELECT 'user.display_name', count(*) FROM shomei.shomei_users WHERE char_length(display_name) > 256
UNION ALL SELECT 'credential.login_id', count(*) FROM shomei.shomei_password_credentials WHERE char_length(login_id) > 256
UNION ALL SELECT 'credential.email', count(*) FROM shomei.shomei_password_credentials WHERE octet_length(email) > 254
UNION ALL SELECT 'passkey.label', count(*) FROM shomei.shomei_webauthn_credentials WHERE char_length(label) > 128
UNION ALL SELECT 'role', count(*) FROM shomei.shomei_roles WHERE char_length(role) > 128
UNION ALL SELECT 'oauth_client.scope', count(*) FROM shomei.shomei_oauth_clients c, jsonb_array_elements_text(c.allowed_scopes) s(value) WHERE char_length(value) > 128
UNION ALL SELECT 'service_account.scope', count(*) FROM shomei.shomei_service_accounts c, jsonb_array_elements_text(c.allowed_scopes) s(value) WHERE char_length(value) > 128;
COMMIT;
