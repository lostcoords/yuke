-- Transport wire-shape facts for a model, derived from the models.dev npm package:
-- the output-token field name and the responses dialect. Stored as the closed enum
-- ordinal. Only complete-model rows carry them; override rows leave them NULL.
ALTER TABLE catalog_models ADD COLUMN max_tokens_field INTEGER
    CHECK (max_tokens_field IS NULL OR (typeof(max_tokens_field) = 'integer' AND max_tokens_field >= 0));

ALTER TABLE catalog_models ADD COLUMN responses_dialect INTEGER
    CHECK (responses_dialect IS NULL OR (typeof(responses_dialect) = 'integer' AND responses_dialect >= 0));
