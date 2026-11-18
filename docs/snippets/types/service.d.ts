import "yuke:plugins";

declare module "yuke:plugins" {
  interface Services {
    "example.counter.v1": {
      count: () => number;
    };
  }
}
