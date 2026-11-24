# credentials

The credential files of the yuke coding agent. Unix only.

- `CredentialFile::new(folder, "auth")` names `auth.json`, its lock file `auth.lock`, and its temporary file
  `auth.json.tmp`. `auth.json` holds the logins of the providers, and `mcp-auth.json` holds the logins of the MCP
  servers.
- `CredentialFile::read` gives the JSON of the file. A missing file gives the default value. A read takes no lock,
  because a write replaces the file whole.
- `CredentialFile::lock` takes the lock file, and it blocks until the holder drops its `Locked`. Only a `Locked` writes.
  The lock file is its own file, because the rename of a write changes the file of the JSON.
- `Locked::write` writes the temporary file, syncs it, and renames it over the JSON file. After a crash, the file is
  whole or the old one. The files have the mode 0600.
- A `FileError` names the path. Its `source` is the cause, so print it with a chain printer.
