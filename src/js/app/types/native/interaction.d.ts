declare module "yuke:internal/native/interaction" {
  import type { CancellationSignal } from "yuke:internal/native/cancellation";

  export const native: {
    readonly maxTextBytes: number;
    readonly maxOptions: number;
    validateSignal(signal: CancellationSignal): void;
    sessionId(signal: CancellationSignal): string | null;
    request(id: number, requestJson: string, signal?: CancellationSignal): Promise<unknown>;
    notify(source: string, message: string, level: string): void;
    cancel(id: number): boolean;
  };
}
