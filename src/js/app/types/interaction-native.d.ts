declare module "yuke:interaction-native" {
  export const native: {
    readonly maxTextBytes: number;
    readonly maxOptions: number;
    watchCancellation(id: number, signal: { aborted: boolean }): Promise<unknown>;
    sessionId(signal: { aborted: boolean }): string | null;
    request(id: number, requestJson: string, signal?: { aborted: boolean }): Promise<unknown>;
    notify(source: string, message: string, level: string): void;
    cancel(id: number): boolean;
  };
}
