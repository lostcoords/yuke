-- name: Upsert_Api_Key :exec
-- provider_id: string!
-- api_key: string!
INSERT OR REPLACE INTO provider_credentials(provider_id, kind, api_key)
VALUES (:provider_id, 'api_key', :api_key);

-- name: Upsert_OAuth :exec
-- provider_id: string!
-- access_token: string!
-- refresh_token: string!
-- expires_at_ms: u64!
-- account_id: string
INSERT OR REPLACE INTO provider_credentials(
    provider_id, kind, access_token, refresh_token, expires_at_ms, account_id
)
VALUES (
    :provider_id, 'oauth', :access_token, :refresh_token, :expires_at_ms, :account_id
);

-- name: Remove_Credential :exec
-- provider_id: string!
DELETE FROM provider_credentials WHERE provider_id = :provider_id;
