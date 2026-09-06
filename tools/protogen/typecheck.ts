import { client } from "../../src/js/app/client.js";

type Equal<A, B> = [A, B] extends [B, A] ? true : false;
type Assert<T extends true> = T;
type MethodNames = Assert<Equal<keyof Wire.Methods, Wire.MethodName>>;
type BroadcastNames = Assert<Equal<keyof Wire.Broadcasts, Wire.BroadcastName>>;

async function requests() {
  const initialized = await client.request("initialize");
  const protocol: number = initialized.protocol;
  const listed = await client.request("session.list", { limit: 3 });
  const rows: ReadonlyArray<Wire.SessionListItem> = listed.items;
  const created = await client.request("session.create", { workspace_path: "/tmp" });
  const session: Wire.Session = created.session;
  await client.request("session.get", { session_id: session.id });
  await client.request("session.history", { session_id: session.id, before_message_id: 0 });
  // @ts-expect-error The result must not degrade to any.
  listed.missing;
  // @ts-expect-error Each method has its own result type.
  const incorrect: Wire.SessionSendInputResult = listed;
  // @ts-expect-error A session requires a workspace path.
  client.request("session.create");
  // @ts-expect-error An empty create payload is invalid.
  client.request("session.create", {});
  // @ts-expect-error The get method needs a session id.
  client.request("session.get", { limit: 3 });
  // @ts-expect-error History requires a cursor.
  client.request("session.history", { session_id: session.id });
  // @ts-expect-error The method set is closed.
  client.request("session.typo", {});
  // @ts-expect-error Skills have no RPC contract yet.
  client.request("skill.list", {});
  // @ts-expect-error Empty parameters reject primitives.
  client.request("initialize", 42);
  // @ts-expect-error A method takes at most one payload.
  client.request("initialize", {}, {});
}

function notification(event: Wire.Notification) {
  if (event.method === "message.part_delta") {
    const delta: Wire.PartDelta = event.params;
    const offset: number = event.params.offset;
    // @ts-expect-error A delta has no interaction response.
    event.params.response;
  }
  if (event.method === "interaction.requested") {
    const id: number = event.params.interaction_id;
    const session: string | null | undefined = event.params.session_id;
  }
}

const canceled: Wire.InteractionResponse = { type: "canceled" };
const root: Wire.SessionOrigin = { type: "root" };
const pending: Wire.ToolState = { type: "pending" };
const empty: Wire.Empty = {};
// @ts-expect-error Empty objects reject nonempty payloads.
const notEmpty: Wire.Empty = { value: 1 };
// @ts-expect-error Empty objects reject primitive values.
const primitive: Wire.Empty = 1;
// @ts-expect-error The discriminator determines the notification payload.
const mismatched: Wire.Notification = { method: "interaction.requested", params: { level: "info", source: "test", message: "hello" } };
