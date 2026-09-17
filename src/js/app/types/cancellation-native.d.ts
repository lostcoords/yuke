declare module "yuke:cancellation-native" {
  const brand: unique symbol;
  export interface CancellationSignal {
    readonly [brand]: true;
    readonly aborted: boolean;
  }
  export function create(): CancellationSignal;
  export function cancel(signal: CancellationSignal): void;
  export function drain(signal: CancellationSignal): Promise<void>;
}
