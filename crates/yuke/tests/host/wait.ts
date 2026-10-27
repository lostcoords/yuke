// A wait for the tests of the test host.

/** Wait until `done` holds, for a state that the host reaches in the background. Fail after one second. */
export async function waitFor(done: () => boolean): Promise<void> {
  for (let tries = 0; !done(); tries += 1) {
    if (tries === 200) throw new Error("the state never came");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
