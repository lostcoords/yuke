// Framework-free attach: register the broadcast queue first so subscribe/resync
// cannot drop the RTT's notifications, then snapshot and pump into a replica.
import { ClosedError } from "./errors.js";
import { SessionReplica } from "./session.js";
export async function attach(client, sessionId, options = {}) {
    const replica = new SessionReplica(sessionId);
    const stream = client.broadcasts({ signal: options.signal });
    await client.request("subscription.set", { sessions: [sessionId] });
    replica.installSnapshot(await client.request("session.resync", { session_id: sessionId }));
    const done = (async () => {
        try {
            for await (const event of stream) {
                const result = replica.applyBroadcast(event);
                if (result.kind !== "gap")
                    continue;
                replica.installSnapshot(await client.request("session.resync", { session_id: sessionId }));
            }
        }
        catch (error) {
            if (error instanceof ClosedError)
                return;
            throw error;
        }
    })();
    return { replica, done };
}
//# sourceMappingURL=attach.js.map