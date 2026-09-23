declare module "yuke:hooks" {
  export function installDispatcher(dispatch: (point: string, payload: any) => Promise<unknown>): void;
  export function installLifecycle(callback: (force: boolean) => void | Promise<void>): number;
  export function setPoints(names: string[], changed: string): void;
}
