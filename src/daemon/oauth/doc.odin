/*
Provider authentication owned by the daemon.

OAuth adapters produce credentials for the daemon's private store, while wire types
expose only non-secret login state.
Codex login parsing requires a complete initial token set; refresh parsing instead
merges independently optional token fields and retains the existing account id when
no new ID token is returned.
*/
package oauth
