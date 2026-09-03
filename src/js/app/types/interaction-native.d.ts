declare module "yuke:interaction-native" {
  export const native: {
    readonly maxTextBytes: number;
    readonly maxOptions: number;
    request(id: number, requestJson: string): Promise<unknown>;
    notify(source: string, message: string, level: string): void;
    cancel(id: number): boolean;
  };
}
