-- name: Clear_Configs :exec
-- session_id: wire.Session_Id!
DELETE FROM session_configs WHERE session_id = :session_id;

-- name: Set_Session_Config :exec
-- A config announcement also becomes the session's future-run default.
-- session_id: wire.Session_Id!
-- config_rev: wire.Config_Rev!
-- model: string!
-- reasoning: string!
UPDATE sessions
    SET config_rev = :config_rev, model = :model, reasoning = :reasoning
    WHERE id = :session_id;

-- name: Set_Prompt :exec
-- A null writes no row, which reads back as `system_prompt: null`.
-- session_id: wire.Session_Id!
-- prompt: string
INSERT OR REPLACE INTO session_prompts(session_id, prompt)
    SELECT :session_id, :prompt WHERE :prompt IS NOT NULL;

-- name: Session_Prompt :one
-- The prompt a run sends. No row means none was set, which is not an error.
-- session_id: wire.Session_Id!
-- prompt: string!
SELECT prompt FROM session_prompts WHERE session_id = :session_id;

-- name: Session_Config :one
-- session_id: wire.Session_Id!
-- requested_rev: wire.Config_Rev!
-- config_rev: wire.Config_Rev!
-- model: string!
-- reasoning: string!
SELECT config_rev, model, reasoning FROM session_configs
    WHERE session_id = :session_id AND config_rev = :requested_rev;
