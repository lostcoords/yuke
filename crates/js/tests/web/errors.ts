// The error checks that the web tests share.

import { assert, rejects, throws } from "yuke:test";

/** The name of the error that `fn` throws. A function that returns fails the test. */
export function thrownName(fn: () => unknown): string {
  const error = throws(fn);
  assert(error instanceof Error, "the function throws an Error");
  return error.name;
}

/** The name of the error that each call throws. A call that returns fails the test. */
export function thrownNames(calls: (() => unknown)[]): string[] {
  return calls.map(thrownName);
}

/** The name of the error that `promise` rejects with. A promise that fulfills fails the test. */
export async function rejectedName(promise: Promise<unknown>): Promise<string> {
  const error = await rejects(promise);
  assert(error instanceof Error, "the promise rejects with an Error");
  return error.name;
}
