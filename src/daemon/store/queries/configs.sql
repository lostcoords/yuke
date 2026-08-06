-- name: Clear_Configs :exec
-- session_id: wire.Session_Id!
DELETE FROM session_configs WHERE session_id = :session_id;

-- name: Set_Prompt :exec
-- A null writes no row, which reads back as `system_prompt: null`.
-- session_id: wire.Session_Id!
-- prompt: string
INSERT OR REPLACE INTO session_prompts(session_id, prompt)
    SELECT :session_id, :prompt WHERE :prompt IS NOT NULL;
