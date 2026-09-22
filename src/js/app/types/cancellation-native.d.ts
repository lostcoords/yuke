declare module "yuke:cancellation-native" {
  const brand: unique symbol;
  export interface CancellationSignal {
    readonly [brand]: true;
    readonly aborted: boolean;
  }
  export function create(): CancellationSignal;
  export function cancel(signal: CancellationSignal): void;
  export function drain(signal: CancellationSignal): Promise<void>;
  /** Calls `callback` once when the signal is canceled. A canceled signal throws; check `aborted` first. */
  export function listen(signal: CancellationSignal, callback: () => void): number;
  /** Removes a listener. A heard or removed id is safe to pass again. */
  export function unlisten(id: number): void;
}
