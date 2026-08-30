declare module "yuke:client-native" {
  type ConnState = "disconnected" | "connecting" | "ready" | "closing";

  type ClientEvent =
    | { type: "conn"; key: string; kind: "ready" | "close" }
    | {
        type: "session";
        connKey: string;
        sessionId: string;
        kind: "gone" | "reload" | "active";
        id?: number;
      }
    | { type: "index"; connKey: string; [k: string]: unknown };

  interface SessionOutline {
    messages: Array<{
      id: number;
      type: "user" | "assistant" | "compaction";
      error?: { type: string; message: string };
    }>;
    active: { id: number; type: "assistant" } | null;
  }

  export const native: {
    setEventSink(fn: (ev: ClientEvent) => void): void;
    connect(opts: { remote?: boolean; host?: string; port?: number; device?: string }): Promise<void>;
    disconnect(connKey: string): void;
    state(connKey: string): ConnState;
    connections(): Array<{ key: string; state: ConnState }>;
    devices(): Promise<unknown[]>;
    request(connKey: string, method: string, paramsJson: string): Promise<string>;
    sessionOpen(connKey: string, sessionId: string): void;
    sessionClose(connKey: string, sessionId: string): void;
    sessionRev(connKey: string, sessionId: string): number;
    sessionResync(connKey: string, sessionId: string): Promise<void>;
    sessionOutline(connKey: string, sessionId: string): string;
    sessionText(connKey: string, sessionId: string, messageId: number): string;
    sessionParts(connKey: string, sessionId: string, messageId: number): string;
  };

  export { ConnState, ClientEvent, SessionOutline };
}
