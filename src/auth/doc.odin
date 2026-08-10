/*
Provider authentication owned by the daemon.

`Store` is the private, versioned `auth.json` credential database. OAuth adapters
produce credentials for it, while wire types expose only non-secret login state.
Codex login parsing requires a complete initial token set; refresh parsing instead
merges independently optional token fields and retains the existing account id when
no new ID token is returned.
*/
package auth
