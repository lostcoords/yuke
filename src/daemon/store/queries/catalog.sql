-- name: Delete_Catalog_Provider :exec
-- provider_id: string!
-- source: string!
DELETE FROM catalog_providers
    WHERE provider_id = :provider_id AND source = :source;

-- name: Delete_Catalog_Source :exec
-- source: string!
DELETE FROM catalog_providers WHERE source = :source;

-- name: Catalog_Source_Size :one
-- source: string!
-- providers: u64!
-- models: u64!
SELECT
    (SELECT count(*) FROM catalog_providers WHERE source = :source) AS providers,
    (SELECT count(*) FROM catalog_models WHERE source = :source) AS models;

-- name: Insert_Catalog_Provider :exec
-- provider_id: string!
-- source: string!
-- models_dev_id: string
-- name: string
-- base_url: string
-- protocol: string
-- etag: string
INSERT INTO catalog_providers(
    provider_id, source, models_dev_id, name, base_url, protocol, etag
)
VALUES (
    :provider_id, :source, :models_dev_id, :name, :base_url, :protocol, :etag
);

-- name: Insert_Catalog_Provider_Env :exec
-- provider_id: string!
-- source: string!
-- ordinal: int!
-- name: string!
INSERT INTO catalog_provider_env(provider_id, source, ordinal, name)
VALUES (:provider_id, :source, :ordinal, :name);

-- name: Insert_Catalog_Model :exec
-- public_model_id: string!
-- provider_id: string!
-- source: string!
-- kind: string!
-- upstream_id: string
-- name: string
-- context_window: u64
-- max_output_tokens: u64
-- base_url: string
-- protocol: string
-- supports_temperature: bool
-- reasoning_replay: string
-- reasoning_format: string
-- max_tokens_field: string
-- reasoning_budget_min: i64
-- reasoning_budget_max: u64
-- supports_vision: bool
-- supports_tools: bool
-- cost_input: f64
-- cost_output: f64
-- cost_cache_read: f64
-- cost_cache_write: f64
INSERT INTO catalog_models(
    public_model_id, provider_id, source, kind,
    upstream_id, name, context_window, max_output_tokens,
    base_url, protocol, supports_temperature,
    reasoning_replay, reasoning_format, max_tokens_field,
    reasoning_budget_min, reasoning_budget_max,
    supports_vision, supports_tools,
    cost_input, cost_output, cost_cache_read, cost_cache_write
)
VALUES (
    :public_model_id, :provider_id, :source, :kind,
    :upstream_id, :name, :context_window, :max_output_tokens,
    :base_url, :protocol, :supports_temperature,
    :reasoning_replay, :reasoning_format, :max_tokens_field,
    :reasoning_budget_min, :reasoning_budget_max,
    :supports_vision, :supports_tools,
    :cost_input, :cost_output, :cost_cache_read, :cost_cache_write
);

-- name: Insert_Catalog_Model_Level :exec
-- public_model_id: string!
-- source: string!
-- kind: string!
-- ordinal: int!
-- level: string!
INSERT INTO catalog_model_reasoning_levels(
    public_model_id, source, kind, ordinal, level
)
VALUES (:public_model_id, :source, :kind, :ordinal, :level);
