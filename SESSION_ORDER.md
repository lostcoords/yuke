# Session order at startup

Sort sessions by `max(last user message commit time, last assistant turn end time)`, newest first.

Expose this timestamp in the session summary and use it for list pagination. Do not use intermediate assistant message commits, tool events, manual compaction, config changes, or session selection.

The GUI applies this rule to live events. It uses receipt time for a user commit because the RPC payload has no commit timestamp. It uses `run.done.timing.ended_at_ms` for a run with `kind: "turn"`. Startup still uses `updated_at_ms` as a temporary fallback.
