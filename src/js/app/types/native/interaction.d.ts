declare module "yuke:internal/native/interaction" {
  export const native: {
    readonly maxTextBytes: number;
    readonly maxOptions: number;
    validateSignal(signal: { aborted: boolean }): void;
    sessionId(signal: { aborted: boolean }): string | null;
    request(id: number, requestJson: string, signal?: { aborted: boolean }): Promise<unknown>;
    notify(source: string, message: string, level: string): void;
    cancel(id: number): boolean;
  };
}
