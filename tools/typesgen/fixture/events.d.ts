// A plugin types its own events by merging into the `Events` interface of `yuke`.
declare module "yuke" {
  interface Events {
    "demo:ping"(count: number): void;
  }
}
export {};
