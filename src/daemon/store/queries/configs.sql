-- name: Clear_Configs :exec
-- session_id: wire.Session_Id!
DELETE FROM session_configs WHERE session_id = :session_id;

-- name: Set_Prompt :exec
-- A null writes no row, which reads back as `system_prompt: null`.
-- session_id: wire.Session_Id!
-- prompt: string
INSERT OR REPLACE INTO session_prompts(session_id, prompt)
    SELECT :session_id, :prompt WHERE :prompt IS NOT NULL;

-- name: Session_Configs :many
-- Every announced config revision for the session, oldest first, so resync and
-- `session.config` resolve a message's `config_rev` without folding the log.
-- session_id: wire.Session_Id!
-- config_rev: wire.Config_Rev!
-- model: string!
-- reasoning: string!
SELECT config_rev, model, reasoning FROM session_configs
    WHERE session_id = :session_id
    ORDER BY config_rev;
