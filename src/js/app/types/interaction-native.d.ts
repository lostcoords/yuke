declare module "yuke:interaction-native" {
  export const native: {
    readonly maxTextBytes: number;
    readonly maxOptions: number;
    request(id: number, requestJson: string): Promise<unknown>;
    cancel(id: number): boolean;
  };
}
