-- name: DeleteProviders :exec
DELETE FROM catalog_providers;

-- name: DeleteModels :exec
DELETE FROM catalog_models;

-- name: InsertProvider :exec
-- id: []const u8!
-- data: []const u8!
INSERT INTO catalog_providers (id, data) VALUES (:id, :data);

-- name: InsertModel :exec
-- id: []const u8!
-- provider_id: []const u8!
-- data: []const u8!
INSERT INTO catalog_models (id, provider_id, data) VALUES (:id, :provider_id, :data);

-- name: SetEtag :exec
-- v: []const u8!
INSERT OR REPLACE INTO catalog_meta (k, v) VALUES ('etag', :v);

-- name: SelectProviders :many
-- data: []const u8!
SELECT data FROM catalog_providers ORDER BY id;

-- name: SelectModels :many
-- provider_id: []const u8!
-- data: []const u8!
SELECT data FROM catalog_models WHERE provider_id = :provider_id ORDER BY id;

-- name: GetEtag :optional
-- v: []const u8!
SELECT v FROM catalog_meta WHERE k = 'etag';
