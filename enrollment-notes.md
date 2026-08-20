## 3. `yuke login` reports every poll `403` as "the request was denied" (HIGH — misleads badly)

The poll loop maps **any** `403` from `POST /api/v1/device_codes/token` to `Enroll_Poll.Denied` and prints `yuke login: the request was denied` (`yuke-odin src/relay/control_plane.odin` `enroll_poll_decode`; `src/yuke/cmd_login.odin` poll loop). But the control plane returns `403` for **multiple** distinct reasons, each with a machine-readable `code` in its `application/problem+json` body:

- `ACCESS_DENIED` — the human actually denied it.
- `PLAN_LIMIT` — e.g. *"The Free plan is limited to 2 devices. Revoke one or upgrade."* (`yuke-cloud app/controllers/api/v1/device_codes_controller.rb` → `Device.enroll!` raising `PlanLimitExceeded`, surfaced from `issue`/`redeem!`).

We spent a long time thinking approval/login/Turbo were broken when the real cause was the account being at its device cap — the CLI hid the actual reason. **Fix:** parse the problem `detail`/`code` and print it (e.g. "enrollment failed: <detail>"), and distinguish plan-limit from a real denial. Consider a distinct outcome for `PLAN_LIMIT` so the exit message is actionable.

## 5. After login we must restart the daemon service but user has no feedback

Auto restart service or prompt user
