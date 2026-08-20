# 2026-08-16 — relay shows the daemon offline after SSH disconnect (systemd --user without linger)

Not a yuke bug — an operational/deployment gotcha. Recorded for the FAQ.

## Symptom

On a remote box (awou, Ubuntu) reached over SSH, the daemon is reachable and the relay shows it
**online** the whole time you are logged in. The moment you disconnect the SSH session, the relay
shows **awou offline**, and you can no longer reach the daemon through the relay — even though you
never stopped the service. Logging back in over SSH brings it back.

Locally on the machine you can always reach `127.0.0.1:9853`; only the relay view is affected while
you are connected, and everything drops on logout.

## Cause

`yuke-daemon.service` is a **`systemd --user`** unit, and lingering was off:

```
$ loginctl show-user "$USER" -p Linger
Linger=no
$ loginctl list-sessions
SESSION  UID USER   STATE
     37 1000 xyaman active     # the SSH connection is the ONLY session
```

Without linger, systemd binds your per-user manager (`user@<uid>.service`) to your login sessions:
it starts the manager when your first session opens and **tears it down when your last session
closes**. The SSH connection was the only session, so logging out stopped `user@1000.service`,
which stopped `yuke-daemon.service`, which dropped the outbound relay link → the relay marked the
device offline.

Proof it restarts per-login, not persistent: right after connecting, both `user@1000.service` and
the daemon PID reported the *same* start timestamp ("active since … ; 69ms ago") — the daemon comes
up on login and dies on logout.

`enabled` is a red herring here: the user's `default.target` only exists while the user manager is
running, which without linger is only during a login session.

Contrast with macOS: there the daemon runs under `launchd` (PPID 1), which is not session-bound, so
it survives SSH/terminal disconnects with no extra configuration. `systemd --user` **is**
session-bound unless you opt out with linger.

## Fix

Enable lingering for the user (once per machine; may need sudo depending on polkit):

```
loginctl enable-linger "$USER"
# verify:
loginctl show-user "$USER" -p Linger     # -> Linger=yes
```

This keeps the user manager (and its units) running at boot and across logout. Since the unit is
already `enabled` (`WantedBy=default.target`), the daemon now starts at boot and stays up regardless
of SSH. Applied on awou 2026-08-16; confirmed the relay stays online after disconnect.

The lighter, correct fix is linger — **not** converting to a root/system service. The daemon binds
loopback and dials out to the relay, so it needs no root. A system unit under
`/etc/systemd/system/` (root or a dedicated service user) is the alternative if you specifically
want it decoupled from the login user, but that is a bigger change and unnecessary here.

## FAQ phrasing

**Q: My daemon goes offline in the relay whenever I disconnect SSH, but I never stopped it. Why?**

A: It is running as a `systemd --user` service and lingering is off, so systemd stops your user
services when your last login session ends. Run `loginctl enable-linger $USER` (verify with
`loginctl show-user $USER -p Linger`). This does not happen on macOS because the daemon runs under
launchd, which is not tied to your login session.
