// A plugin types its own capability by merging into the `Capabilities` interface of `yuke`.
declare module "yuke" {
  interface Capabilities {
    counter: { count(): number };
  }
}
export {};
