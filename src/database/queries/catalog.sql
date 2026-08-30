-- name: DeleteProviders :exec
DELETE FROM catalog_providers;

-- name: InsertProvider :exec
-- id: []const u8!
-- data: []const u8!
INSERT INTO catalog_providers (id, data) VALUES (:id, :data);

-- name: SetEtag :exec
-- v: []const u8!
INSERT OR REPLACE INTO catalog_meta (k, v) VALUES ('etag', :v);

-- name: SetRev :exec
-- v: []const u8!
INSERT OR REPLACE INTO catalog_meta (k, v) VALUES ('rev', :v);

-- name: SelectProvider :optional
-- id: []const u8!
-- data: []const u8!
SELECT data FROM catalog_providers WHERE id = :id;

-- name: GetEtag :optional
-- v: []const u8!
SELECT v FROM catalog_meta WHERE k = 'etag';

-- name: GetRev :optional
-- v: []const u8!
SELECT v FROM catalog_meta WHERE k = 'rev';
