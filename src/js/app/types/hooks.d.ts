declare module "yuke:hooks" {
  export function installDispatcher(dispatch: (point: string, payload: any) => Promise<unknown>): void;
  export function installInputGate(gate: (params: any, method?: "session.send_input" | "session.create") => Promise<unknown>): void;
  export function setPoints(names: string[]): void;
}
